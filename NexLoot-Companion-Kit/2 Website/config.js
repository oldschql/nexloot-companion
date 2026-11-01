// NexLoot website - settings / Einstellungen
// supabaseUrl: Supabase -> Project Settings -> Data API (Project URL)
// anonKey:     Supabase -> Project Settings -> API Keys -> "Publishable key" (sb_publishable_...)
//              Only the PUBLIC key goes here, never the secret / service_role key.
//              Hier gehoert NUR der oeffentliche Schluessel hin, niemals der geheime.
// guild:       your guild ID, exactly as in nexloot.sql / eure Gilden-Kennung wie in nexloot.sql
window.NEXLOOT_CONFIG = {
  supabaseUrl: "https://XXXX.supabase.co",
  anonKey: "DEIN-OEFFENTLICHER-SCHLUESSEL",
  guild: "MyGuild",
  refreshSeconds: 60
};
