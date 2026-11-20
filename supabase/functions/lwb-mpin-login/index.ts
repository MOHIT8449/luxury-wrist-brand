/**
 * Luxury Wrist Brand — login with MPIN after the login session has ended.
 *
 * login.html calls this when the phone has an MPIN (lwbMpin in localStorage) but no login session
 * any more. Body: { uid, device, pin }. The database checks the MPIN of this user on this phone
 * (lwb_mpin_login_check, lwb_mpin_login_setup.sql: bcrypt hash, 5 wrong tries delete it). Only on
 * a right MPIN this function opens a new login session for that user, marks it as OTP-verified
 * (same as the WhatsApp OTP, lwb_login_otp_sessions) and returns its tokens.
 *
 * Function name: lwb-mpin-login   (Verify JWT OFF: there is no login yet; the MPIN is the check)
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
const ERP_ROLES = ["admin", "manager", "sales", "warehouse", "transport", "accounts", "driver"];
const clean = (x) => String(x ?? "").trim();
function sessionIdOf(token) {
  try {
    const part = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    return clean(JSON.parse(atob(part + "===".slice((part.length + 3) % 4))).session_id);
  } catch { return ""; }
}

Deno.serve(async (req) => {
  const cors = corsFor(req.headers.get("origin") || "", req.headers.get("access-control-request-headers") || "");
  const reply = (status, value) => new Response(JSON.stringify(value), { status, headers: cors });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return reply(405, { error: "POST required" });
  try {
    let body;
    try { body = await req.json(); } catch { return reply(400, { error: "Expected JSON body" }); }
    const uid = clean(body?.uid), device = clean(body?.device), pin = clean(body?.pin);
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(uid) ||
        !/^[A-Za-z0-9_-]{16,64}$/.test(device) || !/^[0-9]{4}$/.test(pin))
      return reply(400, { error: "Enter your 4-digit MPIN." });

    const serverUrl = Deno.env.get("SUPABASE_URL");
    let projectSecret = "";
    try { projectSecret = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}").default || ""; } catch { /* legacy */ }
    const serverSecret = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("LWB_DB_SECRET_KEY") || projectSecret;
    if (!serverUrl || !serverSecret) return reply(503, { error: "MPIN login is not configured." });
    const server = createClient(serverUrl, serverSecret, { auth: { autoRefreshToken: false, persistSession: false } });

    const { data: check, error: checkError } = await server.rpc("lwb_mpin_login_check",
      { p_user: uid, p_device: device, p_pin: pin });
    if (checkError) return reply(503, { error: "MPIN login is not set up yet. Please log in with your password." });
    if (!check?.ok) return reply(200, check || { ok: false, blocked: true });

    const { data: profile } = await server.from("user_profiles").select("role,active").eq("id", uid).maybeSingle();
    if (!profile?.active || !ERP_ROLES.includes(clean(profile.role).toLowerCase()))
      return reply(200, { ok: false, inactive: true });

    const { data: got, error: userError } = await server.auth.admin.getUserById(uid);
    const email = got?.user?.email;
    if (userError || !email) return reply(200, { ok: false, error: "This login has no email. Please log in with your password." });

    // A one-time sign-in link made and used here at once (nothing is emailed).
    const { data: link, error: linkError } = await server.auth.admin.generateLink({ type: "magiclink", email });
    const tokenHash = link?.properties?.hashed_token;
    if (linkError || !tokenHash) return reply(502, { error: "Login could not be opened. Please log in with your password." });
    const { data: opened, error: openError } = await server.auth.verifyOtp({ token_hash: tokenHash, type: "magiclink" });
    const session = opened?.session, sessionId = session ? sessionIdOf(session.access_token) : "";
    if (openError || !session || !sessionId || opened?.user?.id !== uid)
      return reply(502, { error: "Login could not be opened. Please log in with your password." });

    // The MPIN on the user's own phone stands in for the OTP of this login.
    const { error: markError } = await server.from("lwb_login_otp_sessions")
      .upsert({ session_id: sessionId, user_id: uid, verified_at: new Date().toISOString() });
    if (markError) return reply(502, { error: "Login could not be opened. Please log in with your password." });

    return reply(200, { ok: true, access_token: session.access_token, refresh_token: session.refresh_token });
  } catch (e) {
    return reply(500, { error: "MPIN login failed: " + clean(e?.message || e).slice(0, 200) });
  }
});
