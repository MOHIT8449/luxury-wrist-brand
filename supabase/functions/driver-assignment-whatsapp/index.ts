/**
 * Luxury Wrist Brand — Automatic WhatsApp DRIVER LOADING ASSIGNMENT.
 *
 * Deploy independently to Supabase Edge Functions (Cloudflare Pages only deploys
 * frontend HTML). This function authenticates the ERP operator, reads SAVED
 * assignments/SKUs, and sends approved Meta WhatsApp template messages.
 *
 * Function name: driver-assignment-whatsapp
 * Required Meta function secrets:
 *   WA_ACCESS_TOKEN, WA_PHONE_NUMBER_ID
 * Optional:
 *   WA_GRAPH_VERSION=v26.0
 *   WA_TEMPLATE_NAME=lwb_driver_loading_assignment
 *   WA_TEMPLATE_LANG=en_US
 * Supabase server credentials are injected into Edge Functions automatically.
 * Never put the WhatsApp access token or DB secret in browser HTML or GitHub.
 *
 * Meta-approved template BODY must contain exactly 8 body variables,
 * ordered as specified in README_DRIVER_WHATSAPP.md.
 */
import { createClient } from "npm:@supabase/supabase-js@2";

const allowedOrigin = "https://luxury-wrist-brand.pages.dev";
const cors = {
  "Access-Control-Allow-Origin": allowedOrigin,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
  "Vary": "Origin",
};
const reply = (status, value) =>
  new Response(JSON.stringify(value), { status, headers: cors });
const clean = (x) => String(x ?? "").trim();
const hasOwn = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
const normalizedStatus = (value) => clean(value).toLowerCase();
const numberText = (n) =>
  new Intl.NumberFormat("en-IN", { maximumFractionDigits: 3 }).format(n);
function normalizeMobile(raw) {
  const digits = clean(raw).replace(/\D/g, "");
  if (/^[6-9]\d{9}$/.test(digits)) return "91" + digits;
  if (/^91[6-9]\d{9}$/.test(digits)) return digits;
  return "";
}
function jsonLimit(input, limit) {
  return clean(input).replace(/[\u0000-\u001F]/g, " ").slice(0, limit) || "—";
}
async function sha256(text) {
  const bytes = new TextEncoder().encode(text);
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
function partitionSkuLines(lines) {
  const chunks = [];
  let buffer = [], length = 0;
  for (const line of lines) {
    if (line.length > 480) throw Error("SKU line is too long for the WhatsApp template");
    const newLength = length + (buffer.length ? 1 : 0) + line.length;
    if (buffer.length && newLength > 520) {
      chunks.push(buffer.join("\n"));
      buffer = []; length = 0;
    }
    buffer.push(line);
    length += (buffer.length > 1 ? 1 : 0) + line.length;
  }
  if (buffer.length) chunks.push(buffer.join("\n"));
  // All SKUs are preserved. Never silently truncate an order.
  if (chunks.length > 30)
    throw Error("This PO has too many SKU groups for one automatic notification. Contact ERP Admin.");
  return chunks;
}
function briefFailure(error) {
  const description = clean(error?.error?.message || error?.message || error?.error || "Unknown Meta API error");
  const code = error?.error?.code || error?.code || "";
  return ("Meta " + (code ? "("+code+") " : "") + description).slice(0, 450);
}
function templateFor(part, partCount, order, assignment, skuText, totalQty, templateName, lang) {
  // Exact template order: PO, Party, Driver, Vehicle, Dispatch, Part, SKUs, Total CS.
  const fields = [
    jsonLimit(order.order_no, 100),
    jsonLimit(order.customer_name, 170),
    jsonLimit(assignment.driver_name, 130),
    jsonLimit(assignment.vehicle_no, 40),
    jsonLimit(assignment.loading_person, 130),
    String(part) + "/" + String(partCount),
    skuText,
    numberText(totalQty),
  ];
  return {
    messaging_product: "whatsapp",
    recipient_type: "individual",
    to: normalizeMobile(assignment.driver_mobile),
    type: "template",
    template: {
      name: templateName,
      language: { code: lang },
      components: [{
        type: "body",
        parameters: fields.map((text) => ({ type: "text", text })),
      }],
    },
  };
}
Deno.serve(async (req) => {
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

    // Always verify the caller's JWT SERVER SIDE before using the RLS-bypass key.
    const { data: authData, error: authError } = await server.auth.getUser(token);
    const operator = authData?.user;
    if (authError || !operator) return reply(401, { error: "Invalid or expired login session" });
    const { data: profile, error: profileError } = await server.from("user_profiles")
      .select("role,active").eq("id", operator.id).single();
    if (profileError || !profile?.active ||
        !["admin", "manager", "transport"].includes(normalizedStatus(profile.role)))
      return reply(403, { error: "Only active Sales Head / Transport roles can send an assignment" });

    let request;
    try { request = await req.json(); }
    catch { return reply(400, { error: "Expected JSON body" }); }
    const orderId = clean(request?.order_id);
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(orderId))
      return reply(400, { error: "Valid order_id is required" });

    // Operators must record confirmation of the driver's WhatsApp opt-in
    // before initiating a new business-initiated message.
    if (request?.driver_opt_in_confirmed !== true)
      return reply(400, { error: "Driver WhatsApp opt-in must be confirmed before sending" });

    const [orderQuery, assignmentQuery, itemsQuery] = await Promise.all([
      server.from("orders")
        .select("id,order_no,customer_name,status").eq("id", orderId).single(),
      server.from("dispatch_assignments")
        .select("id,order_id,driver_name,driver_mobile,vehicle_no,loading_person,assigned_by")
        .eq("order_id", orderId).maybeSingle(),
      server.from("order_items")
        .select("sku_name,approved_qty,ordered_qty").eq("order_id", orderId),
    ]);
    if (orderQuery.error) throw orderQuery.error;
    if (assignmentQuery.error) throw assignmentQuery.error;
    if (itemsQuery.error) throw itemsQuery.error;
    const order = orderQuery.data, assignment = assignmentQuery.data;
    if (!assignment) return reply(409, { error: "Save Driver/Vehicle Assignment first" });
    if (!["transport_allocated","allocated","loading","loaded","invoiced"].includes(normalizedStatus(order.status)))
      return reply(409, { error: "PO has not completed driver allocation" });
    const mobile = normalizeMobile(assignment.driver_mobile);
    if (!mobile) return reply(400, { error: "Driver Mobile must be a valid Indian WhatsApp mobile (10 digits or +91)" });
    if (!clean(assignment.driver_name) || !clean(assignment.vehicle_no) || !clean(assignment.loading_person))
      return reply(400, { error: "Saved assignment missing Driver, Vehicle or Dispatch Loading Person" });

    const skuRows = (itemsQuery.data || [])
      .map((x) => ({
        sku: clean(x.sku_name),
        quantity: Number(x.approved_qty ?? x.ordered_qty ?? 0),
      }))
      .filter((x) => x.quantity > 0);
    if (!skuRows.length) return reply(409, { error: "No approved CS quantity on this PO" });
    if (skuRows.some((x) => !x.sku || !Number.isFinite(x.quantity) || x.quantity > 1e8))
      return reply(409, { error: "Invalid Approved SKU/CS quantity. Verify the PO." });
    skuRows.sort((a, b) => a.sku.localeCompare(b.sku));
    const total = skuRows.reduce((sum, x) => sum + x.quantity, 0);
    const chunks = partitionSkuLines(skuRows.map(x => x.sku + ": " + numberText(x.quantity) + " CS"));
    if (!chunks.length) return reply(409, { error: "No SKU available for this loading assignment" });

    const waToken = Deno.env.get("WA_ACCESS_TOKEN");
    const phoneId = Deno.env.get("WA_PHONE_NUMBER_ID");
    const graphVersion = Deno.env.get("WA_GRAPH_VERSION") || "v26.0";
    const templateName = Deno.env.get("WA_TEMPLATE_NAME") || "lwb_driver_loading_assignment";
    const language = Deno.env.get("WA_TEMPLATE_LANG") || "en_US";
    if (!waToken || !phoneId)
      return reply(503, { error: "Meta WhatsApp API not configured. Set WA_ACCESS_TOKEN and WA_PHONE_NUMBER_ID in Supabase Edge Function Secrets." });
    if (!/^v\d+\.\d+$/.test(graphVersion) || !/^[0-9]{10,25}$/.test(phoneId) ||
        !/^[a-z][a-z0-9_]{1,120}$/.test(templateName))
      return reply(503, { error: "WhatsApp API settings are invalid" });

    const fingerprint = await sha256(JSON.stringify({
      orderId,
      customer: clean(order.customer_name),
      driver: clean(assignment.driver_name),
      mobile,
      vehicle: clean(assignment.vehicle_no).toUpperCase(),
      dispatchTeam: clean(assignment.loading_person),
      skuRows,
    }));

    let accepted = 0, already = 0, failed = 0, unknown = 0, inProgress = 0;
    const errors = [];
    for (let index = 0; index < chunks.length; index++) {
      const partNo = index + 1;
      const logRow = {
        assignment_id: assignment.id,
        order_id: orderId,
        fingerprint,
        part_no: partNo,
        part_count: chunks.length,
        recipient_mobile: mobile,
        status: "sending",
        consent_confirmed_by: operator.id,
      };
      let logId;
      const claim = await server.from("lwb_driver_whatsapp_log").insert(logRow)
        .select("id").single();
      if (claim.error) {
        if (claim.error.code !== "23505") throw claim.error;
        // Duplicate call? Never issue a second message after an accepted or
        // possibly-accepted response. Explicit retry is allowed only for a
        // definite rejection ('failed'), with atomic status transition.
        const prior = await server.from("lwb_driver_whatsapp_log")
          .select("id,status,attempts").eq("assignment_id", assignment.id)
          .eq("fingerprint",fingerprint).eq("part_no",partNo).single();
        if (prior.error) throw prior.error;
        if (prior.data.status === "accepted") { already++; continue; }
        if (prior.data.status === "sending") { inProgress++; continue; }
        if (prior.data.status === "unknown") {
          unknown++;
          errors.push("Part "+partNo+": API result uncertain; check WhatsApp Manager before retrying.");
          continue;
        }
        if (prior.data.attempts >= 10) {
          failed++;errors.push("Part "+partNo+": Retry limit reached.");continue;
        }
        const retry = await server.from("lwb_driver_whatsapp_log")
          .update({
            status: "sending",
            error_message: null,
            attempts: prior.data.attempts+1,
            updated_at: new Date().toISOString(),
            consent_confirmed_by: operator.id,
            consent_confirmed_at: new Date().toISOString(),
          }).eq("id",prior.data.id).eq("status","failed").select("id").maybeSingle();
        if (retry.error) throw retry.error;
        if (!retry.data) { inProgress++; continue; }
        logId = retry.data.id;
      } else {
        logId = claim.data.id;
      }
      const content = templateFor(partNo,chunks.length,order,assignment,chunks[index],total,templateName,language);
      try {
        const response = await fetch(
          "https://graph.facebook.com/"+graphVersion+"/"+phoneId+"/messages",
          {
            method: "POST",
            headers: {
              Authorization: "Bearer "+waToken,
              "Content-Type": "application/json",
            },
            body: JSON.stringify(content),
            signal: AbortSignal.timeout(16000),
          },
        );
        let result = {};
        try { result = await response.json(); } catch { /* response may be invalid */ }
        if (!response.ok || !clean(result?.messages?.[0]?.id)) {
          const errorMessage = response.ok
            ? "Meta response did not include a message ID"
            : briefFailure(result);
          await server.from("lwb_driver_whatsapp_log")
            .update({status:"failed", error_message:errorMessage,updated_at:new Date().toISOString()})
            .eq("id",logId);
          failed++;errors.push("Part "+partNo+": "+errorMessage);
          continue;
        }
        const record = await server.from("lwb_driver_whatsapp_log")
          .update({
            status:"accepted",
            meta_message_id:result.messages[0].id,
            error_message:null,
            updated_at:new Date().toISOString(),
          }).eq("id",logId);
        if (record.error) {
          unknown++;
          errors.push("Part "+partNo+": Meta accepted, but database audit failed. Manual review required.");
          continue;
        }
        accepted++;
      }catch(e) {
        // Request could have reached Meta despite a network timeout. Do not
        // blindly auto-resend (would create duplicates).
        await server.from("lwb_driver_whatsapp_log")
          .update({
            status:"unknown",
            error_message:"Network result uncertain: "+clean(e?.message).slice(0,200),
            updated_at:new Date().toISOString(),
          }).eq("id",logId);
        unknown++;
        errors.push("Part "+partNo+": Network result uncertain; check Meta delivery dashboard.");
      }
    }
    const all = chunks.length;
    const status = (accepted+already === all) ? "accepted"
      : ((inProgress && !failed && !unknown) ? "in_progress" : "partial_failed");
    return reply(200,{
      status, order_no:order.order_no,
      total_parts:all, accepted_parts:accepted,
      already_sent_parts:already, in_progress_parts:inProgress,
      failed_parts:failed, uncertain_parts:unknown,
      // 'accepted' means Meta API accepted the request. Final delivery/read
      // requires a separate Meta webhook, not implemented here.
      info:"Meta API accepted ≠ WhatsApp delivered/read",
      errors:errors.slice(0,8),
    });
  }catch(e){
    console.error("Driver WA handler error:", clean(e?.message));
    return reply(500,{
      error:"Could not prepare Driver WhatsApp notification",
      detail:clean(e?.message).slice(0,250),
    });
  }
});
