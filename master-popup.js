/* Master pages: list first, add / edit form in a popup (Mohit, 4 Nov 2026).
   LWBMasterPopup.mount({panel, bar, title, newLabel, onNew, canNew, cards})
   - panel: id of the form <section>; it is moved into a popup (✕ / Esc / backdrop / Cancel close it).
   - bar: element (or id) of the list header; a "+ New …" button is added there.
   - onNew(): clears the form before it opens. canNew(): true when this login may add.
   - cards: CSS selector of the list table; on a phone each row becomes a compact card
     (labels from the table head), so the page never scrolls sideways.
   Returns {open, close}. Pages call open() from their Edit button and close() after a good save. */
(function () {
  const CSS = `
.mp-modal{position:fixed;inset:0;z-index:1200;background:rgba(0,30,35,.5);display:flex;align-items:flex-start;justify-content:center;padding:24px 12px;overflow:auto}
.mp-modal[hidden]{display:none}
.mp-modal>.mp-card{width:100%;max-width:880px;margin:0!important;box-shadow:0 12px 32px rgba(0,0,0,.25);position:relative}
.mp-x{position:absolute;top:10px;right:10px;border:0;background:#eef1f5;color:#193d65;border-radius:8px;padding:6px 11px;font-weight:700;cursor:pointer;z-index:2}
.mp-card .sectionhead{padding-right:46px}
.mp-new{background:#c9b26a!important;color:#002f37!important;border:1px solid #c9b26a!important;border-radius:8px;padding:8px 13px;font-weight:700;cursor:pointer;white-space:nowrap}
.mp-cancel{white-space:nowrap}
body.mp-open{overflow:hidden}
@media(max-width:700px){
  .mp-modal{padding:0}.mp-modal>.mp-card{min-height:100%;border-radius:0!important}
  .mp-card .fields,.mp-card .form-grid,.mp-card .fa-grid{grid-template-columns:minmax(0,1fr) minmax(0,1fr)!important;gap:8px!important}
  .mp-card .fields>:first-child,.mp-card .form-grid>:first-child,.mp-card .fa-grid>:nth-child(2),.mp-card .field.full{grid-column:span 2!important}
  .mp-card input,.mp-card select{min-width:0;max-width:100%}
  .mp-card .fa-actions,.mp-card .actions{position:sticky;bottom:0;background:#fff;padding:8px 0;margin-top:8px;display:flex;gap:6px;flex-wrap:nowrap;z-index:1}
  .mp-card .actions button{white-space:nowrap}
  .mp-card .actions{flex-wrap:wrap!important}.mp-card .actions .small,.mp-card .actions .hint{flex-basis:100%;order:9;font-size:11.5px}
  .mp-cards-on .tablewrap,.mp-cards-on .scroll,.mp-cards-on .table-wrap{overflow:visible!important;border:0!important}
  table.mp-cards{min-width:0!important}table.mp-cards thead{display:none}
  table.mp-cards tbody tr{display:grid;grid-template-columns:1fr 1fr;gap:3px 10px;padding:9px 4px;border-bottom:1px solid #e3e7ec}
  table.mp-cards tbody td{display:block;border:0!important;padding:0!important;font-size:12.5px;text-align:left!important;min-width:0!important;white-space:normal!important}
  table.mp-cards tbody td[data-label]:not(.mp-main):not(.mp-act)::before{content:attr(data-label)": ";color:#6b7785;font-weight:600}
  table.mp-cards tbody td.mp-main{grid-column:span 2;order:-1;font-size:14px;font-weight:700}
  table.mp-cards tbody td.mp-act{grid-column:span 2;display:flex;gap:6px;margin-top:4px}
  table.mp-cards tbody td.mp-act button{flex:1;padding:7px 10px}
  table.mp-cards tbody td[colspan]{grid-column:span 2}
  table.mp-cards tbody td[hidden]{display:none!important}
}`;
  function style() {
    if (document.getElementById("mpStyle")) return;
    const s = document.createElement("style"); s.id = "mpStyle"; s.textContent = CSS; document.head.appendChild(s);
  }
  // Phone cards: label every cell from the table head; the main column (name) and the last (actions) are marked.
  function cards(sel, mainIdx) {
    let t = document.querySelector(sel); if (t && t.tagName !== "TABLE") t = t.closest("table"); if (!t) return;
    t.classList.add("mp-cards"); (t.closest(".panel,section") || document.body).classList.add("mp-cards-on");
    const label = () => {
      const heads = [...t.querySelectorAll("thead th")].map(th => th.textContent.trim());
      t.querySelectorAll("tbody tr").forEach(tr => [...tr.children].forEach((td, i) => {
        if (td.colSpan > 1) return;
        if (heads[i] && td.dataset.label !== heads[i]) td.dataset.label = heads[i];
        td.classList.toggle("mp-main", i === mainIdx);
        td.classList.toggle("mp-act", i === heads.length - 1 && /action/i.test(heads[i] || ""));
      }));
    };
    label(); new MutationObserver(label).observe(t.tBodies[0] || t, { childList: true, subtree: true });
  }
  function mount(o) {
    style();
    const panel = document.getElementById(o.panel);
    const modal = document.createElement("div"); modal.className = "mp-modal"; modal.hidden = true;
    panel.parentNode.insertBefore(modal, panel); modal.appendChild(panel); panel.classList.add("mp-card");
    panel.setAttribute("role", "dialog"); panel.setAttribute("aria-modal", "true");
    const x = document.createElement("button"); x.type = "button"; x.className = "mp-x"; x.textContent = "✕"; x.setAttribute("aria-label", "Close");
    panel.prepend(x);
    const open = () => { modal.hidden = false; document.body.classList.add("mp-open"); modal.scrollTop = 0;
      setTimeout(() => { const f = panel.querySelector("input:not([type=hidden]):not([disabled]),select,textarea"); if (f) f.focus(); }, 30); };
    const close = () => { modal.hidden = true; document.body.classList.remove("mp-open"); };
    x.onclick = close;
    modal.addEventListener("click", e => { if (e.target === modal) close(); });
    document.addEventListener("keydown", e => { if (e.key === "Escape" && !modal.hidden) close(); });
    if (o.cancelAfter) {
      const at = typeof o.cancelAfter === "string" ? document.getElementById(o.cancelAfter) : o.cancelAfter;
      if (at) { const c = document.createElement("button"); c.type = "button"; c.className = "secondary mp-cancel"; c.textContent = "Cancel"; c.onclick = close; at.after(c); }
    }
    const bar = typeof o.bar === "string" ? document.getElementById(o.bar) : o.bar;
    const nb = document.createElement("button"); nb.type = "button"; nb.className = "mp-new"; nb.textContent = o.newLabel || "+ New";
    nb.onclick = () => { if (o.onNew) o.onNew(); open(); };
    if (bar) bar.appendChild(nb);
    const sync = () => { nb.hidden = o.canNew ? !o.canNew() : false; };
    sync(); setInterval(sync, 1500);
    if (o.cards) cards(o.cards, o.mainCol == null ? 1 : o.mainCol);
    if (/^#(new|add)$/.test(location.hash)) setTimeout(() => { sync(); if (!nb.hidden) nb.click(); }, 900);
    return { open, close };
  }
  window.LWBMasterPopup = { mount, cards };
})();
