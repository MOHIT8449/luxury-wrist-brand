/* LUXURY WRIST BRAND ERP — "count card → list" popup.
   Mohit asked (31 Oct 2026): every card that shows a total number must open the list
   of the records behind that number (click "Pending 18" → the 18 pending orders).

   ERPList.open({
     title: "Pending orders",            // popup heading
     sub:   "Not delivered yet",          // optional line under the heading
     rows:  [...],                        // the records (or use load)
     load:  async () => rows,             // optional: rows fetched when the popup opens
     cols:  [{t:"Order No", v:r=>r.order_no},
             {t:"Amount", v:r=>r.total_amount, money:true, sum:true},
             {t:"Cases",  v:r=>r.total_qty, num:true, sum:true},
             {t:"Status", v:r=>r.status, html:r=>"<b>..</b>"}],
     onRow: r => openOrder(r.id),          // optional: click a row (popup closes first)
     empty: "No record"                   // optional
   });
   ERPList.card(el, () => ({...same options...}));  // makes a card clickable
   ERPList.cards(root, {selector: fn})                // many cards at once

   Read only: the popup only shows records already allowed to this login. */
(function(){
  if(window.ERPList)return;
  const CSS=`
.erp-drill{cursor:pointer;transition:box-shadow .18s ease,transform .18s ease,border-color .18s ease}
.erp-drill:hover{box-shadow:0 8px 22px rgba(0,47,55,.13)!important;transform:translateY(-1px)}
.erp-drill:focus-visible{outline:2px solid #c9b26a;outline-offset:2px}
.erp-drill .erp-drill-hint{display:block!important;margin-top:4px!important;padding:0!important;border:0!important;font-size:11px!important;font-weight:600!important;letter-spacing:.2px!important;color:#7a6420!important;opacity:.8;text-transform:none!important;background:none!important}
.erp-drill:hover .erp-drill-hint{opacity:1}
.erp-ls-back{position:fixed;inset:0;z-index:4800;background:rgba(0,30,35,.48);display:grid;place-items:center;padding:16px;opacity:0;transition:opacity .15s;backdrop-filter:blur(2px);-webkit-backdrop-filter:blur(2px)}
.erp-ls-back.show{opacity:1}
.erp-ls{width:min(1080px,100%);max-height:calc(100dvh - 32px);display:flex;flex-direction:column;background:#fff;border-radius:14px;box-shadow:0 24px 60px rgba(0,30,35,.3);overflow:hidden;font:14px/1.45 "Fira Sans","Segoe UI",Roboto,Arial,sans-serif;color:#1f2a37;transform:translateY(10px);transition:transform .15s}
.erp-ls-back.show .erp-ls{transform:none}
.erp-ls-head{display:flex;align-items:flex-start;gap:12px;padding:16px 18px 12px;background:#002f37;color:#fff;border-bottom:2px solid #c9b26a}
.erp-ls-head h3{margin:0;font-size:18px;font-weight:600;color:#fff}
.erp-ls-head h3 span{display:inline-block;margin-left:8px;padding:1px 10px;border-radius:20px;background:#c9b26a;color:#002f37;font-size:13px;font-weight:700;vertical-align:2px}
.erp-ls-head p{margin:3px 0 0;color:#cfdedd;font-size:12.5px}
.erp-ls-x{margin-left:auto;flex:none;width:34px;height:34px;border-radius:8px;border:1px solid rgba(201,178,106,.5);background:transparent;color:#e4d08f;font-size:22px;line-height:1;cursor:pointer}
.erp-ls-x:hover{background:rgba(255,255,255,.08)}
.erp-ls-tools{display:flex;gap:10px;align-items:center;padding:10px 18px;border-bottom:1px solid #e3e7ec;background:#f7f8f6}
.erp-ls-tools input{flex:1;min-width:0;height:36px;border:1px solid #cfd6de;border-radius:8px;padding:0 12px;font:inherit;outline:none;background:#fff}
.erp-ls-tools input:focus{border-color:#c9b26a;box-shadow:0 0 0 3px rgba(201,178,106,.18)}
.erp-ls-tools small{color:#5d6f72;white-space:nowrap}
.erp-ls-body{overflow:auto;flex:1;min-height:120px}
.erp-ls table{width:100%!important;min-width:0!important;max-width:none!important;border-collapse:collapse;margin:0!important;box-shadow:none!important;border:0!important;background:#fff}
.erp-ls th,.erp-ls td{min-width:0!important;width:auto!important;height:auto!important;font-size:13.5px;line-height:1.4;color:#1f2a37}
.erp-ls td::before,.erp-ls th::before{content:none}
.erp-ls th{position:sticky;top:0;z-index:1;background:#f3f5f2;color:#3d5a5f;font-size:11.5px;font-weight:600;text-transform:uppercase;letter-spacing:.5px;text-align:left;padding:9px 12px;border-bottom:1px solid #e3e7ec;white-space:nowrap}
.erp-ls td{padding:9px 12px;border-bottom:1px solid #eef0ee;vertical-align:top}
.erp-ls .d{white-space:nowrap}
.erp-ls .n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.erp-ls tbody tr:hover{background:#f7f1de}
.erp-ls tbody tr.go{cursor:pointer}
.erp-ls tfoot td{position:sticky;bottom:0;background:#e6f0f0;font-weight:700;color:#002f37;border-top:2px solid #c9b26a}
.erp-ls-msg{padding:34px 18px;text-align:center;color:#5d6f72}
.erp-ls-msg.err{color:#a00d25}
.erp-ls-foot{display:flex;gap:10px;justify-content:flex-end;padding:10px 18px;border-top:1px solid #e3e7ec}
.erp-ls-foot button{border-radius:8px;padding:8px 16px;font:600 13px "Fira Sans","Segoe UI",Arial,sans-serif;cursor:pointer;border:1px solid #cfd6de;background:#fff;color:#002f37}
.erp-ls-foot button.main{background:#002f37;border-color:#002f37;color:#fff}
@media (max-width:700px){
  .erp-ls-back{padding:0;place-items:end stretch}
  .erp-ls{max-height:92dvh;border-radius:14px 14px 0 0}
  .erp-ls-head{padding:12px 14px}
  .erp-ls-head h3{font-size:16px}
  .erp-ls-tools,.erp-ls-foot{padding:8px 12px}
  .erp-ls thead{display:none}
  .erp-ls table,.erp-ls tbody,.erp-ls tfoot,.erp-ls tr,.erp-ls td{display:block;width:100%}
  .erp-ls tbody tr{margin:8px 10px;width:auto;border:1px solid #e3e7ec;border-radius:10px;padding:6px 10px;background:#fff}
  .erp-ls td{display:flex!important;justify-content:space-between;gap:12px;border:0!important;padding:3px 0!important;text-align:right!important;white-space:normal!important;overflow-wrap:anywhere}
  .erp-ls td::before{content:attr(data-l)!important;display:block!important;position:static!important;color:#5d6f72;font-size:12px;text-align:left;flex:none;max-width:45%}
  .erp-ls td.first{font-weight:600;color:#002f37}
  .erp-ls tfoot tr{margin:8px 10px 10px;width:auto;border-radius:10px;padding:6px 10px;background:#e6f0f0;border:1px solid #c9b26a}
  .erp-ls tfoot td{position:static;border:0;background:none}
  .erp-ls tfoot td:empty{display:none}
}`;
  function style(){
    if(document.getElementById("erp-list-css"))return;
    const s=document.createElement("style");s.id="erp-list-css";s.textContent=CSS;document.head.appendChild(s);
  }
  const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const num=v=>{const n=Number(String(v==null?"":v).replace(/[₹,\s]/g,""));return Number.isFinite(n)?n:0};
  const fmt=(v,c)=>{
    if(v==null||v==="")return "";
    if(c.money)return "₹"+num(v).toLocaleString("en-IN",{maximumFractionDigits:c.dec==null?0:c.dec});
    if(c.num)return num(v).toLocaleString("en-IN",{maximumFractionDigits:c.dec==null?2:c.dec})+(c.unit?" "+c.unit:"");
    if(c.date){const d=new Date(String(v).length===10?v+"T00:00:00":v);return isNaN(d)?String(v):d.toLocaleDateString("en-IN",{day:"2-digit",month:"short",year:"numeric"})}
    return String(v);
  };
  function cell(c,r){
    try{
      if(c.html)return c.html(r)||"";
      return esc(fmt(typeof c.v==="function"?c.v(r):r[c.v],c));
    }catch(e){return ""}
  }
  function text(c,r){
    try{const v=typeof c.v==="function"?c.v(r):c.v!=null?r[c.v]:"";return String(v==null?"":v)}catch(e){return ""}
  }

  let current=null;
  function close(){
    if(!current)return;
    const {back,key,last}=current;current=null;
    back.classList.remove("show");document.removeEventListener("keydown",key,true);
    setTimeout(()=>back.remove(),160);
    try{last&&last.focus&&last.focus()}catch(e){}
  }

  function open(opts){
    opts=opts||{};style();close();
    const cols=(opts.cols||[]).filter(Boolean);
    const back=document.createElement("div");back.className="erp-ls-back";
    back.innerHTML=`<div class="erp-ls" role="dialog" aria-modal="true">
      <div class="erp-ls-head"><div><h3>${esc(opts.title||"List")}<span>…</span></h3>${opts.sub?`<p>${esc(opts.sub)}</p>`:""}</div>
        <button type="button" class="erp-ls-x" aria-label="Close">&times;</button></div>
      <div class="erp-ls-tools"><input type="search" placeholder="Search in this list..." aria-label="Search in this list"><small></small></div>
      <div class="erp-ls-body"><div class="erp-ls-msg">Loading list...</div></div>
      <div class="erp-ls-foot">${opts.page?`<button type="button" class="pg">${esc(opts.pageText||"Open full page")}</button>`:""}<button type="button" class="main">Close</button></div>
    </div>`;
    const box=back.firstElementChild,body=box.querySelector(".erp-ls-body"),badge=box.querySelector("h3 span"),
      search=box.querySelector("input"),info=box.querySelector(".erp-ls-tools small");
    const last=document.activeElement;
    const key=e=>{if(e.key==="Escape"){e.preventDefault();close()}};
    current={back,key,last};
    document.addEventListener("keydown",key,true);
    back.addEventListener("click",e=>{if(e.target===back)close()});
    box.querySelector(".erp-ls-x").onclick=close;
    box.querySelector(".main").onclick=close;
    const pg=box.querySelector(".pg");
    if(pg)pg.onclick=()=>{close();if(typeof opts.page==="function")opts.page();else location.href=opts.page};
    document.body.appendChild(back);
    requestAnimationFrame(()=>back.classList.add("show"));

    let rows=[];
    function draw(){
      const q=search.value.trim().toLowerCase();
      const list=q?rows.filter(r=>cols.some(c=>text(c,r).toLowerCase().includes(q))):rows;
      badge.textContent=list.length.toLocaleString("en-IN");
      info.textContent=q?`${list.length} of ${rows.length}`:`${rows.length} record${rows.length===1?"":"s"}`;
      if(!list.length){body.innerHTML=`<div class="erp-ls-msg">${esc(q?"No record matches this search.":(opts.empty||"No record in this list."))}</div>`;return}
      const sums=cols.map(c=>c.sum?list.reduce((s,r)=>s+num(typeof c.v==="function"?c.v(r):r[c.v]),0):null);
      const hasSum=sums.some(s=>s!=null);
      const cls=(c,i)=>[(c.num||c.money)?"n":"",c.date?"d":"",i===0?"first":""].filter(Boolean).join(" ");
      body.innerHTML=`<table><thead><tr><th>#</th>${cols.map((c,i)=>`<th class="${cls(c,i)}">${esc(c.t)}</th>`).join("")}</tr></thead>
        <tbody>${list.slice(0,1500).map((r,ri)=>`<tr data-i="${rows.indexOf(r)}"${opts.onRow?' class="go"':""}><td data-l="#">${ri+1}</td>${cols.map((c,i)=>`<td class="${cls(c,i)}" data-l="${esc(c.t)}">${cell(c,r)}</td>`).join("")}</tr>`).join("")}</tbody>
        ${hasSum?`<tfoot><tr><td data-l="">Total</td>${cols.map((c,i)=>`<td class="${cls(c,i)}" data-l="${esc(c.t)}">${sums[i]==null?"":esc(fmt(sums[i],c.money?c:Object.assign({num:true},c)))}</td>`).join("")}</tr></tfoot>`:""}</table>
        ${list.length>1500?`<div class="erp-ls-msg">Showing first 1500 of ${list.length}. Use search to narrow.</div>`:""}`;
    }
    search.oninput=draw;
    body.addEventListener("click",e=>{
      if(!opts.onRow)return;
      const tr=e.target.closest("tbody tr[data-i]");if(!tr||e.target.closest("a,button"))return;
      const r=rows[Number(tr.dataset.i)];close();opts.onRow(r);
    });
    Promise.resolve().then(()=>opts.load?opts.load():opts.rows).then(r=>{
      if(current&&current.back!==back)return;
      rows=Array.isArray(r)?r:[];
      if(opts.sort)rows=rows.slice().sort(opts.sort);
      draw();
      if(window.matchMedia("(min-width:701px)").matches)search.focus();
    }).catch(e=>{
      badge.textContent="!";
      body.innerHTML=`<div class="erp-ls-msg err">List not loaded: ${esc((e&&e.message)||e||"error")}</div>`;
    });
    return {close};
  }

  // Make a card clickable. make() returns the open() options (or a Promise of them).
  function card(el,make,hint,where){
    if(!el)return el;
    style();
    el.classList.add("erp-drill");
    if(!/^(BUTTON|A)$/.test(el.tagName)){el.setAttribute("role","button");if(!el.hasAttribute("tabindex"))el.tabIndex=0}
    if(!el.title)el.title="Click to see the list";
    if(hint!==false&&!el.querySelector(".erp-drill-hint")){
      const h=document.createElement("small");h.className="erp-drill-hint";h.textContent=hint||"View list ›";(where||el).appendChild(h);
    }
    if(el.__erpDrill){el.__erpDrill=make;return el}
    el.__erpDrill=make;
    const go=e=>{
      const inner=e.target.closest("a[href],input,select,textarea,button");if(inner&&inner!==el&&el.contains(inner))return;
      e.preventDefault();e.stopPropagation();
      Promise.resolve(el.__erpDrill(e)).then(o=>{if(o)open(o)});
    };
    el.addEventListener("click",go);
    el.addEventListener("keydown",e=>{if((e.key==="Enter"||e.key===" ")&&e.target===el)go(e)});
    return el;
  }
  // map: {"#id or selector": make}
  function cards(map,hint,where){
    Object.keys(map).forEach(sel=>document.querySelectorAll(sel).forEach(el=>card(el,map[sel],hint,where&&el.querySelector(where))));
  }
  // map: {"idOfTheNumber": make} → the card holding that number becomes clickable.
  const CARD_SEL=".stat,.metric,.kpi,.ps-kpi,.sum-card,.summary-card,.stat-card,.kpi-card,.mini,.count-card,.tile,.box";
  function ids(map,hint){
    Object.keys(map).forEach(id=>{const n=document.getElementById(id);if(!n)return;
      const el=n.closest(CARD_SEL)||n.parentElement;card(el,map[id],hint)});
  }
  // Standard columns for a list of orders (PO).
  const pretty=v=>{const t=String(v||"").trim().replace(/[_-]+/g," ").toLowerCase();return t?t.replace(/\b\w/g,c=>c.toUpperCase()):"Pending"};
  const ORDER_COLS=[{t:"PO No.",v:o=>(o.order_no||"-")+(o.priority&&o.priority!=="NORMAL"?" · "+o.priority:"")},{t:"Date",v:o=>o.order_date||o.created_at,date:true},
    {t:"Party",v:o=>o.customer_name||o.party||""},{t:"Salesman",v:o=>o.sales_person||""},{t:"Cases",v:"total_qty",num:true,sum:true,dec:0},
    {t:"Weight kg",v:"total_weight",num:true,sum:true,dec:0},{t:"Amount",v:"total_amount",money:true,sum:true},{t:"Status",v:o=>pretty(o.status)}];
  function orders(title,sub,rows,more){return Object.assign({title,sub,rows,cols:ORDER_COLS},more||{})}
  window.ERPList={open,close,card,cards,ids,esc,num,pretty,ORDER_COLS,orders};
})();
