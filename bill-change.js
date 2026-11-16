/* LUXURY WRIST BRAND ERP — PO item changes through Admin (lwb_bill_change_setup.sql)
 * LWBBillChange.open({client, order:{order_id, order_no, party}, admin, onSaved})
 *   Items popup: qty + / −, rate, replace SKU, add / remove SKU, history of earlier changes.
 *   Accounts -> "Send to Admin" (WAITING); Admin -> "Save change" (applied at once).
 * LWBBillChange.review({client, change, admin, onDone})
 *   Old value / new value / difference + every changed line; Admin: Approve / Send back.
 * LWBBillChange.ret({client, order:{order_id}|null, party, parties, onSaved})   (lwb_party_return_setup.sql)
 *   Goods return in CS + PCS: lines of the bill (PO rate) + any other SKU; no order = New return of a party.
 */
(function(){
 'use strict';
 const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
 const rs=n=>"₹"+(Math.round((Number(n)||0)*100)/100).toLocaleString("en-IN",{maximumFractionDigits:2});
 const sg=n=>(n>0.004?"+":n<-0.004?"−":"")+rs(Math.abs(n));
 const r2=n=>Math.round((Number(n)||0)*100)/100;
 const dmy=v=>{const d=String(v||"").slice(0,10).split("-");return d.length===3?d[2]+"/"+d[1]+"/"+d[0]:""};
 const errText=e=>String((e&&(e.message||e.details))||e||"Error").replace(/^STALE: /,"");
 // Loading-time words: the bill is made when the vehicle is loaded, before the goods reach the party (Mohit, 16 Nov 2026)
 const REASONS=["Less qty loaded","Extra qty loaded","Wrong item loaded","Item not on PO but loaded","Qty change before loading","Rate change","Other"];
 const KIND={QTY:"Qty",RATE:"Rate",SKU:"SKU replaced",ADD:"Added",REMOVE:"Removed"};
 const ST={WAITING:["bc-amb","Waiting Admin"],APPROVED:["bc-grn","Approved"],SENT_BACK:["bc-red","Sent back"]};

 const css=`.bc-back{position:fixed;inset:0;z-index:1000;background:rgba(15,23,42,.45);display:flex;align-items:flex-start;justify-content:center;padding:24px 12px;overflow:auto}
 .bc-box{background:#fff;border-radius:12px;width:100%;max-width:860px;padding:12px 14px;box-shadow:0 12px 32px rgba(0,47,55,.25);font-size:14px;color:var(--erp-ink,#10262b)}
 .bc-box.sm{max-width:640px}
 .bc-hd{display:flex;gap:8px;align-items:flex-start;justify-content:space-between;margin:0 0 6px}
 .bc-hd h3{margin:0;font-size:16px}.bc-hd small{display:block;color:var(--erp-muted,#55686c);font-size:12.5px;font-weight:400}
 .bc-x{border:0;background:#f1f3f2;border-radius:8px;width:32px;height:32px;font-size:18px;cursor:pointer;flex:none}
 .bc-t{width:100%;border-collapse:collapse}.bc-t th,.bc-t td{padding:5px 6px;border-bottom:1px solid var(--erp-line,#e3e6e2);text-align:left;vertical-align:middle}
 .bc-t th{font-size:12px;color:var(--erp-muted,#55686c);background:#fafaf8;font-weight:700}.bc-t .n{text-align:right;white-space:nowrap}
 .bc-t td small{display:block;color:var(--erp-muted,#55686c);font-size:11.5px}
 .bc-t tr.rm td{opacity:.5}.bc-t tr.rm .bc-sku{text-decoration:line-through}
 .bc-t tr.ch td{background:#fffbea}
 .bc-step{display:inline-flex;border:1px solid #cfd6d4;border-radius:8px;overflow:hidden;height:32px}
 .bc-step button{width:28px;border:0;background:#f1f3f2;font-size:16px;cursor:pointer}.bc-step input{width:46px;border:0;text-align:center;font:inherit;font-weight:700}
 .bc-in{height:32px;border:1px solid #cfd6d4;border-radius:8px;padding:0 8px;font:inherit;min-width:0;box-sizing:border-box}
 .bc-rate{width:78px;text-align:right}.bc-sk{width:100%}
 .bc-ic{border:1px solid #cfd6d4;background:#fff;border-radius:8px;height:30px;min-width:30px;cursor:pointer;font-size:13px;padding:0 6px}
 .bc-ic.r{color:#b3122b}
 .bc-pos{color:#13824a;font-weight:700}.bc-neg{color:#b3122b;font-weight:700}
 .bc-tag{display:inline-block;border-radius:99px;padding:1px 8px;font-size:11.5px;font-weight:700;white-space:nowrap}
 .bc-amb{background:#fdf0dc;color:#9a5b00}.bc-grn{background:#e3f5ec;color:#13824a}.bc-red{background:#fdecef;color:#b3122b}.bc-blu{background:#e6efff;color:#1d5fbf}
 .bc-row{display:flex;gap:6px;align-items:center;flex-wrap:wrap;margin-top:8px}.bc-row .sp{margin-left:auto}
 .bc-btn{height:36px;border-radius:8px;padding:0 14px;font:inherit;font-weight:700;cursor:pointer;border:1px solid #cfd6d4;background:#fff;white-space:nowrap}
 .bc-btn.pri{background:#00434d;border-color:#00434d;color:#fff}.bc-btn.ok{background:#13824a;border-color:#13824a;color:#fff}.bc-btn.bad{color:#b3122b;border-color:#f0b9b9}
 .bc-btn:disabled{opacity:.55;cursor:default}
 .bc-lnk{border:0;background:none;color:#00434d;font:inherit;font-weight:600;cursor:pointer;padding:0}
 .bc-sum{font-weight:700}
 .bc-diff{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:6px;margin:6px 0 8px}
 .bc-diff div{border-radius:8px;padding:6px 8px;background:#f4f6f5;font-size:12.5px}.bc-diff b{display:block;font-size:17px}
 .bc-diff .pos{background:#e3f5ec;color:#13824a}.bc-diff .neg{background:#fdecef;color:#b3122b}
 .bc-ban{background:#fdf0dc;color:#7a4700;border-radius:8px;padding:6px 10px;margin:0 0 8px;display:flex;gap:8px;align-items:center;flex-wrap:wrap}
 .bc-hist{margin-top:8px;font-size:13px}.bc-hist summary{cursor:pointer;font-weight:700;color:#33404d}
 .bc-hist .h{border-top:1px solid var(--erp-line,#e3e6e2);padding:5px 0;display:flex;gap:6px;flex-wrap:wrap;align-items:center}
 .bc-note{color:var(--erp-muted,#55686c);font-size:12.5px;margin-top:6px}
 .bc-stk{display:flex;gap:4px 6px;flex-wrap:wrap;align-items:center;margin-top:6px;font-size:12.5px}.bc-stk small{color:var(--erp-muted,#55686c);width:100%}
 del{color:#8a969a}ins{text-decoration:none;font-weight:700}
 .bc-pcs{width:46px;text-align:center}.bc-pcs:disabled{background:#f4f6f5}
 .bc-t.rt td{white-space:nowrap}.bc-t.rt td.it{white-space:normal}
 .bc-pty{width:100%;margin:0 0 6px}
 @media(max-width:600px){.bc-back{padding:8px}.bc-box{padding:10px}
  .bc-t.rt thead{display:none}.bc-t.rt tr{display:grid;grid-template-columns:auto auto minmax(0,1fr) auto auto;gap:4px 6px;align-items:center;border-bottom:1px solid var(--erp-line,#e3e6e2);padding:6px 0}
  .bc-t.rt td{border:0;padding:0}.bc-t.rt td.it{grid-column:1 / -1}.bc-t.rt td.am{text-align:right}.bc-t.rt td.rr{text-align:left}
  .bc-t.rt tr.ch td{background:none}.bc-t.rt tr.ch{background:#fffbea}.bc-t.rt td:last-child:empty{display:none}.bc-t.rt .bc-step input{width:38px}.bc-t.rt .bc-rate{width:64px}
  .bc-row.ra{display:grid;grid-template-columns:auto minmax(0,1fr)}.bc-row.ra .bc-btn{grid-column:1 / -1}
  .bc-t.ed thead{display:none}.bc-t.ed tr{display:grid;grid-template-columns:auto auto 1fr auto;gap:4px 6px;align-items:center;border-bottom:1px solid var(--erp-line,#e3e6e2);padding:6px 0}
  .bc-t.ed td{border:0;padding:0}.bc-t.ed td.it{grid-column:1 / -1}.bc-t.ed td.am{text-align:right}
  .bc-diff b{font-size:14px}.bc-row .sp{margin-left:0;width:100%}
  .bc-t.ed tr.ch td{background:none}.bc-t.ed tr.ch{background:#fffbea}
  .bc-row.act{display:grid;grid-template-columns:1fr 1fr}.bc-row.act input{grid-column:1 / -1}}`;
 function style(){if(document.getElementById("bc-css"))return;const s=document.createElement("style");s.id="bc-css";s.textContent=css;document.head.appendChild(s)}
 function shell(html,small){style();const b=document.createElement("div");b.className="bc-back";b.innerHTML=`<div class="bc-box${small?" sm":""}" role="dialog" aria-modal="true">${html}</div>`;
  document.body.appendChild(b);const close=()=>b.remove();b.querySelector(".bc-x").onclick=close;
  b.addEventListener("click",e=>{if(e.target===b)close()});b.addEventListener("keydown",e=>{if(e.key==="Escape"){e.stopPropagation();close()}});return {b,close}}
 const say=(t)=>window.ERPShell&&ERPShell.alert?ERPShell.alert(t):alert(t);
 const ask=(t)=>window.ERPShell&&ERPShell.confirm?ERPShell.confirm(t):Promise.resolve(confirm(t));
 const toast=t=>window.ERPShell&&ERPShell.toast?ERPShell.toast(t):0;
 // Clear "OK" popup after a send / approve (the old toast was missed by users).
 const done=(title,t)=>{return window.ERPShell&&ERPShell.alert?ERPShell.alert(t,{kind:"info",title:"✓ "+title}):alert(title+"\n\n"+t)};
 // Godown stock a change moves after loading: + = back to godown, − = more went to the party.
 function stockMoves(lines){const m=new Map(),add=(k,q)=>{if(!k)return;const u=k.trim().toUpperCase();const x=m.get(u)||{sku:k.trim(),c:0};x.c+=q;m.set(u,x)};
  for(const l of lines||[]){add(l.sku_old,Number(l.qty_old)||0);add(l.sku,-(Number(l.qty)||0))}
  return [...m.values()].filter(x=>Math.abs(x.c)>0.0001)}
 const stockText=lines=>stockMoves(lines).map(x=>`${x.sku} ${x.c>0?"+":"−"}${Math.abs(x.c)} CS`).join(", ");

 function lineText(l){
  const k=l.kind||[];
  if(k.includes("ADD"))return `<b>${esc(l.sku)}</b> <span class="bc-tag bc-blu">Added</span>`;
  if(k.includes("REMOVE")&&!k.includes("SKU"))return `<del>${esc(l.sku_old)}</del> <span class="bc-tag bc-red">Removed</span>`;
  return (k.includes("SKU")?`<del>${esc(l.sku_old)}</del> → <ins>${esc(l.sku)}</ins> <span class="bc-tag bc-amb">SKU replaced</span>`:esc(l.sku))+
   k.filter(x=>x!=="SKU").map(x=>` <span class="bc-tag bc-blu">${KIND[x]}</span>`).join("");
 }
 const qtyText=l=>Number(l.qty_old)!==Number(l.qty)?`<del>${Number(l.qty_old)}</del> <ins>${Number(l.qty)}</ins>`:String(Number(l.qty));
 const rateText=l=>l.rate_old!=null&&Number(l.rate_old)!==Number(l.rate)?`<del>${Number(l.rate_old)}</del> <ins>${Number(l.rate)}</ins>`:String(Number(l.rate));

 /* ---------- Items / Edit ---------- */
 async function open(o){
  const {client,order,admin}=o;
  const {data:d,error}=await client.rpc("lwb_bill_change_items",{p_order_id:order.order_id});
  if(error)return say(/lwb_bill_change_items|schema cache/i.test(error.message)?"Run lwb_bill_change_setup.sql first (merge the update).":errText(error));
  const loaded=d.qty_col==="loaded_qty";
  const rows=d.items.map(i=>({id:i.item_id,sku0:i.sku_name,sku:i.sku_name,q0:Number(i.qty),q:Number(i.qty),r0:Number(i.rate),r:Number(i.rate),h:i,swap:false}));
  const wait=(d.changes||[]).find(c=>c.status==="WAITING");
  const bills=(d.bill&&d.bill.bills)||[];
  const {b,close}=shell(`<div class="bc-hd"><div><h3>${esc(d.order_no)} · ${esc(d.party)}</h3><small>${loaded?"Loaded qty (on the vehicle)":"Approved qty (not loaded yet)"} · rate per case${d.bill&&d.bill.invoice_no?" · Tally bill "+esc(d.bill.invoice_no)+" "+rs(d.bill.amount):""}</small></div><button type="button" class="bc-x" aria-label="Close">✕</button></div>
   ${wait?`<div class="bc-ban">⏳ A change of <b>${sg(wait.diff)}</b> by ${esc(wait.by||"")} is waiting for Admin.<button type="button" class="bc-lnk" data-wv>View</button>${admin?"":"<small>Sending again replaces it.</small>"}</div>`:""}
   <datalist id="bc-skus">${(d.skus||[]).map(s=>`<option value="${esc(s)}">`).join("")}</datalist>
   <div style="overflow:auto"><table class="bc-t ed"><thead><tr><th>Item</th><th>Qty (CS)</th><th class="n">Rate</th><th class="n">Amount</th><th></th></tr></thead><tbody></tbody></table></div>
   <div class="bc-row"><button type="button" class="bc-lnk" data-add>+ Add SKU</button>${loaded?`<button type="button" class="bc-lnk" data-ret title="Goods came back from the party (cases and pieces)">↩ Return goods</button>`:""}<span class="sp bc-sum" data-sum></span></div>
   ${loaded?`<div class="bc-stk" data-stk hidden></div>`:""}
   <div class="bc-row"><select class="bc-in" data-reason style="flex:1 1 170px"><option value="">Reason…</option>${REASONS.map(r=>`<option>${r}</option>`).join("")}</select>
    <input class="bc-in" data-note maxlength="500" placeholder="Note for Admin" style="flex:2 1 200px">
    ${bills.length>1?`<select class="bc-in" data-bill title="Bill that takes the difference" style="flex:1 1 150px">${bills.map(x=>`<option value="${esc(x.no)}">Bill ${esc(x.no)} · ${esc(x.firm||"")}</option>`).join("")}</select>`:""}
    <button type="button" class="bc-btn pri" data-send>${admin?"Save change":"Send to Admin"}</button></div>
   <div class="bc-note">${loaded?"Fewer cases loaded on the vehicle? Press − here and choose “Less qty loaded” (no Return needed): on approve the bill goes down and those cases stay in godown stock. ":""}${admin?"Your change is saved at once.":"Nothing changes until Admin or Sales Head approves."} ${d.bill&&d.bill.amount?"After approval the Tally bill amount moves by the same difference, so To collect follows.":"The bill amount to make follows the new value."}</div>
   ${(d.changes||[]).length?`<details class="bc-hist"><summary>History (${d.changes.length})</summary>${d.changes.map(c=>`<div class="h"><span class="bc-tag ${(ST[c.status]||[])[0]||""}">${(ST[c.status]||[])[1]||c.status}</span> ${dmy(c.requested_at)} · ${esc(c.by||"")} · ${rs(c.old_value)} → ${rs(c.new_value)} <b class="${c.diff>=0?"bc-pos":"bc-neg"}">${sg(c.diff)}</b>${c.reason?" · "+esc(c.reason):""}${c.reply?` · Admin: ${esc(c.reply)}`:""} <button type="button" class="bc-lnk" data-hv="${esc(c.id)}">View</button></div>`).join("")}</details>`:""}`);
  const tb=b.querySelector("tbody"),sum=b.querySelector("[data-sum]");
  const oldV=rows.reduce((a,x)=>a+x.q0*x.r0,0);
  function draw(){
   tb.innerHTML=rows.map((x,i)=>{const ch=x.id&&(x.q!==x.q0||x.r!==x.r0||x.sku.toUpperCase()!==x.sku0.toUpperCase()),rm=x.q===0,dv=x.q*x.r-(x.id?x.q0*x.r0:0);
    const sh=x.id&&x.h.loaded!=null?Number(x.h.approved)-Number(x.h.loaded):0;
    const hist=x.id?`PO ${Number(x.h.ordered)} · OK ${Number(x.h.approved)}${x.h.loaded!=null?" · Loaded "+Number(x.h.loaded):""}${sh>0?` <span class="bc-tag bc-red">Short at loading ${sh} CS</span>`:""}`:"new";
    return `<tr data-i="${i}" class="${rm?"rm":ch||!x.id?"ch":""}"><td class="it">${x.swap||!x.id?`<input class="bc-in bc-sk" list="bc-skus" value="${esc(x.sku)}" placeholder="Type SKU" aria-label="SKU">${x.id?`<small>was ${esc(x.sku0)}</small>`:""}`:`<span class="bc-sku">${esc(x.sku)}</span><small>${hist}</small>`}</td>
     <td><span class="bc-step"><button type="button" data-m aria-label="Less">−</button><input inputmode="numeric" value="${x.q}" aria-label="Qty"><button type="button" data-p aria-label="More">+</button></span></td>
     <td class="n"><input class="bc-in bc-rate" inputmode="decimal" value="${x.r||""}" placeholder="Rate" aria-label="Rate"></td>
     <td class="n am">${rs(x.q*x.r)}${Math.abs(dv)>0.004?`<small class="${dv>0?"bc-pos":"bc-neg"}">${sg(dv)}</small>`:""}</td>
     <td class="n">${x.id?`<button type="button" class="bc-ic" data-sw title="Replace SKU">⇄</button> `:""}<button type="button" class="bc-ic r" data-rm title="${rm&&x.id?"Undo":"Remove"}">${rm&&x.id?"↺":"✕"}</button></td></tr>`}).join("");
   tb.querySelectorAll("tr").forEach(tr=>{const x=rows[tr.dataset.i],qi=tr.querySelector(".bc-step input"),ri=tr.querySelector(".bc-rate"),si=tr.querySelector(".bc-sk");
    tr.querySelector("[data-m]").onclick=()=>{x.q=Math.max(0,x.q-1);draw()};tr.querySelector("[data-p]").onclick=()=>{x.q++;draw()};
    qi.onchange=()=>{x.q=Math.max(0,parseInt(qi.value,10)||0);draw()};ri.onchange=()=>{x.r=r2(String(ri.value).replace(/[,₹\s]/g,""));draw()};
    if(si)si.onchange=()=>{x.sku=si.value.trim();draw()};
    const sw=tr.querySelector("[data-sw]");if(sw)sw.onclick=()=>{x.swap=!x.swap;if(!x.swap)x.sku=x.sku0;draw();if(x.swap)tb.querySelector(`tr[data-i="${tr.dataset.i}"] .bc-sk`).select()};
    tr.querySelector("[data-rm]").onclick=()=>{if(!x.id){rows.splice(rows.indexOf(x),1)}else x.q=x.q===0?x.q0:0;draw()}});
   const nv=rows.reduce((a,x)=>a+x.q*x.r,0),df=r2(nv-oldV);
   const stk=b.querySelector("[data-stk]");
   if(stk){const m=stockMoves(rows.filter(x=>x.id||x.q>0).map(x=>({sku_old:x.id?x.sku0:null,qty_old:x.id?x.q0:0,sku:x.sku,qty:x.q})));
    stk.hidden=!m.length;stk.innerHTML=`<b>${admin?"Godown stock":"On approve, godown stock"}</b>`+m.map(x=>`<span class="bc-tag ${x.c>0?"bc-grn":"bc-red"}">${esc(x.sku)} ${x.c>0?"+":"−"}${Math.abs(x.c)} CS</span>`).join("")}
   sum.innerHTML=`Old ${rs(oldV)} → New ${rs(nv)} <span class="bc-tag ${df>0.004?"bc-grn":df<-0.004?"bc-red":"bc-amb"}">${Math.abs(df)>0.004?sg(df):"no change"}</span>`;
  }
  draw();
  b.querySelector("[data-add]").onclick=()=>{rows.push({id:null,sku0:"",sku:"",q0:0,q:1,r0:0,r:0,h:null,swap:true});draw();const s=tb.querySelectorAll(".bc-sk");s[s.length-1].focus()};
  const rb=b.querySelector("[data-ret]");if(rb)rb.onclick=()=>{close();ret({client,order:{order_id:d.order_id},onSaved:o.onSaved})};
  const wv=b.querySelector("[data-wv]");if(wv)wv.onclick=()=>review({client,admin,change:{...wait,order_no:d.order_no,party:d.party},onDone:()=>{close();o.onSaved&&o.onSaved()}});
  b.querySelectorAll("[data-hv]").forEach(x=>x.onclick=()=>{const c=d.changes.find(y=>y.id===x.dataset.hv);review({client,admin,change:{...c,order_no:d.order_no,party:d.party},onDone:()=>{close();o.onSaved&&o.onSaved()}})});
  b.querySelector("[data-send]").onclick=async e=>{
   const btn=e.currentTarget;  // e.currentTarget is null after an await: keep the button first
   if(btn.disabled)return;
   const items=rows.filter(x=>x.id||x.q>0).map(x=>({item_id:x.id||null,sku_name:x.sku.trim(),qty:x.q,rate:x.r}));
   if(items.some(x=>!x.sku_name))return say("Type the SKU of every new line.");
   if(items.some(x=>x.qty>0&&!(x.rate>0)))return say("Enter the rate of every line.");
   const nv=rows.reduce((a,x)=>a+x.q*x.r,0),df=r2(nv-oldV);
   const reason=b.querySelector("[data-reason]").value,note=b.querySelector("[data-note]").value.trim(),bs=b.querySelector("[data-bill]");
   if(!admin&&!reason)return say("Choose the reason for the change.");
   if(!await ask(`${admin?"Save":"Send to Admin"} this change on ${d.order_no}?\n\nOld ${rs(oldV)} → New ${rs(nv)} (${sg(df)})`))return;
   btn.disabled=true;const label=btn.textContent;btn.textContent=admin?"Saving…":"Sending…";
   let r,error;
   try{({data:r,error}=await client.rpc("lwb_bill_change_request",{p_order_id:d.order_id,p_items:items,p_reason:reason||null,p_note:note||null,p_bill_no:bs?bs.value:(bills[0]&&bills[0].no)||null}))}
   catch(x){error=x}
   if(error){btn.disabled=false;btn.textContent=label;return say(errText(error))}
   close();o.onSaved&&o.onSaved(r);
   const stock=loaded?stockText(rows.filter(x=>x.id||x.q>0).map(x=>({sku_old:x.id?x.sku0:null,qty_old:x.id?x.q0:0,sku:x.sku,qty:x.q}))):"";
   done(r.status==="APPROVED"?"Change saved":"Sent to Admin",
    `${d.order_no} · Old ${rs(oldV)} → New ${rs(nv)} (${sg(df)})`+(r.status==="APPROVED"?(stock?"\n\nStock: "+stock:""):"\n\nAdmin or Sales Head will approve it. Until then nothing changes."+(stock?"\nOn approve, stock: "+stock:"")))};
 }

 /* ---------- Goods return (CS + PCS) ---------- */
 const today=()=>new Date(Date.now()+330*60000).toISOString().slice(0,10);
 const cspc=(c,p)=>[c?c+" CS":"",p?p+" PCS":""].filter(Boolean).join(" + ")||"0";
 async function ret(o){
  const {client,order}=o,oid=order&&order.order_id||null;
  const {data:d,error}=await client.rpc("lwb_party_return_form",{p_order_id:oid,p_party:oid?null:(o.party||null)});
  if(error)return say(/lwb_party_return_form|schema cache/i.test(error.message)?"Run lwb_party_return_setup.sql first (merge the update).":errText(error));
  const sk=new Map((d.skus||[]).map(x=>[x.sku.toUpperCase(),x]));
  const rows=(d.items||[]).map(i=>({id:i.item_id,sku:i.sku_name,cs:0,pc:0,r:Number(i.rate)||0,ppc:i.ppc||null,max:r2(Number(i.cases)-Number(i.returned)),cases:Number(i.cases),back:Number(i.returned)||0}));
  if(!rows.length)rows.push({id:null,sku:"",cs:0,pc:0,r:0,ppc:null});
  const bill=d.bill,parties=o.parties||[];
  const {b,close}=shell(`<div class="bc-hd"><div><h3>↩ ${oid?"Return · "+esc(d.order_no)+" · "+esc(d.party):"New return"}</h3><small>${oid?(bill?"Tally bill "+esc(bill.invoice_no)+" "+rs(bill.amount):"No Tally bill yet")+" · ":"Goods back from a party, not against a bill · "}rate per case · PCS = pieces</small></div><button type="button" class="bc-x" aria-label="Close">✕</button></div>
   ${oid?"":`<input class="bc-in bc-pty" data-party list="bc-pl" maxlength="200" placeholder="Party (who gave the goods back)" aria-label="Party" value="${esc(o.party||"")}"><datalist id="bc-pl">${parties.map(n=>`<option value="${esc(n)}">`).join("")}</datalist>`}
   <datalist id="bc-rskus">${(d.skus||[]).map(s=>`<option value="${esc(s.sku)}">`).join("")}</datalist>
   <div style="overflow:auto"><table class="bc-t rt"><thead><tr><th>Item</th><th>CS</th><th>PCS</th><th class="n">Rate</th><th class="n">Return ₹</th><th></th></tr></thead><tbody></tbody></table></div>
   <div class="bc-row"><button type="button" class="bc-lnk" data-add>+ ${oid?"Other SKU (not on this bill)":"Add SKU"}</button><span class="sp bc-sum" data-sum></span></div>
   <div class="bc-row ra"><input type="date" class="bc-in" data-date value="${today()}" max="${today()}" aria-label="Return date" style="flex:0 0 auto">
    <input class="bc-in" data-note maxlength="300" placeholder="Note (why it came back)" style="flex:2 1 160px">
    ${bill?`<input class="bc-in" data-cn maxlength="100" placeholder="Tally credit note no. (optional)" style="flex:1 1 150px">`:""}
    <button type="button" class="bc-btn pri" data-save>Save return</button></div>
   <div class="bc-note">${!oid?"The value comes off this party's balance at once (return credit).":bill?"A credit note is saved on bill "+esc(bill.invoice_no)+" at once, so its Due and To collect go down.":"Make the Tally bill for the value after this return."} Godown stock does not change here.</div>`);
  const tb=b.querySelector("tbody"),sum=b.querySelector("[data-sum]");
  const val=x=>x.r>0?r2((x.cs+(x.ppc&&x.pc?x.pc/x.ppc:0))*x.r):0;
  function draw(){
   tb.innerHTML=rows.map((x,i)=>{const on=x.cs>0||x.pc>0;
    return `<tr data-i="${i}" class="${on?"ch":""}"><td class="it">${x.id?`<span class="bc-sku">${esc(x.sku)}</span><small>${x.cases} CS on bill${x.back?" · "+r2(x.back)+" back before":""}${x.ppc?" · 1 CS = "+x.ppc+" PCS":""}</small>`:`<input class="bc-in bc-sk" list="bc-rskus" value="${esc(x.sku)}" placeholder="Type SKU" aria-label="SKU">${x.sku&&x.ppc?`<small>1 CS = ${x.ppc} PCS</small>`:""}`}</td>
     <td><span class="bc-step"><button type="button" data-m aria-label="Less">−</button><input inputmode="numeric" data-cs value="${x.cs}" aria-label="Cases"><button type="button" data-p aria-label="More">+</button></span></td>
     <td><input class="bc-in bc-pcs" inputmode="numeric" data-pc value="${x.pc||""}" placeholder="${x.ppc?"PCS":"—"}" aria-label="Pieces"${x.ppc?"":` disabled title="No PCS per case in SKU Master"`}></td>
     <td class="n rr">${x.id?`<span title="PO rate">${rs(x.r)}</span>`:`<input class="bc-in bc-rate" inputmode="decimal" data-r value="${x.r||""}" placeholder="Rate" aria-label="Rate per case">`}</td>
     <td class="n am">${on?`<b>${rs(val(x))}</b>`:"—"}</td>
     <td class="n">${x.id?"":`<button type="button" class="bc-ic r" data-rm title="Remove">✕</button>`}</td></tr>`}).join("");
   tb.querySelectorAll("tr").forEach(tr=>{const x=rows[tr.dataset.i],ci=tr.querySelector("[data-cs]"),pi=tr.querySelector("[data-pc]"),ri=tr.querySelector("[data-r]"),si=tr.querySelector(".bc-sk");
    tr.querySelector("[data-m]").onclick=()=>{x.cs=Math.max(0,x.cs-1);draw()};tr.querySelector("[data-p]").onclick=()=>{x.cs++;draw()};
    ci.onchange=()=>{x.cs=Math.max(0,parseInt(ci.value,10)||0);draw()};
    pi.onchange=()=>{let p=Math.max(0,parseInt(pi.value,10)||0);if(x.ppc&&p>=x.ppc){x.cs+=Math.floor(p/x.ppc);p=p%x.ppc}x.pc=p;draw()};
    if(ri)ri.onchange=()=>{x.r=r2(String(ri.value).replace(/[,₹\s]/g,""));draw()};
    if(si)si.onchange=()=>{const m=sk.get(si.value.trim().toUpperCase());x.sku=m?m.sku:si.value.trim();x.ppc=m&&m.ppc||null;if(!x.ppc)x.pc=0;if(m&&m.rate&&!x.r)x.r=Number(m.rate);draw()};
    const rm=tr.querySelector("[data-rm]");if(rm)rm.onclick=()=>{rows.splice(rows.indexOf(x),1);if(!rows.length)rows.push({id:null,sku:"",cs:0,pc:0,r:0,ppc:null});draw()}});
   const on=rows.filter(x=>x.cs>0||x.pc>0),t=r2(on.reduce((a,x)=>a+val(x),0));
   sum.innerHTML=on.length?`${on.length} SKU · Return <span class="bc-tag bc-red">− ${rs(t)}</span>`:"Enter CS / PCS that came back";
  }
  draw();
  b.querySelector("[data-add]").onclick=()=>{rows.push({id:null,sku:"",cs:0,pc:0,r:0,ppc:null});draw();const s=tb.querySelectorAll(".bc-sk");s[s.length-1].focus()};
  b.querySelector("[data-save]").onclick=async e=>{
   const btn=e.currentTarget;if(btn.disabled)return;
   const on=rows.filter(x=>x.cs>0||x.pc>0);
   if(!on.length)return say("Enter the cases or pieces that came back.");
   if(on.some(x=>!x.id&&!x.sku))return say("Type the SKU of every new line.");
   if(on.some(x=>!x.id&&!sk.has(x.sku.toUpperCase())))return say("Pick the SKU from the list (SKU Master).");
   if(on.some(x=>!(x.r>0)))return say("Enter the rate per case of every line.");
   const over=on.find(x=>x.id&&(x.cs+(x.ppc?x.pc/x.ppc:0))>x.max+0.0001);if(over)return say(over.sku+": only "+r2(over.max)+" CS is left to return on this bill.");
   const pin=b.querySelector("[data-party]"),party=pin?pin.value.trim():"";
   if(!oid&&!party)return say("Choose the party the goods came back from.");
   const date=b.querySelector("[data-date]").value,note=b.querySelector("[data-note]").value.trim(),cn=b.querySelector("[data-cn]");
   if(!date)return say("Enter the return date.");
   const t=r2(on.reduce((a,x)=>a+val(x),0));
   if(!await ask(`Save return of ${rs(t)}${oid?" on "+d.order_no:""} from ${oid?d.party:party}?\n\n`+on.map(x=>x.sku+" · "+cspc(x.cs,x.pc)+" · "+rs(val(x))).join("\n")))return;
   btn.disabled=true;btn.textContent="Saving…";
   let r,err;
   try{({data:r,error:err}=await client.rpc("lwb_party_return_save",{p_order_id:oid,p_party:oid?null:party,p_return_date:date,
     p_items:on.map(x=>({item_id:x.id||null,sku_name:x.sku,cases:x.cs,pcs:x.pc,rate:x.r})),p_note:note||null,p_note_no:cn&&cn.value.trim()||null}))}
   catch(x){err=x}
   if(err){btn.disabled=false;btn.textContent="Save return";return say(errText(err))}
   close();o.onSaved&&o.onSaved(r);
   done("Return saved",`${r.return_no} · ${r.party} · − ${rs(r.amount)}`+(r.credit_note?`\n\nCredit note ${r.credit_note} saved on bill ${bill.invoice_no}: Due goes down by ${rs(r.amount)}.`:oid?"\n\nNo Tally bill yet: make the bill for the value after this return.":"\n\nThe party's balance goes down by "+rs(r.amount)+"."));
  };
 }

 /* ---------- Admin review ---------- */
 function stockRow(c){
  if(c.qty_col!=="loaded_qty")return "";
  const sa=Array.isArray(c.stock_applied)?c.stock_applied:null;
  const list=sa?sa.map(x=>({sku:x.sku,c:Number(x.cases)||0,skip:x.skipped})):stockMoves(c.lines);
  if(!list.length)return c.status==="WAITING"?`<div class="bc-note">Stock: no change (rate only).</div>`:"";
  return `<div class="bc-stk"><b>${sa?"Godown stock moved":c.status==="WAITING"?"On approve, godown stock":"Godown stock"}</b>${list.map(x=>`<span class="bc-tag ${x.skip?"bc-amb":x.c>0?"bc-grn":"bc-red"}">${esc(x.sku)} ${x.c>0?"+":"−"}${Math.abs(x.c)} CS${x.skip?" · not in SKU Master":""}</span>`).join("")}<small>+ back to godown · − more went to party</small></div>`;
 }
 function review(o){
  const {client,change:c,admin}=o,st=ST[c.status]||["",c.status],can=admin&&c.status==="WAITING";
  const {b,close}=shell(`<div class="bc-hd"><div><h3>Change on ${esc(c.order_no)} · ${esc(c.party)}</h3><small>By ${esc(c.by||"")} · ${dmy(c.requested_at)} ${new Date(c.requested_at).toLocaleTimeString("en-IN",{hour:"numeric",minute:"2-digit"})}${c.reason?" · "+esc(c.reason):""} · <span class="bc-tag ${st[0]}">${st[1]}</span></small></div><button type="button" class="bc-x" aria-label="Close">✕</button></div>
   <div class="bc-diff"><div>Old value<b>${rs(c.old_value)}</b></div><div>New value<b>${rs(c.new_value)}</b></div><div class="${c.diff>0?"pos":c.diff<0?"neg":""}">Difference<b>${sg(c.diff)}</b></div></div>
   <div style="overflow:auto"><table class="bc-t"><thead><tr><th>Change</th><th class="n">Qty</th><th class="n">Rate</th><th class="n">₹</th></tr></thead><tbody>
   ${(c.lines||[]).map(l=>`<tr><td>${lineText(l)}</td><td class="n">${qtyText(l)}</td><td class="n">${rateText(l)}</td><td class="n ${l.diff>0?"bc-pos":l.diff<0?"bc-neg":""}">${sg(l.diff)}</td></tr>`).join("")}</tbody></table></div>
   ${stockRow(c)}
   ${c.note?`<div class="bc-note">Note: ${esc(c.note)}</div>`:""}
   ${c.bill_applied?`<div class="bc-note">Tally bill${c.bill_applied.no?" "+esc(c.bill_applied.no):""}: ${rs(c.bill_applied.from)} → ${rs(c.bill_applied.to)}</div>`:c.bill_no&&can?`<div class="bc-note">On approve, Tally bill ${esc(c.bill_no)} moves by ${sg(c.diff)}.</div>`:""}
   ${c.reply?`<div class="bc-note">Admin: ${esc(c.reply)}${c.decided?" ("+esc(c.decided)+")":""}</div>`:""}
   ${can?`<div class="bc-row act"><input class="bc-in" data-reply maxlength="500" placeholder="Reply to Accounts (optional)" style="flex:1 1 200px"><button type="button" class="bc-btn bad" data-no>Send back</button><button type="button" class="bc-btn ok" data-ok>Approve ${sg(c.diff)}</button></div>`:""}`,true);
  if(!can)return;
  const go=async(ok,btn)=>{
   if(btn.disabled)return;
   if(!await ask(ok?`Approve ${sg(c.diff)} on ${c.order_no}?\n\nThe PO lines change${c.bill_no?" and the Tally bill moves by the same amount":""}.`:`Send this change back to ${c.by||"Accounts"}? Nothing changes.`))return;
   btn.disabled=true;
   const {error}=await client.rpc("lwb_bill_change_decide",{p_id:c.id,p_approve:ok,p_reply:b.querySelector("[data-reply]").value.trim()||null});
   if(error){btn.disabled=false;return say(errText(error))}
   close();o.onDone&&o.onDone();
   const stock=c.qty_col==="loaded_qty"?stockText(c.lines):"";
   done(ok?"Approved":"Sent back",ok?`${c.order_no} · ${sg(c.diff)} · PO lines changed${c.bill_no?", Tally bill moved":""}.`+(stock?"\n\nStock: "+stock:""):`${c.order_no} · sent back to ${c.by||"Accounts"}. Nothing changed.`)};
  b.querySelector("[data-ok]").onclick=e=>go(true,e.currentTarget);
  b.querySelector("[data-no]").onclick=e=>go(false,e.currentTarget);
 }
 window.LWBBillChange={open,review,ret,sg,cspc};
})();
