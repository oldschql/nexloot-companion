-- =====================================================================
-- NexLoot – Datenbank für Webapp und Companion-App (Supabase)
-- Einmal komplett im Supabase "SQL Editor" ausführen (Run).
-- Vorher unten bei  >>> SCHREIB-PASSWORT <<<  ein eigenes Passwort eintragen.
-- Das Skript kann gefahrlos noch einmal ausgeführt werden (z. B. um das Passwort zu ändern).
--
-- English: run this whole file once in the Supabase "SQL Editor" (Run).
-- Before that, at the very bottom, replace 'MyGuild' with your guild ID and
-- HIER-EIN-LANGES-PASSWORT with a long write password of your own.
-- Safe to run again, e.g. to change the password.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- Aktueller Stand pro Gilde (Coins, Historie, Sessions, Rechte, Item-Namen, Klassen)
create table if not exists public.nexloot_state (
  guild       text primary key,
  rev         bigint      not null default 0,
  data        jsonb       not null default '{}'::jsonb,
  updated_at  timestamptz not null default now(),
  updated_by  text
);

-- Sicherungen: jeder neue Stand wird zusätzlich hier abgelegt (die letzten 300 pro Gilde)
create table if not exists public.nexloot_snapshots (
  id          bigserial primary key,
  guild       text        not null,
  rev         bigint      not null,
  data        jsonb       not null,
  created_at  timestamptz not null default now(),
  created_by  text
);
create index if not exists nexloot_snapshots_guild_idx on public.nexloot_snapshots (guild, id desc);

-- Schreib-Passwort (nur als Hash gespeichert, für niemanden lesbar)
create table if not exists public.nexloot_secret (
  guild       text primary key,
  pw_hash     text not null
);

-- Zugriffsrechte: lesen darf jeder (Webapp), schreiben nur über die Funktionen unten
alter table public.nexloot_state     enable row level security;
alter table public.nexloot_snapshots enable row level security;
alter table public.nexloot_secret    enable row level security;

drop policy if exists "nexloot lesen" on public.nexloot_state;
create policy "nexloot lesen" on public.nexloot_state for select to anon, authenticated using (true);
-- nexloot_snapshots und nexloot_secret: keine Policy = für anon/authenticated weder lesbar noch schreibbar

grant usage on schema public to anon, authenticated;
grant select on public.nexloot_state to anon, authenticated;
revoke insert, update, delete on public.nexloot_state from anon, authenticated;
revoke all on public.nexloot_snapshots from anon, authenticated;
revoke all on public.nexloot_secret from anon, authenticated;

-- ---------------------------------------------------------------------
-- Passwort prüfen (intern)
-- ---------------------------------------------------------------------
create or replace function public.nexloot_check(p_guild text, p_secret text)
returns void
language plpgsql security definer
set search_path = public, extensions
as $$
declare h text;
begin
  select pw_hash into h from public.nexloot_secret where guild = p_guild;
  if h is null or p_secret is null or extensions.crypt(p_secret, h) <> h then
    raise exception 'NexLoot: falsches Schreib-Passwort' using errcode = '28P01';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Neuen Stand hochladen. Wird nur übernommen, wenn p_rev größer ist als der gespeicherte Stand.
-- Antwort: {"ok": true/false, "rev": <Stand in der Datenbank>}
-- ---------------------------------------------------------------------
create or replace function public.nexloot_push(p_guild text, p_rev bigint, p_data jsonb, p_by text, p_secret text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare cur bigint;
begin
  perform public.nexloot_check(p_guild, p_secret);
  if p_rev is null or p_rev < 1 or p_data is null or jsonb_typeof(p_data) <> 'object' then
    raise exception 'NexLoot: ungültige Daten';
  end if;
  select rev into cur from public.nexloot_state where guild = p_guild for update;
  if cur is not null and p_rev <= cur then
    return jsonb_build_object('ok', false, 'rev', cur);
  end if;
  insert into public.nexloot_state as s (guild, rev, data, updated_at, updated_by)
    values (p_guild, p_rev, p_data, now(), p_by)
    on conflict (guild) do update set rev = excluded.rev, data = excluded.data,
      updated_at = excluded.updated_at, updated_by = excluded.updated_by
    where s.rev < excluded.rev;
  insert into public.nexloot_snapshots (guild, rev, data, created_by) values (p_guild, p_rev, p_data, p_by);
  delete from public.nexloot_snapshots
    where guild = p_guild and id < (select min(id) from (select id from public.nexloot_snapshots
      where guild = p_guild order by id desc limit 300) k);
  return jsonb_build_object('ok', true, 'rev', p_rev);
end $$;

-- Passwort testen (Knopf "Verbindung testen" in der Companion-App)
create or replace function public.nexloot_auth(p_guild text, p_secret text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  perform public.nexloot_check(p_guild, p_secret);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Item-Namen, Klassen und Sessions ergänzen, ohne den Stand zu ändern
-- ---------------------------------------------------------------------
create or replace function public.nexloot_extras(p_guild text, p_items jsonb, p_classes jsonb, p_sessions jsonb, p_secret text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  perform public.nexloot_check(p_guild, p_secret);
  update public.nexloot_state set data = data
      || jsonb_build_object('items', coalesce(data->'items', '{}'::jsonb) || coalesce(p_items, '{}'::jsonb))
      || jsonb_build_object('classes', coalesce(data->'classes', '{}'::jsonb) || coalesce(p_classes, '{}'::jsonb))
      || case when p_sessions is null then '{}'::jsonb else jsonb_build_object('sessions', p_sessions) end,
    updated_at = now()
  where guild = p_guild;
  return jsonb_build_object('ok', found);
end $$;

-- ---------------------------------------------------------------------
-- Notfall: einen älteren Stand aus den Sicherungen zurückholen.
-- Er bekommt eine neue, höhere Stand-Nummer und wird so von allen übernommen.
--   Liste:        select id, rev, created_at, created_by from nexloot_snapshots order by id desc;
--   Zurückholen:  select nexloot_restore('MyGuild', <id>, '<Schreib-Passwort>');
-- ---------------------------------------------------------------------
create or replace function public.nexloot_restore(p_guild text, p_snapshot bigint, p_secret text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare d jsonb; cur bigint;
begin
  perform public.nexloot_check(p_guild, p_secret);
  select data into d from public.nexloot_snapshots where guild = p_guild and id = p_snapshot;
  if d is null then raise exception 'NexLoot: Sicherung % nicht gefunden', p_snapshot; end if;
  select rev into cur from public.nexloot_state where guild = p_guild for update;
  cur := coalesce(cur, 0) + 1;
  return public.nexloot_push(p_guild, cur, d || jsonb_build_object('restoredFrom', p_snapshot), 'Wiederhergestellt', p_secret);
end $$;

revoke all on function public.nexloot_check(text, text) from public, anon, authenticated;
revoke all on function public.nexloot_push(text, bigint, jsonb, text, text) from public;
revoke all on function public.nexloot_extras(text, jsonb, jsonb, jsonb, text) from public;
revoke all on function public.nexloot_restore(text, bigint, text) from public;
revoke all on function public.nexloot_auth(text, text) from public;
grant execute on function public.nexloot_auth(text, text) to anon, authenticated;
grant execute on function public.nexloot_push(text, bigint, jsonb, text, text) to anon, authenticated;
grant execute on function public.nexloot_extras(text, jsonb, jsonb, jsonb, text) to anon, authenticated;
grant execute on function public.nexloot_restore(text, bigint, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Wöchentlicher Coin-Verfall (ab Companion 1.4 / Addon 0.24 macht ihn die Datenbank, nicht mehr das Spiel)
-- Jeden Mittwoch um 5:30 Uhr deutscher Zeit: 10 % von allen Coins (abgerundet).
-- Minus-Stände bleiben, wie sie sind. Verpasste Wochen werden nachgeholt.
-- Steht als "Verfall" in der Historie, bekommt eine neue Stand-Nummer und eine Sicherung.
-- ---------------------------------------------------------------------

-- Letzter Stichtag (Mittwoch 5:30 Europe/Berlin) vor p_now, als Unix-Zeit
create or replace function public.nexloot_decay_boundary(p_now timestamptz default now())
returns bigint
language plpgsql stable
as $$
declare loc timestamp; d timestamp;
begin
  loc := p_now at time zone 'Europe/Berlin';
  d := date_trunc('day', loc)
       - ((extract(isodow from loc)::int - 3 + 7) % 7) * interval '1 day'  -- Mittwoch = 3
       + interval '5 hours 30 minutes';
  if d > loc then d := d - interval '7 days'; end if;
  return extract(epoch from (d at time zone 'Europe/Berlin'))::bigint;
end $$;

create or replace function public.nexloot_decay(p_now timestamptz default now())
returns integer
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  pct    constant int := 10;      -- Prozent pro Woche
  r      record;
  e      record;
  b      bigint;
  last   bigint;
  n      int;
  i      int;
  v      bigint;
  d      jsonb;
  c      jsonb;
  why    text;
  newrev bigint;
  cnt    int := 0;
begin
  b := public.nexloot_decay_boundary(p_now);
  for r in select guild, rev, data from public.nexloot_state order by guild for update loop
    d := r.data;
    if jsonb_typeof(d->'coins') is distinct from 'object' then continue; end if;
    last := coalesce(floor((d->>'lastDecay')::numeric), 0)::bigint;
    if last <= 0 then
      -- noch nie ein Verfall: nur den Stichtag merken (wie das Addon beim ersten Start)
      d := d || jsonb_build_object('lastDecay', b);
    else
      if b - last < 302400 then continue; end if;          -- diese Woche schon erledigt
      n := greatest(1, round((b - last) / 604800.0)::int);  -- Wochen seit dem letzten Verfall
      c := '{}'::jsonb;
      for e in select key, value from jsonb_each(d->'coins') loop
        if jsonb_typeof(e.value) <> 'number' then continue; end if;
        v := floor((e.value #>> '{}')::numeric)::bigint;
        if v > 0 then
          for i in 1..n loop v := (v * (100 - pct)) / 100; end loop;
        end if;
        c := c || jsonb_build_object(e.key, v);
      end loop;
      why := '-' || pct || '%' || case when n > 1 then ' (' || n || ' Wochen)' else '' end;
      d := d || jsonb_build_object(
        'coins', c,
        'history', coalesce(d->'history', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
          't', extract(epoch from p_now)::bigint, 'name', '*', 'id', 0, 'cost', 0, 'key', 'V', 'why', why)),
        'lastDecay', b);
    end if;
    newrev := r.rev + 1;
    d := d || jsonb_build_object('rev', newrev);
    update public.nexloot_state
       set rev = newrev, data = d, updated_at = now(), updated_by = 'Datenbank (Verfall)'
     where guild = r.guild;
    insert into public.nexloot_snapshots (guild, rev, data, created_by) values (r.guild, newrev, d, 'Datenbank (Verfall)');
    delete from public.nexloot_snapshots
      where guild = r.guild and id < (select min(id) from (select id from public.nexloot_snapshots
        where guild = r.guild order by id desc limit 300) k);
    cnt := cnt + 1;
  end loop;
  return cnt;
end $$;

-- Nur die Datenbank selbst (Zeitplan) darf den Verfall auslösen – nicht die Webapp, nicht die Companion-App
revoke all on function public.nexloot_decay(timestamptz) from public, anon, authenticated;
revoke all on function public.nexloot_decay_boundary(timestamptz) from public, anon, authenticated;

-- Zeitplan: alle 15 Minuten nachsehen, ob der Verfall fällig ist (die Funktion macht ihn nur einmal pro Woche).
-- So passt es auch bei Sommer-/Winterzeit, und ein verpasster Lauf wird sofort nachgeholt.
create extension if not exists pg_cron with schema pg_catalog;
select cron.unschedule(jobid) from cron.job where jobname = 'nexloot-verfall';
select cron.schedule('nexloot-verfall', '*/15 * * * *', 'select public.nexloot_decay()');

-- ---------------------------------------------------------------------
-- >>> SCHREIB-PASSWORT <<<   Gilden-Kennung und Passwort hier eintragen.
-- English: put your guild ID and write password here. 'MyGuild' must match config.js
-- and the companion app. Officers enter the same password in the companion app.
-- Dasselbe Passwort tragen die Offiziere in der Companion-App ein. Die Webapp braucht es nicht.
-- ---------------------------------------------------------------------
insert into public.nexloot_secret (guild, pw_hash)
values ('MyGuild', extensions.crypt('HIER-EIN-LANGES-PASSWORT', extensions.gen_salt('bf')))
on conflict (guild) do update set pw_hash = excluded.pw_hash;
