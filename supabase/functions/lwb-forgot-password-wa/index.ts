/**
 * Luxury Wrist Brand — Forgot password with a WhatsApp code.
 *
 * login.html > Forgot password > Login Mobile.
 *   { action: "send",  mobile }                  -> 6-digit code on WhatsApp to that Login Mobile
 *   { action: "reset", mobile, code, password }  -> right code = new password saved
 * The answer to "send" is the same whether the mobile exists or not, so nobody can check numbers.
 * Same Meta template and secrets as login-whatsapp-otp (WA_ACCESS_TOKEN, WA_PHONE_NUMBER_ID,
 * WA_OTP_TEMPLATE_NAME, WA_OTP_TEMPLATE_LANG). Needs lwb_password_reset_whatsapp_setup.sql.
 *
 * Function name: lwb-forgot-password-wa   (Verify JWT OFF: the user cannot log in yet; the code is the check)
 */
import { createClient } from "npm:@supabase/supabase-js@2";

const allowedOrigins = ["https://luxurywristbrand.com", "https://www.luxurywristbrand.com", "https://luxury-wrist-brand.pages.dev"];
const corsFor = (origin, asked) => ({
  "Access-Control-Allow-Origin":
    allowedOrigins.includes(origin) || /^https:\/\/[a-z0-9-]+\.luxury-wrist-brand\.pages\.dev$/.test(origin)
      ? origin : allowedOrigins[0],
  "Access-Control-Allow-Headers": /^[a-z0-9,\s-]{1,500}$/i.test(asked || "")
    ? asked : "authorization, x-client-info, apikey, content-type, x-region",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
  "Vary": "Origin",
});
const CODE_MINUTES = 10, RESEND_SECONDS = 45, MAX_SENDS_PER_HOUR = 5, MAX_TRIES = 5;
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

Deno.serve(async (req) => {
  const cors = corsFor(req.headers.get("origin") || "", req.headers.get("access-control-request-headers") || "");
  const reply = (status, value) => new Response(JSON.stringify(value), { status, headers: cors });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return reply(405, { error: "POST required" });
  try {
    let body;
    try { body = await req.json(); } catch { return reply(400, { error: "Expected JSON body" }); }
    const action = clean(body?.action), mobile = mobile10(body?.mobile);
    if (!mobile) return reply(400, { error: "Enter a valid 10-digit mobile number." });

    const serverUrl = Deno.env.get("SUPABASE_URL");
    let projectSecret = "";
    try { projectSecret = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}").default || ""; } catch { /* legacy */ }
    const serverSecret = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("LWB_DB_SECRET_KEY") || projectSecret;
    if (!serverUrl || !serverSecret) return reply(503, { error: "Password reset is not configured." });
    const server = createClient(serverUrl, serverSecret, { auth: { autoRefreshToken: false, persistSession: false } });

    // Login Mobile is unique (lwb_user_login_setup.sql). Only active ERP users.
    const { data: profiles } = await server.from("user_profiles").select("id,role,active,mobile")
      .in("mobile", [mobile, "91" + mobile, "+91" + mobile, "0" + mobile]).limit(2);
    const profile = (profiles || []).length === 1 ? profiles[0] : null;
    const userId = profile?.active && ERP_ROLES.includes(clean(profile.role).toLowerCase()) ? profile.id : "";
    const to = "******" + mobile.slice(-4);
    const now = Date.now();

    const { data: row, error: rowError } = userId
      ? await server.from("lwb_pw_reset_codes").select("*").eq("user_id", userId).maybeSingle()
      : { data: null, error: null };
    if (rowError) return reply(503, { error: "Password reset by WhatsApp is not set up yet. Please ask Admin." });

    if (action === "send") {
      if (!userId) return reply(200, { sent: true, to, wait: RESEND_SECONDS });
      const waToken = Deno.env.get("WA_ACCESS_TOKEN"), phoneId = Deno.env.get("WA_PHONE_NUMBER_ID");
      if (!waToken || !phoneId) return reply(503, { error: "WhatsApp is not set up. Please use the Login Email or ask Admin." });
      const sentAt = row?.sent_at ? Date.parse(row.sent_at) : 0;
      const wait = Math.ceil((sentAt + RESEND_SECONDS * 1000 - now) / 1000);
      if (wait > 0) return reply(200, { sent: false, wait, to });
      const windowStart = row?.window_start && now - Date.parse(row.window_start) < 3600e3 ? row.window_start : new Date(now).toISOString();
      const sends = windowStart === row?.window_start ? (row.send_count || 0) : 0;
      if (sends >= MAX_SENDS_PER_HOUR) return reply(429, { error: "Too many codes. Please try again after 1 hour or ask Admin." });

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
        return reply(502, { error: "WhatsApp could not send the code: " + m });
      }
      const { error: saveError } = await server.from("lwb_pw_reset_codes").upsert({
        user_id: userId,
        code_hash: await sha256("reset:" + userId + ":" + code),
        expires_at: new Date(now + CODE_MINUTES * 60e3).toISOString(),
        tries: 0,
        sent_at: new Date(now).toISOString(),
        window_start: windowStart,
        send_count: sends + 1,
      });
      if (saveError) return reply(500, { error: "Code could not be saved. Please try again." });
      return reply(200, { sent: true, to, wait: RESEND_SECONDS });
    }

    if (action === "reset") {
      const code = clean(body?.code).replace(/\D/g, ""), password = String(body?.password ?? "");
      if (code.length !== 6) return reply(400, { error: "Enter the 6-digit code from WhatsApp." });
      if (password.length < 6) return reply(400, { error: "New Password must be at least 6 characters." });
      if (password.length > 72) return reply(400, { error: "Password is too long (max 72 characters)." });
      if (!userId || !row?.code_hash || Date.parse(row.expires_at) < now)
        return reply(400, { error: "The code is wrong or has expired. Tap Resend Code." });
      if ((row.tries || 0) >= MAX_TRIES) return reply(429, { error: "Too many wrong tries. Tap Resend Code." });
      await server.from("lwb_pw_reset_codes").update({ tries: (row.tries || 0) + 1 }).eq("user_id", userId);
      if (await sha256("reset:" + userId + ":" + code) !== row.code_hash)
        return reply(400, { error: "Wrong code. Check WhatsApp and try again." });
      const { error: pwError } = await server.auth.admin.updateUserById(userId, { password });
      if (pwError) return reply(400, { error: "Password could not be saved: " + clean(pwError.message).slice(0, 200) });
      await server.from("lwb_pw_reset_codes").update({ code_hash: null, expires_at: null }).eq("user_id", userId);
      return reply(200, { ok: true });
    }
    return reply(400, { error: "Unknown action" });
  } catch (e) {
    return reply(500, { error: "Password reset failed: " + clean(e?.message || e).slice(0, 200) });
  }
});
