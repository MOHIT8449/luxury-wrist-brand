// WhatsApp order chat (Mohit, 21 Nov 2026): pure steps, no network / database here, so it is tested
// with node (tests/whatsapp-order). index.ts reads the message, keeps the state per mobile and sends the replies.
//
// step(state, input, ctx) -> {state, replies:[msg...], submit?:{shop, city}}
//   state  : {stage, brand, cat, page, sku, cart:[{sku,qty}], shop, city}
//   input  : {kind:'text', text} | {kind:'pick', id}   (list row / reply button id or quick-reply payload)
//   ctx    : {catalog:{brands:[{id,name}], skus:[{name,brand,category,pcs}]}, party:{name}|null, profileName}
//   msg    : {type:'text', body} | {type:'buttons', body, buttons:[{id,title}]}
//            | {type:'list', body, button, sections:[{title, rows:[{id,title,description}]}]}
// WhatsApp limits: list = max 10 rows in all, row title 24, row description 72, section title 24,
// list button 20, reply buttons max 3 with title 20.

export const MAX_ROWS = 10;
const keep = (st) => ({ ...fresh(), shop: st.shop || "", city: st.city || "" });
export const fresh = () => ({ stage: "idle", brand: "", cat: "", page: 0, sku: "", cart: [], shop: "", city: "" });
const cut = (s, n) => { s = String(s || ""); return s.length > n ? s.slice(0, n - 1) + "…" : s; };
const norm = (s) => String(s || "").toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
const START = /^(hi+|hello|hey|hii|order|order karen|order karein|order करें|ऑर्डर|ऑर्डर करें|menu|start|namaste|नमस्ते|jai shree krishna|kem cho)\b/i;
const CANCEL = /^(cancel|stop|रद्द|रद्द करें|band|बंद)\b/i;

function brandSkus(ctx, brand) { return (ctx.catalog.skus || []).filter((s) => s.brand === brand); }
function brandName(ctx, id) { return ((ctx.catalog.brands || []).find((b) => b.id === id) || {}).name || ""; }
function cats(list) { return [...new Set(list.map((s) => s.category || "Other"))]; }
function caseWord(n) { return n === 1 ? "केस" : "केस"; }

export function hello(ctx) {
  const who = ctx.party && ctx.party.name ? ctx.party.name : ctx.profileName || "";
  return "नमस्ते" + (who ? " " + who : "") + " 🙏";
}

function brandMenu(ctx, lead) {
  const brands = (ctx.catalog.brands || []).slice(0, MAX_ROWS);
  if (!brands.length) return { type: "text", body: "अभी ऑनलाइन ऑर्डर बंद है। कृपया 92743 82694 पर कॉल करें।" };
  return {
    type: "list", body: (lead ? lead + "\n" : "") + "कौन से ब्रांड का ऑर्डर देना है?", button: "ब्रांड चुनें",
    sections: [{ title: "ब्रांड", rows: brands.map((b) => {
      const some = brandSkus(ctx, b.id).slice(0, 4).map((s) => s.name).join(", ");
      return { id: "b:" + b.id, title: cut(b.name, 24), description: cut(some, 72) };
    }) }],
  };
}

// Products of the brand: one list when they fit, else categories first, then pages of 9 + "More".
function productMenu(ctx, st) {
  const all = brandSkus(ctx, st.brand);
  const bn = brandName(ctx, st.brand);
  if (!all.length) return { type: "text", body: bn + " का कोई प्रोडक्ट अभी ऑनलाइन नहीं है।" };
  const cs = cats(all);
  if (all.length > MAX_ROWS && cs.length > 1 && !st.cat) {
    return { type: "list", body: bn + ": कैटेगरी चुनें 👇", button: "कैटेगरी",
      sections: [{ title: "कैटेगरी", rows: cs.slice(0, MAX_ROWS).map((c, i) => ({ id: "c:" + i, title: cut(c, 24),
        description: cut(all.filter((s) => (s.category || "Other") === c).length + " प्रोडक्ट", 72) })) }] };
  }
  const list = st.cat ? all.filter((s) => (s.category || "Other") === st.cat) : all;
  const per = list.length > MAX_ROWS ? MAX_ROWS - 1 : MAX_ROWS;
  const page = Math.max(0, Math.min(st.page || 0, Math.ceil(list.length / per) - 1));
  const rows = list.slice(page * per, page * per + per).map((s) => {
    const inCart = (st.cart || []).find((c) => c.sku === s.name);
    return { id: "p:" + s.name, title: cut(s.name, 24),
      description: cut([s.name.length > 24 ? s.name : "", s.pcs ? s.pcs + " pcs / case" : "", inCart ? "🛒 " + inCart.qty + " केस" : ""].filter(Boolean).join(" · "), 72) };
  });
  if (list.length > per * (page + 1)) rows.push({ id: "pg:" + (page + 1), title: "और प्रोडक्ट ▶", description: "अगले प्रोडक्ट देखें" });
  return { type: "list", body: bn + (st.cat ? " · " + st.cat : "") + ": प्रोडक्ट चुनें 👇", button: "प्रोडक्ट",
    sections: [{ title: cut(st.cat || bn, 24), rows }] };
}

export function cartText(ctx, st) {
  const total = st.cart.reduce((a, c) => a + c.qty, 0);
  return "🛒 आपका ऑर्डर (" + brandName(ctx, st.brand) + ")\n" +
    st.cart.map((c) => "• " + c.sku + " — " + c.qty + " " + caseWord(c.qty)).join("\n") +
    "\nकुल: " + total + " केस";
}
function cartMenu(ctx, st, lead) {
  return { type: "buttons", body: (lead ? lead + "\n\n" : "") + cartText(ctx, st),
    buttons: [{ id: "a:more", title: "➕ और प्रोडक्ट" }, { id: "a:send", title: "✅ ऑर्डर भेजो" }, { id: "a:cancel", title: "❌ रद्द करें" }] };
}

// Whole cases: "10", "10 case", "१०".
export function parseQty(text) {
  const t = String(text || "").replace(/[०-९]/g, (d) => String("०१२३४५६७८९".indexOf(d))).trim();
  const m = t.match(/^(\d{1,4})\s*(cs|case|cases|केस|पेटी|peti|box)?\.?$/i);
  return m ? Number(m[1]) : null;
}

// Match a typed product name ("thums up 250") to one SKU of the brand.
function findSku(ctx, brand, text) {
  const words = norm(text).split(" ").filter(Boolean);
  if (!words.length) return null;
  const hits = brandSkus(ctx, brand).filter((s) => words.every((w) => norm(s.name).includes(w)));
  return hits.length === 1 ? hits[0] : null;
}

export function step(state, input, ctx) {
  let st = { ...fresh(), ...(state || {}) };
  st.cart = Array.isArray(st.cart) ? st.cart.slice() : [];
  const out = (replies, extra) => ({ state: st, replies, ...(extra || {}) });
  const pick = input.kind === "pick" ? String(input.id || "") : "";
  const text = input.kind === "text" ? String(input.text || "").trim() : "";

  if (pick === "a:cancel" || CANCEL.test(text)) {
    st = keep(st);
    return out([{ type: "text", body: "ठीक है, ऑर्डर रद्द कर दिया। नया ऑर्डर देने के लिए \"Order\" लिखें।" }]);
  }
  // Template "Order करें" button, or hi / order typed: start (keep a half-made cart).
  if (/^(order|start|ORDER)$/i.test(pick) || (!pick && START.test(text) && st.stage !== "qty" && st.stage !== "shop")) {
    if (st.cart.length) return out([cartMenu(ctx, st, hello(ctx) + " आपका पिछला ऑर्डर अभी बाकी है:")]);
    st = keep(st);
    const brands = ctx.catalog.brands || [];
    if (brands.length === 1) { st.brand = brands[0].id; st.stage = "product"; return out([{ type: "text", body: hello(ctx) }, productMenu(ctx, st)]); }
    st.stage = "brand";
    return out([brandMenu(ctx, hello(ctx))]);
  }
  if (pick.startsWith("b:")) {
    const id = pick.slice(2);
    if (!brandName(ctx, id)) return out([brandMenu(ctx, "ये ब्रांड अभी नहीं है।")]);
    if (st.cart.length && st.brand && st.brand !== id) {
      return out([cartMenu(ctx, st, "एक ऑर्डर में एक ही ब्रांड। पहले ये ऑर्डर भेजें या रद्द करें, फिर " + brandName(ctx, id) + " का ऑर्डर दें।")]);
    }
    st.brand = id; st.cat = ""; st.page = 0; st.stage = "product";
    return out([productMenu(ctx, st)]);
  }
  if (pick.startsWith("c:")) {
    const c = cats(brandSkus(ctx, st.brand))[Number(pick.slice(2))];
    st.cat = c || ""; st.page = 0; st.stage = "product";
    return out([productMenu(ctx, st)]);
  }
  if (pick.startsWith("pg:")) { st.page = Number(pick.slice(3)) || 0; return out([productMenu(ctx, st)]); }
  if (pick.startsWith("p:")) {
    const s = brandSkus(ctx, st.brand).find((x) => x.name === pick.slice(2));
    if (!s) return out([productMenu(ctx, st)]);
    st.sku = s.name; st.stage = "qty";
    const had = st.cart.find((c) => c.sku === s.name);
    return out([{ type: "text", body: s.name + ": कितने केस? नंबर लिखें" + (had ? " (अभी " + had.qty + ", 0 लिखें तो हट जाएगा)" : "") + "।" }]);
  }
  if (pick === "a:more") { st.cat = ""; st.page = 0; st.stage = "product"; return out([productMenu(ctx, st)]); }
  if (pick === "a:send") {
    if (!st.cart.length) return out([st.brand ? productMenu(ctx, st) : brandMenu(ctx, "अभी कोई प्रोडक्ट नहीं चुना।")]);
    if (!ctx.party && !st.shop) {
      st.stage = "shop";
      return out([{ type: "text", body: "आखिरी कदम: अपनी दुकान का नाम और एरिया लिखें।\nजैसे: Jay Ambe Store, Varachha Surat" }]);
    }
    return out([], { submit: { shop: st.shop, city: st.city } });
  }

  if (st.stage === "qty" && text) {
    const n = parseQty(text);
    if (n == null || n > 5000) return out([{ type: "text", body: "सिर्फ़ केस का नंबर लिखें, जैसे 10।" }]);
    st.cart = st.cart.filter((c) => c.sku !== st.sku);
    if (n > 0) st.cart.push({ sku: st.sku, qty: n });
    if (st.cart.length > 60) st.cart = st.cart.slice(0, 60);
    st.sku = ""; st.stage = "cart";
    if (!st.cart.length) return out([productMenu(ctx, st)]);
    return out([cartMenu(ctx, st)]);
  }
  if (st.stage === "shop" && text) {
    const clean = text.replace(/\s+/g, " ").slice(0, 160);
    if (clean.length < 3 || /(https?:\/\/|www\.)/i.test(clean)) return out([{ type: "text", body: "दुकान का नाम और एरिया लिखें, जैसे: Jay Ambe Store, Varachha Surat" }]);
    const i = clean.indexOf(",");
    st.shop = (i > 0 ? clean.slice(0, i) : clean).trim().slice(0, 100);
    st.city = (i > 0 ? clean.slice(i + 1) : "").trim().slice(0, 60);
    return out([], { submit: { shop: st.shop, city: st.city } });
  }
  // Typed a product name while choosing products: "thums up 250".
  if (text && st.brand && (st.stage === "product" || st.stage === "cart")) {
    const s = findSku(ctx, st.brand, text);
    if (s) { st.sku = s.name; st.stage = "qty"; return out([{ type: "text", body: s.name + ": कितने केस? नंबर लिखें।" }]); }
    return out([st.cart.length ? cartMenu(ctx, st, "समझ नहीं आया। नीचे से चुनें 👇") : productMenu(ctx, st)]);
  }
  // Anything else: start.
  if (st.cart.length) return out([cartMenu(ctx, st)]);
  st = keep(st); st.stage = "brand";
  return out([brandMenu(ctx, hello(ctx) + " Luxury Wrist Brand में आपका स्वागत है।")]);
}

// After the order is saved.
export function doneText(ctx, st, ref) {
  const total = st.cart.reduce((a, c) => a + c.qty, 0);
  return "✅ ऑर्डर मिल गया: " + ref + "\n" + brandName(ctx, st.brand) + " · " + total + " केस · " + st.cart.length + " प्रोडक्ट\n" +
    "हमारी टीम रेट और डिलीवरी कन्फ़र्म करेगी। धन्यवाद 🙏";
}

// Meta webhook message -> input. Returns null for messages we do not read (status, reaction...).
export function inputOf(msg) {
  if (!msg || typeof msg !== "object") return null;
  if (msg.type === "text") return { kind: "text", text: String(msg.text?.body || "").slice(0, 500) };
  if (msg.type === "interactive") {
    const r = msg.interactive?.list_reply || msg.interactive?.button_reply;
    return r ? { kind: "pick", id: String(r.id || "").slice(0, 200) } : null;
  }
  // Template quick-reply button ("Order करें").
  if (msg.type === "button") return { kind: "pick", id: /order/i.test(String(msg.button?.payload || msg.button?.text || "")) ? "order" : String(msg.button?.payload || "").slice(0, 200) };
  return { kind: "text", text: "" };
}

// Reply -> Meta Cloud API message body.
export function apiBody(to, m) {
  const base = { messaging_product: "whatsapp", recipient_type: "individual", to };
  if (m.type === "buttons") return { ...base, type: "interactive", interactive: { type: "button", body: { text: cut(m.body, 1024) },
    action: { buttons: m.buttons.slice(0, 3).map((b) => ({ type: "reply", reply: { id: b.id, title: cut(b.title, 20) } })) } } };
  if (m.type === "list") return { ...base, type: "interactive", interactive: { type: "list", body: { text: cut(m.body, 1024) },
    action: { button: cut(m.button, 20), sections: m.sections.map((s) => ({ title: cut(s.title, 24),
      rows: s.rows.slice(0, MAX_ROWS).map((r) => ({ id: cut(r.id, 200), title: cut(r.title, 24), ...(r.description ? { description: cut(r.description, 72) } : {}) })) })) } } };
  return { ...base, type: "text", text: { body: cut(m.body, 4096), preview_url: false } };
}
