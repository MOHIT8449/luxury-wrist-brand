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
.erp-ls-bk{flex:none;height:34px;padding:0 10px;border-radius:8px;border:1px solid rgba(201,178,106,.5);background:transparent;color:#e4d08f;font:600 13px "Fira Sans","Segoe UI",Arial,sans-serif;cursor:pointer;white-space:nowrap}
.erp-ls-bk:hover{background:rgba(255,255,255,.08)}
.erp-ls-trail{margin:0 0 2px;color:#c9b26a;font-size:11.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:100%}
.erp-ls-head>div{min-width:0}
.erp-ls-tt{font-style:normal}
.erp-ls-foot{flex-wrap:nowrap;overflow-x:auto}
.erp-ls-foot button{white-space:nowrap}
.erp-ls td .erp-go{color:#7a6420;font-size:16px;font-weight:700}
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
.erp-ls tbody tr:focus{outline:2px solid #c9b26a;outline-offset:-2px;background:#f7f1de}
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
  .erp-ls td.first{font-weight:600;color:#002f37;grid-column:1/-1}
  .erp-ls tbody tr{display:grid!important;grid-template-columns:minmax(0,1fr) minmax(0,1fr);column-gap:14px;padding:4px 10px}
  .erp-ls tbody td[data-l="#"]{display:none!important}
  .erp-ls tbody td:empty{display:none!important}
  .erp-ls td::before{max-width:55%}
  .erp-ls tfoot tr{margin:8px 10px 10px;width:auto;border-radius:10px;padding:6px 10px;background:#e6f0f0;border:1px solid #c9b26a}
  .erp-ls tfoot td{position:static;border:0;background:none}
  .erp-ls tfoot td:empty{display:none!important}
  .erp-ls td .erp-go{display:none}
  .erp-ls tbody tr.go{border-left:3px solid #c9b26a}
  .erp-ls-head h3 span{margin-left:6px}
  .erp-ls-bk{height:32px;padding:0 8px}
}`;
  function style(){
    if(document.getElementById("erp-list-css"))return;
    const s=document.createElement("style");s.id="erp-list-css";s.textContent=CSS;document.head.appendChild(s);
  }
  const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const num=v=>{const n=Number(String(v==null?"":v).replace(/[₹,\s]/g,""));return Number.isFinite(n)?n:0};
  const fmt=(v,c)=>{
    if(v==null||v==="")return "";
    if(c.money)return (num(v)<0?"−":"")+"₹"+Math.abs(num(v)).toLocaleString("en-IN",{maximumFractionDigits:c.dec==null?0:c.dec});
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

  let current=null,pendingBack=null,pendingTimer=0;
  // A row of one popup opened another popup: remember the first one so "‹ Back" can return to it.
  function markBack(o){pendingBack=o;clearTimeout(pendingTimer);pendingTimer=setTimeout(()=>{pendingBack=null},4000)}
  function close(){
    if(!current)return;
    const {back,key,last}=current;current=null;
    back.classList.remove("show");document.removeEventListener("keydown",key,true);
    setTimeout(()=>back.remove(),160);
    try{last&&last.focus&&last.focus()}catch(e){}
  }

  function open(opts,viaBack){
    opts=opts||{};style();
    if(!viaBack){opts.__parent=pendingBack&&pendingBack.opts!==opts?pendingBack:null}
    pendingBack=null;clearTimeout(pendingTimer);
    const parent=opts.__parent;
    close();
    let cols=(opts.cols||[]).filter(Boolean);
    // Rows with no own action still open their detail: a PO opens its items, a party its bills (LWBDrill below).
    const rowAct=r=>opts.onRow||(opts.drill!==false&&window.LWBDrill&&LWBDrill.can(r)?(x=>LWBDrill.open(x)):null);
    const trail=[];for(let p=parent;p&&trail.length<3;p=p.opts.__parent)trail.unshift(p.opts.title||"List");
    const back=document.createElement("div");back.className="erp-ls-back";
    back.innerHTML=`<div class="erp-ls" role="dialog" aria-modal="true">
      <div class="erp-ls-head">${parent?`<button type="button" class="erp-ls-bk" aria-label="Back to ${esc(parent.opts.title||"list")}">‹ Back</button>`:""}<div>${trail.length?`<p class="erp-ls-trail">${esc(trail.join(" › "))}</p>`:""}<h3><i class="erp-ls-tt">${esc(opts.title||"List")}</i><span>…</span></h3><p class="erp-ls-sub"${opts.sub?"":" hidden"}>${esc(opts.sub||"")}</p></div>
        <button type="button" class="erp-ls-x" aria-label="Close">&times;</button></div>
      <div class="erp-ls-tools"><input type="search" placeholder="Search in this list..." aria-label="Search in this list"><small></small></div>
      <div class="erp-ls-body"><div class="erp-ls-msg">Loading list...</div></div>
      <div class="erp-ls-foot">${(opts.links||[]).map((l,i)=>`<button type="button" data-lk="${i}">${esc(l.t)}</button>`).join("")}${opts.page?`<button type="button" class="pg">${esc(opts.pageText||"Open full page")}</button>`:""}<button type="button" class="main">Close</button></div>
    </div>`;
    const box=back.firstElementChild,body=box.querySelector(".erp-ls-body"),badge=box.querySelector("h3 span"),
      search=box.querySelector("input"),info=box.querySelector(".erp-ls-tools small");
    const last=document.activeElement;
    const goBack=()=>{if(parent){const p=parent;open(p.opts,true);if(current&&p.q){const s=current.back.querySelector(".erp-ls-tools input");s.value=p.q;s.dispatchEvent(new Event("input"))}}};
    // Esc = one step back when this popup came from another one, else close.
    const key=e=>{if(e.key==="Escape"){e.preventDefault();e.stopPropagation();if(parent)goBack();else close()}};
    current={back,key,last:parent?parent.last:last};
    const bk=box.querySelector(".erp-ls-bk");if(bk)bk.onclick=goBack;
    box.querySelectorAll("[data-lk]").forEach(b=>b.onclick=()=>{const l=opts.links[Number(b.dataset.lk)];if(!l)return;
      if(l.keep){markBack({opts,q:search.value,last:current&&current.last});l.go()}else{close();if(l.go)l.go();else location.href=l.href}});
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
        <tbody>${list.slice(0,1500).map((r,ri)=>`<tr data-i="${rows.indexOf(r)}"${rowAct(r)?' class="go" tabindex="0" title="Open details"':""}><td data-l="#">${ri+1}</td>${cols.map((c,i)=>`<td class="${cls(c,i)}" data-l="${esc(c.t)}">${cell(c,r)}${i===cols.length-1&&rowAct(r)?' <span class="erp-go" aria-hidden="true">›</span>':""}</td>`).join("")}</tr>`).join("")}</tbody>
        ${hasSum?`<tfoot><tr><td data-l="">Total</td>${cols.map((c,i)=>`<td class="${cls(c,i)}" data-l="${esc(c.t)}">${sums[i]==null?"":esc(fmt(sums[i],c.money?c:Object.assign({num:true},c)))}</td>`).join("")}</tr></tfoot>`:""}</table>
        ${list.length>1500?`<div class="erp-ls-msg">Showing first 1500 of ${list.length}. Use search to narrow.</div>`:""}`;
    }
    search.oninput=draw;
    const act=r=>{const f=rowAct(r);if(!f)return false;markBack({opts,q:search.value,last:current&&current.last});f(r);if(pendingBack){pendingBack=null;close()}return true};
    // Keyboard: ↓ from search goes to the rows, ↑ / ↓ move between rows, Enter opens a row (Mohit: work by keyboard).
    const trs=()=>[...body.querySelectorAll("tbody tr[data-i]")];
    search.addEventListener("keydown",e=>{
      if(e.key==="ArrowDown"){const t=trs()[0];if(t){e.preventDefault();if(!t.hasAttribute("tabindex"))t.tabIndex=-1;t.focus()}}
      else if(e.key==="Enter"){const t=trs();if(t.length===1&&rowAct(rows[Number(t[0].dataset.i)])){e.preventDefault();act(rows[Number(t[0].dataset.i)])}}
    });
    body.addEventListener("keydown",e=>{
      const tr=e.target.closest&&e.target.closest("tbody tr[data-i]");if(!tr)return;
      if(e.key==="ArrowDown"||e.key==="ArrowUp"){e.preventDefault();const t=trs(),i=t.indexOf(tr)+(e.key==="ArrowDown"?1:-1);
        if(i<0){search.focus();return}const n=t[i];if(n){if(!n.hasAttribute("tabindex"))n.tabIndex=-1;n.focus()}}
      else if(e.key==="Enter"){const r=rows[Number(tr.dataset.i)];if(rowAct(r)){e.preventDefault();act(r)}}
    });
    body.addEventListener("click",e=>{
      const tr=e.target.closest("tbody tr[data-i]");if(!tr||e.target.closest("a,button"))return;
      act(rows[Number(tr.dataset.i)]);
    });
    const ui={title:t=>{box.querySelector(".erp-ls-tt").textContent=t||""},sub:t=>{const p=box.querySelector(".erp-ls-sub");p.textContent=t||"";p.hidden=!t}};
    Promise.resolve().then(()=>opts.load?opts.load(ui):opts.rows).then(r=>{
      if(current&&current.back!==back)return;
      rows=Array.isArray(r)?r:[];cols=(opts.cols||[]).filter(Boolean);
      if(opts.sort)rows=rows.slice().sort(opts.sort);
      draw();
      if(window.matchMedia("(min-width:701px)").matches)search.focus();
      else if(parent)box.querySelector(".erp-ls-bk").focus({preventScroll:true});
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

/* LUXURY WRIST BRAND ERP — drill down to the detail behind any row (Mohit, 5 Nov 2026):
   "Outstanding → party list → tap a party → its bills → tap a bill → what is in that bill".
   LWBDrill.order(row | orderId)  : PO / bill popup with its SKU lines (qty, rate, amount).
   LWBDrill.party(row | name)     : the party's bills due (tap a bill = its items); no bill due = recent POs.
   LWBDrill.can(row) / open(row)  : used by ERPList for rows that have no own action.
   Every popup has "‹ Back" to the list it came from (Esc too). Read only. */
(function(){
  if(window.LWBDrill||!window.ERPList)return;
  const URL_="https://txkbhadzdbxpieunfvox.supabase.co",KEY_="sb_publishable_W4I3Q5ODf0g17sq5uDml2Q_sLolXYEk";
  const db=()=>window.__lwbBellClient||(window.supabase&&(window.__lwbBellClient=window.supabase.createClient(URL_,KEY_)));
  const key=v=>String(v==null?"":v).toUpperCase().replace(/[^A-Z0-9]+/g," ").trim();
  const n=v=>{const x=Number(v);return Number.isFinite(x)?x:0};
  const rs=v=>(n(v)<0?"−":"")+"₹"+Math.abs(Math.round(n(v))).toLocaleString("en-IN");
  const dmy=d=>d?String(d).slice(8,10)+"/"+String(d).slice(5,7)+"/"+String(d).slice(0,4):"";
  const days=d=>{if(!d)return "";const t=new Date(String(d).slice(0,10)+"T00:00:00+05:30");return isNaN(t)?"":Math.max(0,Math.floor((Date.now()-t)/864e5))};
  const isObj=r=>r&&typeof r==="object";
  const orderId=r=>isObj(r)?(r.order_id||(r.order_no&&r.id&&!r.sku_name?r.id:null)):null;
  const partyName=r=>{if(!isObj(r))return "";const v=r.party||r.customer_name||r.party_name||r.main_party;return typeof v==="string"&&v.trim()?v.trim():""};
  const can=r=>isObj(r)&&r.__drill!==false&&!!(orderId(r)||partyName(r));
  const qtyOf=i=>n(i.loaded_qty)>0?n(i.loaded_qty):i.approved_qty!=null&&i.approved_qty!==""?n(i.approved_qty):n(i.ordered_qty);
  const pretty=ERPList.pretty;
  const poT=no=>/^PO\b/i.test(String(no||""))?String(no):"PO "+(no||"");
  let payLoading=null,billInfo=null;
  function payJs(){
    if(window.LWBPartyPay)return Promise.resolve(window.LWBPartyPay);
    return payLoading||(payLoading=new Promise((ok,bad)=>{const s=document.createElement("script");s.src="party-pay.js";s.onload=()=>ok(window.LWBPartyPay);s.onerror=()=>{payLoading=null;bad(Error("party-pay.js not loaded"))};document.head.appendChild(s)}));
  }
  // Bills of every party, once per page open (Billing & Outstanding data; refused for logins without it).
  async function bills(){
    if(billInfo&&Date.now()-billInfo.at<120e3)return billInfo.v;
    const P=await payJs(),v=await P.load(db());billInfo={at:Date.now(),v};return v;
  }

  /* ---------- one PO / bill ---------- */
  function order(x){
    const row=isObj(x)?x:{},id=isObj(x)?orderId(x):x;
    let o=null;
    const head=()=>{const r=Object.assign({},o||{},row);
      return [dmy(r.order_date||r.created_at),r.customer_name||r.party,r.status?pretty(r.status):"",
        r.invoice_no?"Bill "+r.invoice_no+(r.bill_amount!=null?" · "+rs(r.bill_amount):""):"",
        r.due!=null&&n(r.due)>0.5?"Due "+rs(r.due):""].filter(Boolean).join(" · ")};
    ERPList.open({
      title:poT(row.order_no),sub:head()||"Loading...",drill:false,
      empty:"No SKU line in this PO.",
      load:async ui=>{
        const C=db();if(!C)throw Error("Not connected");
        let q=id?await C.from("orders").select("*").eq("id",id).maybeSingle():{data:null};
        if((!q.data||q.error)&&row.order_no)q=await C.from("orders").select("*").eq("order_no",row.order_no).limit(1).maybeSingle();
        if(q.error)throw q.error;o=q.data;
        if(!o)throw Error("This PO is not open for your login.");
        ui.title(poT(o.order_no||row.order_no));ui.sub(head());
        const it=await C.from("order_items").select("*").eq("order_id",o.id);
        if(it.error)throw it.error;
        return (it.data||[]).map(i=>Object.assign({},i,{__q:qtyOf(i),__amt:qtyOf(i)*n(i.rate)}));
      },
      cols:[{t:"SKU",v:i=>i.sku_name||i.sku||""},{t:"Ordered",v:"ordered_qty",num:true,sum:true,dec:0},
        {t:"Approved",v:"approved_qty",num:true,sum:true,dec:0},{t:"Loaded",v:"loaded_qty",num:true,sum:true,dec:0},
        {t:"Rate",v:"rate",money:true,dec:2},{t:"Amount",v:"__amt",money:true,sum:true}],
      links:[{t:"Bill details",go:()=>{location.href="accounts-invoice.html?order="+encodeURIComponent((o&&o.id)||id)}}].filter(()=>!!(row.invoice_no||row.bill_amount!=null||row.__bill)),
      page:()=>{location.href="warehouse-orders.html?order="+encodeURIComponent((o&&o.id)||id)},pageText:"Open PO →"
    });
  }

  /* ---------- one party ---------- */
  const BILL_COLS=[{t:"PO",v:"order_no"},{t:"Bill date",v:"invoice_date",date:true},
    {t:"Bill no.",v:b=>(b.bills||[]).length?(b.bills||[]).map(x=>x.no).join(", "):b.invoice_no||""},
    {t:"Days",v:b=>days(b.invoice_date),num:true,dec:0},{t:"Bill",v:"bill_amount",money:true,sum:true},
    {t:"Credit note",v:"credit_notes",money:true,sum:true},{t:"Received",v:b=>n(b.driver)+n(b.office),money:true,sum:true},
    {t:"Due",v:"due",money:true,sum:true}];
  function party(x){
    const name=isObj(x)?partyName(x):String(x||"").trim();
    const given=isObj(x)&&Array.isArray(x.bills)&&x.bills.every(b=>isObj(b)&&("due" in b||"order_id" in b))?x.bills:null;
    const opts={title:name||"Party",sub:"Bills due · tap a bill to see what is in it",empty:"No bill due and no recent PO for this party.",
      load:async ui=>{
        let list=given,p=isObj(x)?x:null;
        if(!list){
          try{const info=await bills(),k=key(info.parentOf(name));p=info.parties.get(k)||null;list=p?p.bills:[]}
          catch(e){list=null}
        }
        if(list&&list.length){
          opts.cols=BILL_COLS;
          if(p&&p.net!=null)ui.sub((p.net>0.5?"To collect "+rs(p.net):p.net<-0.5?"Advance "+rs(-p.net):"Settled")+" · "+list.length+" bill"+(list.length===1?"":"s")+" due"+(n(p.opening)?" · opening "+rs(p.opening):"")+" · tap a bill");
          return list.map(b=>Object.assign({},b,{order_id:b.order_id}));
        }
        // No bill due (or no Billing access): the party's recent POs.
        opts.cols=ERPList.ORDER_COLS;
        const C=db();if(!C)return [];
        const r=await C.from("orders").select("id,order_no,order_date,created_at,customer_name,sales_person,status,priority,total_qty,total_weight,total_amount").ilike("customer_name",name).order("created_at",{ascending:false}).limit(100);
        if(r.error)throw r.error;
        ui.sub((list?"No bill due. ":"")+"Recent POs of this party · tap a PO to see its items");
        return r.data||[];
      },
      cols:BILL_COLS,onRow:r=>order(r),
      links:[{t:"Ledger →",go:()=>{location.href="party-ledger.html?party="+encodeURIComponent(name)}}]};
    ERPList.open(opts);
  }
  function open(r){if(orderId(r))return order(r);const p=partyName(r);if(p)return party(r)}
  // Rows on a page: data-drill-order="<order id>" (data-drill-no="<PO no>") or data-drill-party="<name>".
  const DCSS=`[data-drill-order],[data-drill-party]{cursor:pointer}
tr[data-drill-order]:hover,tr[data-drill-party]:hover{background:#f7f1de}
[data-drill-order]:focus-visible,[data-drill-party]:focus-visible{outline:2px solid #c9b26a;outline-offset:-2px}`;
  function dcss(){if(document.getElementById("erp-drill-css"))return;const s=document.createElement("style");s.id="erp-drill-css";s.textContent=DCSS;document.head.appendChild(s)}
  if(document.head)dcss();else document.addEventListener("DOMContentLoaded",dcss);
  const hit=e=>{const t=e.target;if(!t.closest)return null;const el=t.closest("[data-drill-order],[data-drill-party]");if(!el)return null;
    const inner=t.closest("a[href],button,input,select,textarea,label,[onclick]");if(inner&&inner!==el&&el.contains(inner))return null;return el};
  const go=el=>{if(el.hasAttribute("data-drill-order"))order({order_id:el.dataset.drillOrder,order_no:el.dataset.drillNo||"",__bill:!!el.dataset.drillBill});else party(el.dataset.drillParty)};
  document.addEventListener("click",e=>{const el=hit(e);if(!el)return;e.preventDefault();e.stopPropagation();go(el)},true);
  document.addEventListener("keydown",e=>{if(e.key!=="Enter"||e.defaultPrevented)return;const el=hit(e);if(!el||e.target!==el)return;e.preventDefault();e.stopPropagation();go(el)},true);
  // Make them reachable by Tab.
  new MutationObserver(()=>document.querySelectorAll("[data-drill-order]:not([tabindex]),[data-drill-party]:not([tabindex])").forEach(x=>{x.tabIndex=0;if(!x.title)x.title="Tap to see details"})).observe(document.documentElement,{childList:true,subtree:true});
  window.LWBDrill={can,open,order,party};
})();
