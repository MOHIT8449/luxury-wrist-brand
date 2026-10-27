/* Credit / Debit note popup (Tally note no., date, amount, reason) for one PO's Tally invoice.
   LWBNote.open({db, order:{id, order_no, party, invoice_no}, kind, amount, reason, title, onSaved})
   Saves with lwb_save_tally_note (lwb_tally_bill_flow_setup.sql). Accounts / Admin only. */
(function(){
  "use strict";
  const esc=v=>String(v??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const today=()=>new Date(Date.now()+330*60e3).toISOString().slice(0,10);
  const rs=n=>"₹"+Number(n||0).toLocaleString("en-IN",{maximumFractionDigits:2});
  const CSS=`.lwbn-ov{position:fixed;inset:0;background:#101827aa;display:flex;align-items:center;justify-content:center;padding:16px;z-index:9999}
.lwbn{background:#fff;color:#182a42;width:min(460px,100%);max-height:92vh;overflow:auto;border-radius:12px;font:14px/1.5 Arial,sans-serif;box-shadow:0 18px 50px #0005}
.lwbn h3{margin:0;padding:15px 18px;background:#14253f;color:#fff;font-size:16px}
.lwbn .b{padding:16px 18px;display:grid;gap:11px}
.lwbn p{margin:0;color:#4c5f76;font-size:13px}
.lwbn label{display:block;font-size:11px;color:#657992;text-transform:uppercase;margin-bottom:4px}
.lwbn input{width:100%;box-sizing:border-box;padding:10px;border:1px solid #c2cedf;border-radius:7px;font:14px Arial}
.lwbn .k{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.lwbn .k button{padding:11px;border-radius:8px;border:2px solid #c2cedf;background:#fff;color:#23384f;font-weight:bold;cursor:pointer}
.lwbn .k button[aria-pressed=true]{border-color:#1769d8;background:#eaf2ff;color:#123f7a}
.lwbn .two{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.lwbn .f{display:flex;gap:9px;justify-content:flex-end;padding:0 18px 16px}
.lwbn .f button{padding:10px 16px;border:0;border-radius:7px;font-weight:bold;cursor:pointer;background:#e7edf5;color:#23384f}
.lwbn .f .go{background:#1769d8;color:#fff}
.lwbn .f button:disabled{opacity:.55;cursor:not-allowed}
.lwbn .e{color:#a02c2c;font-size:13px;min-height:1px}`;
  function open(o){
    if(!document.getElementById("lwbn-css")){const s=document.createElement("style");s.id="lwbn-css";s.textContent=CSS;document.head.appendChild(s)}
    let kind=o.kind==="DEBIT"?"DEBIT":"CREDIT";
    const ord=o.order||{};
    const ov=document.createElement("div");ov.className="lwbn-ov";
    ov.innerHTML=`<div class="lwbn" role="dialog" aria-modal="true" aria-labelledby="lwbnT">
      <h3 id="lwbnT">${esc(o.title||"Credit / Debit note")}</h3>
      <div class="b">
        <p><b>${esc(ord.party)}</b> · PO ${esc(ord.order_no)}${ord.invoice_no?" · Tally bill "+esc(ord.invoice_no):""}</p>
        ${o.info?`<p>${esc(o.info)}</p>`:""}
        <div class="k"><button type="button" data-k="CREDIT">Credit note<br><small style="font-weight:normal">return, rate cut: party pays less</small></button><button type="button" data-k="DEBIT">Debit note<br><small style="font-weight:normal">extra charge: party pays more</small></button></div>
        <div class="two"><div><label for="lwbnNo">Tally note no.</label><input id="lwbnNo" maxlength="100" autocomplete="off" placeholder="e.g. CN/45"></div>
        <div><label for="lwbnDate">Note date</label><input id="lwbnDate" type="date"></div></div>
        <div><label for="lwbnAmt">Amount (as in Tally)</label><input id="lwbnAmt" type="number" min="0.01" step="0.01" inputmode="decimal"></div>
        <div><label for="lwbnWhy">Reason</label><input id="lwbnWhy" maxlength="300" autocomplete="off" placeholder="e.g. 3 cases returned (damaged)"></div>
        <div class="e" id="lwbnErr"></div>
      </div>
      <div class="f"><button type="button" data-x>${esc(o.skipText||"Not now")}</button><button type="button" class="go" data-save>Save note</button></div></div>`;
    document.body.appendChild(ov);
    const q=s=>ov.querySelector(s);
    q("#lwbnDate").value=today();
    if(o.amount>0)q("#lwbnAmt").value=Number(o.amount).toFixed(2);
    if(o.reason)q("#lwbnWhy").value=o.reason;
    const setK=k=>{kind=k;ov.querySelectorAll("[data-k]").forEach(b=>b.setAttribute("aria-pressed",String(b.dataset.k===k)))};
    setK(kind);
    ov.querySelectorAll("[data-k]").forEach(b=>b.onclick=()=>setK(b.dataset.k));
    const close=()=>{ov.remove();document.removeEventListener("keydown",esc_)};
    const esc_=e=>{if(e.key==="Escape")close()};
    document.addEventListener("keydown",esc_);
    q("[data-x]").onclick=close;
    ov.addEventListener("click",e=>{if(e.target===ov)close()});
    q("[data-save]").onclick=async()=>{
      const no=q("#lwbnNo").value.trim(),dt=q("#lwbnDate").value,amt=Number(q("#lwbnAmt").value),why=q("#lwbnWhy").value.trim();
      const err=q("#lwbnErr");
      if(!no){err.textContent="Enter the note number from Tally.";return}
      if(!dt){err.textContent="Enter the note date.";return}
      if(!(amt>0)){err.textContent="Enter the amount.";return}
      const btn=q("[data-save]");btn.disabled=true;err.textContent="";
      try{
        const {error}=await o.db.rpc("lwb_save_tally_note",{p_order_id:ord.id,p_kind:kind,p_note_no:no,p_note_date:dt,p_amount:amt,p_reason:why||null});
        if(error)throw error;
        close();
        if(o.onSaved)o.onSaved({kind,no,amount:amt});
      }catch(e){
        err.textContent=/lwb_save_tally_note|schema cache|function/i.test(e.message)?"Not set up yet: run lwb_tally_bill_flow_setup.sql once in Supabase.":e.message;
        btn.disabled=false;
      }
    };
    setTimeout(()=>q("#lwbnNo").focus(),30);
    return {close};
  }
  // After money or a return comes in: ask for the credit note of an approved return not yet noted,
  // or (when a delivery with a return is still short of money) offer a credit / debit note. Quietly does nothing if the
  // Tally bill flow is not set up or the page user cannot read the notes.
  async function check(o){
    const ord=o.order||{};
    try{
      const [t,n]=await Promise.all([
        o.db.from("lwb_tally_invoices").select("invoice_no").eq("order_id",ord.id).maybeSingle(),
        o.db.from("lwb_tally_notes").select("kind,amount,cancelled_at").eq("order_id",ord.id)]);
      if(t.error||n.error)return;
      const cr=(n.data||[]).filter(x=>x.kind==="CREDIT"&&!x.cancelled_at).reduce((a,x)=>a+Number(x.amount||0),0);
      const ret=Number(o.approvedReturn||0),left=Math.round((ret-cr)*100)/100;
      if(!t.data){
        if(left>0.5&&o.say)o.say("Return of "+rs(ret)+" needs a credit note, but the Tally bill of "+ord.order_no+" is not entered yet (Accounts > Tally Bill & Invoice No.).");
        return;
      }
      const order={...ord,invoice_no:t.data.invoice_no};
      if(left>0.5)return open({...o,order,kind:"CREDIT",amount:left,reason:o.reason||"Return approved",
        title:"Return: make the credit note",info:"Return approved "+rs(ret)+(cr?", credit notes so far "+rs(cr):"")+". Make the credit note in Tally and enter it here."});
      if(o.hadReturn&&Number(o.outstanding||0)>1)return open({...o,order,kind:"CREDIT",title:"Money short: credit / debit note?",skipText:"No note needed",
        info:rs(o.outstanding)+" is still to collect. If it is a rate cut, discount or damage, make a credit note in Tally; if an extra charge, a debit note. If the party pays later, choose No note needed."});
    }catch(_){}
  }
  window.LWBNote={open,check};
})();
