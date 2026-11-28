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
  brand: "#0f4c5c", gold: "#b08d3c", totbg: "#f3f6f7", band: "#eaf1f3", g: "#15803d", r: "#b91c1c", b: "#1d4ed8",
};
const PW = 800, PH = 1131, PX = 40, CW = PW - 2 * PX;       // A4 at 800 px wide
const PCX = [0, 0.46, 0.62, 0.78, 1].map(f => PX + Math.round(f * CW));
const PH_ROW = { kv: 32, th: 32, tr: 31, sec: 52, grp: 30, h1: 96, sum: 40, note: 34 };
// Evening report rows: ["h1", title, line 2, line 3] centred title block, ["sum", [3 texts]] blue bar of
// 3 boxes, ["note", text] centred grey line, ["brk"] new page, ["th", cells, widths] any number of columns
// (widths = fractions of the page; the "tr" rows under it use the same columns).
const TOP = 132, BOTTOM = PH - 62;                          // content area
export const PAGE_PX = BOTTOM - TOP;

export function pages(doc, max = PAGE_PX, H = PH_ROW) {
  const rows = (doc.rows || []).filter(r => H[r[0]] || r[0] === "brk");
  const out = [];
  let cur = [], h = 0, th = null;
  const flush = () => { if (cur.length) out.push(cur); cur = []; h = 0; };
  for (const r of rows) {
    const t = r[0];
    if (t === "brk") { flush(); th = null; continue; }
    if (t === "sec" || t === "h1") th = null;
    if (t === "th") th = r;
    const need = H[t] + ((t === "sec" || t === "th" || t === "grp") ? 2 * H.tr : t === "h1" ? H.sec + H.sum : 0);   // keep a title / head / brand with 2 rows
    if (h + need > max && cur.length) {
      flush();
      if ((t === "tr" || t === "grp") && th) { cur.push(th); h += H.th; }
    }
    cur.push(r); h += H[t];
  }
  flush();
  return out;
}

// The page is drawn through a small painter g = {rect, line, text}; one painter writes SVG
// (previews / tests), the other draws straight into the PDF (vector text: light and sharp).
function paint(g, rows, meta, i, n) {
  let cx = PCX, wide = 0, sno = false;  // columns of the table being drawn (a "th" with widths changes them)
  const colsOf = wd => { const o = [PX]; let a = 0; for (const f of wd) { a += Number(f) || 0; o.push(PX + Math.round(Math.min(a, 1) * CW)); } o[o.length - 1] = PX + CW; return o; };
  const cell = (c, y, s, o = {}) => {
    const x0 = cx[c], x1 = cx[c + 1], w = x1 - x0 - 20, last = cx.length - 2;
    // default 4 columns: first left, last right; own widths: the widest column (name) left, S.No. centred
    const align = o.align || (cx === PCX ? (c === 0 ? "start" : c === last ? "end" : "middle")
      : c === wide ? "start" : c === 0 ? (sno ? "middle" : "start") : c === last ? "end" : "middle");
    const x = align === "start" ? x0 + 10 : align === "end" ? x1 - 10 : (x0 + x1) / 2;
    g.text(x, y, s, { ...o, align, w });
  };
  // header
  g.text(PX, 58, "LUXURY WRIST BRAND", { size: 22, bold: true, fill: P.brand, w: 460, ls: 1.5 });
  g.text(PX, 86, (meta.title || "Report") + (meta.sub ? "  ·  " + meta.sub : ""), { size: 14, fill: P.sub, w: 460 });
  g.text(PW - PX, 58, meta.date || "", { size: 16, bold: true, align: "end", w: 240 });
  g.text(PW - PX, 86, "Page " + (i + 1) + " of " + n, { size: 12, fill: P.mute, align: "end", w: 200 });
  g.rect(PX, 104, CW, 3, P.brand); g.rect(PX, 104, 90, 3, P.gold);
  // rows
  let y = TOP, z = 0;
  for (const r of rows) {
    const t = r[0], h = PH_ROW[t];
    if (t === "h1") {
      g.text(PW / 2, y + 22, r[1], { size: 22, bold: true, align: "middle", w: CW });
      g.line(PW / 2 - 70, PW / 2 + 70, y + 37, P.ink, 1.2);
      g.text(PW / 2, y + 56, r[2] || "", { size: 15, bold: true, fill: P.brand, align: "middle", w: CW });
      g.text(PW / 2, y + 78, r[3] || "", { size: 14, bold: true, fill: P.sub, align: "middle", w: CW });
      cx = PCX; z = 0;
    } else if (t === "sum") {
      const n = (r[1] || []).length || 1, bw = CW / n;
      for (let c = 0; c < n; c++) {
        g.rect(PX + c * bw + (c ? 2 : 0), y + 4, bw - (c ? 2 : 0), h - 8, P.brand);
        g.text(PX + c * bw + 10, y + h / 2, r[1][c], { size: 13, bold: true, fill: "#ffffff", w: bw - 20 });
      }
    } else if (t === "note") {
      g.text(PW / 2, y + h / 2, r[1], { size: 12.5, bold: true, fill: P.mute, align: "middle", w: CW });
    } else if (t === "sec") {
      cx = PCX;
      g.rect(PX, y + 14, 4, 22, P.brand);
      g.text(PX + 14, y + 25, r[1], { size: 15, bold: true, w: CW - 20 });
      g.line(PX, PW - PX, y + h - 4, P.line, 1);
      z = 0;
    } else if (t === "th") {
      cx = Array.isArray(r[2]) ? colsOf(r[2]) : PCX;
      wide = Array.isArray(r[2]) ? r[2].indexOf(Math.max(...r[2])) : 0; sno = /^s\.?\s*no/i.test(String((r[1] || [])[0] || ""));
      g.rect(PX, y, CW, h, P.thbg);
      for (let c = 0; c < cx.length - 1; c++) cell(c, y + h / 2, String((r[1] || [])[c] || "").toUpperCase(), { size: 11, bold: true, fill: P.sub, ls: 0.4 });
      z = 0;
    } else if (t === "grp") {            // brand band: name left, count + amount right
      g.rect(PX, y + 4, CW, h - 4, P.band);
      g.rect(PX, y + 4, 3, h - 4, P.gold);
      g.text(PX + 12, y + 4 + (h - 4) / 2, r[1], { size: 12.5, bold: true, fill: P.brand, w: CW * 0.55, ls: 0.6 });
      g.text(PW - PX - 10, y + 4 + (h - 4) / 2, r[2] || "", { size: 12, bold: true, fill: P.sub, align: "end", w: CW * 0.42 });
      z = 0;
    } else if (t === "tr") {
      const tot = !!r[2], tone = r[3] && P[r[3]];
      if (tot) { g.rect(PX, y, CW, h, P.totbg); g.line(PX, PW - PX, y, P.brand, 1.5); }
      else if (z++ % 2 === 1) g.rect(PX, y, CW, h, P.zebra);
      for (let c = 0; c < cx.length - 1; c++) cell(c, y + h / 2, (r[1] || [])[c] ?? "", { size: cx === PCX ? 13 : 12, bold: tot, fill: tone || P.ink });
      g.line(PX, PW - PX, y + h, P.line, 1);
    } else if (t === "kv") {
      const tone = r[3] && P[r[3]];
      g.text(PX + 10, y + h / 2, r[1], { size: 13, fill: P.sub, w: CW * 0.36 });
      g.text(PW - PX - 10, y + h / 2, r[2], { size: 13, bold: true, fill: tone || P.ink, align: "end", w: CW * 0.6 });
      g.line(PX, PW - PX, y + h, P.line, 1, true);
    }
    y += h;
  }
  // footer
  g.line(PX, PW - PX, PH - 44, P.line, 1);
  g.text(PX, PH - 26, "Luxury Wrist Brand ERP  ·  luxurywristbrand.com", { size: 11, fill: P.mute, w: 360 });
  g.text(PW - PX, PH - 26, "Confidential  ·  " + (meta.footer || "For management"), { size: 11, fill: P.mute, align: "end", w: 300 });
}

// SVG of one A4 page (preview / tests).
export function renderPage(rows, meta, i, n) {
  const o = [`<rect width="${PW}" height="${PH}" fill="#ffffff"/>`];
  paint({
    rect: (x, y, w, h, c) => o.push(`<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="${c}"/>`),
    line: (x1, x2, y, c, w, dash) => o.push(`<line x1="${x1}" y1="${y}" x2="${x2}" y2="${y}" stroke="${c}" stroke-width="${w}"${dash ? ' stroke-dasharray="3 3"' : ""}/>`),
    text: (x, y, s, t = {}) => {
      const size = t.size || 13, bold = !!t.bold;
      o.push(`<text x="${x}" y="${y}" font-size="${size}" font-weight="${bold ? 700 : 400}" fill="${t.fill || P.ink}" text-anchor="${t.align || "start"}" dominant-baseline="central"${t.ls ? ` letter-spacing="${t.ls}"` : ""}>${esc(fit(s, (t.w || CW) + 24, size, bold))}</text>`);
    },
  }, rows, meta, i, n);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${PW}" height="${PH}" viewBox="0 0 ${PW} ${PH}"><g font-family="Roboto">${o.join("")}</g></svg>`;
}

// Vector PDF. lib = {PDFDocument, rgb}, fontkit = @pdf-lib/fontkit, fonts = [Roboto regular, bold] bytes.
// meta = {title, sub, date, footer}. Returns PDF bytes.
export async function buildPdf(doc, lib, fontkit, fonts, meta = {}) {
  const { PDFDocument, rgb } = lib;
  const pdf = await PDFDocument.create();
  pdf.registerFontkit(fontkit);
  pdf.setTitle("Luxury Wrist Brand · " + (meta.title || "Report") + (meta.date ? " · " + meta.date : ""));
  pdf.setAuthor("Luxury Wrist Brand ERP"); pdf.setCreator("Luxury Wrist Brand ERP");
  const reg = await pdf.embedFont(fonts[0], { subset: true }), bold = await pdf.embedFont(fonts[1], { subset: true });
  const has = new Set(reg.getCharacterSet());
  const k = 595.28 / PW, PHpt = PH * k;
  const col = hex => { const v = parseInt(hex.slice(1), 16); return rgb((v >> 16 & 255) / 255, (v >> 8 & 255) / 255, (v & 255) / 255); };
  const clean = s => Array.from(String(s == null ? "" : s)).map(ch => ch === "✓" ? "OK" : has.has(ch.codePointAt(0)) ? ch : "").join("");
  const list = pages(doc);
  for (let i = 0; i < list.length; i++) {
    const page = pdf.addPage([595.28, PHpt]);
    paint({
      rect: (x, y, w, h, c) => page.drawRectangle({ x: x * k, y: PHpt - (y + h) * k, width: w * k, height: h * k, color: col(c) }),
      line: (x1, x2, y, c, w, dash) => page.drawLine({ start: { x: x1 * k, y: PHpt - y * k }, end: { x: x2 * k, y: PHpt - y * k },
        thickness: w * k, color: col(c), ...(dash ? { dashArray: [3 * k, 3 * k] } : {}) }),
      text: (x, y, s, t = {}) => {
        const f = t.bold ? bold : reg, size = (t.size || 13) * k, max = (t.w || CW) * k;
        let txt = clean(s);
        if (f.widthOfTextAtSize(txt, size) > max) {
          while (txt.length > 1 && f.widthOfTextAtSize(txt + "…", size) > max) txt = txt.slice(0, -1);
          txt = txt.trimEnd() + "…";
        }
        const w = f.widthOfTextAtSize(txt, size);
        const px = t.align === "end" ? x * k - w : t.align === "middle" ? x * k - w / 2 : x * k;
        page.drawText(txt, { x: px, y: PHpt - y * k - size * 0.35, size, font: f, color: col(t.fill || P.ink) });
      },
    }, list[i], meta, i, list.length);
  }
  return await pdf.save();
}
