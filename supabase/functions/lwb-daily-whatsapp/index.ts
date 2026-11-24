// LWB daily WhatsApp reports (lwb_daily_whatsapp_setup.sql).
// Called only by the database (Close Day trigger, back-up cron, Admin "Send now" / "Test to my WhatsApp")
// with the secret in lwb_daily_wa_config. For each report: draw the purple table image (SVG -> PNG),
// upload it to Meta, send it, and mark the log row SENT / FAILED.
//   Normal send: approved template (image header + 2 body values: report name, date).
//   Test send / template not approved yet: plain image with caption, which WhatsApp delivers only when
//   the person sent any message to the business number in the last 24 hours.
//   PDF (Day Book, or a report too long for one image): the same table on A4 pages, sent as a document
//   (template with a DOCUMENT header: lwb_daily_report_pdf; else a plain document inside the 24 hours).
// Secrets (same as the login OTP): WA_ACCESS_TOKEN, WA_PHONE_NUMBER_ID, optional WA_GRAPH_VERSION.
import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
import { initWasm, Resvg } from 'npm:@resvg/resvg-wasm@2.6.2';
import { PDFDocument } from 'npm:pdf-lib@1.17.1';
import { renderSvg, buildPdf, FONT_URLS, WASM_URL } from './render.mjs';

const json = (status, value) => new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
const db = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false, autoRefreshToken: false } });
function sameSecret(a, b) { if (!a || !b || a.length !== b.length) return false; let v = 0; for (let i = 0; i < a.length; i++) v |= a.charCodeAt(i) ^ b.charCodeAt(i); return v === 0; }

let fonts = null, wasmReady = null;
async function ready() {
  if (!wasmReady) wasmReady = fetch(WASM_URL).then(r => { if (!r.ok) throw Error('Image engine download failed'); return r.arrayBuffer(); }).then(b => initWasm(b));
  await wasmReady;
  if (!fonts) fonts = await Promise.all(FONT_URLS.map(async u => { const r = await fetch(u); if (!r.ok) throw Error('Font download failed'); return new Uint8Array(await r.arrayBuffer()); }));
}
function png(doc) {
  return new Resvg(renderSvg(doc), { font: { fontBuffers: fonts, defaultFontFamily: 'Roboto', loadSystemFonts: false }, fitTo: { mode: 'zoom', value: 1.5 } }).render().asPng();
}

const graph = () => 'https://graph.facebook.com/' + (Deno.env.get('WA_GRAPH_VERSION') || 'v26.0') + '/' + Deno.env.get('WA_PHONE_NUMBER_ID');
const auth = () => ({ Authorization: 'Bearer ' + Deno.env.get('WA_ACCESS_TOKEN') });
async function metaError(r) {
  let j = null; try { j = await r.json(); } catch { /* no body */ }
  const e = j?.error || {};
  return Object.assign(Error(((e.code ? e.code + ': ' : '') + (e.error_data?.details || e.message || ('HTTP ' + r.status))).slice(0, 280)), { code: Number(e.code || 0) });
}
async function upload(bytes, name, type = 'image/png') {
  const f = new FormData();
  f.append('messaging_product', 'whatsapp');
  f.append('type', type);
  f.append('file', new Blob([bytes], { type }), name);
  const r = await fetch(graph() + '/media', { method: 'POST', headers: auth(), body: f, signal: AbortSignal.timeout(30000) });
  if (!r.ok) throw await metaError(r);
  return (await r.json()).id;
}
async function post(body) {
  const r = await fetch(graph() + '/messages', { method: 'POST', headers: { ...auth(), 'Content-Type': 'application/json' },
    body: JSON.stringify({ messaging_product: 'whatsapp', ...body }), signal: AbortSignal.timeout(20000) });
  if (!r.ok) throw await metaError(r);
  return (await r.json())?.messages?.[0]?.id || '';
}
// f = {id, pdf, filename}
const head = f => f.pdf ? { type: 'document', document: { id: f.id, filename: f.filename } } : { type: 'image', image: { id: f.id } };
const viaTemplate = (m, f, c, dd) => post({ to: m.to, type: 'template', template: { name: f.pdf ? (c.template_doc || 'lwb_daily_report_pdf') : c.template, language: { code: c.lang },
  components: [{ type: 'header', parameters: [head(f)] },
               { type: 'body', parameters: [{ type: 'text', text: m.title }, { type: 'text', text: dd }] }] } });
const viaImage = (m, f, dd) => {
  const caption = 'LWB daily report · ' + m.title + ' · ' + dd;
  return f.pdf ? post({ to: m.to, type: 'document', document: { id: f.id, filename: f.filename, caption } })
               : post({ to: m.to, type: 'image', image: { id: f.id, caption } });
};
// Template missing / not approved yet -> plain image; outside the 24 h window -> template.
const TEMPLATE_PROBLEM = [132000, 132001, 132005, 132007, 132012, 132015, 132016];

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json(405, { error: 'POST required' });
  try {
    const { data: c, error } = await db.from('lwb_daily_wa_config').select('webhook_secret,template,lang').eq('id', 1).single();
    if (error || !c) return json(503, { error: 'Run lwb_daily_whatsapp_setup.sql first' });
    if (!sameSecret(req.headers.get('x-lwb-wa-secret') || '', c.webhook_secret)) return json(401, { error: 'Unauthorized' });
    if (!Deno.env.get('WA_ACCESS_TOKEN') || !Deno.env.get('WA_PHONE_NUMBER_ID')) return json(503, { error: 'WhatsApp is not configured' });
    const body = await req.json();
    const date = String(body?.date || '').slice(0, 10);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return json(400, { error: 'date required' });
    const claim = await db.rpc('lwb_daily_wa_claim', { p_date: date, p_test_user: body?.test_user || null, p_only: body?.only || null });
    if (claim.error) return json(500, { error: claim.error.message });
    const list = claim.data?.messages || [], test = !!claim.data?.test, dd = date.split('-').reverse().join('/');
    const tpl = { template: claim.data?.template || c.template, template_doc: claim.data?.template_doc, lang: claim.data?.lang || c.lang };
    if (!list.length) return json(200, { sent: 0 });
    await ready();
    const media = new Map();     // same report to many people -> one upload (one PDF)
    let sent = 0, failed = 0;
    for (const m of list) {
      try {
        const key = (m.pdf ? 'pdf:' : 'png:') + JSON.stringify(m.doc);
        const base = ('LWB-' + m.title + '-' + dd).replace(/\W+/g, '-');
        if (!media.has(key)) {
          media.set(key, m.pdf
            ? { pdf: true, filename: base + '.pdf', id: await upload(await buildPdf(m.doc, png, PDFDocument, 'LWB ' + m.title + ' ' + dd), base + '.pdf', 'application/pdf') }
            : { pdf: false, id: await upload(png(m.doc), base + '.png') });
        }
        const f = media.get(key);
        let wa;
        if (test) {
          try { wa = await viaImage(m, f, dd); }
          catch (e) { if (e.code === 131047) wa = await viaTemplate(m, f, tpl, dd); else throw e; }
        } else {
          try { wa = await viaTemplate(m, f, tpl, dd); }
          catch (e) { if (TEMPLATE_PROBLEM.includes(e.code)) wa = await viaImage(m, f, dd); else throw e; }
        }
        await db.rpc('lwb_daily_wa_mark', { p_id: m.id, p_ok: true, p_wa_id: wa, p_error: null });
        sent++;
      } catch (e) {
        failed++;
        await db.rpc('lwb_daily_wa_mark', { p_id: m.id, p_ok: false, p_wa_id: null,
          p_error: e.code === 131047 ? 'Outside 24 hours and the template is not approved yet: ' + e.message : String(e.message || e) });
      }
    }
    return json(200, { sent, failed });
  } catch (e) {
    return json(500, { error: String(e?.message || e).slice(0, 300) });
  }
});
