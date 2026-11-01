-- =====================================================================
-- NexLoot – Gildenübersicht und Meilensteine (Addon 0.29, Companion-App 1.7)
-- Einmal im Supabase "SQL Editor" ausführen (Run). Kann gefahrlos noch einmal ausgeführt werden.
-- Braucht die Grundeinrichtung aus nexloot.sql (Schreib-Passwort).
--
-- Die Companion-App eines Offiziers lädt die Gildenliste hoch (Level, Klasse, Rang, zuletzt online,
-- dazu Rolle, Talente und Berufe der Spieler mit NexLoot 0.29). Steigt jemand über Level 25, 40 oder 60,
-- legt die Datenbank genau einen Meilenstein an - auch wenn mehrere Offiziere hochladen. Eine Companion-App
-- mit Discord-Webhook holt neue Meilensteine ab (reserviert sie, damit nur einer postet) und postet sie.
-- Die Webapp liest beide Tabellen (nur lesen).
-- English: optional guild overview and level milestones (add-on 0.29, companion app 1.7).
-- Run this whole file once in the Supabase "SQL Editor" after nexloot.sql. Safe to run again.
-- =====================================================================

create table if not exists public.nexloot_members (
  guild       text    not null,
  name        text    not null,
  level       int     not null default 0,
  class       text,
  rank        text,
  rank_index  int,
  online      boolean not null default false,
  last_seen   bigint,            -- zuletzt online (Unix-Zeit, aus der Gildenliste)
  role        text,              -- T / H / D (wählt der Spieler im Addon)
  talents     text,              -- Punkte pro Baum, z. B. "0/31/20"
  spec        text,              -- Baum mit den meisten Punkten (in der Sprache des Spielers)
  profs       jsonb,             -- Berufe mit Stufe, z. B. {"ALC": 150, "HER": 225}
  info_at     bigint,            -- wann der Spieler Rolle/Talente/Berufe zuletzt geschickt hat
  in_guild    boolean not null default true,
  first_seen  bigint  not null,
  seen_at     bigint  not null,  -- Zeit der Gildenliste, aus der die Zeile zuletzt kam
  primary key (guild, name)
);

create table if not exists public.nexloot_milestones (
  id     bigserial primary key,
  guild  text   not null,
  name   text   not null,
  kind   text   not null,        -- 'level'
  value  int    not null,        -- 25 / 40 / 60
  place  int,                    -- der Wievielte der Gilde (bei Level 60)
  class  text,
  at     bigint not null,        -- wann erreicht (so genau, wie es das Addon weiß)
  created   bigint not null default (extract(epoch from now()))::bigint, -- wann eingetragen (Uhr der Datenbank)
  posted_at bigint,              -- bei Discord gepostet (bzw. gerade dabei)
  posted_by text,
  unique (guild, name, kind, value)
);
alter table public.nexloot_milestones add column if not exists created bigint not null default (extract(epoch from now()))::bigint;
alter table public.nexloot_milestones add column if not exists posted_at bigint;
alter table public.nexloot_milestones add column if not exists posted_by text;
create index if not exists nexloot_milestones_guild_idx on public.nexloot_milestones (guild, at desc);

-- lesen darf jeder (Webapp), schreiben nur über die Funktion unten
alter table public.nexloot_members    enable row level security;
alter table public.nexloot_milestones enable row level security;
drop policy if exists "nexloot lesen" on public.nexloot_members;
create policy "nexloot lesen" on public.nexloot_members for select to anon, authenticated using (true);
drop policy if exists "nexloot lesen" on public.nexloot_milestones;
create policy "nexloot lesen" on public.nexloot_milestones for select to anon, authenticated using (true);
grant select on public.nexloot_members, public.nexloot_milestones to anon, authenticated;
revoke insert, update, delete on public.nexloot_members, public.nexloot_milestones from anon, authenticated;

-- ---------------------------------------------------------------------
-- Gildenliste hochladen (Companion-App).
-- p_members: [{"n": Name, "l": Level, "c": Klasse, "r": Rang, "ri": Rang-Nr., "on": true/false, "lo": zuletzt online,
--              "lt": seit wann auf diesem Level, "ro": Rolle, "t": Talente, "sp": Spec, "p": {"ALC": 150},
--              "ia": Zeit der Spieler-Infos}, ...]
-- p_full:    die Liste ist vollständig (wer fehlt, ist nicht mehr in der Gilde)
-- Antwort:   {"ok": true, "members": Anzahl, "milestones": [neue Meilensteine]}
-- ---------------------------------------------------------------------
create or replace function public.nexloot_roster(p_guild text, p_members jsonb, p_at bigint, p_full boolean, p_by text, p_secret text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  m      jsonb;
  cur    public.nexloot_members%rowtype;
  nm     text;
  lvl    int;
  cls    text;
  ia     bigint;
  lo     bigint;
  lt     bigint;
  pr     jsonb;
  th     int;
  pl     int;
  newid  bigint;
  n      int := 0;
  out    jsonb := '[]'::jsonb;
begin
  perform public.nexloot_check(p_guild, p_secret);
  -- laden zwei Offiziere gleichzeitig hoch, wartet der zweite (sonst könnten zwei Spieler denselben Platz bekommen)
  perform pg_advisory_xact_lock(hashtext('nexloot_roster:' || p_guild));
  if p_members is null or jsonb_typeof(p_members) <> 'array' or p_at is null or p_at < 1 then
    raise exception 'NexLoot: ungültige Gildenliste';
  end if;
  if jsonb_array_length(p_members) > 2000 then raise exception 'NexLoot: Gildenliste zu lang'; end if;
  -- wer früher aufgestiegen ist, kommt zuerst dran (Platz bei Level 60)
  for m in select value from jsonb_array_elements(p_members)
      order by case when jsonb_typeof(value) = 'object' and (value->>'lt') ~ '^\d{1,12}$' then (value->>'lt')::bigint end nulls last loop
    if jsonb_typeof(m) <> 'object' then continue; end if;
    nm := btrim(coalesce(m->>'n', ''));
    if nm = '' or length(nm) > 64 then continue; end if;
    lvl := case when (m->>'l') ~ '^\d{1,3}$' then least((m->>'l')::int, 100) else 0 end;
    cls := case when (m->>'c') ~ '^[A-Z]{2,20}$' then m->>'c' end;
    lo  := case when (m->>'lo') ~ '^\d{1,12}$' then (m->>'lo')::bigint end;
    ia  := case when (m->>'ia') ~ '^\d{1,12}$' then (m->>'ia')::bigint end;
    pr  := case when jsonb_typeof(m->'p') = 'object' then m->'p' end;
    lt  := case when (m->>'lt') ~ '^\d{1,12}$' then (m->>'lt')::bigint end;
    if lt is not null and (lt > p_at or lt < p_at - 30 * 86400) then lt := null; end if;
    n := n + 1;
    select * into cur from public.nexloot_members where guild = p_guild and name = nm for update;
    if not found then
      -- zum ersten Mal gesehen: nur merken (kein Meilenstein für das, was schon vorher erreicht war)
      insert into public.nexloot_members (guild, name, level, class, rank, rank_index, online, last_seen,
          role, talents, spec, profs, info_at, in_guild, first_seen, seen_at)
        values (p_guild, nm, lvl, cls, left(m->>'r', 40), case when (m->>'ri') ~ '^\d{1,2}$' then (m->>'ri')::int end,
          coalesce(m->>'on' in ('true', '1'), false), lo,
          case when (m->>'ro') in ('T', 'H', 'D') then m->>'ro' end, left(m->>'t', 20), left(m->>'sp', 40), pr, ia,
          true, p_at, p_at);
      continue;
    end if;
    -- neuer Charakter mit demselben Namen (Beta -> Live, gelöscht und neu erstellt): das Level fällt auf 1-5.
    -- Dann gilt das neue Level (Meilensteine bleiben, wie sie sind).
    if lvl between 1 and 5 and cur.level >= lvl + 5 and p_at > cur.seen_at then
      update public.nexloot_members set level = lvl, first_seen = p_at where guild = p_guild and name = nm;
      cur.level := lvl;
    end if;
    if lvl > cur.level and cur.level > 0 then
      foreach th in array array[25, 40, 60] loop
        if cur.level < th and lvl >= th then
          pl := null;
          if th = 60 then
            select count(*) + 1 into pl from public.nexloot_milestones where guild = p_guild and kind = 'level' and value = 60;
          end if;
          newid := null;
          insert into public.nexloot_milestones (guild, name, kind, value, place, class, at)
            values (p_guild, nm, 'level', th, pl, coalesce(cls, cur.class), coalesce(lt, p_at))
            on conflict (guild, name, kind, value) do nothing
            returning id into newid;
          if newid is not null then
            out := out || jsonb_build_array(jsonb_build_object('id', newid, 'name', nm, 'kind', 'level', 'value', th, 'place', pl,
              'class', coalesce(cls, cur.class), 'at', coalesce(lt, p_at)));
          end if;
        end if;
      end loop;
    end if;
    update public.nexloot_members set
        level      = greatest(level, lvl),
        class      = coalesce(cls, class),
        rank       = case when p_at >= seen_at then coalesce(left(m->>'r', 40), rank) else rank end,
        rank_index = case when p_at >= seen_at and (m->>'ri') ~ '^\d{1,2}$' then (m->>'ri')::int else rank_index end,
        online     = case when p_at >= seen_at then coalesce(m->>'on' in ('true', '1'), false) else online end,
        last_seen  = greatest(coalesce(last_seen, 0), coalesce(lo, 0)),
        in_guild   = case when p_at >= seen_at then true else in_guild end,
        role       = case when ia is not null and ia > coalesce(info_at, 0) then
                       case when (m->>'ro') in ('T', 'H', 'D') then m->>'ro' end else role end,
        talents    = case when ia is not null and ia > coalesce(info_at, 0) then left(m->>'t', 20) else talents end,
        spec       = case when ia is not null and ia > coalesce(info_at, 0) then left(m->>'sp', 40) else spec end,
        profs      = case when ia is not null and ia > coalesce(info_at, 0) then pr else profs end,
        info_at    = greatest(coalesce(info_at, 0), coalesce(ia, 0)),
        seen_at    = greatest(seen_at, p_at)
      where guild = p_guild and name = nm;
  end loop;
  if p_full then
    -- vollständige Liste: wer darin fehlt (und nicht später gesehen wurde), ist nicht mehr in der Gilde
    update public.nexloot_members set in_guild = false, online = false
      where guild = p_guild and in_guild and seen_at < p_at;
  end if;
  return jsonb_build_object('ok', true, 'members', n, 'milestones', out);
end $$;

revoke all on function public.nexloot_roster(text, jsonb, bigint, boolean, text, text) from public;
grant execute on function public.nexloot_roster(text, jsonb, bigint, boolean, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Neue Meilensteine für Discord abholen (Companion-App mit Webhook). Reserviert sie gleich,
-- damit sie nur einer postet. Klappt das Posten nicht, gibt nexloot_ms_release sie wieder frei.
-- p_since: nur Meilensteine, die seitdem eingetragen wurden (Unix-Zeit)
-- ---------------------------------------------------------------------
create or replace function public.nexloot_ms_claim(p_guild text, p_since bigint, p_by text, p_secret text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  res jsonb;
begin
  perform public.nexloot_check(p_guild, p_secret);
  with c as (
    update public.nexloot_milestones m
       set posted_at = (extract(epoch from now()))::bigint, posted_by = left(coalesce(p_by, ''), 64)
     where m.id in (select x.id from public.nexloot_milestones x
                     where x.guild = p_guild and x.posted_at is null and x.created >= coalesce(p_since, 0)
                     order by x.created, x.id limit 25
                     for update skip locked)
    returning m.id, m.name, m.kind, m.value, m.place, m.class, m.at
  )
  select coalesce(jsonb_agg(to_jsonb(c) order by c.at, c.id), '[]'::jsonb) into res from c;
  return res;
end $$;

create or replace function public.nexloot_ms_release(p_guild text, p_ids jsonb, p_secret text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  n int;
begin
  perform public.nexloot_check(p_guild, p_secret);
  update public.nexloot_milestones set posted_at = null, posted_by = null
   where guild = p_guild and id in (select (e)::bigint from jsonb_array_elements_text(
           case when jsonb_typeof(p_ids) = 'array' then p_ids else '[]'::jsonb end) e where e ~ '^\d{1,18}$');
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'released', n);
end $$;

revoke all on function public.nexloot_ms_claim(text, bigint, text, text) from public;
grant execute on function public.nexloot_ms_claim(text, bigint, text, text) to anon, authenticated;
revoke all on function public.nexloot_ms_release(text, jsonb, text) from public;
grant execute on function public.nexloot_ms_release(text, jsonb, text) to anon, authenticated;
