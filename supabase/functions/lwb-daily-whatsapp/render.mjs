// LWB daily WhatsApp report: one report "doc" -> SVG table in the purple PO-image style.
// Same layout for the Edge Function (SVG -> PNG with resvg) and the Node test.
//
// doc = { who: "NADIM TINWALA · SALESMAN", rows: [
//   ["kv", "DATE", "24/11/2026", tone?],          label | value (value spans 3 columns)
//   ["sec", "MONTH TARGET"],                       section bar
//   ["th", ["PRODUCT NAME","QTY","RATE","AMOUNT"]],
//   ["tr", ["250ML FANTA", "20", "455", "9,100"], total?, tone?] ] }
// tone: "g" green, "r" red, "b" blue.

const W = 800;
const COLS = [0.46, 0.16, 0.16, 0.22].map(f => Math.round(f * W));
const X = [0, COLS[0], COLS[0] + COLS[1], COLS[0] + COLS[1] + COLS[2], W];
const C = {
  head: "#5b2a96", sec: "#7a4cb8", k: "#e6dcf5", v: "#f5f0fc", row: "#ffffff", tot: "#efe7fa",
  line: "#b9a3dc", ink: "#2b2140", kink: "#3a2266", white: "#ffffff",
  g: "#13824a", r: "#c0392b", b: "#1d5fbf",
};
const esc = s => String(s == null ? "" : s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

// Rough Roboto widths (no font metrics in the Edge Function): enough to cut long text with "…".
function fit(text, width, size, bold) {
  const s = String(text == null ? "" : text);
  const per = size * (bold ? 0.6 : 0.56);
  const max = Math.floor((width - 24) / per);
  return s.length <= max ? s : s.slice(0, Math.max(1, max - 1)).trimEnd() + "…";
}
function txt(x, y, w, s, o = {}) {
  const size = o.size || 19, bold = !!o.bold, anchor = o.align || "middle";
  const tx = anchor === "start" ? x + 12 : anchor === "end" ? x + w - 12 : x + w / 2;
  return `<text x="${tx}" y="${y}" font-size="${size}" font-weight="${bold ? 700 : 400}" fill="${o.fill || C.ink}" text-anchor="${anchor}" dominant-baseline="central">${esc(fit(s, w, size, bold))}</text>`;
}
function box(x, y, w, h, fill) {
  return `<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="${fill}" stroke="${C.line}" stroke-width="2"/>`;
}

export function renderSvg(doc) {
  const out = [];
  let y = 0;
  // Header: brand name in the middle, person on the right
  const hh = 58;
  out.push(box(0, y, W, hh, C.head));
  out.push(`<text x="${W * 0.36}" y="${y + hh / 2}" font-size="25" font-weight="700" fill="${C.white}" text-anchor="middle" dominant-baseline="central">LUXURY WRIST BRAND</text>`);
  out.push(`<text x="${W - 12}" y="${y + hh / 2}" font-size="15" font-weight="700" fill="${C.white}" text-anchor="end" dominant-baseline="central">${esc(fit(doc.who || "", W * 0.36, 15, true))}</text>`);
  y += hh;
  const RH = 46;
  for (const r of doc.rows || []) {
    const t = r[0];
    if (t === "kv") {
      const tone = r[3] && C[r[3]];
      out.push(box(0, y, X[1], RH, C.k), box(X[1], y, W - X[1], RH, C.v));
      out.push(txt(0, y + RH / 2, X[1], String(r[1] || "").toUpperCase(), { bold: true, fill: C.kink }));
      out.push(txt(X[1], y + RH / 2, W - X[1], r[2], { bold: true, fill: tone || C.ink }));
    } else if (t === "sec") {
      out.push(box(0, y, W, 40, C.sec));
      out.push(txt(0, y + 20, W, String(r[1] || "").toUpperCase(), { bold: true, fill: C.white, size: 18 }));
      y += 40; continue;
    } else if (t === "th") {
      for (let i = 0; i < 4; i++) {
        out.push(box(X[i], y, X[i + 1] - X[i], RH, C.head));
        out.push(txt(X[i], y + RH / 2, X[i + 1] - X[i], (r[1] || [])[i] || "", { bold: true, fill: C.white }));
      }
    } else if (t === "tr") {
      const tot = !!r[2], tone = r[3] && C[r[3]];
      for (let i = 0; i < 4; i++) {
        out.push(box(X[i], y, X[i + 1] - X[i], RH, tot ? C.tot : C.row));
        out.push(txt(X[i], y + RH / 2, X[i + 1] - X[i], (r[1] || [])[i] ?? "",
          { bold: tot, align: i === 0 ? "start" : i === 3 ? "end" : "middle", fill: tone || C.ink }));
      }
    } else continue;
    y += RH;
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${y}" viewBox="0 0 ${W} ${y}">` +
    `<rect width="${W}" height="${y}" fill="#fff"/><g font-family="Roboto">${out.join("")}</g></svg>`;
}

export const FONT_URLS = [
  "https://cdn.jsdelivr.net/npm/@expo-google-fonts/roboto@0.2.3/Roboto_400Regular.ttf",
  "https://cdn.jsdelivr.net/npm/@expo-google-fonts/roboto@0.2.3/Roboto_700Bold.ttf",
];
export const WASM_URL = "https://cdn.jsdelivr.net/npm/@resvg/resvg-wasm@2.6.2/index_bg.wasm";

// ---------------------------------------------------------------------------
// PDF (Day Book / long reports): the same table cut into A4 pages.
// A table that goes on to the next page repeats its column heads; a section
// title or column head never sits alone at the bottom of a page.
// ---------------------------------------------------------------------------
const H = { kv: 46, th: 46, tr: 46, sec: 40 };
export const PAGE_PX = 1100;          // table height per A4 page (800 px wide)

export function pages(doc, max = PAGE_PX) {
  const rows = (doc.rows || []).filter(r => H[r[0]]);
  const out = [];
  let cur = [], h = 58, th = null;
  const flush = () => { if (cur.length) out.push(cur); cur = []; h = 58; };
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i], t = r[0];
    if (t === "sec") th = null;
    if (t === "th") th = r;
    // keep a title / head together with the next 2 rows
    const need = H[t] + ((t === "sec" || t === "th") ? 2 * 46 : 0);
    if (h + need > max && cur.length) {
      flush();
      if (t === "tr" && th) { cur.push(th); h += H.th; }
    }
    cur.push(r); h += H[t];
  }
  flush();
  return out.map((rows, i) => ({ who: (doc.who || "") + (out.length > 1 ? " · " + (i + 1) + "/" + out.length : ""), rows }));
}

// toPng(svgDoc) -> Uint8Array PNG; PDFDocument from pdf-lib. Returns PDF bytes.
export async function buildPdf(doc, toPng, PDFDocument, title) {
  const pdf = await PDFDocument.create();
  pdf.setTitle(title || "LWB report"); pdf.setAuthor("Luxury Wrist Brand ERP"); pdf.setCreator("Luxury Wrist Brand ERP");
  const A4W = 595.28, A4H = 841.89, M = 22, w = A4W - 2 * M;
  for (const pg of pages(doc)) {
    const img = await pdf.embedPng(toPng(pg));
    const page = pdf.addPage([A4W, A4H]);
    const h = img.height * (w / img.width);
    page.drawImage(img, { x: M, y: A4H - M - h, width: w, height: h });
  }
  return await pdf.save();
}
