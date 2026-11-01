-- =====================================================================
-- NexLoot – Raid-Helper anbinden (Webapp)
-- Ein Setup aus der Webapp hängt an einem Raid-Helper-Event. Die Webapp zeigt, wer sich bei Raid-Helper
-- angemeldet hat, schreibt die Gruppen in die Raid-Helper-Komposition (Comp-Tool) und lässt Raid-Helper sie im
-- Kanal des Events posten (mit Erwähnungen, mit Premium auch Bestätigen/Absagen; der Post aktualisiert sich).
-- Umgekehrt holt der Setup-Editor auf Knopfdruck eine Aufstellung, die im Comp-Tool von Raid-Helper gebaut wurde.
--
-- Einmal im Supabase "SQL Editor" ausführen (Run) – NACH nexloot_konten.sql. Kann gefahrlos noch einmal
-- ausgeführt werden. Vorher in Supabase -> Vault zwei Secrets anlegen (siehe ANLEITUNG, Schritt 10):
--   raidhelper_key    = der Server-API-Key von Raid-Helper (in Discord: /apikey)
--   raidhelper_server = die ID eures Discord-Servers
-- Der Key bleibt in Supabase: Webapp, Addon und Companion-App sehen ihn nie. Aufrufen dürfen das nur Offiziere.
-- Braucht die Erweiterung "http" (wird unten eingeschaltet; geht auch unter Database -> Extensions) und für das
-- Senden die Edge Function "nexloot-raidhelper" (Datei nexloot-raidhelper.ts, ANLEITUNG Schritt 10): Änderungen
-- nimmt Raid-Helper direkt aus der Datenbank nicht an.
-- English: optional Raid-Helper connection (GUIDE.txt, step 10). Needs the Vault secrets raidhelper_key and
-- raidhelper_server and the edge function nexloot-raidhelper. Run after nexloot_konten.sql. Safe to run again.
-- =====================================================================

do $$
begin
  if to_regproc('extensions.http') is null and to_regproc('public.http') is null then
    create extension if not exists http with schema extensions;
  end if;
end $$;

-- Zwischenspeicher für Events (Anmeldungen), damit die Webapp Raid-Helper nicht bei jedem Klick fragt
create table if not exists public.nexloot_rh_cache (
  guild      text        not null,
  event_id   text        not null,
  data       jsonb       not null,
  at         timestamptz not null default now(),
  primary key (guild, event_id)
);
alter table public.nexloot_rh_cache enable row level security;
revoke all on public.nexloot_rh_cache from anon, authenticated;

-- ---------------------------------------------------------------------
-- (intern) Secrets aus dem Vault, Aufruf der Raid-Helper-API, Antworten prüfen
-- ---------------------------------------------------------------------
create or replace function public.nexloot_rh_secret(p_name text)
returns text
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare v text;
begin
  begin
    execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1' into v using p_name;
  exception when others then v := null;
  end;
  return nullif(btrim(coalesce(v, '')), '');
end $$;

create or replace function public.nexloot_rh_server()
returns text
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare v text := public.nexloot_rh_secret('raidhelper_server');
begin
  if v is null or v !~ '^\d{5,25}$' then
    raise exception 'NexLoot: Raid-Helper ist noch nicht eingerichtet - in Supabase fehlt im Vault die Server-ID (raidhelper_server)';
  end if;
  return v;
end $$;

-- Adresse der Edge Function "nexloot-raidhelper" (über sie gehen Änderungen an Raid-Helper, siehe unten).
-- Aus dem Anmelde-Token der Webapp (Aussteller = https://<projekt>.supabase.co/auth/v1); im Vault kann man sie mit
-- raidhelper_relay auch fest eintragen. p_project (nur Fehlersuche im SQL Editor): die Projekt-Adresse.
-- null = unbekannt (z. B. im SQL Editor, da gibt es kein Anmelde-Token).
drop function if exists public.nexloot_rh_relay();
create or replace function public.nexloot_rh_relay(p_project text default null)
returns text
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare
  v text := public.nexloot_rh_secret('raidhelper_relay');
  iss text;
begin
  if v ~ '^https://' then return v; end if;
  if p_project ~ '^https://[A-Za-z0-9.-]+/?$' then return rtrim(p_project, '/') || '/functions/v1/nexloot-raidhelper'; end if;
  begin
    iss := nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'iss';
  exception when others then iss := null;
  end;
  if iss ~ '^https://[A-Za-z0-9.-]+/auth/v1/?$' then
    return regexp_replace(iss, '/auth/v1/?$', '') || '/functions/v1/nexloot-raidhelper';
  end if;
  return null;
end $$;

-- (intern) eine Änderung über die Edge Function schicken. Raid-Helper nimmt Änderungen (PATCH/POST) direkt aus der
-- Datenbank nicht an (die Verbindung wird ohne Antwort geschlossen), über die Edge Function schon.
-- Die Funktion bekommt den Key nur für diesen einen Aufruf und speichert nichts.
create or replace function public.nexloot_rh_via(p_url text, p_method text, p_path text, p_body jsonb, p_key text, p_tries int)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare
  hd jsonb;
  auth text;
  akey text;
  hs http_header[];
  r http_response;
  j jsonb;
  t int;
  n int := case when upper(p_method) = 'POST' then 1 else greatest(1, least(coalesce(p_tries, 2), 2)) end;
begin
  -- angemeldet wie in der Webapp (die Edge Function lässt nur angemeldete Aufrufe zu)
  begin
    hd := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then hd := null;
  end;
  akey := hd->>'apikey';
  auth := coalesce(hd->>'authorization', 'Bearer ' || akey);
  hs := array[http_header('x-rh-key', p_key), http_header('Expect', '')];
  if auth is not null then hs := hs || http_header('Authorization', auth); end if;
  if akey is not null then hs := hs || http_header('apikey', akey); end if;
  begin perform http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000'); exception when others then null; end;
  for t in 1..n loop
    begin
      r := http(('POST', p_url, hs, 'application/json',
                 jsonb_build_object('method', upper(p_method), 'path', p_path, 'body', coalesce(p_body, '{}'::jsonb))::text)::http_request);
      exit;
    exception when others then
      if t = n then
        raise exception 'NexLoot: Die Edge Function nexloot-raidhelper ist nicht erreichbar (%)', left(sqlerrm, 160);
      end if;
      perform pg_sleep(0.5);
    end;
  end loop;
  begin j := r.content::jsonb; exception when others then j := null; end;
  if jsonb_typeof(j) is distinct from 'object' then j := null; end if;
  if r.status = 404 and (j is null or not (j ? 'status')) then
    raise exception 'NexLoot: In Supabase fehlt noch die Edge Function nexloot-raidhelper (ANLEITUNG, Schritt 10)';
  end if;
  if r.status in (401, 403) and (j is null or not (j ? 'status')) then
    raise exception 'NexLoot: Die Edge Function nexloot-raidhelper lässt den Aufruf nicht zu (%)',
      left(coalesce(j->>'msg', j->>'message', j->>'error', r.content, ''), 160);
  end if;
  if j is null or j ? 'error' or not (j ? 'status') then
    raise exception 'NexLoot: Raid-Helper ist gerade nicht erreichbar (% % über die Edge Function: %)', upper(p_method), p_path,
      left(coalesce(j->>'error', r.content, ''), 160);
  end if;
  return jsonb_build_object('status', (j->>'status')::int, 'body', coalesce(j->'body', '{}'::jsonb));
end $$;

-- Rückgabe: {"status": HTTP-Status, "body": Antwort als JSON}. p_tries: so oft versuchen, wenn die Verbindung abbricht.
-- Änderungen (PATCH/POST) gehen über die Edge Function, wenn ihre Adresse bekannt ist (p_direct: trotzdem direkt).
-- (ältere Fassungen entfernen, sonst wären Aufrufe mehrdeutig)
drop function if exists public.nexloot_rh_call(text, text, jsonb, jsonb);
drop function if exists public.nexloot_rh_call(text, text, jsonb, jsonb, int);
create or replace function public.nexloot_rh_call(p_method text, p_path text, p_body jsonb default null, p_headers jsonb default null,
                                                   p_tries int default 3, p_direct boolean default false)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare
  k text := public.nexloot_rh_secret('raidhelper_key');
  m text := upper(p_method);
  n int := greatest(1, least(coalesce(p_tries, 3), 3));
  relay text;
  hs http_header[];
  r http_response;
  j jsonb;
  h record;
  t int;
begin
  if k is null then
    raise exception 'NexLoot: Raid-Helper ist noch nicht eingerichtet - in Supabase fehlt im Vault der API-Key (raidhelper_key)';
  end if;
  if m <> 'GET' and not coalesce(p_direct, false) then
    relay := public.nexloot_rh_relay();
    if relay is not null then
      return public.nexloot_rh_via(relay, m, p_path, p_body, k, n);
    end if;
  end if;
  hs := array[http_header('Authorization', k)];
  for h in select x.key, x.value from jsonb_each_text(coalesce(p_headers, '{}'::jsonb)) x loop
    hs := hs || http_header(h.key, h.value);
  end loop;
  -- Daten gleich mitschicken: ohne "Expect: 100-continue" (das hängt curl bei PATCH sonst von selbst an)
  if p_body is not null and not (coalesce(p_headers, '{}'::jsonb) ? 'Expect') then
    hs := hs || http_header('Expect', '');
  end if;
  begin perform http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000'); exception when others then null; end;
  for t in 1..n loop
    begin
      r := http((m, 'https://raid-helper.xyz/api/v4' || p_path, hs,
                 case when p_body is null then null else 'application/json; charset=utf-8' end,
                 case when p_body is null then null else p_body::text end)::http_request);
      exit;
    exception when others then
      -- bricht die Verbindung ab: noch einmal mit frischer Verbindung. Eine Ankündigung (POST) nur, wenn gar keine
      -- Verbindung zustande kam - sonst stünde sie womöglich doppelt in Discord.
      if t = n or (m = 'POST' and sqlerrm !~* '(could not resolve|couldn''t connect|failed to connect|connection refused|connection timed out|ssl connect)') then
        raise exception 'NexLoot: Raid-Helper ist gerade nicht erreichbar (% %: %)', m, p_path, left(sqlerrm, 160);
      end if;
      begin perform http_reset_curlopt(); exception when others then null; end;
      begin perform http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000'); exception when others then null; end;
      perform pg_sleep(0.5 * t);
    end;
  end loop;
  begin j := r.content::jsonb; exception when others then j := jsonb_build_object('reason', left(coalesce(r.content, ''), 200)); end;
  return jsonb_build_object('status', r.status, 'body', j);
end $$;

create or replace function public.nexloot_rh_okay(p_res jsonb)
returns boolean
language sql immutable
as $$
  select coalesce((p_res->>'status')::int, 0) between 200 and 299 and coalesce(p_res->'body'->>'status', '') <> 'failed'
$$;

-- Antwort prüfen: bei Erfolg die Antwort, sonst eine verständliche Fehlermeldung
create or replace function public.nexloot_rh_need(p_res jsonb, p_what text)
returns jsonb
language plpgsql immutable
as $$
declare
  st int := coalesce((p_res->>'status')::int, 0);
  why text := coalesce(p_res->'body'->>'reason', p_res->'body'->>'message', p_res->'body'->>'error', 'Fehler ' || st);
begin
  if public.nexloot_rh_okay(p_res) then return p_res->'body'; end if;
  if st in (401, 403) and why ~* '(auth|api ?key|token)' then
    raise exception 'NexLoot: Raid-Helper lehnt den API-Key ab - in Discord mit /apikey prüfen und im Vault neu eintragen';
  end if;
  raise exception 'NexLoot: Raid-Helper (%): %', p_what, left(why, 200);
end $$;

-- ---------------------------------------------------------------------
-- (intern) Klassen, Spezialisierungen und Anmeldungen zuordnen
-- ---------------------------------------------------------------------
create or replace function public.nexloot_rh_norm(t text)
returns text
language sql immutable
as $$
  select regexp_replace(lower(translate(coalesce(t, ''), 'ÄÖÜäöüß', 'AOUaous')), '[^a-z]', '', 'g')
$$;

-- unsere Klasse -> so kann sie bei Raid-Helper heißen (vereinfacht geschrieben)
create or replace function public.nexloot_rh_cls_names(p_cls text)
returns text[]
language sql immutable
as $$
  select case p_cls
    when 'WARRIOR' then array['warrior', 'krieger'] when 'PALADIN' then array['paladin'] when 'HUNTER' then array['hunter', 'jager', 'jaeger']
    when 'ROGUE' then array['rogue', 'schurke'] when 'PRIEST' then array['priest', 'priester'] when 'SHAMAN' then array['shaman', 'schamane']
    when 'MAGE' then array['mage', 'magier'] when 'WARLOCK' then array['warlock', 'hexenmeister'] when 'DRUID' then array['druid', 'druide']
    when 'DEATHKNIGHT' then array['deathknight', 'dk', 'todesritter'] when 'MONK' then array['monk', 'monch', 'moench']
    when 'DEMONHUNTER' then array['demonhunter', 'dh', 'damonenjager'] when 'EVOKER' then array['evoker', 'rufer']
    else array[]::text[] end
$$;

-- Raid-Helper-Klasse (bei Klassen-Vorlagen) -> unsere Klasse
create or replace function public.nexloot_rh_class_key(p_name text)
returns text
language sql immutable
as $$
  select k from unnest(array['WARRIOR', 'PALADIN', 'HUNTER', 'ROGUE', 'PRIEST', 'SHAMAN', 'MAGE', 'WARLOCK', 'DRUID',
                             'DEATHKNIGHT', 'MONK', 'DEMONHUNTER', 'EVOKER']) k
   where public.nexloot_rh_norm(p_name) = any(public.nexloot_rh_cls_names(k)) limit 1
$$;

-- Raid-Helper-Spezialisierung -> unsere Klasse. Bei Vorlagen nach Rollen (z. B. "wowforever": Tank, Melee, Ranged,
-- Healer) steckt die Klasse nur im Spec-Namen; doppelte Namen haben eine Ziffer (Holy = Priester, Holy1 = Paladin).
create or replace function public.nexloot_rh_spec_class(p_spec text)
returns text
language sql immutable
as $$
  select case regexp_replace(lower(coalesce(p_spec, '')), '[^a-z0-9]', '', 'g')
    when 'arms' then 'WARRIOR' when 'fury' then 'WARRIOR' when 'protection' then 'WARRIOR'
    when 'holy1' then 'PALADIN' when 'protection1' then 'PALADIN' when 'retribution' then 'PALADIN'
    when 'beastmastery' then 'HUNTER' when 'marksmanship' then 'HUNTER' when 'survival' then 'HUNTER'
    when 'assassination' then 'ROGUE' when 'combat' then 'ROGUE' when 'subtlety' then 'ROGUE' when 'outlaw' then 'ROGUE'
    when 'discipline' then 'PRIEST' when 'holy' then 'PRIEST' when 'shadow' then 'PRIEST' when 'smite' then 'PRIEST'
    when 'elemental' then 'SHAMAN' when 'enhancement' then 'SHAMAN' when 'restoration1' then 'SHAMAN'
    when 'arcane' then 'MAGE' when 'fire' then 'MAGE' when 'frost' then 'MAGE'
    when 'affliction' then 'WARLOCK' when 'demonology' then 'WARLOCK' when 'destruction' then 'WARLOCK'
    when 'balance' then 'DRUID' when 'feral' then 'DRUID' when 'guardian' then 'DRUID' when 'restoration' then 'DRUID'
    else null end
$$;

-- Spec zu einem Talentbaum (Reihenfolge wie im Spiel; Namen wie bei Raid-Helper)
create or replace function public.nexloot_rh_tree_spec(p_cls text, p_tree int)
returns text
language sql immutable
as $$
  select (case p_cls
    when 'WARRIOR' then array['Arms', 'Fury', 'Protection'] when 'PALADIN' then array['Holy1', 'Protection1', 'Retribution']
    when 'HUNTER' then array['Beastmastery', 'Marksmanship', 'Survival'] when 'ROGUE' then array['Assassination', 'Combat', 'Subtlety']
    when 'PRIEST' then array['Discipline', 'Holy', 'Shadow'] when 'SHAMAN' then array['Elemental', 'Enhancement', 'Restoration1']
    when 'MAGE' then array['Arcane', 'Fire', 'Frost'] when 'WARLOCK' then array['Affliction', 'Demonology', 'Destruction']
    when 'DRUID' then array['Balance', 'Feral', 'Restoration'] else null end)[p_tree]
$$;

-- Baum mit den meisten Punkten aus "0/31/20" (1, 2 oder 3; null = unbekannt)
create or replace function public.nexloot_rh_top_tree(p_talents text)
returns int
language sql immutable
as $$
  select t.i::int from unnest(string_to_array(coalesce(p_talents, ''), '/')) with ordinality as t(v, i)
   where t.v ~ '^\d+$' and t.v::int > 0 order by t.v::int desc, t.i limit 1
$$;

-- unsere Klasse zu einer Anmeldung bzw. zu einem Paar aus Raid-Helper-Klasse und Spezialisierung
create or replace function public.nexloot_rh_wow_class(p_cls text, p_spec text)
returns text
language sql immutable
as $$
  select coalesce(public.nexloot_rh_class_key(p_cls), public.nexloot_rh_spec_class(p_spec))
$$;

-- Rolle einer Raid-Helper-Spezialisierung: T, H, D ('' = unbekannt)
create or replace function public.nexloot_rh_spec_role(sp jsonb)
returns text
language sql immutable
as $$
  select case
    when public.nexloot_rh_norm(sp->>'roleName') like '%tank%' then 'T'
    when public.nexloot_rh_norm(sp->>'roleName') like '%heal%' then 'H'
    when public.nexloot_rh_norm(sp->>'roleName') ~ '(melee|ranged|dps|damage)' then 'D'
    when public.nexloot_rh_norm(sp->>'name') in ('protection', 'guardian', 'bear', 'blood', 'vengeance', 'brewmaster') then 'T'
    when public.nexloot_rh_norm(sp->>'name') in ('holy', 'restoration', 'discipline', 'resto', 'mistweaver', 'preservation') then 'H'
    when coalesce(sp->>'name', '') <> '' then 'D'
    else '' end
$$;

-- Art einer Anmeldung: ok, tentative (vorläufig), late (später), bench (Ersatzbank), absent (abgemeldet)
create or replace function public.nexloot_rh_kind(p_cls text)
returns text
language sql immutable
as $$
  select case public.nexloot_rh_norm(p_cls) when 'absence' then 'absent' when 'tentative' then 'tentative' when 'late' then 'late'
    when 'bench' then 'bench' else 'ok' end
$$;

create or replace function public.nexloot_rh_arr(v jsonb)
returns jsonb
language sql immutable
as $$
  select case when jsonb_typeof(v) = 'array' then v else '[]'::jsonb end
$$;

-- Klasse eines Charakters (Gildenliste, sonst aus dem Spielstand)
create or replace function public.nexloot_rh_char_class(p_guild text, p_char text)
returns text
language sql stable security definer
set search_path = public
as $$
  select coalesce((select m.class from public.nexloot_members m where m.guild = p_guild and m.name = p_char),
                  (select st.data->'classes'->>p_char from public.nexloot_state st where st.guild = p_guild))
$$;

-- Event von Raid-Helper (öffentlich lesbar); 60 Sekunden zwischengespeichert
create or replace function public.nexloot_rh_event_data(p_guild text, p_event text, p_fresh boolean)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare
  c public.nexloot_rh_cache;
  b jsonb;
begin
  if coalesce(p_event, '') !~ '^\d{5,25}$' then raise exception 'NexLoot: ungültiges Raid-Helper-Event'; end if;
  select * into c from public.nexloot_rh_cache where guild = p_guild and event_id = p_event;
  if found and not coalesce(p_fresh, false) and c.at > now() - interval '60 seconds' then return c.data; end if;
  b := public.nexloot_rh_need(public.nexloot_rh_call('GET', '/events/' || p_event), 'Event');
  insert into public.nexloot_rh_cache (guild, event_id, data, at) values (p_guild, p_event, b, now())
    on conflict (guild, event_id) do update set data = excluded.data, at = excluded.at;
  delete from public.nexloot_rh_cache where at < now() - interval '2 days';
  return b;
end $$;

-- Anmeldungen eines Events mit den passenden Charakteren (über die Discord-Verknüpfung in der Webapp):
-- passt die Klasse der Anmeldung zu einem Charakter, dieser; sonst der Lieblings-Charakter (bzw. alle)
create or replace function public.nexloot_rh_signups(p_guild text, ev jsonb)
returns jsonb
language sql stable security definer
set search_path = public
as $$
  with su as (
    select x.v as s, x.v->>'userId' as did, coalesce(x.v->>'className', '') as cls, public.nexloot_rh_kind(x.v->>'className') as kind,
           public.nexloot_rh_wow_class(x.v->>'className', x.v->>'specName') as wcls,
           coalesce(nullif(substring(x.v->>'position' from '^\d+'), '')::int, 0) as pos
      from jsonb_array_elements(public.nexloot_rh_arr(ev->'signUps')) as x(v)
  ),
  ch as (
    select l.discord_id, l.char_name, l.fav, public.nexloot_rh_char_class(p_guild, l.char_name) as cls
      from public.nexloot_links l where l.guild = p_guild
  )
  select coalesce(jsonb_agg(jsonb_build_object('name', su.s->>'name', 'did', su.did, 'cls', su.cls, 'spec', su.s->>'specName', 'kind', su.kind,
           'pos', su.pos, 'chars', coalesce((
             select jsonb_agg(c.char_name order by c.char_name) from ch c
              where c.discord_id = su.did
                and (c.cls = su.wcls
                     or (not exists (select 1 from ch c2 where c2.discord_id = su.did and c2.cls = su.wcls)
                         and (c.fav or not exists (select 1 from ch c3 where c3.discord_id = su.did and c3.fav))))), '[]'::jsonb))
           order by su.pos, su.s->>'name'), '[]'::jsonb)
    from su
$$;

-- ---------------------------------------------------------------------
-- Webapp (nur Offiziere): kommende Raid-Helper-Events, ein Event mit Anmeldungen, Setup verknüpfen, senden
-- ---------------------------------------------------------------------
create or replace function public.nexloot_rh_events(p_guild text)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare
  now_s bigint := (extract(epoch from now()))::bigint;
  b jsonb;
begin
  perform public.nexloot_need_officer(p_guild);
  b := public.nexloot_rh_need(public.nexloot_rh_call('GET', '/servers/' || public.nexloot_rh_server() || '/events', null,
         jsonb_build_object('StartTimeFilter', (now_s - 6 * 3600)::text)), 'Events');
  return jsonb_build_object(
    'events', coalesce((select jsonb_agg(t.e order by (t.e->>'start')::bigint nulls last, t.e->>'id') from (
        select jsonb_build_object('id', x.v->>'id', 'title', coalesce(nullif(x.v->>'title', ''), nullif(x.v->>'displayTitle', ''), '?'),
                 'start', nullif(substring(x.v->>'startTime' from '^\d+'), '')::bigint, 'channel', x.v->>'channelId', 'channelName', x.v->>'channelName',
                 'signups', coalesce(nullif(substring(x.v->>'signUpCount' from '^\d+'), '')::int, jsonb_array_length(public.nexloot_rh_arr(x.v->'signUps')))) as e
          from jsonb_array_elements(public.nexloot_rh_arr(b->'postedEvents')) as x(v)
         where x.v->>'id' ~ '^\d{5,25}$'
           and coalesce(nullif(substring(x.v->>'startTime' from '^\d+'), '')::bigint, now_s) > now_s - 6 * 3600
         order by nullif(substring(x.v->>'startTime' from '^\d+'), '')::bigint nulls last limit 40) t), '[]'::jsonb),
    'linked', coalesce((select jsonb_object_agg(s.rh_event, s.id) from public.nexloot_setups s
                         where s.guild = p_guild and s.rh_event is not null and s.status <> 'deleted'), '{}'::jsonb));
end $$;

create or replace function public.nexloot_rh_event(p_guild text, p_event text, p_fresh boolean default false)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare ev jsonb;
begin
  perform public.nexloot_need_officer(p_guild);
  ev := public.nexloot_rh_event_data(p_guild, p_event, p_fresh);
  return jsonb_build_object('id', ev->>'id', 'title', ev->>'title', 'start', nullif(substring(ev->>'startTime' from '^\d+'), '')::bigint,
    'channel', ev->>'channelId', 'channelName', ev->>'channelName', 'signups', public.nexloot_rh_signups(p_guild, ev));
end $$;

-- Aufstellung aus dem Comp-Tool von Raid-Helper holen und den Charakteren zuordnen (der Setup-Editor übernimmt sie
-- in die Gruppen; gespeichert wird erst mit dem Editor). Zuordnung eines Platzes: über die Discord-Verknüpfung der
-- Charakter mit der Klasse des Platzes, sonst der Lieblings-Charakter, sonst der erste; ohne Verknüpfung ein
-- Charakter der Gilde mit genau diesem Namen. Jeder Charakter höchstens einmal.
-- Rückgabe: {"title", "groupCount", "slotCount", "slots": [{"group", "slot", "name", "char" (fehlt = keiner gefunden),
-- "cls", "spec", "confirmed", "linked"}]}
create or replace function public.nexloot_rh_comp(p_guild text, p_event text)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare
  res jsonb;
  cr jsonb;
  out jsonb := '[]'::jsonb;
  used text[] := '{}';
  x record;
  ch text;
  wcls text;
  did text;
begin
  perform public.nexloot_need_officer(p_guild);
  if coalesce(p_event, '') !~ '^\d{5,25}$' then raise exception 'NexLoot: ungültiges Raid-Helper-Event'; end if;
  res := public.nexloot_rh_call('GET', '/comps/' || p_event);
  if coalesce((res->>'status')::int, 0) = 404 or coalesce(res->'body'->>'reason', '') ~* 'unknown comp' then
    raise exception 'NexLoot: Raid-Helper hat für dieses Event noch keine Komposition';
  end if;
  cr := public.nexloot_rh_need(res, 'Komposition');
  for x in select t.v,
                  coalesce(nullif(substring(t.v->>'groupNumber' from '^\d+'), '')::int, 0) as g,
                  coalesce(nullif(substring(t.v->>'slotNumber' from '^\d+'), '')::int, 0) as s
             from jsonb_array_elements(public.nexloot_rh_arr(cr->'slots')) as t(v)
            order by 2, 3
  loop
    ch := null;
    did := nullif(btrim(coalesce(x.v->>'userId', '')), '');
    wcls := public.nexloot_rh_wow_class(x.v->>'className', x.v->>'specName');
    if did is not null then
      select l.char_name into ch from public.nexloot_links l
       where l.guild = p_guild and l.discord_id = did and not (l.char_name = any(used))
       order by coalesce(wcls is not null and public.nexloot_rh_char_class(p_guild, l.char_name) = wcls, false) desc, l.fav desc, l.char_name
       limit 1;
    end if;
    if ch is null and coalesce(btrim(x.v->>'name'), '') <> '' then
      -- ohne (passende) Discord-Verknüpfung: ein Charakter der Gilde mit genau diesem Namen
      select m.name into ch from public.nexloot_members m
       where m.guild = p_guild and lower(m.name) = lower(btrim(x.v->>'name')) and not (m.name = any(used))
       limit 1;
    end if;
    if ch is not null then used := used || ch; end if;
    out := out || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('group', x.g, 'slot', x.s, 'name', coalesce(nullif(btrim(x.v->>'name'), ''), '?'),
             'char', ch, 'cls', x.v->>'className', 'spec', x.v->>'specName', 'confirmed', x.v->>'isConfirmed', 'linked', did is not null)));
  end loop;
  return jsonb_build_object('title', cr->>'title', 'groupCount', cr->'groupCount', 'slotCount', cr->'slotCount', 'slots', out);
end $$;

-- Setup an ein Raid-Helper-Event hängen (leer = lösen). Ändert das Setup selbst nicht.
create or replace function public.nexloot_setup_rh_link(p_guild text, p_id bigint, p_event text)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare
  me public.nexloot_users;
  v text := nullif(btrim(coalesce(p_event, '')), '');
  ev jsonb;
  srv text;
begin
  me := public.nexloot_need_officer(p_guild);
  if v is not null then
    if v !~ '^\d{5,25}$' then raise exception 'NexLoot: ungültiges Raid-Helper-Event'; end if;
    ev := public.nexloot_rh_event_data(p_guild, v, true);
    srv := public.nexloot_rh_secret('raidhelper_server');
    if srv is not null and coalesce(ev->>'serverId', srv) <> srv then
      raise exception 'NexLoot: Das Raid-Helper-Event gehört zu einem anderen Discord-Server';
    end if;
  end if;
  update public.nexloot_setups
     set rh_event = v,
         rh_ann = case when v is distinct from rh_event then null else rh_ann end,
         rh_sent_at = case when v is distinct from rh_event then null else rh_sent_at end,
         rh_sent_rev = case when v is distinct from rh_event then null else rh_sent_rev end,
         rh_sent_by = case when v is distinct from rh_event then null else rh_sent_by end
   where id = p_id and guild = p_guild and status <> 'deleted';
  if not found then raise exception 'NexLoot: Setup gibt es nicht mehr'; end if;
  return jsonb_build_object('ok', true, 'id', p_id, 'rh_event', v);
end $$;

-- (intern) Komposition aus einem Setup bauen. ev = das Event (Anmeldungen, Klassen der Vorlage), cr = die bisherige
-- Komposition (Bestätigungen, Gruppennamen, Klassen) oder null. Rückgabe: {"payload": Inhalt für PATCH /comps,
-- "nouser": ohne Discord-Verknüpfung, "nosignup": nicht angemeldet, "skipped": Klasse unbekannt (nicht gesendet),
-- "guessed": Spec geraten (weder Anmeldung noch Rolle noch Talente bekannt)}
create or replace function public.nexloot_rh_build(p_guild text, s public.nexloot_setups, ev jsonb, cr jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare
  ccl jsonb := public.nexloot_rh_arr(cr->'classes');
  conf jsonb := '{}'::jsonb;
  slots jsonb := '[]'::jsonb;
  seen text[] := '{}';
  g jsonb;
  gi int := 0;
  si int;
  ng int := greatest(1, least(8, round(s.size / 5.0)::int));
  nm text;
  did text;
  ccls text;
  crole text;
  ctal text;
  tspec text;
  drole text;
  guess boolean;
  su jsonb;
  cname text;
  sname text;
  grp jsonb;
  nouser text[] := '{}';
  nosign text[] := '{}';
  noclass text[] := '{}';
  guessed text[] := '{}';
begin
  -- bisherige Komposition: Bestätigungen merken
  select coalesce(jsonb_object_agg(coalesce(x.v->>'userId', 'n:' || lower(x.v->>'name')), x.v->>'isConfirmed'), '{}'::jsonb) into conf
    from jsonb_array_elements(public.nexloot_rh_arr(cr->'slots')) as x(v)
   where coalesce(x.v->>'isConfirmed', '') <> '' and coalesce(x.v->>'userId', x.v->>'name', '') <> '';
  for g in select x.v from jsonb_array_elements(public.nexloot_rh_arr(s.data->'groups')) as x(v) loop
    gi := gi + 1;
    exit when gi > ng;
    si := 0;
    for nm in select y.v from jsonb_array_elements_text(public.nexloot_rh_arr(g)) as y(v) loop
      si := si + 1;
      exit when si > 5;
      did := (select l.discord_id from public.nexloot_links l where l.guild = p_guild and l.char_name = nm);
      ccls := public.nexloot_rh_char_class(p_guild, nm);
      crole := null; ctal := null; guess := false;
      select m.role, m.talents into crole, ctal from public.nexloot_members m where m.guild = p_guild and m.name = nm;
      if coalesce(crole, '') = '' and ccls in ('ROGUE', 'MAGE', 'WARLOCK', 'HUNTER') then crole := 'D'; end if;
      su := null;
      if did is not null then
        select x.v into su from jsonb_array_elements(public.nexloot_rh_arr(ev->'signUps')) as x(v)
         where x.v->>'userId' = did and public.nexloot_rh_kind(x.v->>'className') = 'ok'
         order by (public.nexloot_rh_wow_class(x.v->>'className', x.v->>'specName') is not distinct from ccls) desc limit 1;
      end if;
      cname := null; sname := null;
      if su is not null and (ccls is null or public.nexloot_rh_wow_class(su->>'className', su->>'specName') is not distinct from ccls
                             or public.nexloot_rh_wow_class(su->>'className', su->>'specName') is null) then
        -- angemeldet: genau so, wie bei Raid-Helper
        cname := su->>'className';
        sname := nullif(su->>'specName', '');
      elsif ccls is not null then
        -- sonst: die Spec des Talentbaums mit den meisten Punkten, wenn sie zur Rolle passt (Talente schickt das Addon ab 0.29)
        tspec := public.nexloot_rh_tree_spec(ccls, public.nexloot_rh_top_tree(ctal));
        if tspec is not null then
          select c.v->>'name', sp.v->>'name' into cname, sname
            from jsonb_array_elements(public.nexloot_rh_arr(ev->'classes')) with ordinality as c(v, ci),
                 jsonb_array_elements(public.nexloot_rh_arr(c.v->'specs')) with ordinality as sp(v, si)
           where ((public.nexloot_rh_class_key(c.v->>'name') is null and lower(sp.v->>'name') = lower(tspec))
                  or (public.nexloot_rh_class_key(c.v->>'name') = ccls and public.nexloot_rh_norm(sp.v->>'name') = public.nexloot_rh_norm(tspec)))
             and (coalesce(crole, '') = '' or public.nexloot_rh_spec_role(sp.v) = crole)
           order by c.ci, sp.si limit 1;
        end if;
        -- sonst: erste Spezialisierung der Klasse mit der Rolle (Vorlagen nach Klassen oder nach Rollen)
        if cname is null and coalesce(crole, '') <> '' then
          select c.v->>'name', sp.v->>'name' into cname, sname
            from jsonb_array_elements(public.nexloot_rh_arr(ev->'classes')) with ordinality as c(v, ci),
                 jsonb_array_elements(public.nexloot_rh_arr(c.v->'specs')) with ordinality as sp(v, si)
           where public.nexloot_rh_wow_class(c.v->>'name', sp.v->>'name') = ccls and public.nexloot_rh_spec_role(sp.v) = crole
           order by c.ci, sp.si limit 1;
        end if;
        -- Rolle unbekannt: die übliche Raid-Rolle der Klasse (Krieger Schaden; Paladin, Priester, Schamane, Druide Heiler)
        if cname is null and coalesce(crole, '') = '' then
          drole := case ccls when 'PALADIN' then 'H' when 'PRIEST' then 'H' when 'SHAMAN' then 'H' when 'DRUID' then 'H' else 'D' end;
          select c.v->>'name', sp.v->>'name' into cname, sname
            from jsonb_array_elements(public.nexloot_rh_arr(ev->'classes')) with ordinality as c(v, ci),
                 jsonb_array_elements(public.nexloot_rh_arr(c.v->'specs')) with ordinality as sp(v, si)
           where public.nexloot_rh_wow_class(c.v->>'name', sp.v->>'name') = ccls and public.nexloot_rh_spec_role(sp.v) = drole
           order by c.ci, sp.si limit 1;
          guess := cname is not null;
        end if;
        -- Vorlage mit Klassen ohne passende Spezialisierung: nur die Klasse
        if cname is null then
          select c.v->>'name' into cname from jsonb_array_elements(public.nexloot_rh_arr(ev->'classes')) as c(v)
           where public.nexloot_rh_class_key(c.v->>'name') = ccls limit 1;
        end if;
        -- zur Not: irgendeine Spezialisierung der Klasse
        if cname is null then
          select c.v->>'name', sp.v->>'name' into cname, sname
            from jsonb_array_elements(public.nexloot_rh_arr(ev->'classes')) with ordinality as c(v, ci),
                 jsonb_array_elements(public.nexloot_rh_arr(c.v->'specs')) with ordinality as sp(v, si)
           where public.nexloot_rh_wow_class(c.v->>'name', sp.v->>'name') = ccls
           order by c.ci, sp.si limit 1;
          guess := cname is not null;
        end if;
      end if;
      -- nur Klassen und Specs, die die Komposition kennt
      if cname is not null and jsonb_array_length(ccl) > 0 then
        if not exists (select 1 from jsonb_array_elements(ccl) as c(v) where c.v->>'name' = cname) then
          cname := null; sname := null;
        elsif sname is not null and not exists (select 1 from jsonb_array_elements(ccl) as c(v), jsonb_array_elements(public.nexloot_rh_arr(c.v->'specs')) as sp(v)
                                                 where c.v->>'name' = cname and sp.v->>'name' = sname) then
          sname := null;
        end if;
      end if;
      if did is null then nouser := nouser || nm; elsif su is null then nosign := nosign || nm; end if;
      if cname is null then
        -- ohne Klasse kann Raid-Helper mit dem Platz nichts anfangen: nicht senden (die Webapp nennt die Namen)
        noclass := noclass || nm;
        continue;
      end if;
      if guess then guessed := guessed || nm; end if;
      -- ein Discord-Konto steht bei Raid-Helper auf höchstens einem Platz (die ID des Platzes ist die des Spielers)
      if did is not null and did = any(seen) then did := null; end if;
      if did is not null then seen := seen || did; end if;
      slots := slots || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('groupNumber', gi, 'slotNumber', si, 'name', nm,
                 'id', did, 'userId', did, 'className', cname, 'specName', sname,
                 'isConfirmed', coalesce(conf->>coalesce(did, 'n:' || lower(nm)), 'unconfirmed'))));
    end loop;
  end loop;
  -- Gruppen (Namen aus Raid-Helper behalten); Anzeige-Einstellungen der Komposition bleiben, wie sie bei Raid-Helper sind
  select jsonb_agg(jsonb_build_object('name', coalesce((select x.v->>'name' from jsonb_array_elements(public.nexloot_rh_arr(cr->'groups')) as x(v)
                                                        where x.v->>'position' = i::text limit 1), 'Group ' || i), 'position', i) order by i)
    into grp from generate_series(1, ng) as i;
  return jsonb_build_object(
    'payload', jsonb_build_object('title', left(s.title, 100), 'groupCount', ng, 'slotCount', 5, 'groups', grp, 'slots', slots),
    'nouser', to_jsonb(nouser), 'nosignup', to_jsonb(nosign), 'skipped', to_jsonb(noclass), 'guessed', to_jsonb(guessed));
end $$;

-- Gruppen in die Raid-Helper-Komposition schreiben. Beim ersten Mal (oder mit p_new_post) postet Raid-Helper sie
-- im Kanal des Events: mit Erwähnung der Spieler, mit Premium aktualisiert sich der Post danach von selbst und
-- die Spieler können bestätigen/absagen. Bestätigungen von Spielern, die eingeteilt bleiben, gehen nicht verloren.
create or replace function public.nexloot_rh_send(p_guild text, p_id bigint, p_new_post boolean default false)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare
  me public.nexloot_users;
  s public.nexloot_setups;
  ev jsonb;
  cr jsonb;
  b jsonb;
  res jsonb;
  ab jsonb;
  ann boolean;
  prem boolean := true;
  chan text;
  bench text;
begin
  me := public.nexloot_need_officer(p_guild);
  select * into s from public.nexloot_setups where id = p_id and guild = p_guild and status <> 'deleted' for update;
  if not found then raise exception 'NexLoot: Setup gibt es nicht mehr'; end if;
  if s.status <> 'published' then raise exception 'NexLoot: Erst veröffentlichen, dann an Raid-Helper senden'; end if;
  if s.rh_event is null then raise exception 'NexLoot: Das Setup hängt noch an keinem Raid-Helper-Event'; end if;
  -- Event mit Anmeldungen (höchstens eine Minute alt), bisherige Komposition
  ev := public.nexloot_rh_event_data(p_guild, s.rh_event, false);
  cr := public.nexloot_rh_call('GET', '/comps/' || s.rh_event);
  b := public.nexloot_rh_build(p_guild, s, ev, case when public.nexloot_rh_okay(cr) then cr->'body' else null end);
  res := public.nexloot_rh_call('PATCH', '/comps/' || s.rh_event, b->'payload');
  if not public.nexloot_rh_okay(res) and coalesce(res->'body'->>'reason', '') ~* 'unknown comp' then
    raise exception 'NexLoot: Raid-Helper hat für dieses Event noch keine Komposition - bei Raid-Helper einmal das Comp-Tool des Events öffnen, dann noch einmal senden';
  end if;
  perform public.nexloot_rh_need(res, 'Komposition');
  ann := coalesce(p_new_post, false) or s.rh_ann is distinct from s.rh_event;
  if ann then
    chan := coalesce(ev->>'channelId', '');
    if chan !~ '^\d{5,25}$' then raise exception 'NexLoot: Raid-Helper hat keinen Kanal für das Event geliefert'; end if;
    bench := (select string_agg(x.v, ', ') from jsonb_array_elements_text(public.nexloot_rh_arr(s.data->'bench')) as x(v));
    ab := jsonb_build_object('channelId', chan, 'mentions', 'signed', 'confirmation', 'updatingAndConfirming');
    if bench is not null then ab := ab || jsonb_build_object('description', left('Ersatzbank: ' || bench, 1500)); end if;
    res := public.nexloot_rh_call('POST', '/comps/' || s.rh_event || '/announcements', ab);
    if not public.nexloot_rh_okay(res) and coalesce(res->'body'->>'reason', '') ~* 'premium' then
      prem := false;  -- ohne Premium: ein einfacher Post (aktualisiert sich nicht)
      res := public.nexloot_rh_call('POST', '/comps/' || s.rh_event || '/announcements', ab - 'confirmation');
    end if;
    perform public.nexloot_rh_need(res, 'Ankündigung');
  end if;
  update public.nexloot_setups
     set rh_sent_at = (extract(epoch from now()))::bigint, rh_sent_rev = s.rev, rh_sent_by = me.name,
         rh_ann = case when ann and prem then s.rh_event when ann then null else rh_ann end
   where id = s.id;
  return jsonb_build_object('ok', true, 'posted', ann, 'premium', prem, 'slots', jsonb_array_length(b->'payload'->'slots'),
    'nouser', b->'nouser', 'nosignup', b->'nosignup', 'skipped', b->'skipped', 'guessed', b->'guessed');
end $$;

-- Fehlersuche, nur im Supabase SQL Editor: liest Event und Komposition des zuletzt geänderten Setups mit
-- Raid-Helper-Event, zeigt, welche Plätze gesendet würden, probiert eine Änderung direkt aus der Datenbank (das lässt
-- Raid-Helper derzeit nicht zu) und über die Edge Function (so sendet die Webapp). Postet nichts in Discord, schreibt
-- aber die Komposition des Events (wie das Senden).
-- Aufruf:  select * from nexloot_rh_check(null, 'https://<projekt>.supabase.co');
--          (Projekt-Adresse wie in der Webapp; ein bestimmtes Setup: statt null seine Nummer)
drop function if exists public.nexloot_rh_check(bigint);
create or replace function public.nexloot_rh_check(p_setup bigint default null, p_project text default null)
returns table (schritt text, ergebnis text)
language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare
  st public.nexloot_setups;
  ev jsonb := '{}'::jsonb;
  cr jsonb;
  b jsonb;
  pl jsonb;
  res jsonb;
  t record;
  relay text;
  r http_response;
  j jsonb;
begin
  select * into st from public.nexloot_setups x
   where x.rh_event is not null and x.status <> 'deleted' and (p_setup is null or x.id = p_setup)
   order by x.updated_at desc limit 1;
  schritt := '0 Setup';
  if not found then ergebnis := 'kein Setup mit Raid-Helper-Event gefunden'; return next; return; end if;
  ergebnis := st.title || ' (Nr. ' || st.id || ', ' || st.status || ', Event ' || st.rh_event || ')';
  return next;
  schritt := '1 Event lesen';
  begin
    res := public.nexloot_rh_call('GET', '/events/' || st.rh_event, null, null, 1);
    if public.nexloot_rh_okay(res) then ev := res->'body'; end if;
    ergebnis := (res->>'status') || case when public.nexloot_rh_okay(res) then ' ok, ' || jsonb_array_length(public.nexloot_rh_arr(ev->'signUps')) || ' Anmeldungen'
                                         else ' ' || left(coalesce(res->'body'->>'reason', ''), 200) end;
  exception when others then ergebnis := 'Fehler: ' || left(sqlerrm, 250);
  end;
  return next;
  perform pg_sleep(1);
  schritt := '2 Komposition lesen';
  begin
    res := public.nexloot_rh_call('GET', '/comps/' || st.rh_event, null, null, 1);
    if public.nexloot_rh_okay(res) then cr := res->'body'; end if;
    ergebnis := (res->>'status') || case when public.nexloot_rh_okay(res) then ' ok, ' || jsonb_array_length(public.nexloot_rh_arr(cr->'slots')) || ' Plätze belegt'
                                         else ' ' || left(coalesce(res->'body'->>'reason', ''), 200) end;
  exception when others then ergebnis := 'Fehler: ' || left(sqlerrm, 250);
  end;
  return next;
  b := public.nexloot_rh_build(st.guild, st, ev, cr);
  pl := b->'payload';
  schritt := '3 Plätze';
  ergebnis := jsonb_array_length(pl->'slots') || ': ' ||
    coalesce((select string_agg((y.x->>'name') || ' ' || coalesce(y.x->>'className', '-') || '/' || coalesce(y.x->>'specName', '-') ||
                                case when y.x ? 'userId' then '' else ' (ohne Discord)' end, ', ' order by y.i)
                from jsonb_array_elements(pl->'slots') with ordinality as y(x, i)), '') ||
    case when jsonb_array_length(b->'skipped') > 0 then ' | ohne Klasse, nicht gesendet: ' || (select string_agg(z.v, ', ') from jsonb_array_elements_text(b->'skipped') as z(v)) else '' end ||
    case when jsonb_array_length(b->'guessed') > 0 then ' | Spec geraten: ' || (select string_agg(z.v, ', ') from jsonb_array_elements_text(b->'guessed') as z(v)) else '' end;
  return next;
  relay := public.nexloot_rh_relay(p_project);
  schritt := '4 Ändern direkt: nur Titel';
  perform pg_sleep(1);
  begin
    res := public.nexloot_rh_call('PATCH', '/comps/' || st.rh_event, jsonb_build_object('title', coalesce(cr->>'title', left(st.title, 100))), null, 1, true);
    ergebnis := (res->>'status') || case when public.nexloot_rh_okay(res) then ' ok' else ' ' || left(coalesce(res->'body'->>'reason', ''), 200) end;
  exception when others then
    ergebnis := 'Fehler: ' || left(regexp_replace(sqlerrm, '^NexLoot: Raid-Helper ist gerade nicht erreichbar \(PATCH /comps/\d+: ', '('), 250);
  end;
  return next;
  if relay is null then
    schritt := '5 Edge Function';
    ergebnis := 'Adresse unbekannt - so aufrufen: select * from nexloot_rh_check(null, ''https://<projekt>.supabase.co'');';
    return next;
    return;
  end if;
  schritt := '5 Edge Function: Verbindung zu Raid-Helper';
  begin
    r := http(('POST', relay, array[http_header('Expect', '')], 'application/json', '{"test": true}')::http_request);
    begin j := r.content::jsonb; exception when others then j := null; end;
    ergebnis := case
      when r.status = 404 and (j is null or not (j ? 'test')) then 'fehlt noch (in Supabase unter Edge Functions anlegen: nexloot-raidhelper)'
      when r.status in (401, 403) then 'lässt den Aufruf nicht zu - bei der Funktion "Verify JWT" ausschalten (' || left(coalesce(j->>'msg', j->>'message', r.content, ''), 80) || ')'
      when j ? 'test' then case when (j->>'status')::int between 200 and 499 then 'ok, Raid-Helper antwortet (' || (j->>'status') || ' in ' || (j->>'ms') || ' ms)'
                                else 'Raid-Helper antwortet ' || (j->>'status') end
      else 'Fehler ' || r.status || ': ' || left(coalesce(j->>'error', r.content, ''), 200) end;
  exception when others then ergebnis := 'Fehler: ' || left(sqlerrm, 250);
  end;
  return next;
  for t in select * from (values
      (6, 'Ändern über die Edge Function: nur Titel', jsonb_build_object('title', coalesce(cr->>'title', left(st.title, 100)))),
      (7, 'Ändern über die Edge Function: alle Plätze', pl)) as v(nr, was, body)
  loop
    schritt := t.nr || ' ' || t.was;
    if t.nr = 7 and jsonb_array_length(pl->'slots') = 0 then
      ergebnis := 'übersprungen (keine Plätze)';
    else
      perform pg_sleep(1);
      begin
        res := public.nexloot_rh_via(relay, 'PATCH', '/comps/' || st.rh_event, t.body, public.nexloot_rh_secret('raidhelper_key'), 1);
        ergebnis := (res->>'status') || case when public.nexloot_rh_okay(res) then ' ok' else ' ' || left(coalesce(res->'body'->>'reason', res->'body'->>'message', ''), 200) end;
      exception when others then
        ergebnis := 'Fehler: ' || left(regexp_replace(sqlerrm, '^NexLoot: ', ''), 250);
      end;
    end if;
    return next;
  end loop;
end $$;

-- Rechte: die internen Funktionen sind von außen nicht aufrufbar, die für die Webapp nur angemeldet (Offiziere prüfen sie selbst)
revoke all on function public.nexloot_rh_secret(text) from public, anon, authenticated;
revoke all on function public.nexloot_rh_server() from public, anon, authenticated;
revoke all on function public.nexloot_rh_call(text, text, jsonb, jsonb, int, boolean) from public, anon, authenticated;
revoke all on function public.nexloot_rh_relay(text) from public, anon, authenticated;
revoke all on function public.nexloot_rh_via(text, text, text, jsonb, text, int) from public, anon, authenticated;
revoke all on function public.nexloot_rh_okay(jsonb) from public, anon, authenticated;
revoke all on function public.nexloot_rh_need(jsonb, text) from public, anon, authenticated;
revoke all on function public.nexloot_rh_norm(text) from public, anon, authenticated;
revoke all on function public.nexloot_rh_cls_names(text) from public, anon, authenticated;
revoke all on function public.nexloot_rh_spec_role(jsonb) from public, anon, authenticated;
revoke all on function public.nexloot_rh_class_key(text) from public, anon, authenticated;
revoke all on function public.nexloot_rh_spec_class(text) from public, anon, authenticated;
revoke all on function public.nexloot_rh_wow_class(text, text) from public, anon, authenticated;
revoke all on function public.nexloot_rh_tree_spec(text, int) from public, anon, authenticated;
revoke all on function public.nexloot_rh_top_tree(text) from public, anon, authenticated;
revoke all on function public.nexloot_rh_kind(text) from public, anon, authenticated;
revoke all on function public.nexloot_rh_arr(jsonb) from public, anon, authenticated;
revoke all on function public.nexloot_rh_char_class(text, text) from public, anon, authenticated;
revoke all on function public.nexloot_rh_event_data(text, text, boolean) from public, anon, authenticated;
revoke all on function public.nexloot_rh_signups(text, jsonb) from public, anon, authenticated;
revoke all on function public.nexloot_rh_build(text, public.nexloot_setups, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.nexloot_rh_check(bigint, text) from public, anon, authenticated;
revoke all on function public.nexloot_rh_events(text) from public, anon;
revoke all on function public.nexloot_rh_event(text, text, boolean) from public, anon;
revoke all on function public.nexloot_rh_comp(text, text) from public, anon;
revoke all on function public.nexloot_setup_rh_link(text, bigint, text) from public, anon;
revoke all on function public.nexloot_rh_send(text, bigint, boolean) from public, anon;
grant execute on function public.nexloot_rh_events(text) to authenticated;
grant execute on function public.nexloot_rh_event(text, text, boolean) to authenticated;
grant execute on function public.nexloot_rh_comp(text, text) to authenticated;
grant execute on function public.nexloot_setup_rh_link(text, bigint, text) to authenticated;
grant execute on function public.nexloot_rh_send(text, bigint, boolean) to authenticated;
