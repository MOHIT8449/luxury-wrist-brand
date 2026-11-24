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
// PDF (Day Book / long reports): its own clean A4 business-report look
// (not the purple WhatsApp image): white page, dark teal title band line,
// light grey table heads, thin row lines, page number in the footer.
// A table that goes on to the next page repeats its column heads; a section
// title or column head never sits alone at the bottom of a page.
// ---------------------------------------------------------------------------
const P = {
  ink: "#111827", sub: "#4b5563", mute: "#6b7280", line: "#e5e7eb", zebra: "#f9fafb", thbg: "#eef2f4",
  brand: "#0f4c5c", gold: "#b08d3c", totbg: "#f3f6f7", g: "#15803d", r: "#b91c1c", b: "#1d4ed8",
};
const PW = 800, PH = 1131, PX = 40, CW = PW - 2 * PX;       // A4 at 800 px wide
const PCX = [0, 0.46, 0.62, 0.78, 1].map(f => PX + Math.round(f * CW));
const PH_ROW = { kv: 32, th: 32, tr: 31, sec: 52 };
const TOP = 132, BOTTOM = PH - 62;                          // content area
export const PAGE_PX = BOTTOM - TOP;

export function pages(doc, max = PAGE_PX, H = PH_ROW) {
  const rows = (doc.rows || []).filter(r => H[r[0]]);
  const out = [];
  let cur = [], h = 0, th = null;
  const flush = () => { if (cur.length) out.push(cur); cur = []; h = 0; };
  for (const r of rows) {
    const t = r[0];
    if (t === "sec") th = null;
    if (t === "th") th = r;
    const need = H[t] + ((t === "sec" || t === "th") ? 2 * H.tr : 0);   // keep a title / head with 2 rows
    if (h + need > max && cur.length) {
      flush();
      if (t === "tr" && th) { cur.push(th); h += H.th; }
    }
    cur.push(r); h += H[t];
  }
  flush();
  return out;
}

function ptxt(x, y, s, o = {}) {
  const size = o.size || 13, bold = !!o.bold, anchor = o.align || "start";
  const w = o.w || CW;
  return `<text x="${x}" y="${y}" font-size="${size}" font-weight="${bold ? 700 : 400}" fill="${o.fill || P.ink}" text-anchor="${anchor}" dominant-baseline="central"${o.ls ? ` letter-spacing="${o.ls}"` : ""}>${esc(fit(s, w + 24 - 16, size, bold))}</text>`;
}
const hline = (x1, x2, y, c = P.line, w = 1) => `<line x1="${x1}" y1="${y}" x2="${x2}" y2="${y}" stroke="${c}" stroke-width="${w}"/>`;
const cell = (i, y, s, o = {}) => {
  const x0 = PCX[i], x1 = PCX[i + 1], w = x1 - x0 - 16;
  const align = o.align || (i === 0 ? "start" : i === 3 ? "end" : "middle");
  const x = align === "start" ? x0 + 10 : align === "end" ? x1 - 10 : (x0 + x1) / 2;
  return ptxt(x, y, s, { ...o, align, w });
};

// One A4 page: header (brand, report, date, page), rows, footer.
export function renderPage(rows, meta, i, n) {
  const o = [];
  o.push(`<rect width="${PW}" height="${PH}" fill="#ffffff"/>`);
  // header
  o.push(ptxt(PX, 58, "LUXURY WRIST BRAND", { size: 22, bold: true, fill: P.brand, ls: 1.5 }));
  o.push(ptxt(PX, 86, (meta.title || "Report") + (meta.sub ? "  ·  " + meta.sub : ""), { size: 14, fill: P.sub }));
  o.push(ptxt(PW - PX, 58, meta.date || "", { size: 16, bold: true, align: "end", w: 260 }));
  o.push(ptxt(PW - PX, 86, "Page " + (i + 1) + " of " + n, { size: 12, fill: P.mute, align: "end", w: 200 }));
  o.push(`<rect x="${PX}" y="104" width="${CW}" height="3" fill="${P.brand}"/><rect x="${PX}" y="104" width="90" height="3" fill="${P.gold}"/>`);
  // rows
  let y = TOP, z = 0;
  for (const r of rows) {
    const t = r[0], h = PH_ROW[t];
    if (t === "sec") {
      const top = y + 14;
      o.push(`<rect x="${PX}" y="${top}" width="4" height="22" fill="${P.brand}"/>`);
      o.push(ptxt(PX + 14, top + 11, r[1], { size: 15, bold: true, fill: P.ink }));
      o.push(hline(PX, PW - PX, y + h - 4, P.line));
      z = 0;
    } else if (t === "th") {
      o.push(`<rect x="${PX}" y="${y}" width="${CW}" height="${h}" fill="${P.thbg}"/>`);
      for (let c = 0; c < 4; c++) o.push(cell(c, y + h / 2, String((r[1] || [])[c] || "").toUpperCase(), { size: 11, bold: true, fill: P.sub, ls: 0.4 }));
      z = 0;
    } else if (t === "tr") {
      const tot = !!r[2], tone = r[3] && P[r[3]];
      if (tot) { o.push(`<rect x="${PX}" y="${y}" width="${CW}" height="${h}" fill="${P.totbg}"/>`); o.push(hline(PX, PW - PX, y, P.brand, 1.5)); }
      else if (z++ % 2 === 1) o.push(`<rect x="${PX}" y="${y}" width="${CW}" height="${h}" fill="${P.zebra}"/>`);
      for (let c = 0; c < 4; c++) o.push(cell(c, y + h / 2, (r[1] || [])[c] ?? "", { size: 13, bold: tot, fill: tone || P.ink }));
      o.push(hline(PX, PW - PX, y + h, P.line));
    } else if (t === "kv") {
      const tone = r[3] && P[r[3]];
      o.push(ptxt(PX + 10, y + h / 2, r[1], { size: 13, fill: P.sub, w: CW * 0.4 }));
      o.push(ptxt(PW - PX - 10, y + h / 2, r[2], { size: 13, bold: true, fill: tone || P.ink, align: "end", w: CW * 0.6 }));
      o.push(`<line x1="${PX}" y1="${y + h}" x2="${PW - PX}" y2="${y + h}" stroke="${P.line}" stroke-width="1" stroke-dasharray="3 3"/>`);
    }
    y += h;
  }
  // footer
  o.push(hline(PX, PW - PX, PH - 44, P.line));
  o.push(ptxt(PX, PH - 26, "Luxury Wrist Brand ERP  ·  luxurywristbrand.com", { size: 11, fill: P.mute }));
  o.push(ptxt(PW - PX, PH - 26, "Confidential  ·  " + (meta.footer || "For management"), { size: 11, fill: P.mute, align: "end", w: 300 }));
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${PW}" height="${PH}" viewBox="0 0 ${PW} ${PH}"><g font-family="Roboto">${o.join("")}</g></svg>`;
}

// svgToPng(svg) -> Uint8Array PNG; PDFDocument from pdf-lib. meta = {title, sub, date, footer}. Returns PDF bytes.
export async function buildPdf(doc, svgToPng, PDFDocument, meta = {}) {
  const pdf = await PDFDocument.create();
  pdf.setTitle("Luxury Wrist Brand · " + (meta.title || "Report") + (meta.date ? " · " + meta.date : ""));
  pdf.setAuthor("Luxury Wrist Brand ERP"); pdf.setCreator("Luxury Wrist Brand ERP");
  const list = pages(doc);
  for (let i = 0; i < list.length; i++) {
    const img = await pdf.embedPng(svgToPng(renderPage(list[i], meta, i, list.length)));
    const page = pdf.addPage([595.28, 841.89]);
    page.drawImage(img, { x: 0, y: 0, width: 595.28, height: 841.89 });
  }
  return await pdf.save();
}
