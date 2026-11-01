-- =====================================================================
-- NexLoot – Gildenübersicht zurücksetzen (z. B. zum Start auf dem Live-Server)
-- Löscht die Gildenliste und alle Meilensteine (Level 25/40/60) aus der Beta. Danach fängt alles neu an:
-- die nächste Gildenliste ist wieder die Grundlage, und der erste 60er ist wieder Platz 1.
-- Nex-Coins, Historie und Sessions bleiben unberührt (die setzt du im Spiel zurück: Optionen -> Daten löschen).
-- Im Supabase "SQL Editor" ausführen (Run).
-- English: clears the guild roster and all milestones (e.g. for a fresh start on a new server).
-- Coins, history and sessions are not touched. Run it in the Supabase "SQL Editor".
-- =====================================================================
delete from public.nexloot_milestones;
delete from public.nexloot_members;
