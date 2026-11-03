/* LUXURY WRIST BRAND ERP — PO item changes through Admin (lwb_bill_change_setup.sql)
 * LWBBillChange.open({client, order:{order_id, order_no, party}, admin, onSaved})
 *   Items popup: qty + / −, rate, replace SKU, add / remove SKU, history of earlier changes.
 *   Accounts -> "Send to Admin" (WAITING); Admin -> "Save change" (applied at once).
 * LWBBillChange.review({client, change, admin, onDone})
 *   Old value / new value / difference + every changed line; Admin: Approve / Send back.
 */
(function(){
 'use strict';
 const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
 const rs=n=>"₹"+(Math.round((Number(n)||0)*100)/100).toLocaleString("en-IN",{maximumFractionDigits:2});
 const sg=n=>(n>0.004?"+":n<-0.004?"−":"")+rs(Math.abs(n));
 const r2=n=>Math.round((Number(n)||0)*100)/100;
 const dmy=v=>{const d=String(v||"").slice(0,10).split("-");return d.length===3?d[2]+"/"+d[1]+"/"+d[0]:""};
 const errText=e=>String((e&&(e.message||e.details))||e||"Error").replace(/^STALE: /,"");
 const REASONS=["Wrong item loaded","Less qty reached","Extra qty reached","Item not on PO but reached","Rate change","Other"];
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
 .bc-lnk{border:0;background:none;color:#1769d8;font:inherit;font-weight:600;cursor:pointer;padding:0}
 .bc-sum{font-weight:700}
 .bc-diff{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:6px;margin:6px 0 8px}
 .bc-diff div{border-radius:8px;padding:6px 8px;background:#f4f6f5;font-size:12.5px}.bc-diff b{display:block;font-size:17px}
 .bc-diff .pos{background:#e3f5ec;color:#13824a}.bc-diff .neg{background:#fdecef;color:#b3122b}
 .bc-ban{background:#fdf0dc;color:#7a4700;border-radius:8px;padding:6px 10px;margin:0 0 8px;display:flex;gap:8px;align-items:center;flex-wrap:wrap}
 .bc-hist{margin-top:8px;font-size:13px}.bc-hist summary{cursor:pointer;font-weight:700;color:#33404d}
 .bc-hist .h{border-top:1px solid var(--erp-line,#e3e6e2);padding:5px 0;display:flex;gap:6px;flex-wrap:wrap;align-items:center}
 .bc-note{color:var(--erp-muted,#55686c);font-size:12.5px;margin-top:6px}
 del{color:#8a969a}ins{text-decoration:none;font-weight:700}
 @media(max-width:600px){.bc-back{padding:8px}.bc-box{padding:10px}
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
  const {b,close}=shell(`<div class="bc-hd"><div><h3>${esc(d.order_no)} · ${esc(d.party)}</h3><small>${loaded?"Loaded qty (what reached the party)":"Approved qty (not loaded yet)"} · rate per case${d.bill&&d.bill.invoice_no?" · Tally bill "+esc(d.bill.invoice_no)+" "+rs(d.bill.amount):""}</small></div><button type="button" class="bc-x" aria-label="Close">✕</button></div>
   ${wait?`<div class="bc-ban">⏳ A change of <b>${sg(wait.diff)}</b> by ${esc(wait.by||"")} is waiting for Admin.<button type="button" class="bc-lnk" data-wv>View</button>${admin?"":"<small>Sending again replaces it.</small>"}</div>`:""}
   <datalist id="bc-skus">${(d.skus||[]).map(s=>`<option value="${esc(s)}">`).join("")}</datalist>
   <div style="overflow:auto"><table class="bc-t ed"><thead><tr><th>Item</th><th>Qty (CS)</th><th class="n">Rate</th><th class="n">Amount</th><th></th></tr></thead><tbody></tbody></table></div>
   <div class="bc-row"><button type="button" class="bc-lnk" data-add>+ Add SKU</button><span class="sp bc-sum" data-sum></span></div>
   <div class="bc-row"><select class="bc-in" data-reason style="flex:1 1 170px"><option value="">Reason…</option>${REASONS.map(r=>`<option>${r}</option>`).join("")}</select>
    <input class="bc-in" data-note maxlength="500" placeholder="Note for Admin" style="flex:2 1 200px">
    ${bills.length>1?`<select class="bc-in" data-bill title="Bill that takes the difference" style="flex:1 1 150px">${bills.map(x=>`<option value="${esc(x.no)}">Bill ${esc(x.no)} · ${esc(x.firm||"")}</option>`).join("")}</select>`:""}
    <button type="button" class="bc-btn pri" data-send>${admin?"Save change":"Send to Admin"}</button></div>
   <div class="bc-note">${admin?"Your change is saved at once.":"Nothing changes until Admin approves."} ${d.bill&&d.bill.amount?"After approval the Tally bill amount moves by the same difference, so To collect follows.":"The bill amount to make follows the new value."}</div>
   ${(d.changes||[]).length?`<details class="bc-hist"><summary>History (${d.changes.length})</summary>${d.changes.map(c=>`<div class="h"><span class="bc-tag ${(ST[c.status]||[])[0]||""}">${(ST[c.status]||[])[1]||c.status}</span> ${dmy(c.requested_at)} · ${esc(c.by||"")} · ${rs(c.old_value)} → ${rs(c.new_value)} <b class="${c.diff>=0?"bc-pos":"bc-neg"}">${sg(c.diff)}</b>${c.reason?" · "+esc(c.reason):""}${c.reply?` · Admin: ${esc(c.reply)}`:""} <button type="button" class="bc-lnk" data-hv="${esc(c.id)}">View</button></div>`).join("")}</details>`:""}`);
  const tb=b.querySelector("tbody"),sum=b.querySelector("[data-sum]");
  const oldV=rows.reduce((a,x)=>a+x.q0*x.r0,0);
  function draw(){
   tb.innerHTML=rows.map((x,i)=>{const ch=x.id&&(x.q!==x.q0||x.r!==x.r0||x.sku.toUpperCase()!==x.sku0.toUpperCase()),rm=x.q===0,dv=x.q*x.r-(x.id?x.q0*x.r0:0);
    const hist=x.id?`PO ${Number(x.h.ordered)} · OK ${Number(x.h.approved)}${x.h.loaded!=null?" · Loaded "+Number(x.h.loaded):""}`:"new";
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
   sum.innerHTML=`Old ${rs(oldV)} → New ${rs(nv)} <span class="bc-tag ${df>0.004?"bc-grn":df<-0.004?"bc-red":"bc-amb"}">${Math.abs(df)>0.004?sg(df):"no change"}</span>`;
  }
  draw();
  b.querySelector("[data-add]").onclick=()=>{rows.push({id:null,sku0:"",sku:"",q0:0,q:1,r0:0,r:0,h:null,swap:true});draw();const s=tb.querySelectorAll(".bc-sk");s[s.length-1].focus()};
  const wv=b.querySelector("[data-wv]");if(wv)wv.onclick=()=>review({client,admin,change:{...wait,order_no:d.order_no,party:d.party},onDone:()=>{close();o.onSaved&&o.onSaved()}});
  b.querySelectorAll("[data-hv]").forEach(x=>x.onclick=()=>{const c=d.changes.find(y=>y.id===x.dataset.hv);review({client,admin,change:{...c,order_no:d.order_no,party:d.party},onDone:()=>{close();o.onSaved&&o.onSaved()}})});
  b.querySelector("[data-send]").onclick=async e=>{
   const items=rows.filter(x=>x.id||x.q>0).map(x=>({item_id:x.id||null,sku_name:x.sku.trim(),qty:x.q,rate:x.r}));
   if(items.some(x=>!x.sku_name))return say("Type the SKU of every new line.");
   if(items.some(x=>x.qty>0&&!(x.rate>0)))return say("Enter the rate of every line.");
   const nv=rows.reduce((a,x)=>a+x.q*x.r,0),df=r2(nv-oldV);
   const reason=b.querySelector("[data-reason]").value,note=b.querySelector("[data-note]").value.trim(),bs=b.querySelector("[data-bill]");
   if(!admin&&!reason)return say("Choose the reason for the change.");
   if(!await ask(`${admin?"Save":"Send to Admin"} this change on ${d.order_no}?\n\nOld ${rs(oldV)} → New ${rs(nv)} (${sg(df)})`))return;
   e.currentTarget.disabled=true;
   const {data:r,error}=await client.rpc("lwb_bill_change_request",{p_order_id:d.order_id,p_items:items,p_reason:reason||null,p_note:note||null,p_bill_no:bs?bs.value:(bills[0]&&bills[0].no)||null});
   if(error){e.currentTarget.disabled=false;return say(errText(error))}
   toast(r.status==="APPROVED"?"Change saved · "+sg(r.diff):"Sent to Admin · "+sg(r.diff));close();o.onSaved&&o.onSaved(r)};
 }

 /* ---------- Admin review ---------- */
 function review(o){
  const {client,change:c,admin}=o,st=ST[c.status]||["",c.status],can=admin&&c.status==="WAITING";
  const {b,close}=shell(`<div class="bc-hd"><div><h3>Change on ${esc(c.order_no)} · ${esc(c.party)}</h3><small>By ${esc(c.by||"")} · ${dmy(c.requested_at)} ${new Date(c.requested_at).toLocaleTimeString("en-IN",{hour:"numeric",minute:"2-digit"})}${c.reason?" · "+esc(c.reason):""} · <span class="bc-tag ${st[0]}">${st[1]}</span></small></div><button type="button" class="bc-x" aria-label="Close">✕</button></div>
   <div class="bc-diff"><div>Old value<b>${rs(c.old_value)}</b></div><div>New value<b>${rs(c.new_value)}</b></div><div class="${c.diff>0?"pos":c.diff<0?"neg":""}">Difference<b>${sg(c.diff)}</b></div></div>
   <div style="overflow:auto"><table class="bc-t"><thead><tr><th>Change</th><th class="n">Qty</th><th class="n">Rate</th><th class="n">₹</th></tr></thead><tbody>
   ${(c.lines||[]).map(l=>`<tr><td>${lineText(l)}</td><td class="n">${qtyText(l)}</td><td class="n">${rateText(l)}</td><td class="n ${l.diff>0?"bc-pos":l.diff<0?"bc-neg":""}">${sg(l.diff)}</td></tr>`).join("")}</tbody></table></div>
   ${c.note?`<div class="bc-note">Note: ${esc(c.note)}</div>`:""}
   ${c.bill_applied?`<div class="bc-note">Tally bill${c.bill_applied.no?" "+esc(c.bill_applied.no):""}: ${rs(c.bill_applied.from)} → ${rs(c.bill_applied.to)}</div>`:c.bill_no&&can?`<div class="bc-note">On approve, Tally bill ${esc(c.bill_no)} moves by ${sg(c.diff)}.</div>`:""}
   ${c.reply?`<div class="bc-note">Admin: ${esc(c.reply)}${c.decided?" ("+esc(c.decided)+")":""}</div>`:""}
   ${can?`<div class="bc-row act"><input class="bc-in" data-reply maxlength="500" placeholder="Reply to Accounts (optional)" style="flex:1 1 200px"><button type="button" class="bc-btn bad" data-no>Send back</button><button type="button" class="bc-btn ok" data-ok>Approve ${sg(c.diff)}</button></div>`:""}`,true);
  if(!can)return;
  const go=async(ok,btn)=>{
   if(!await ask(ok?`Approve ${sg(c.diff)} on ${c.order_no}?\n\nThe PO lines change${c.bill_no?" and the Tally bill moves by the same amount":""}.`:`Send this change back to ${c.by||"Accounts"}? Nothing changes.`))return;
   btn.disabled=true;
   const {error}=await client.rpc("lwb_bill_change_decide",{p_id:c.id,p_approve:ok,p_reply:b.querySelector("[data-reply]").value.trim()||null});
   if(error){btn.disabled=false;return say(errText(error))}
   toast(ok?"Approved · "+sg(c.diff):"Sent back");close();o.onDone&&o.onDone()};
  b.querySelector("[data-ok]").onclick=e=>go(true,e.currentTarget);
  b.querySelector("[data-no]").onclick=e=>go(false,e.currentTarget);
 }
 window.LWBBillChange={open,review,sg};
})();
