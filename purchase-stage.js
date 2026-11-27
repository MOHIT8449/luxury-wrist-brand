/* Purchase stages (Mohit, 27 Nov 2026, lwb_purchase_stages_setup.sql).
   LWBPurchaseStage.dispatch({client, truck, onDone}) = popup "Company dispatched": vehicle no., invoice no. / date and
   the cases the company really sent per SKU (starts with the ECRS ordered cases). Also "Not coming" (company did not send).
   truck = {id, no, day, rows:[{sku_id,name,cs}], sent_rows, vehicle_no, invoice_no, invoice_date, closed_at}. */
(function(){
  'use strict';
  const esc=v=>String(v==null?"":v).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
  const num=v=>{const n=Number(v);return isFinite(n)?n:0};
  const fmt=v=>num(v).toLocaleString("en-IN",{maximumFractionDigits:2});
  const dmy=d=>d?String(d).slice(8,10)+"/"+String(d).slice(5,7)+"/"+String(d).slice(0,4):"";
  const today=()=>new Date().toLocaleDateString("en-CA",{timeZone:"Asia/Kolkata"});
  function css(){
    if(document.getElementById("pstCss"))return;
    const s=document.createElement("style");s.id="pstCss";
    s.textContent=`.pst-back{position:fixed;inset:0;background:rgba(15,23,42,.45);z-index:950;display:flex;align-items:flex-start;justify-content:center;padding:4vh 10px;overflow:auto}
.pst-pop{width:min(560px,100%);background:#fff;border-radius:12px;box-shadow:0 24px 60px rgba(15,23,42,.3);color:#1f2a37;font-size:14px}
.pst-h{display:flex;align-items:center;gap:8px;padding:11px 14px;border-bottom:1px solid #e3e7ec}.pst-h h3{margin:0;font-size:16px;flex:1;min-width:0}
.pst-h h3 small{display:block;font-size:12.5px;color:#6b7785;font-weight:500}
.pst-x{border:1px solid #e3e7ec;background:#fff;border-radius:6px;width:32px;height:32px;font-size:15px;cursor:pointer;flex:none}
.pst-b{padding:10px 14px}
.pst-f{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;margin-bottom:10px}
.pst-f label{display:flex;flex-direction:column;gap:3px;font-size:12px;color:#6b7785;min-width:0}
.pst-f input,.pst-t input{height:34px;border:1px solid #cfd6de;border-radius:6px;padding:0 8px;font:inherit;font-size:14px;min-width:0;width:100%;background:#fff;color:#1f2a37}
.pst-t{border-collapse:collapse;width:100%;font-size:13.5px}
.pst-t th,.pst-t td{border-bottom:1px solid #e3e7ec;padding:5px 6px;text-align:right}
.pst-t th:first-child,.pst-t td:first-child{text-align:left}
.pst-t th{background:#f6f7f9;font-size:11px;text-transform:uppercase;color:#2b3440}
.pst-t td input{width:84px;height:30px;text-align:right}
.pst-t tfoot td{font-weight:800;background:#fafbfc}
.pst-d{display:inline-block;min-width:40px;padding:1px 6px;border-radius:4px;font-size:12px;font-weight:800}
.pst-d.m{background:#fdecef;color:#c8102e}.pst-d.ok{background:#e4f6e9;color:#0d6b36}.pst-d.p{background:#e8f0fe;color:#1a56c4}
.pst-hint{font-size:12px;color:#6b7785;margin:8px 0 0}
.pst-err{background:#ffebeb;color:#9b2020;padding:7px 10px;border-radius:6px;margin-top:8px;font-size:13px}
.pst-ft{display:flex;gap:6px;padding:10px 14px;border-top:1px solid #e3e7ec}
.pst-ft button{height:36px;padding:0 12px;border-radius:6px;border:1px solid #e3e7ec;background:#fff;color:#1f2a37;font:inherit;font-size:13.5px;font-weight:700;cursor:pointer;flex:1 1 0;min-width:0;white-space:nowrap}
.pst-ft .go{background:#1a56c4;border-color:#1a56c4;color:#fff}.pst-ft .no{color:#b42318;border-color:#f0c2c2}
@media(max-width:540px){.pst-back{padding:0}.pst-pop{border-radius:0;min-height:100%}.pst-f{grid-template-columns:1fr 1fr}.pst-f label:first-child{grid-column:1/-1}.pst-t td input{width:68px}.pst-lg{display:none}}`;
    document.head.appendChild(s);
  }
  function dispatch({client,truck,onDone}){
    css();
    const t=truck,sent=new Map((Array.isArray(t.sent_rows)?t.sent_rows:[]).map(r=>[String(r.sku_id),num(r.cs)]));
    const rows=(t.rows||[]).map(r=>({sku_id:String(r.sku_id),name:r.name||"",cs:num(r.cs),sent:sent.has(String(r.sku_id))?sent.get(String(r.sku_id)):num(r.cs)}));
    const back=document.createElement("div");back.className="pst-back";
    back.innerHTML=`<div class="pst-pop" role="dialog" aria-modal="true" aria-label="Company dispatch">
      <div class="pst-h"><h3>🚚 Company dispatch · ECRS Order ${esc(t.no||"")}<small>Ordered ${esc(dmy(t.day))}${t.closed_at?" · marked Not coming":""}</small></h3><button type="button" class="pst-x" data-x aria-label="Close">✕</button></div>
      <div class="pst-b">
        <div class="pst-f"><label>Vehicle no.<input id="pstVeh" maxlength="20" placeholder="GJ05..." value="${esc(t.vehicle_no||"")}" autocomplete="off"></label>
          <label>Company invoice no.<input id="pstInv" maxlength="40" value="${esc(t.invoice_no||"")}" autocomplete="off"></label>
          <label>Invoice date<input id="pstDt" type="date" value="${esc(t.invoice_date||today())}"></label></div>
        <table class="pst-t"><thead><tr><th>SKU</th><th>Ordered<span class="pst-lg"> CS</span></th><th><span class="pst-lg">Company </span>sent<span class="pst-lg"> CS</span></th><th>Diff</th></tr></thead><tbody>${rows.map((r,i)=>
          `<tr><td>${esc(r.name)}</td><td>${fmt(r.cs)}</td><td><input type="number" min="0" step="1" inputmode="numeric" data-i="${i}" value="${r.sent}" aria-label="Sent cases ${esc(r.name)}"></td><td data-d="${i}"></td></tr>`).join("")}</tbody>
          <tfoot><tr><td>Total</td><td>${fmt(rows.reduce((a,r)=>a+r.cs,0))}</td><td id="pstTot"></td><td id="pstTotD"></td></tr></tfoot></table>
        <p class="pst-hint">Change the cases if the company sent less or more than the ECRS order. When the vehicle reaches the godown, the purchase bill with this invoice no. or vehicle no. joins this order by itself.</p>
        <div id="pstErr" class="pst-err" hidden></div>
      </div>
      <div class="pst-ft"><button type="button" class="go" data-save>Save dispatch</button>${t.closed_at?'<button type="button" data-open>Open again</button>':'<button type="button" class="no" data-close>✕ Not coming</button>'}<button type="button" data-x>Cancel</button></div></div>`;
    document.body.appendChild(back);
    const $=s=>back.querySelector(s);
    const diff=(a,b)=>{const d=a-b;return d?'<span class="pst-d '+(d<0?"m":"p")+'">'+(d>0?"+":"")+fmt(d)+"</span>":'<span class="pst-d ok">✓</span>'};
    const upd=()=>{rows.forEach((r,i)=>{$('[data-d="'+i+'"]').innerHTML=diff(r.sent,r.cs)});
      const s=rows.reduce((a,r)=>a+r.sent,0),o=rows.reduce((a,r)=>a+r.cs,0);$("#pstTot").textContent=fmt(s);$("#pstTotD").innerHTML=diff(s,o)};
    back.querySelectorAll("input[data-i]").forEach(el=>el.addEventListener("input",()=>{rows[+el.dataset.i].sent=Math.max(0,Math.round(num(el.value)));upd()}));
    upd();
    const close=()=>{back.remove();document.removeEventListener("keydown",key)};
    const key=e=>{if(e.key==="Escape")close()};document.addEventListener("keydown",key);
    back.querySelectorAll("[data-x]").forEach(b=>b.onclick=close);
    back.addEventListener("click",e=>{if(e.target===back)close()});
    const err=m=>{$("#pstErr").hidden=!m;$("#pstErr").textContent=m||""};
    const clean=m=>String(m||"").replace(/^.*?ERROR:\s*/,"");
    $("[data-save]").onclick=async()=>{
      const vc=window.LWBVeh?LWBVeh.check($("#pstVeh").value):null;
      if(vc&&!vc.empty&&!vc.ok){if($("#pstVeh").lwbVehShow)$("#pstVeh").lwbVehShow();return err("Vehicle no.: "+vc.err)}
      const veh=vc&&vc.ok?vc.value:$("#pstVeh").value.trim(),inv=$("#pstInv").value.trim();
      if(!veh&&!inv)return err("Enter the vehicle no. or the company invoice no.");
      $("[data-save]").disabled=true;
      const r=await client.rpc("lwb_ecrs_dispatch",{p_truck:t.id,p_vehicle:veh,p_invoice:inv,p_invoice_date:$("#pstDt").value||null,
        p_rows:rows.map(x=>({sku_id:x.sku_id,name:x.name,cs:x.sent}))});
      $("[data-save]").disabled=false;
      if(r.error)return err(/function|schema cache/i.test(r.error.message)?"Purchase stages are not set up yet (lwb_purchase_stages_setup.sql runs by itself when merged).":"Not saved: "+clean(r.error.message));
      close();if(onDone)onDone("dispatch");
    };
    const cl=$("[data-close]"),op=$("[data-open]");
    if(cl)cl.onclick=async()=>{
      const note=await window.prompt("ECRS Order "+(t.no||"")+" will not come (company did not send it).\nReason (optional):","");
      if(note==null)return;
      const r=await client.rpc("lwb_ecrs_close",{p_truck:t.id,p_close:true,p_note:note});
      if(r.error)return err("Not saved: "+clean(r.error.message));
      close();if(onDone)onDone("close");
    };
    if(op)op.onclick=async()=>{
      const r=await client.rpc("lwb_ecrs_close",{p_truck:t.id,p_close:false,p_note:null});
      if(r.error)return err("Not saved: "+clean(r.error.message));
      close();if(onDone)onDone("open");
    };
    if(window.LWBVeh)LWBVeh.attach($("#pstVeh"));
    setTimeout(()=>{const v=$("#pstVeh");if(v)v.focus()},30);
  }
  window.LWBPurchaseStage={dispatch};
})();
