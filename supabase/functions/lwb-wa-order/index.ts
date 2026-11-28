/**
 * Luxury Wrist Brand — take customer orders on WhatsApp (Mohit, 21 Nov 2026).
 *
 * Meta WhatsApp Cloud API webhook. Meta calls https://luxurywristbrand.com/api/whatsapp
 * (Cloudflare Pages Function functions/api/whatsapp.js passes it here unchanged).
 *   GET  : webhook check (hub.verify_token = WA_VERIFY_TOKEN, default "lwb-wa-order").
 *   POST : messages. Signature X-Hub-Signature-256 is checked with WA_APP_SECRET (Meta App > Settings > Basic);
 *          without that secret nothing is read.
 * Chat steps are in logic.js (brand > products > cases > Send). The order goes to
 * lwb_web_order_intake(p, 'WHATSAPP') (lwb_web_order_setup.sql): known party = pending PO at once,
 * else Website Orders. State per mobile in lwb_wa_sessions; each Meta message id is handled once (lwb_wa_seen).
 *
 * Function name: lwb-wa-order (verify_jwt = false in supabase/config.toml: Meta has no Supabase login).
 * Secrets: WA_ACCESS_TOKEN, WA_PHONE_NUMBER_ID (already set), WA_APP_SECRET, optional WA_VERIFY_TOKEN, WA_GRAPH_VERSION.
 * Needs lwb_whatsapp_order_setup.sql.
 */
import { createClient } from "npm:@supabase/supabase-js@2";
import { step, fresh, inputOf, apiBody, doneText } from "./logic.js";

const SESSION_HOURS = 6;
const enc = new TextEncoder();

async function validSignature(raw: string, header: string, secret: string) {
  const m = /^sha256=([0-9a-f]{64})$/i.exec(header || "");
  if (!m || !secret) return false;
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(raw)));
  const hex = Array.from(sig).map((b) => b.toString(16).padStart(2, "0")).join("");
  // constant-time compare
  let diff = hex.length ^ m[1].length;
  for (let i = 0; i < hex.length; i++) diff |= hex.charCodeAt(i) ^ (m[1].toLowerCase().charCodeAt(i) || 0);
  return diff === 0;
}
function mobile10(raw: string) {
  let d = String(raw || "").replace(/\D/g, "");
  if (d.length === 12 && d.startsWith("91")) d = d.slice(2);
  return /^[6-9]\d{9}$/.test(d) ? d : "";
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (req.method === "GET") {
    const want = Deno.env.get("WA_VERIFY_TOKEN") || "lwb-wa-order";
    if (url.searchParams.get("hub.mode") === "subscribe" && url.searchParams.get("hub.verify_token") === want) {
      return new Response(url.searchParams.get("hub.challenge") || "", { status: 200 });
    }
    return new Response("Forbidden", { status: 403 });
  }
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const raw = await req.text();
  if (raw.length > 200000) return new Response("Too large", { status: 413 });
  const secret = Deno.env.get("WA_APP_SECRET") || "";
  if (!secret) { console.error("WA_APP_SECRET not set: message ignored"); return new Response("ok"); }
  if (!(await validSignature(raw, req.headers.get("x-hub-signature-256") || "", secret))) return new Response("Bad signature", { status: 401 });

  let body: any;
  try { body = JSON.parse(raw); } catch { return new Response("ok"); }
  const token = Deno.env.get("WA_ACCESS_TOKEN"), phoneId = Deno.env.get("WA_PHONE_NUMBER_ID");
  const serverUrl = Deno.env.get("SUPABASE_URL");
  let projectSecret = "";
  try { projectSecret = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}").default || ""; } catch { /* legacy */ }
  const serverSecret = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("LWB_DB_SECRET_KEY") || projectSecret;
  if (!token || !phoneId || !serverUrl || !serverSecret) { console.error("WhatsApp order not configured"); return new Response("ok"); }
  const db = createClient(serverUrl, serverSecret, { auth: { autoRefreshToken: false, persistSession: false } });
  const graph = Deno.env.get("WA_GRAPH_VERSION") || "v26.0";

  const send = async (to: string, m: any) => {
    const r = await fetch("https://graph.facebook.com/" + graph + "/" + phoneId + "/messages", {
      method: "POST", headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
      body: JSON.stringify(apiBody(to, m)),
    });
    if (!r.ok) console.error("WhatsApp send failed", r.status, (await r.text()).slice(0, 300));
  };

  let catalog: any = null;
  for (const entry of body?.entry || []) {
    for (const change of entry?.changes || []) {
      const v = change?.value || {};
      if (String(v?.metadata?.phone_number_id || "") !== phoneId) continue;   // another number of the account
      const names = new Map((v.contacts || []).map((c: any) => [String(c.wa_id), String(c?.profile?.name || "").slice(0, 60)]));
      for (const msg of v.messages || []) {
        const from = String(msg.from || ""), mobile = mobile10(from);
        const input = inputOf(msg);
        if (!mobile || !input) continue;
        // Meta may send the same message again: handle it once.
        const seen = await db.from("lwb_wa_seen").insert({ msg_id: String(msg.id || "").slice(0, 200), mobile });
        if (seen.error) { if (seen.error.code === "23505") continue; console.error("seen", seen.error.message); }

        try {
          if (!catalog) {
            const c = await db.rpc("lwb_web_catalog");
            catalog = c.data || { brands: [], skus: [] };
          }
          const who = await db.rpc("lwb_wa_party", { p_mobile: mobile });
          const party = who.data && who.data.count === 1 ? { name: who.data.name } : null;
          const ctx = { catalog, party, profileName: names.get(from) || "" };
          const sess = await db.from("lwb_wa_sessions").select("state,updated_at").eq("mobile", mobile).maybeSingle();
          let state = sess.data?.state || fresh();
          if (sess.data && Date.now() - Date.parse(sess.data.updated_at) > SESSION_HOURS * 3600e3) state = fresh();

          const r: any = step(state, input, ctx);
          let replies = r.replies;
          let next = r.state;
          if (r.submit) {
            const p = {
              mobile, name: (party?.name || ctx.profileName || r.submit.shop || "WhatsApp customer").slice(0, 60),
              shop: r.submit.shop || party?.name || "", city: r.submit.city || "", brand: next.brand,
              items: next.cart.map((c: any) => ({ sku: c.sku, qty: c.qty })), note: "WhatsApp order",
            };
            const res = await db.rpc("lwb_web_order_intake", { p, p_channel: "WHATSAPP" });
            if (res.error) {
              replies = [{ type: "text", body: "ऑर्डर नहीं गया: " + String(res.error.message || "").slice(0, 200) + "\nकृपया 92743 82694 पर कॉल करें।" }];
            } else {
              replies = [{ type: "text", body: doneText(ctx, next, res.data?.ref || "") }];
              next = { ...fresh(), shop: next.shop, city: next.city };   // remember the shop for next time
            }
          }
          await db.from("lwb_wa_sessions").upsert({ mobile, state: next, updated_at: new Date().toISOString() });
          for (const m of replies) await send(from, m);
        } catch (e) {
          console.error("order chat failed", String(e).slice(0, 300));
          await send(from, { type: "text", body: "अभी कुछ गड़बड़ है। कृपया थोड़ी देर बाद फिर लिखें या 92743 82694 पर कॉल करें।" });
        }
      }
    }
  }
  return new Response("ok");
});
