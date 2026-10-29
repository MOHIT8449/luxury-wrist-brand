/**
 * Luxury Wrist Brand — WhatsApp OTP for ERP login.
 *
 * After the password, login.html calls this function with the user's login
 * session. "send" sends a 6-digit code to the user's Login Mobile on WhatsApp
 * (Meta authentication template); "verify" checks it and marks THIS login
 * session as OTP-verified (public.lwb_login_otp_sessions).
 *
 * Function name: login-whatsapp-otp   (Verify JWT ON)
 * Uses the same Meta secrets as driver-assignment-whatsapp:
 *   WA_ACCESS_TOKEN, WA_PHONE_NUMBER_ID
 * Optional:
 *   WA_GRAPH_VERSION=v26.0
 *   WA_OTP_TEMPLATE_NAME=lwb_login_otp
 *   WA_OTP_TEMPLATE_LANG=en_US
 * Needs lwb_whatsapp_otp_setup.sql. See README_LOGIN_OTP.md.
 */
import { createClient } from "npm:@supabase/supabase-js@2";

const allowedOrigins = ["https://luxury-wrist-brand.pages.dev"];
const corsFor = (origin) => ({
  "Access-Control-Allow-Origin":
    allowedOrigins.includes(origin) || /^https:\/\/[a-z0-9-]+\.luxury-wrist-brand\.pages\.dev$/.test(origin)
      ? origin : allowedOrigins[0],
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
  "Vary": "Origin",
});
const CODE_MINUTES = 5, RESEND_SECONDS = 45, MAX_SENDS_PER_HOUR = 6, MAX_TRIES = 5;
const ERP_ROLES = ["admin", "manager", "sales", "warehouse", "transport", "accounts", "driver"];

const clean = (x) => String(x ?? "").trim();
function mobile10(raw) {
  let d = clean(raw).replace(/\D/g, "");
  if (d.length === 12 && d.startsWith("91")) d = d.slice(2);
  if (d.length === 11 && d.startsWith("0")) d = d.slice(1);
  return /^[6-9]\d{9}$/.test(d) ? d : "";
}
async function sha256(text) {
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(hash)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
function sixDigits() {
  const n = crypto.getRandomValues(new Uint32Array(1))[0] % 1000000;
  return String(n).padStart(6, "0");
}
// The JWT was already verified by getUser(); this only reads its session_id claim.
function sessionIdOf(token) {
  try {
    const part = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    return clean(JSON.parse(atob(part + "===".slice((part.length + 3) % 4))).session_id);
  } catch { return ""; }
}

Deno.serve(async (req) => {
  const cors = corsFor(req.headers.get("origin") || "");
  const reply = (status, value) => new Response(JSON.stringify(value), { status, headers: cors });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return reply(405, { error: "POST required" });
  try {
    const token = (req.headers.get("authorization") || "").match(/^Bearer\s+(.+)$/i)?.[1];
    if (!token) return reply(401, { error: "Login required" });
    const serverUrl = Deno.env.get("SUPABASE_URL");
    let projectSecret = "";
    try {
      projectSecret = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}").default || "";
    } catch { /* older hosted projects may use only the legacy service key */ }
    const serverSecret = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
      Deno.env.get("LWB_DB_SECRET_KEY") || projectSecret;
    if (!serverUrl || !serverSecret)
      return reply(503, { error: "Backend Supabase credentials are not configured" });
    const server = createClient(serverUrl, serverSecret, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: authData, error: authError } = await server.auth.getUser(token);
    const user = authData?.user;
    const sessionId = sessionIdOf(token);
    if (authError || !user || !sessionId) return reply(401, { error: "Invalid or expired login session" });
    const { data: profile } = await server.from("user_profiles")
      .select("role,active,mobile").eq("id", user.id).maybeSingle();
    if (!profile?.active || !ERP_ROLES.includes(clean(profile.role).toLowerCase()))
      return reply(403, { error: "This login is not approved by LWB Admin" });

    let body;
    try { body = await req.json(); } catch { return reply(400, { error: "Expected JSON body" }); }
    const action = clean(body?.action);
    const now = Date.now();
    const { data: row, error: rowError } = await server.from("lwb_login_otp_codes")
      .select("*").eq("user_id", user.id).maybeSingle();
    if (rowError) return reply(503, { error: "Run lwb_whatsapp_otp_setup.sql in Supabase first", not_configured: true });

    if (action === "send") {
      const mobile = mobile10(profile.mobile);
      if (!mobile) return reply(409, { error: "No Login Mobile saved for this user", no_mobile: true });
      const waToken = Deno.env.get("WA_ACCESS_TOKEN"), phoneId = Deno.env.get("WA_PHONE_NUMBER_ID");
      if (!waToken || !phoneId) return reply(503, { error: "WhatsApp is not configured", not_configured: true });
      const to = "******" + mobile.slice(-4);
      const sentAt = row?.sent_at ? Date.parse(row.sent_at) : 0;
      const wait = Math.ceil((sentAt + RESEND_SECONDS * 1000 - now) / 1000);
      if (wait > 0) return reply(200, { sent: false, wait, to });
      const windowStart = row?.window_start && now - Date.parse(row.window_start) < 3600e3 ? row.window_start : new Date(now).toISOString();
      const sends = windowStart === row?.window_start ? (row.send_count || 0) : 0;
      if (sends >= MAX_SENDS_PER_HOUR)
        return reply(429, { error: "Too many OTPs. Try again after some time or use the Authenticator app." });

      const code = sixDigits();
      const graph = Deno.env.get("WA_GRAPH_VERSION") || "v26.0";
      const response = await fetch("https://graph.facebook.com/" + graph + "/" + phoneId + "/messages", {
        method: "POST",
        headers: { Authorization: "Bearer " + waToken, "Content-Type": "application/json" },
        body: JSON.stringify({
          messaging_product: "whatsapp",
          to: "91" + mobile,
          type: "template",
          template: {
            name: Deno.env.get("WA_OTP_TEMPLATE_NAME") || "lwb_login_otp",
            language: { code: Deno.env.get("WA_OTP_TEMPLATE_LANG") || "en_US" },
            components: [
              { type: "body", parameters: [{ type: "text", text: code }] },
              { type: "button", sub_type: "url", index: "0", parameters: [{ type: "text", text: code }] },
            ],
          },
        }),
        signal: AbortSignal.timeout(16000),
      });
      let result = {};
      try { result = await response.json(); } catch { /* ignore */ }
      if (!response.ok || !result?.messages?.[0]?.id) {
        const m = clean(result?.error?.message || "Unknown Meta error").slice(0, 300);
        return reply(502, { error: "WhatsApp could not send the OTP: " + m });
      }
      const { error: saveError } = await server.from("lwb_login_otp_codes").upsert({
        user_id: user.id,
        code_hash: await sha256(user.id + ":" + code),
        expires_at: new Date(now + CODE_MINUTES * 60e3).toISOString(),
        tries: 0,
        sent_at: new Date(now).toISOString(),
        window_start: windowStart,
        send_count: sends + 1,
      });
      if (saveError) return reply(500, { error: "OTP could not be saved" });
      return reply(200, { sent: true, to, wait: RESEND_SECONDS });
    }

    if (action === "verify") {
      const code = clean(body?.code).replace(/\D/g, "");
      if (code.length !== 6) return reply(400, { error: "Enter the 6-digit code" });
      if (!row?.code_hash || Date.parse(row.expires_at) < now)
        return reply(400, { error: "OTP expired. Tap Resend OTP." });
      if ((row.tries || 0) >= MAX_TRIES)
        return reply(429, { error: "Too many wrong tries. Tap Resend OTP." });
      await server.from("lwb_login_otp_codes").update({ tries: (row.tries || 0) + 1 }).eq("user_id", user.id);
      if (await sha256(user.id + ":" + code) !== row.code_hash)
        return reply(400, { error: "Wrong OTP. Check WhatsApp and try again." });
      await server.from("lwb_login_otp_codes").update({ code_hash: null, expires_at: null }).eq("user_id", user.id);
      const { error: okError } = await server.from("lwb_login_otp_sessions")
        .upsert({ session_id: sessionId, user_id: user.id, verified_at: new Date(now).toISOString() });
      if (okError) return reply(500, { error: "OTP could not be saved" });
      return reply(200, { ok: true });
    }
    return reply(400, { error: "Unknown action" });
  } catch (e) {
    return reply(500, { error: "OTP service error: " + clean(e?.message).slice(0, 200) });
  }
});
