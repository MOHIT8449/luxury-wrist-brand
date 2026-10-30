/* Payment Collection popup for one PO's Tally bill: money the party paid, split over Cash / UPI / Bank / Cheque.
   Cash is entered as notes (500 x count ...) and adds up by itself. What is left stays as the party's outstanding.
   LWBPay.open({db, order:{id, order_no, party, invoice_no}, due, onSaved})
   Saves with lwb_save_tally_payment (lwb_party_payment_collection_setup.sql). Accounts / Admin only. */
(function(){
  "use strict";
  const esc=v=>String(v??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const today=()=>new Date(Date.now()+330*60e3).toISOString().slice(0,10);
  const rs=n=>"₹"+Number(n||0).toLocaleString("en-IN",{minimumFractionDigits:2,maximumFractionDigits:2});
  const NOTES=["500","200","100","50","20","10"];
  const MODES={CASH:"Cash",UPI:"UPI",BANK:"Bank",CHEQUE:"Cheque"};
  const REF={UPI:"UPI ref / UTR (optional)",BANK:"Bank UTR / ref (optional)",CHEQUE:"Cheque no."};
  const CSS=`.lwbp-ov{position:fixed;inset:0;background:#101827aa;display:flex;align-items:center;justify-content:center;padding:16px;z-index:4800}
.lwbp{background:#fff;color:#182a42;width:min(560px,100%);max-height:94vh;overflow:auto;border-radius:12px;font:14px/1.5 Arial,sans-serif;box-shadow:0 18px 50px #0005}
.lwbp h3{margin:0;padding:15px 18px;background:#14253f;color:#fff;font-size:16px}
.lwbp .b{padding:16px 18px;display:grid;gap:12px}
.lwbp p{margin:0;color:#4c5f76;font-size:13px}
.lwbp label{display:block;font-size:11px;color:#657992;text-transform:uppercase;margin-bottom:4px}
.lwbp input,.lwbp select{width:100%;box-sizing:border-box;padding:9px;border:1px solid #c2cedf;border-radius:7px;font:14px Arial;background:#fff}
.lwbp .two{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.lwbp .ln{border:1px solid #d5e0ee;border-radius:9px;padding:11px;display:grid;gap:9px;background:#f7faff}
.lwbp .lh{display:flex;gap:8px;align-items:center}
.lwbp .lh select{flex:1}
.lwbp .lh .x{background:#e7edf5;color:#a02c2c;border:0;border-radius:7px;padding:8px 11px;font-weight:bold;cursor:pointer}
.lwbp .nt{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:7px}
.lwbp .nt input{padding:7px;text-align:right}
.lwbp .ct{font-size:13px;color:#16603b;font-weight:bold;text-align:right}
.lwbp .add{background:none;border:0;color:#1769d8;font-weight:bold;cursor:pointer;padding:2px 0;justify-self:start}
.lwbp .sum{display:grid;grid-template-columns:1fr auto;gap:3px 12px;background:#eef3fa;border-radius:9px;padding:11px 13px;font-size:14px}
.lwbp .sum b{text-align:right;font-variant-numeric:tabular-nums}
.lwbp .sum .left{color:#a02c2c}.lwbp .sum .ok{color:#16603b}
.lwbp .f{display:flex;gap:9px;justify-content:flex-end;padding:0 18px 16px}
.lwbp .f button{padding:10px 16px;border:0;border-radius:7px;font-weight:bold;cursor:pointer;background:#e7edf5;color:#23384f}
.lwbp .f .go{background:#157a48;color:#fff}
.lwbp .f button:disabled{opacity:.55;cursor:not-allowed}
.lwbp .e{color:#a02c2c;font-size:13px;min-height:1px}
@media(max-width:480px){.lwbp .nt{grid-template-columns:repeat(2,minmax(0,1fr))}.lwbp .two{grid-template-columns:1fr}}`;
  function open(o){
    if(!document.getElementById("lwbp-css")){const s=document.createElement("style");s.id="lwbp-css";s.textContent=CSS;document.head.appendChild(s)}
    const ord=o.order||{},due=Number(o.due||0);
    const ov=document.createElement("div");ov.className="lwbp-ov";
    ov.innerHTML=`<div class="lwbp" role="dialog" aria-modal="true" aria-labelledby="lwbpT">
      <h3 id="lwbpT">Payment collection</h3>
      <div class="b">
        <p><b>${esc(ord.party)}</b> · PO ${esc(ord.order_no)}${ord.invoice_no?" · Tally bill "+esc(ord.invoice_no):""}</p>
        <div class="two"><div><label for="lwbpDate">Payment date</label><input id="lwbpDate" type="date"></div>
        <div><label for="lwbpRem">Remark (optional)</label><input id="lwbpRem" maxlength="300" autocomplete="off" placeholder="e.g. paid at shop"></div></div>
        <div id="lwbpLines" style="display:grid;gap:9px"></div>
        <button type="button" class="add" id="lwbpAdd">+ Add another mode (split payment)</button>
        <div class="sum"><span>Money due now</span><b>${rs(due)}</b><span>Received now</span><b id="lwbpGot">${rs(0)}</b><span id="lwbpLeftL">Left (party outstanding)</span><b id="lwbpLeft" class="left">${rs(due)}</b></div>
        <div class="e" id="lwbpErr"></div>
      </div>
      <div class="f"><button type="button" data-x>Close</button><button type="button" class="go" data-save>Save payment</button></div></div>`;
    document.body.appendChild(ov);
    const q=s=>ov.querySelector(s),lines=q("#lwbpLines");
    q("#lwbpDate").value=today();
    const used=()=>[...lines.children].map(l=>l.querySelector("select").value);
    const lineTotal=l=>{
      if(l.querySelector("select").value!=="CASH")return Number(l.querySelector(".am").value)||0;
      return NOTES.reduce((a,n)=>a+Number(n)*(Math.floor(Number(l.querySelector('[data-n="'+n+'"]').value)||0)),0)+(Number(l.querySelector('[data-n="coins"]').value)||0);
    };
    const total=()=>{
      let got=0;
      for(const l of lines.children){const t=lineTotal(l);got+=t;const c=l.querySelector(".ct");if(c)c.textContent="Cash total "+rs(t)}
      got=Math.round(got*100)/100;
      const left=Math.round((due-got)*100)/100;
      q("#lwbpGot").textContent=rs(got);
      q("#lwbpLeft").textContent=rs(Math.abs(left));
      q("#lwbpLeftL").textContent=left< -0.5?"More than due by":"Left (party outstanding)";
      q("#lwbpLeft").className=left>0.5||left< -0.5?"left":"ok";
      q("#lwbpAdd").hidden=lines.children.length>=4;
      return got;
    };
    const fill=(l,mode)=>{
      const body=l.querySelector(".lb");
      body.innerHTML=mode==="CASH"
        ?'<div class="nt">'+NOTES.map(n=>'<div><label>₹'+n+' notes</label><input data-n="'+n+'" type="number" min="0" step="1" inputmode="numeric" placeholder="0"></div>').join("")+
          '<div><label>Coins ₹</label><input data-n="coins" type="number" min="0" step="0.01" inputmode="decimal" placeholder="0"></div></div><div class="ct"></div>'
        :'<div class="two"><div><label>Amount ₹</label><input class="am" type="number" min="0.01" step="0.01" inputmode="decimal"></div>'+
          '<div><label>'+REF[mode]+'</label><input class="rf" maxlength="100" autocomplete="off"></div></div>';
      body.querySelectorAll("input").forEach(i=>i.addEventListener("input",total));
      total();
    };
    const add=mode=>{
      const l=document.createElement("div");l.className="ln";
      l.innerHTML='<div class="lh"><select aria-label="Payment mode">'+Object.entries(MODES).map(([k,v])=>'<option value="'+k+'">'+v+'</option>').join("")+'</select><button type="button" class="x" aria-label="Remove this mode">×</button></div><div class="lb"></div>';
      const sel=l.querySelector("select");sel.value=mode;
      sel.onchange=()=>{if(used().filter(m=>m===sel.value).length>1){q("#lwbpErr").textContent=MODES[sel.value]+" is already added.";sel.value=sel.dataset.was;return}q("#lwbpErr").textContent="";sel.dataset.was=sel.value;fill(l,sel.value)};
      sel.dataset.was=mode;
      l.querySelector(".x").onclick=()=>{if(lines.children.length>1){l.remove();total()}};
      lines.appendChild(l);fill(l,mode);return l;
    };
    add("CASH");
    q("#lwbpAdd").onclick=()=>{const m=Object.keys(MODES).find(k=>!used().includes(k));if(m)add(m)};
    const close=()=>{ov.remove();document.removeEventListener("keydown",esc_)};
    const esc_=e=>{if(e.key==="Escape")close()};
    document.addEventListener("keydown",esc_);
    q("[data-x]").onclick=close;
    q("[data-save]").onclick=async()=>{
      const err=q("#lwbpErr"),dt=q("#lwbpDate").value;
      const out=[],shown=[];
      for(const l of lines.children){
        const mode=l.querySelector("select").value,amt=lineTotal(l);
        if(!(amt>0))continue;
        if(mode==="CASH"){
          const notes={};
          for(const n of [...NOTES,"coins"]){const v=Number(l.querySelector('[data-n="'+n+'"]').value)||0;if(v<0||(n!=="coins"&&v!==Math.floor(v))){err.textContent="Check the count of ₹"+n+" notes.";return}if(v>0)notes[n]=v}
          out.push({mode,notes});shown.push("Cash "+rs(amt));
        }else{
          const ref=l.querySelector(".rf").value.trim();
          if(mode==="CHEQUE"&&!ref){err.textContent="Enter the cheque number.";return}
          out.push({mode,amount:Math.round(amt*100)/100,ref});shown.push(MODES[mode]+" "+rs(amt)+(ref?" ("+ref+")":""));
        }
      }
      const got=total();
      if(!out.length){err.textContent="Enter the money received (cash notes or amount).";return}
      if(!dt){err.textContent="Enter the payment date.";return}
      if(got>due+1){err.textContent="Received "+rs(got)+" is more than the money due "+rs(due)+".";return}
      const left=Math.max(0,Math.round((due-got)*100)/100);
      if(!await confirm("Save payment of "+rs(got)+" from "+ord.party+"?\n\n"+shown.join("\n")+
        "\n\n"+(left>0.5?rs(left)+" stays as the party's outstanding.":"The bill is fully paid.")))return;
      const btn=q("[data-save]");btn.disabled=true;err.textContent="";
      try{
        const {error}=await o.db.rpc("lwb_save_tally_payment",{p_order_id:ord.id,p_pay_date:dt,p_lines:out,p_remark:q("#lwbpRem").value.trim()||null});
        if(error)throw error;
        close();
        if(o.onSaved)o.onSaved({amount:got,left});
      }catch(e){
        err.textContent=/lwb_save_tally_payment|schema cache|function/i.test(e.message)?"Not set up yet: run lwb_party_payment_collection_setup.sql once in Supabase.":e.message;
        btn.disabled=false;
      }
    };
    setTimeout(()=>{const i=lines.querySelector("input");if(i)i.focus()},30);
    return {close};
  }
  window.LWBPay={open};
})();
