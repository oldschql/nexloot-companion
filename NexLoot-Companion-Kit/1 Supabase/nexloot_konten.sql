-- =====================================================================
-- NexLoot – Anmelden mit Discord, „Mein Charakter“, Offiziere und Raid-Setups (Webapp)
-- Einmal im Supabase "SQL Editor" ausführen (Run). Kann gefahrlos noch einmal ausgeführt werden.
-- Braucht die Grundeinrichtung aus nexloot.sql (Schreib-Passwort) und nexloot_gilde.sql (Gildenliste).
-- Dazu in Supabase den Login mit Discord einschalten (siehe ANLEITUNG, Schritt 8).
--
-- Wer sich in der Webapp mit Discord anmeldet, bekommt ein Konto (nexloot_users). Jeder verknüpft
-- seine Charaktere selbst (nexloot_links, ein Charakter gehört immer nur zu einem Discord-Konto);
-- Offiziere können jede Verknüpfung setzen, auch für Discord-Konten, die sich nie angemeldet haben.
-- Offizier wird, wer in der Webapp einmal das Schreib-Passwort der Gilde eingibt (dasselbe wie in der
-- Companion-App). Offiziere planen Raid-Setups (nexloot_setups); veröffentlichte sieht jeder.
-- Ab Companion-App 1.8 / NexLoot 0.30 kommen veröffentlichte Setups auch ins Spiel und nach Discord.
-- Vergangene Raids: alle alten Setups (seitenweise) und welche Session zu einem Setup gehört.
-- Klassen-Symbole (Companion-App 1.8.2): pro Klasse ein Discord-Emoji für die Nachricht zum Setup (nexloot_settings).
-- Raid-Helper: ein Setup kann an ein Raid-Helper-Event hängen (rh_event); dann postet Raid-Helper die Gruppen
-- (nexloot_raidhelper.sql) und die Companion-App lässt ihre eigene Discord-Nachricht dafür weg.
-- Alles läuft über die Funktionen unten - direkt lesen oder schreiben kann niemand.
-- English: Discord login, "my character", officers and raid setups for the website (companion app 1.8,
-- add-on 0.30). Run this whole file once in the Supabase "SQL Editor" after nexloot.sql and nexloot_gilde.sql.
-- Safe to run again. Then turn on the Discord login in Supabase (GUIDE.txt, step 8).
-- =====================================================================

-- Fehlt die Grundeinrichtung oder die Gildenliste, hier mit einem klaren Hinweis aufhören
do $$
begin
  if to_regclass('public.nexloot_state') is null or to_regclass('public.nexloot_members') is null then
    raise exception 'NexLoot: Zuerst nexloot.sql und nexloot_gilde.sql ausführen, dann diese Datei. (English: run nexloot.sql and nexloot_gilde.sql first, then this file.)';
  end if;
end $$;

create table if not exists public.nexloot_users (
  guild        text        not null,
  discord_id   text        not null,
  uid          uuid,                    -- Supabase-Konto (ab dem ersten Login)
  name         text,                    -- Name in Discord
  avatar       text,
  role         text        not null default 'member',  -- member / officer
  unlocked_at  timestamptz,
  created_at   timestamptz not null default now(),
  seen_at      timestamptz,
  primary key (guild, discord_id)
);
create table if not exists public.nexloot_links (
  guild        text        not null,
  char_name    text        not null,
  discord_id   text        not null,
  fav          boolean     not null default false,   -- Lieblings-Charakter (Startseite)
  set_by       text,                                 -- 'self' oder der Offizier
  at           timestamptz not null default now(),
  primary key (guild, char_name)
);
create index if not exists nexloot_links_discord_idx on public.nexloot_links (guild, discord_id);
create table if not exists public.nexloot_setups (
  id           bigserial   primary key,
  guild        text        not null,
  title        text        not null,
  size         int         not null default 40,
  starts_at    bigint,                  -- Raidbeginn (Unix-Zeit)
  status       text        not null default 'draft',   -- draft / published
  data         jsonb       not null default '{}'::jsonb, -- {"groups": [[Name, ...], ...], "bench": [...], "out": [...], "notes": {Name: Text}}
  rh_event     text,                    -- Raid-Helper-Event (später)
  rev          int         not null default 1,
  created_by   text,
  updated_by   text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists nexloot_setups_guild_idx on public.nexloot_setups (guild, starts_at);
-- Discord (Companion-App 1.8): eine Nachricht pro Setup, bei Änderungen bearbeitet, beim Löschen entfernt
alter table public.nexloot_setups add column if not exists dc_msg   text;    -- Discord-Nachricht (ID)
alter table public.nexloot_setups add column if not exists dc_hook  text;    -- Webhook (ID), mit dem gepostet wurde - nur der kann sie ändern
alter table public.nexloot_setups add column if not exists dc_rev   int;     -- in diesem Stand gepostet
alter table public.nexloot_setups add column if not exists dc_at    bigint;  -- wann zuletzt gepostet/geändert
alter table public.nexloot_setups add column if not exists dc_by    text;    -- von welcher Companion-App (Name)
alter table public.nexloot_setups add column if not exists dc_claim bigint;  -- eine Companion-App postet gerade (seit wann)
-- Session (Loot-Vergabe) zum Setup: 'Host|Session-Nr.', '-' = keine; leer = automatisch (die Session, die an dem Abend lief)
alter table public.nexloot_setups add column if not exists sess     text;
-- Raid-Helper (nexloot_raidhelper.sql): zuletzt gesendet (Zeit, Stand, von wem), Ankündigung schon gepostet (für welches Event)
alter table public.nexloot_setups add column if not exists rh_sent_at  bigint;
alter table public.nexloot_setups add column if not exists rh_sent_rev int;
alter table public.nexloot_setups add column if not exists rh_sent_by  text;
alter table public.nexloot_setups add column if not exists rh_ann      text;
-- Einstellungen der Gilde, z. B. key 'dc_emojis' = Klassen-Symbole für Discord {"WARRIOR": "<:Krieger:123…>", …}
create table if not exists public.nexloot_settings (
  guild        text        not null,
  key          text        not null,
  value        jsonb       not null default '{}'::jsonb,
  updated_by   text,
  updated_at   timestamptz not null default now(),
  primary key (guild, key)
);

alter table public.nexloot_users  enable row level security;
alter table public.nexloot_links  enable row level security;
alter table public.nexloot_setups enable row level security;
alter table public.nexloot_settings enable row level security;
revoke all on public.nexloot_users, public.nexloot_links, public.nexloot_setups, public.nexloot_settings from anon, authenticated;

-- ---------------------------------------------------------------------
-- (intern) Discord-Konto des Aufrufers - aus auth.identities (kann man selbst nicht ändern)
-- ---------------------------------------------------------------------
create or replace function public.nexloot_my_discord(out did text, out dname text, out avatar text)
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare
  u uuid := auth.uid();
begin
  if u is null then raise exception 'NexLoot: bitte mit Discord anmelden' using errcode = '28000'; end if;
  select i.provider_id,
         left(coalesce(nullif(i.identity_data->'custom_claims'->>'global_name', ''), nullif(i.identity_data->>'full_name', ''),
                       nullif(i.identity_data->>'name', ''), 'Discord'), 64),
         left(i.identity_data->>'avatar_url', 300)
    into did, dname, avatar
    from auth.identities i where i.user_id = u and i.provider = 'discord' limit 1;
  if did is null then raise exception 'NexLoot: nur mit Discord-Anmeldung' using errcode = '28000'; end if;
end $$;

-- (intern) Konto anlegen bzw. Name/Bild auffrischen, Rolle zurück
create or replace function public.nexloot_touch(p_guild text)
returns public.nexloot_users
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  me record;
  u public.nexloot_users;
begin
  if p_guild is null or p_guild = '' then raise exception 'NexLoot: Gilde fehlt'; end if;
  -- nur Gilden, die es hier gibt (mit Schreib-Passwort aus nexloot.sql) - sonst ließen sich beliebig viele anlegen
  if not exists (select 1 from public.nexloot_secret where guild = p_guild) then raise exception 'NexLoot: unbekannte Gilde'; end if;
  select * into me from public.nexloot_my_discord();
  insert into public.nexloot_users (guild, discord_id, uid, name, avatar, seen_at)
    values (p_guild, me.did, auth.uid(), me.dname, me.avatar, now())
    on conflict (guild, discord_id) do update
      set uid = excluded.uid, name = excluded.name, avatar = excluded.avatar, seen_at = now()
    returning * into u;
  return u;
end $$;

create or replace function public.nexloot_is_officer(p_guild text, p_did text)
returns boolean
language sql stable security definer
set search_path = public
as $$ select exists (select 1 from public.nexloot_users where guild = p_guild and discord_id = p_did and role = 'officer') $$;

-- (intern) Charakter, den es in der Gilde gibt (Gildenliste oder Nex-Coins)
create or replace function public.nexloot_known_char(p_guild text, p_char text)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.nexloot_members where guild = p_guild and name = p_char)
      or exists (select 1 from public.nexloot_state where guild = p_guild and data->'coins' ? p_char)
$$;

-- (intern) Antwort für die Webapp: wer bin ich, welche Charaktere
create or replace function public.nexloot_me_json(p_guild text, u public.nexloot_users)
returns jsonb
language sql stable security definer
set search_path = public
as $$
  select jsonb_build_object('discord_id', u.discord_id, 'name', u.name, 'avatar', u.avatar, 'role', u.role,
    'chars', coalesce((select jsonb_agg(jsonb_build_object('char', l.char_name, 'fav', l.fav, 'set_by', l.set_by)
                                        order by l.fav desc, l.char_name)
                       from public.nexloot_links l where l.guild = p_guild and l.discord_id = u.discord_id), '[]'::jsonb))
$$;

-- (intern) hat ein Konto Charaktere, aber keinen Favoriten mehr: den ersten nehmen
create or replace function public.nexloot_fix_fav(p_guild text, p_did text)
returns void
language sql security definer
set search_path = public
as $$
  update public.nexloot_links set fav = true
   where guild = p_guild and discord_id = p_did
     and not exists (select 1 from public.nexloot_links x where x.guild = p_guild and x.discord_id = p_did and x.fav)
     and char_name = (select min(y.char_name) from public.nexloot_links y where y.guild = p_guild and y.discord_id = p_did)
$$;

-- ---------------------------------------------------------------------
-- Ich (nach dem Login): Konto, Rolle, verknüpfte Charaktere
-- ---------------------------------------------------------------------
create or replace function public.nexloot_me(p_guild text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare u public.nexloot_users;
begin
  u := public.nexloot_touch(p_guild);
  return public.nexloot_me_json(p_guild, u);
end $$;

-- Charakter selbst verknüpfen ("Das bin ich"); p_fav = als Lieblings-Charakter
create or replace function public.nexloot_claim(p_guild text, p_char text, p_fav boolean)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  u public.nexloot_users;
  owner text;
  n int;
  ch text := btrim(coalesce(p_char, ''));
begin
  u := public.nexloot_touch(p_guild);
  if ch = '' or length(ch) > 64 then raise exception 'NexLoot: ungültiger Charakter'; end if;
  if not public.nexloot_known_char(p_guild, ch) then raise exception 'NexLoot: Charakter % ist nicht in der Gilde', ch; end if;
  select discord_id into owner from public.nexloot_links where guild = p_guild and char_name = ch for update;
  if owner is not null and owner <> u.discord_id then
    raise exception 'NexLoot: % ist schon mit einem anderen Discord-Konto verknüpft - bitte an einen Offizier wenden', ch;
  end if;
  select count(*) into n from public.nexloot_links where guild = p_guild and discord_id = u.discord_id;
  if owner is null and n >= 12 then raise exception 'NexLoot: höchstens 12 Charaktere pro Discord-Konto'; end if;
  insert into public.nexloot_links (guild, char_name, discord_id, fav, set_by)
    values (p_guild, ch, u.discord_id, coalesce(p_fav, false) or n = 0, 'self')
    on conflict (guild, char_name) do update set fav = public.nexloot_links.fav or coalesce(p_fav, false), at = now();
  if coalesce(p_fav, false) or n = 0 then
    update public.nexloot_links set fav = (char_name = ch) where guild = p_guild and discord_id = u.discord_id;
  end if;
  return public.nexloot_me_json(p_guild, u);
end $$;

-- eigene Verknüpfung lösen
create or replace function public.nexloot_unclaim(p_guild text, p_char text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  u public.nexloot_users;
  wasfav boolean;
begin
  u := public.nexloot_touch(p_guild);
  delete from public.nexloot_links where guild = p_guild and char_name = p_char and discord_id = u.discord_id returning fav into wasfav;
  if wasfav then perform public.nexloot_fix_fav(p_guild, u.discord_id); end if; -- anderer Charakter wird Favorit
  return public.nexloot_me_json(p_guild, u);
end $$;

-- Offizier freischalten: mit dem Schreib-Passwort der Gilde (wie in der Companion-App)
create or replace function public.nexloot_unlock(p_guild text, p_secret text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare u public.nexloot_users;
begin
  perform public.nexloot_check(p_guild, p_secret);
  u := public.nexloot_touch(p_guild);
  update public.nexloot_users set role = 'officer', unlocked_at = now()
    where guild = p_guild and discord_id = u.discord_id returning * into u;
  return public.nexloot_me_json(p_guild, u);
end $$;

-- (intern) nur Offiziere
create or replace function public.nexloot_need_officer(p_guild text)
returns public.nexloot_users
language plpgsql security definer
set search_path = public, extensions
as $$
declare u public.nexloot_users;
begin
  u := public.nexloot_touch(p_guild);
  if u.role <> 'officer' then raise exception 'NexLoot: nur für Offiziere' using errcode = '42501'; end if;
  return u;
end $$;

-- (intern) Klassen-Symbole für Discord (leer = keine)
create or replace function public.nexloot_dc_emojis_of(p_guild text)
returns jsonb
language sql stable security definer
set search_path = public
as $$
  select coalesce((select value from public.nexloot_settings where guild = p_guild and key = 'dc_emojis'), '{}'::jsonb)
$$;

-- ---------------------------------------------------------------------
-- Verwaltung (Offiziere): alle Discord-Konten und Verknüpfungen
-- ---------------------------------------------------------------------
create or replace function public.nexloot_admin(p_guild text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  perform public.nexloot_need_officer(p_guild);
  return jsonb_build_object(
    'users', coalesce((select jsonb_agg(jsonb_build_object('discord_id', x.discord_id, 'name', x.name, 'avatar', x.avatar, 'role', x.role,
                         'login', x.uid is not null, 'seen_at', x.seen_at, 'unlocked_at', x.unlocked_at) order by lower(coalesce(x.name, x.discord_id)))
                       from public.nexloot_users x where x.guild = p_guild), '[]'::jsonb),
    'links', coalesce((select jsonb_agg(jsonb_build_object('char', l.char_name, 'discord_id', l.discord_id, 'fav', l.fav, 'set_by', l.set_by, 'at', l.at)
                         order by l.char_name)
                       from public.nexloot_links l where l.guild = p_guild), '[]'::jsonb),
    'emojis', public.nexloot_dc_emojis_of(p_guild));
end $$;

-- Charakter einem Discord-Konto zuordnen (auch eines, das sich nie angemeldet hat). Leere p_discord_id = Verknüpfung lösen.
create or replace function public.nexloot_link_set(p_guild text, p_char text, p_discord_id text, p_discord_name text, p_fav boolean)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  me public.nexloot_users;
  ch text := btrim(coalesce(p_char, ''));
  did text := btrim(coalesce(p_discord_id, ''));
  prev text;
begin
  me := public.nexloot_need_officer(p_guild);
  if ch = '' or length(ch) > 64 then raise exception 'NexLoot: ungültiger Charakter'; end if;
  select discord_id into prev from public.nexloot_links where guild = p_guild and char_name = ch for update;
  if did = '' then
    delete from public.nexloot_links where guild = p_guild and char_name = ch;
    if prev is not null then perform public.nexloot_fix_fav(p_guild, prev); end if;
    return public.nexloot_admin(p_guild);
  end if;
  if did !~ '^\d{15,22}$' then raise exception 'NexLoot: ungültige Discord-ID (nur Ziffern)'; end if;
  if not public.nexloot_known_char(p_guild, ch) then raise exception 'NexLoot: Charakter % ist nicht in der Gilde', ch; end if;
  insert into public.nexloot_users (guild, discord_id, name)
    values (p_guild, did, nullif(left(btrim(coalesce(p_discord_name, '')), 64), ''))
    on conflict (guild, discord_id) do update
      set name = coalesce(public.nexloot_users.name, excluded.name);
  insert into public.nexloot_links (guild, char_name, discord_id, fav, set_by)
    values (p_guild, ch, did, coalesce(p_fav, false), left(coalesce(me.name, 'Offizier'), 64))
    on conflict (guild, char_name) do update
      set discord_id = excluded.discord_id, fav = excluded.fav, set_by = excluded.set_by, at = now();
  if coalesce(p_fav, false) or (select count(*) from public.nexloot_links where guild = p_guild and discord_id = did) = 1 then
    update public.nexloot_links set fav = (char_name = ch) where guild = p_guild and discord_id = did;
  end if;
  perform public.nexloot_fix_fav(p_guild, did);
  if prev is not null and prev <> did then perform public.nexloot_fix_fav(p_guild, prev); end if; -- dem bisherigen Besitzer einen Favoriten lassen
  return public.nexloot_admin(p_guild);
end $$;

-- Rolle ändern (Offiziere): z. B. einen Offizier wieder zum Mitglied machen. Sich selbst nicht.
create or replace function public.nexloot_role_set(p_guild text, p_discord_id text, p_role text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare me public.nexloot_users;
begin
  me := public.nexloot_need_officer(p_guild);
  if p_role not in ('member', 'officer') then raise exception 'NexLoot: ungültige Rolle'; end if;
  if p_discord_id = me.discord_id then raise exception 'NexLoot: die eigene Rolle kann man nicht ändern'; end if;
  update public.nexloot_users set role = p_role, unlocked_at = case when p_role = 'officer' then now() else unlocked_at end
    where guild = p_guild and discord_id = p_discord_id;
  return public.nexloot_admin(p_guild);
end $$;

-- ---------------------------------------------------------------------
-- Raid-Setups: veröffentlichte sieht jeder, Entwürfe nur Offiziere
-- ---------------------------------------------------------------------
create or replace function public.nexloot_setups(p_guild text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  off boolean := false;
  me record;
begin
  if auth.uid() is not null then
    begin
      select * into me from public.nexloot_my_discord();
      off := public.nexloot_is_officer(p_guild, me.did);
    exception when others then off := false;
    end;
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title, 'size', s.size, 'starts_at', s.starts_at,
             'status', s.status, 'data', s.data, 'rev', s.rev, 'updated_by', s.updated_by, 'updated_at', s.updated_at,
             'discord', s.dc_msg is not null and s.dc_rev = s.rev, 'sess', s.sess,
             'rh_event', s.rh_event, 'rh_sent_at', s.rh_sent_at, 'rh_sent_rev', s.rh_sent_rev, 'rh_sent_by', s.rh_sent_by)
             order by s.starts_at nulls last, s.id)
           from public.nexloot_setups s
           where s.guild = p_guild and (s.status = 'published' or (off and s.status = 'draft'))
             and (s.starts_at is null or s.starts_at > (extract(epoch from now()))::bigint - 21 * 86400)), '[]'::jsonb);
end $$;

-- (intern) Namensliste aus dem Setup prüfen
create or replace function public.nexloot_names_ok(v jsonb, maxn int)
returns boolean
language sql immutable
as $$
  select v is null or (jsonb_typeof(v) = 'array' and jsonb_array_length(v) <= maxn
    and not exists (select 1 from jsonb_array_elements(v) e where jsonb_typeof(e) <> 'string' or length(e #>> '{}') > 64))
$$;

-- Setup speichern (neu: p_id = null). p_rev = Stand, den man bearbeitet hat (sonst: inzwischen geändert)
create or replace function public.nexloot_setup_save(p_guild text, p_id bigint, p_rev int, p_title text, p_size int, p_starts_at bigint,
                                                     p_status text, p_data jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  me public.nexloot_users;
  s public.nexloot_setups;
  g jsonb;
begin
  me := public.nexloot_need_officer(p_guild);
  if btrim(coalesce(p_title, '')) = '' or length(p_title) > 80 then raise exception 'NexLoot: Titel fehlt oder ist zu lang'; end if;
  if p_size not in (5, 10, 20, 25, 40) then raise exception 'NexLoot: Raidgröße 5, 10, 20, 25 oder 40'; end if;
  if p_status not in ('draft', 'published') then raise exception 'NexLoot: ungültiger Status'; end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' or jsonb_typeof(coalesce(p_data->'groups', '[]'::jsonb)) <> 'array'
     or jsonb_array_length(coalesce(p_data->'groups', '[]'::jsonb)) > 8
     or not public.nexloot_names_ok(p_data->'bench', 100) or not public.nexloot_names_ok(p_data->'out', 200)
     or (p_data ? 'notes' and jsonb_typeof(p_data->'notes') <> 'object') or length(p_data::text) > 60000 then
    raise exception 'NexLoot: ungültiges Setup';
  end if;
  for g in select value from jsonb_array_elements(coalesce(p_data->'groups', '[]'::jsonb)) loop
    if not public.nexloot_names_ok(g, 5) then raise exception 'NexLoot: höchstens 5 Spieler pro Gruppe'; end if;
  end loop;
  if p_id is null then
    insert into public.nexloot_setups (guild, title, size, starts_at, status, data, created_by, updated_by)
      values (p_guild, btrim(p_title), p_size, p_starts_at, p_status, p_data, me.name, me.name)
      returning * into s;
  else
    select * into s from public.nexloot_setups where id = p_id and guild = p_guild for update;
    if not found or s.status = 'deleted' then raise exception 'NexLoot: Setup gibt es nicht mehr'; end if;
    if p_rev is not null and s.rev <> p_rev then
      raise exception 'NexLoot: % hat das Setup inzwischen geändert - bitte neu laden', coalesce(s.updated_by, 'jemand');
    end if;
    update public.nexloot_setups set title = btrim(p_title), size = p_size, starts_at = p_starts_at, status = p_status, data = p_data,
        rev = s.rev + 1, updated_by = me.name, updated_at = now()
      where id = p_id returning * into s;
  end if;
  return jsonb_build_object('id', s.id, 'title', s.title, 'size', s.size, 'starts_at', s.starts_at, 'status', s.status, 'data', s.data,
    'rev', s.rev, 'updated_by', s.updated_by, 'updated_at', s.updated_at);
end $$;

create or replace function public.nexloot_setup_delete(p_guild text, p_id bigint)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  me public.nexloot_users;
  now_s bigint := (extract(epoch from now()))::bigint;
begin
  me := public.nexloot_need_officer(p_guild);
  -- steht das Setup (gleich) in Discord und ist der Raid nicht lange vorbei: nur als gelöscht markieren -
  -- die Companion-App entfernt die Nachricht und dann die Zeile
  update public.nexloot_setups set status = 'deleted', rev = rev + 1, updated_by = me.name, updated_at = now()
   where id = p_id and guild = p_guild and status <> 'deleted'
     and (dc_msg is not null or coalesce(dc_claim, 0) > now_s - 120)
     and (starts_at is null or starts_at > now_s - 12 * 3600);
  if not found then
    delete from public.nexloot_setups where id = p_id and guild = p_guild and status <> 'deleted';
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Ab NexLoot 0.30 / Companion-App 1.8: Setups im Spiel und in Discord
-- ---------------------------------------------------------------------
-- (intern) alle Namen eines Setups (Gruppen, Ersatzbank, nicht dabei)
create or replace function public.nexloot_setup_names(d jsonb)
returns text[]
language sql immutable
as $$
  select coalesce(array_agg(distinct x), '{}'::text[]) from (
    select jsonb_array_elements_text(g) x
      from jsonb_array_elements(case when jsonb_typeof(d->'groups') = 'array' then d->'groups' else '[]'::jsonb end) g
     where jsonb_typeof(g) = 'array'
    union all select jsonb_array_elements_text(case when jsonb_typeof(d->'bench') = 'array' then d->'bench' else '[]'::jsonb end)
    union all select jsonb_array_elements_text(case when jsonb_typeof(d->'out') = 'array' then d->'out' else '[]'::jsonb end)
  ) t
$$;

-- (intern) Klasse und Rolle zu den Namen (Gildenliste, sonst Klasse aus dem Spielstand)
create or replace function public.nexloot_setup_people(p_guild text, p_names text[])
returns jsonb
language sql stable security definer
set search_path = public
as $$
  with n as (select distinct x as name from unnest(coalesce(p_names, '{}'::text[])) x),
       st as (select data->'classes' as cl from public.nexloot_state where guild = p_guild),
       p as (select n.name, coalesce(m.class, (select st.cl->>n.name from st)) as c, m.role as r
               from n left join public.nexloot_members m on m.guild = p_guild and m.name = n.name)
  select coalesce(jsonb_object_agg(p.name, jsonb_strip_nulls(jsonb_build_object('c', p.c, 'r', p.r))), '{}'::jsonb)
    from p where p.c is not null or p.r is not null
$$;

-- Veröffentlichte Setups für das Spiel (die Companion-App schreibt sie in WebData.lua). Lesen darf jeder (wie die Webapp).
-- at = Zeit der Datenbank (damit vergleichen die Addons, welcher Stand neuer ist), h = Prüfsumme des Inhalts
create or replace function public.nexloot_setups_live(p_guild text)
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare
  now_s bigint := (extract(epoch from now()))::bigint;
  l jsonb;
  ppl jsonb;
  names text[];
begin
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'rev', s.rev, 'title', s.title, 'size', s.size, 'starts_at', s.starts_at,
           'data', s.data, 'by', s.updated_by) order by s.starts_at nulls last, s.id), '[]'::jsonb)
    into l
    from (select * from public.nexloot_setups x
           where x.guild = p_guild and x.status = 'published' and (x.starts_at is null or x.starts_at > now_s - 12 * 3600)
           order by x.starts_at nulls last, x.id limit 8) s;
  select coalesce(array_agg(distinct n), '{}'::text[]) into names
    from jsonb_array_elements(l) e, unnest(public.nexloot_setup_names(e->'data')) n;
  ppl := public.nexloot_setup_people(p_guild, names);
  return jsonb_build_object('at', now_s, 'h', left(md5(l::text || ppl::text), 12), 'setups', l, 'people', ppl);
end $$;

-- Discord: was muss gepostet, geändert oder entfernt werden? Holt höchstens 5 Aufträge und reserviert sie
-- 2 Minuten lang (so postet bei mehreren Offizieren nur eine Companion-App). Nachrichten eines anderen Webhooks
-- bearbeitet die Companion-App mit diesem Webhook erst, wenn sie 15 Minuten lang niemand angefasst hat.
create or replace function public.nexloot_setup_claim(p_guild text, p_hook text, p_by text, p_secret text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  now_s bigint := (extract(epoch from now()))::bigint;
  l jsonb;
  names text[];
begin
  perform public.nexloot_check(p_guild, p_secret);
  with c as (
    update public.nexloot_setups s set dc_claim = now_s
     where s.id in (select x.id from public.nexloot_setups x
                     where x.guild = p_guild and coalesce(x.dc_claim, 0) < now_s - 120
                       and (x.dc_msg is null or x.dc_hook is null or x.dc_hook = coalesce(p_hook, '') or coalesce(x.dc_at, 0) < now_s - 900)
                       and ((x.status = 'published' and x.rh_event is null and (x.dc_msg is null or coalesce(x.dc_rev, 0) < x.rev)
                             and (x.starts_at is null or x.starts_at > now_s - 6 * 3600))
                            or (x.status <> 'published' and x.dc_msg is not null)
                            or (x.status = 'published' and x.rh_event is not null and x.dc_msg is not null)
                            or x.status = 'deleted')
                     order by x.updated_at, x.id limit 5
                     for update skip locked)
    returning s.id, s.rev, s.title, s.size, s.starts_at, s.status, s.data, s.updated_by, s.updated_at, s.dc_msg, s.dc_hook, s.rh_event
  )
  -- an ein Raid-Helper-Event gehängt: Raid-Helper postet, die eigene Nachricht wird entfernt (Status "raidhelper")
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'rev', c.rev, 'title', c.title, 'size', c.size, 'starts_at', c.starts_at,
           'status', case when c.status = 'published' and c.rh_event is not null then 'raidhelper' else c.status end, 'data', c.data, 'by', c.updated_by, 'at', (extract(epoch from c.updated_at))::bigint,
           'msg', c.dc_msg, 'hook', c.dc_hook) order by c.updated_at, c.id), '[]'::jsonb)
    into l from c;
  select coalesce(array_agg(distinct n), '{}'::text[]) into names
    from jsonb_array_elements(l) e, unnest(public.nexloot_setup_names(e->'data')) n;
  -- ids: Discord-Konten der Charaktere (für @-Erwähnungen; nur wer in der Webapp verknüpft ist)
  return jsonb_build_object('jobs', l, 'people', public.nexloot_setup_people(p_guild, names),
    'ids', coalesce((select jsonb_object_agg(k.char_name, k.discord_id) from public.nexloot_links k
                      where k.guild = p_guild and k.char_name = any(names)), '{}'::jsonb),
    'emojis', public.nexloot_dc_emojis_of(p_guild));
end $$;

-- Discord: erledigt. p_msg = Nachricht (null = entfernt). Gelöschte Setups verschwinden danach ganz.
create or replace function public.nexloot_setup_done(p_guild text, p_id bigint, p_rev int, p_msg text, p_hook text, p_by text, p_secret text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  s public.nexloot_setups;
begin
  perform public.nexloot_check(p_guild, p_secret);
  if p_msg is not null and p_msg !~ '^\d{1,25}$' then raise exception 'NexLoot: ungültige Discord-Nachricht'; end if;
  if p_hook is not null and p_hook !~ '^\d{1,25}$' then raise exception 'NexLoot: ungültiger Webhook'; end if;
  select * into s from public.nexloot_setups where id = p_id and guild = p_guild for update;
  if not found then return jsonb_build_object('ok', true, 'gone', true); end if;
  if p_msg is null and s.status = 'deleted' then
    delete from public.nexloot_setups where id = p_id;
    return jsonb_build_object('ok', true, 'deleted', true);
  end if;
  update public.nexloot_setups
     set dc_msg = p_msg, dc_hook = case when p_msg is null then null else p_hook end,
         dc_rev = case when p_msg is null then null else p_rev end,
         dc_at = (extract(epoch from now()))::bigint, dc_by = left(coalesce(p_by, ''), 64), dc_claim = null
   where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- Discord: hat nicht geklappt - Reservierung aufheben (später noch einmal)
create or replace function public.nexloot_setup_release(p_guild text, p_id bigint, p_secret text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  perform public.nexloot_check(p_guild, p_secret);
  update public.nexloot_setups set dc_claim = null where id = p_id and guild = p_guild;
  return jsonb_build_object('ok', true);
end $$;

-- Rechte: nur die Funktionen für die Webapp sind von außen aufrufbar
-- ---------------------------------------------------------------------
-- Vergangene Raids (Webapp): veröffentlichte Setups, deren Raid über 6 Stunden her ist - neueste zuerst,
-- seitenweise (p_before = Termin des letzten, den man schon hat). Lesen darf jeder (wie die Setups).
-- ---------------------------------------------------------------------
create or replace function public.nexloot_setups_past(p_guild text, p_before bigint, p_limit int)
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare
  now_s bigint := (extract(epoch from now()))::bigint;
  n int := least(greatest(coalesce(p_limit, 20), 1), 50);
  l jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'title', x.title, 'size', x.size, 'starts_at', x.starts_at, 'status', x.status,
           'data', x.data, 'rev', x.rev, 'updated_by', x.updated_by, 'updated_at', x.updated_at, 'sess', x.sess)
           order by x.starts_at desc, x.id desc), '[]'::jsonb)
    into l
    from (select * from public.nexloot_setups s
           where s.guild = p_guild and s.status = 'published' and s.starts_at is not null and s.starts_at < now_s - 6 * 3600
             and (p_before is null or s.starts_at < p_before)
           order by s.starts_at desc, s.id desc limit n + 1) x;
  return jsonb_build_object('list', coalesce((select jsonb_agg(t.e order by t.i) from jsonb_array_elements(l) with ordinality t(e, i)
                                              where t.i <= n), '[]'::jsonb),
                            'more', jsonb_array_length(l) > n);
end $$;

-- Session zu einem Setup festlegen (Offiziere): 'Host|Session-Nr.', '-' = keine, leer/null = wieder automatisch.
-- Ändert das Setup selbst nicht (die Discord-Nachricht bleibt, wie sie ist).
create or replace function public.nexloot_setup_session(p_guild text, p_id bigint, p_sess text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  me public.nexloot_users;
  v text := nullif(btrim(coalesce(p_sess, '')), '');
begin
  me := public.nexloot_need_officer(p_guild);
  if v is not null and v <> '-' and v !~ '^[^|]{1,64}\|\d{1,12}$' then raise exception 'NexLoot: ungültige Session'; end if;
  update public.nexloot_setups set sess = v where id = p_id and guild = p_guild and status <> 'deleted';
  if not found then raise exception 'NexLoot: Setup gibt es nicht mehr'; end if;
  return jsonb_build_object('ok', true, 'id', p_id, 'sess', v);
end $$;

-- ---------------------------------------------------------------------
-- Klassen-Symbole für die Discord-Nachricht der Setups (Offiziere): {"WARRIOR": "<:Krieger:123456789012345678>", …}.
-- Ein leerer Eintrag nimmt das Symbol wieder weg. Ändert sich etwas, schreibt die Companion-App (ab 1.8.2) die
-- Nachrichten der kommenden Raids in den nächsten Minuten neu.
-- ---------------------------------------------------------------------
create or replace function public.nexloot_dc_emojis_set(p_guild text, p_map jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  me public.nexloot_users;
  m jsonb := '{}'::jsonb;
  old jsonb;
  e record;
  v text;
  n int := 0;
  now_s bigint := (extract(epoch from now()))::bigint;
begin
  me := public.nexloot_need_officer(p_guild);
  if p_map is null or jsonb_typeof(p_map) <> 'object' then raise exception 'NexLoot: ungültige Klassen-Symbole'; end if;
  for e in select x.key, x.value from jsonb_each(p_map) x loop
    if e.key not in ('WARRIOR', 'PALADIN', 'HUNTER', 'ROGUE', 'PRIEST', 'SHAMAN', 'MAGE', 'WARLOCK', 'DRUID',
                     'DEATHKNIGHT', 'MONK', 'DEMONHUNTER', 'EVOKER') then
      raise exception 'NexLoot: unbekannte Klasse %', left(e.key, 20);
    end if;
    continue when jsonb_typeof(e.value) = 'null';
    if jsonb_typeof(e.value) <> 'string' then raise exception 'NexLoot: ungültiges Symbol bei %', e.key; end if;
    v := btrim(e.value #>> '{}');
    continue when v = '';
    if v !~ '^<a?:[A-Za-z0-9_]{2,32}:[0-9]{15,25}>$' then
      raise exception 'NexLoot: ungültiges Symbol bei % (Emoji-Code wie <:Name:123456789012345678>)', e.key;
    end if;
    m := m || jsonb_build_object(e.key, v);
  end loop;
  old := public.nexloot_dc_emojis_of(p_guild);
  insert into public.nexloot_settings (guild, key, value, updated_by, updated_at) values (p_guild, 'dc_emojis', m, me.name, now())
    on conflict (guild, key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  if m is distinct from old then
    update public.nexloot_setups set dc_rev = 0
     where guild = p_guild and status = 'published' and dc_msg is not null and (starts_at is null or starts_at > now_s - 6 * 3600);
    get diagnostics n = row_count;
  end if;
  return jsonb_build_object('ok', true, 'emojis', m, 'redo', n);
end $$;

revoke all on function public.nexloot_my_discord() from public, anon, authenticated;
revoke all on function public.nexloot_touch(text) from public, anon, authenticated;
revoke all on function public.nexloot_is_officer(text, text) from public, anon, authenticated;
revoke all on function public.nexloot_known_char(text, text) from public, anon, authenticated;
revoke all on function public.nexloot_me_json(text, public.nexloot_users) from public, anon, authenticated;
revoke all on function public.nexloot_need_officer(text) from public, anon, authenticated;
revoke all on function public.nexloot_names_ok(jsonb, int) from public, anon, authenticated;
revoke all on function public.nexloot_fix_fav(text, text) from public, anon, authenticated;
revoke all on function public.nexloot_setup_people(text, text[]) from public, anon, authenticated;
revoke all on function public.nexloot_dc_emojis_of(text) from public, anon, authenticated;
revoke all on function public.nexloot_me(text) from public, anon;
revoke all on function public.nexloot_claim(text, text, boolean) from public, anon;
revoke all on function public.nexloot_unclaim(text, text) from public, anon;
revoke all on function public.nexloot_unlock(text, text) from public, anon;
revoke all on function public.nexloot_admin(text) from public, anon;
revoke all on function public.nexloot_link_set(text, text, text, text, boolean) from public, anon;
revoke all on function public.nexloot_role_set(text, text, text) from public, anon;
revoke all on function public.nexloot_setups(text) from public;
revoke all on function public.nexloot_setup_save(text, bigint, int, text, int, bigint, text, jsonb) from public, anon;
revoke all on function public.nexloot_setup_delete(text, bigint) from public, anon;
grant execute on function public.nexloot_me(text) to authenticated;
grant execute on function public.nexloot_claim(text, text, boolean) to authenticated;
grant execute on function public.nexloot_unclaim(text, text) to authenticated;
grant execute on function public.nexloot_unlock(text, text) to authenticated;
grant execute on function public.nexloot_admin(text) to authenticated;
grant execute on function public.nexloot_link_set(text, text, text, text, boolean) to authenticated;
grant execute on function public.nexloot_role_set(text, text, text) to authenticated;
grant execute on function public.nexloot_setups(text) to anon, authenticated;
grant execute on function public.nexloot_setup_save(text, bigint, int, text, int, bigint, text, jsonb) to authenticated;
grant execute on function public.nexloot_setup_delete(text, bigint) to authenticated;
-- für die Companion-App (mit dem Schreib-Passwort) bzw. lesend für alle
revoke all on function public.nexloot_setups_live(text) from public;
grant execute on function public.nexloot_setups_live(text) to anon, authenticated;
revoke all on function public.nexloot_setup_claim(text, text, text, text) from public;
grant execute on function public.nexloot_setup_claim(text, text, text, text) to anon, authenticated;
revoke all on function public.nexloot_setup_done(text, bigint, int, text, text, text, text) from public;
grant execute on function public.nexloot_setup_done(text, bigint, int, text, text, text, text) to anon, authenticated;
revoke all on function public.nexloot_setup_release(text, bigint, text) from public;
grant execute on function public.nexloot_setup_release(text, bigint, text) to anon, authenticated;
revoke all on function public.nexloot_setups_past(text, bigint, int) from public;
grant execute on function public.nexloot_setups_past(text, bigint, int) to anon, authenticated;
revoke all on function public.nexloot_setup_session(text, bigint, text) from public, anon;
grant execute on function public.nexloot_setup_session(text, bigint, text) to authenticated;
revoke all on function public.nexloot_dc_emojis_set(text, jsonb) from public, anon;
grant execute on function public.nexloot_dc_emojis_set(text, jsonb) to authenticated;
