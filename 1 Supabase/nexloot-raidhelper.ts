// English: Supabase edge function "nexloot-raidhelper" for the optional Raid-Helper connection (GUIDE.txt,
// step 10). Supabase -> Edge Functions -> "Deploy a new function" -> "Via Editor", paste this file, name it
// nexloot-raidhelper, deploy, then turn off "Verify JWT" on the function. It only forwards two kinds of
// requests to Raid-Helper with the key the database passes for that call, and stores nothing.
//
// NexLoot – Brücke zu Raid-Helper (Supabase Edge Function "nexloot-raidhelper")
//
// Raid-Helper nimmt Änderungen (Komposition schreiben, ankündigen) direkt aus der Supabase-Datenbank nicht an:
// die Verbindung wird ohne Antwort geschlossen. Die Datenbank (nexloot_raidhelper.sql) schickt sie deshalb über
// diese Funktion. Sie leitet nur diese zwei Arten von Anfragen an die Raid-Helper-API weiter, mit dem API-Key, den
// die Datenbank für genau diesen Aufruf mitgibt, und speichert nichts.
//
// Einrichten: Supabase -> Edge Functions -> "Deploy a new function" -> "Via Editor", diesen Text einfügen,
// Name: nexloot-raidhelper -> "Deploy function". Danach bei der Funktion unter "Details" die Einstellung
// "Verify JWT" (bzw. "Verify JWT with legacy secret") ausschalten und speichern: Die Funktion braucht keine
// Anmeldung, denn ohne gültigen Raid-Helper-Key kann man mit ihr nichts anfangen.

const RH = "https://raid-helper.xyz/api/v4";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-rh-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function antwort(daten: unknown, status = 200): Response {
  return new Response(JSON.stringify(daten), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return antwort({ error: "nur POST" }, 405);
  // deno-lint-ignore no-explicit-any
  let a: any;
  try {
    a = await req.json();
  } catch {
    return antwort({ error: "kein JSON" }, 400);
  }
  const t0 = Date.now();
  try {
    if (a && a.test === true) {
      // Verbindungstest ohne Key: Raid-Helper sollte mit 404 antworten (diese Adresse gibt es nicht)
      const r = await fetch(RH + "/nexloot-test", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
      return antwort({ test: true, status: r.status, ms: Date.now() - t0, text: (await r.text()).slice(0, 100) });
    }
    const method = String(a?.method ?? "").toUpperCase();
    const path = String(a?.path ?? "");
    const erlaubt = (method === "PATCH" && /^\/comps\/\d{5,25}$/.test(path)) ||
      (method === "POST" && /^\/comps\/\d{5,25}\/announcements$/.test(path));
    if (!erlaubt) return antwort({ error: "Diese Anfrage leitet die Funktion nicht weiter" }, 400);
    const key = req.headers.get("x-rh-key") ?? "";
    if (!key) return antwort({ error: "Der API-Key fehlt" }, 400);
    const r = await fetch(RH + path, {
      method,
      headers: { Authorization: key, "Content-Type": "application/json; charset=utf-8" },
      body: JSON.stringify(a?.body ?? {}),
    });
    const text = await r.text();
    let body: unknown;
    try {
      body = JSON.parse(text);
    } catch {
      body = { reason: text.slice(0, 200) };
    }
    return antwort({ status: r.status, body, ms: Date.now() - t0 });
  } catch (e) {
    return antwort({ error: String((e as Error)?.message ?? e), ms: Date.now() - t0 }, 502);
  }
});
