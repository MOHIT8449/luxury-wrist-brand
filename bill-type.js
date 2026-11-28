/* LUXURY WRIST BRAND ERP — GST or CASH bill on every PO (lwb_order_bill_type_setup.sql, Mohit 28 Nov 2026)
   LWBBillType.load(client, ids)        -> Map(order_id -> {bill_type, bill_made_as, bill_note, set_by, party_default, required})
   LWBBillType.tag(type, extra)         -> badge html: blue "GST" / amber "CASH" / red "GST / Cash not set"
   LWBBillType.kindOf(row)              -> the kind the bill is (made as, else as set on the PO)
   LWBBillType.payCheck({client, bills:[{order_id, order_no, party, amount}], lines:[{mode, amount}]})
        -> true = go on and save (mismatch recorded with the reason picked), false = go back and change the mode
   LWBBillType.askReason({title, html, placeholder, ok}) -> reason text or null
   Rule: GST bill = Bank / UPI / Cheque; Cash bill = Cash. */
(function(){
  if(window.LWBBillType)return;
  const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const r2=n=>Math.round((Number(n)||0)*100)/100;
  const rs=v=>"₹"+Math.abs(r2(v)).toLocaleString("en-IN",{maximumFractionDigits:2});
  const MODE={CASH:"Cash",UPI:"UPI",BANK:"Bank",CHEQUE:"Cheque",OTHER:"Other"};
  const CSS=`.lbt{display:inline-flex;align-items:center;gap:3px;font-weight:800;font-size:11.5px;line-height:1;padding:3px 8px;border-radius:99px;letter-spacing:.3px;white-space:nowrap;vertical-align:middle}
.lbt.g{background:#dbeafe;color:#1d4ed8;border:1px solid #93c5fd}.lbt.c{background:#fef3c7;color:#92400e;border:1px solid #fcd34d}
.lbt.n{background:#fee2e2;color:#b91c1c;border:1px solid #fca5a5}.lbt.m{background:#fff;color:#64748b;border:1px dashed #cbd5e1;font-weight:700}
/* z-index 9600: above the Party payment popup (9000), else the mode popup opens hidden behind it and Save stays grey (Mohit 28 Nov 2026) */
.lbt-ov{position:fixed;inset:0;background:#0f1923aa;display:flex;align-items:center;justify-content:center;padding:16px;z-index:9600}
.lbt-d{box-sizing:border-box;background:#fff;color:#17212b;width:min(470px,100%);max-height:94vh;overflow:auto;border-radius:12px;padding:14px 16px;font:14px/1.4 system-ui,Segoe UI,Arial,sans-serif;box-shadow:0 18px 50px #0006}
.lbt-d h3{margin:0 0 8px;font-size:17px}.lbt-d p{margin:6px 0;color:#4b5763;font-size:13px}
.lbt-cmp{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:8px;margin:8px 0}.lbt-cmp>div{border:1px solid #e3e0d7;border-radius:8px;padding:7px 9px}
.lbt-cmp small{display:block;font-size:11px;font-weight:700;color:#6b7682;margin-bottom:3px}.lbt-cmp b{display:block;font-size:16px;margin-top:3px}
.lbt-rows{margin:8px 0;border:1px solid #e3e0d7;border-radius:8px}.lbt-rows div{display:flex;gap:6px;align-items:center;padding:6px 8px;border-top:1px solid #f0ede6;flex-wrap:wrap}
.lbt-rows div:first-child{border-top:0}.lbt-rows span.a{margin-left:auto;font-weight:800}
.lbt-note{background:#fff8e6;border-left:3px solid #f59e0b;padding:5px 8px;border-radius:6px;font-size:12.5px;margin:6px 0}
.lbt-d label{display:block;font-size:12px;font-weight:700;color:#3d4853;margin:8px 0 3px}
.lbt-d select,.lbt-d input{width:100%;box-sizing:border-box;font:inherit;border:1px solid #cfd6de;border-radius:8px;padding:8px 9px;background:#fff}
.lbt-f{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}.lbt-f button{flex:1 1 auto;white-space:normal;border:0;border-radius:8px;padding:9px 12px;font:inherit;font-weight:700;cursor:pointer}
.lbt-f .p{background:#1d6fd6;color:#fff}.lbt-f .s{background:#fff;border:1px solid #cfd6de;color:#17212b}.lbt-f .r{background:#b91c1c;color:#fff}
.lbt-err{color:#b91c1c;font-size:12.5px;font-weight:700;margin-top:6px}
.lbt-two{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:10px;margin:10px 0 4px}
.lbt-big{display:flex;flex-direction:column;align-items:center;gap:3px;border:2px solid #cfd6de;background:#fff;border-radius:12px;padding:14px 8px;cursor:pointer;font:inherit;color:#17212b}
.lbt-big span{font-size:26px;line-height:1}.lbt-big b{font-size:15px}.lbt-big small{font-size:11px;font-weight:700;color:#6b7682}
.lbt-big.g:hover,.lbt-big.g.on{border-color:#1d4ed8;background:#eff5ff}.lbt-big.g b{color:#1d4ed8}
.lbt-big.c:hover,.lbt-big.c.on{border-color:#d97706;background:#fff8eb}.lbt-big.c b{color:#92400e}
.lbt-big:focus-visible{outline:3px solid #0f3b3a;outline-offset:2px}
.lbt-chk{display:flex!important;align-items:center;gap:7px;font-weight:600!important;color:#4b5763!important;margin:8px 0 0!important}.lbt-chk input{width:auto}
.lbt-sum{display:flex;flex-wrap:wrap;gap:4px 12px;font-size:13px;color:#4b5763}.lbt-sum b{color:#17212b}`;
  let styled=false;
  const css=()=>{if(styled)return;styled=true;const s=document.createElement("style");s.textContent=CSS;document.head.appendChild(s)};

  async function load(client,ids){
    const m=new Map(),list=[...new Set((ids||[]).filter(Boolean))];
    for(let i=0;i<list.length;i+=150){
      const {data,error}=await client.rpc("lwb_order_bill_types",{p_ids:list.slice(i,i+150)});
      if(error)return m; // setup not run yet = no GST / Cash anywhere, pages work as before
      for(const r of data||[])m.set(r.order_id,r);
    }
    return m;
  }
  const kindOf=r=>r?(r.bill_made_as||r.bill_type||null):null;
  function tag(type,extra){css();
    const t=String(type||"").toUpperCase();
    if(t==="GST")return `<span class="lbt g" title="GST bill">🧾 GST${extra?" "+esc(extra):""}</span>`;
    if(t==="CASH")return `<span class="lbt c" title="Cash bill">💵 CASH${extra?" "+esc(extra):""}</span>`;
    return `<span class="lbt n" title="Sales Head / Admin has not chosen GST or Cash">⚠ GST / Cash not set</span>`;
  }
  const isCashMode=m=>String(m||"").toUpperCase()==="CASH";

  function dialog(html){css();
    const ov=document.createElement("div");ov.className="lbt-ov";ov.innerHTML=`<div class="lbt-d" role="dialog" aria-modal="true">${html}</div>`;
    // keep it inside the visible screen even when the page is a little wider than the phone
    const vw=window.visualViewport?Math.round(visualViewport.width):innerWidth;if(vw<innerWidth-1){ov.style.right="auto";ov.style.width=vw+"px"}
    document.body.appendChild(ov);return ov}

  // Reason box (bill made as the other kind, change after the bill ...). Resolves the text, or null.
  function askReason(o){
    return new Promise(res=>{
      const ov=dialog(`<h3>${esc(o.title||"Reason")}</h3>${o.html||""}<label for="lbtR">Reason (required)</label>
        <input id="lbtR" maxlength="300" autocomplete="off" placeholder="${esc(o.placeholder||"")}"><div class="lbt-err" hidden></div>
        <div class="lbt-f">${o.back?`<button type="button" class="p" data-b>${esc(o.back)}</button>`:""}<button type="button" class="${o.back?"r":"p"}" data-ok>${esc(o.ok||"Save")}</button><button type="button" class="s" data-x>Cancel</button></div>`);
      const q=s=>ov.querySelector(s),inp=q("#lbtR");
      const done=v=>{ov.remove();document.removeEventListener("keydown",key,true);res(v)};
      const key=e=>{if(e.key==="Escape"){e.stopPropagation();e.preventDefault();done(null)}};
      document.addEventListener("keydown",key,true);
      q("[data-x]").onclick=()=>done(null);
      if(o.back)q("[data-b]").onclick=()=>done({back:true});
      q("[data-ok]").onclick=()=>{const v=inp.value.trim();if(v.length<3){const e=q(".lbt-err");e.textContent="Write the reason (3 letters or more).";e.hidden=false;inp.focus();return}done(v)};
      inp.onkeydown=e=>{if(e.key==="Enter"){e.preventDefault();q("[data-ok]").click()}};
      setTimeout(()=>inp.focus(),30);
    });
  }

  // Payment against bills: mode must match the kind of the bill. Mismatch = popup, recorded with the reason, bell.
  async function payCheck(o){
    const bills=(o.bills||[]).filter(b=>b&&b.order_id&&Number(b.amount)>0.005);
    const lines=(o.lines||[]).filter(l=>Number(l.amount)>0.005||l.mode==="CASH");
    if(!bills.length||!lines.length)return true;
    let types;try{types=await load(o.client,bills.map(b=>b.order_id))}catch(e){return true}
    const cash=lines.filter(l=>isCashMode(l.mode)),other=lines.filter(l=>!isCashMode(l.mode));
    const rows=[];
    for(const b of bills){const k=kindOf(types.get(b.order_id));if(!k)continue;
      if(k==="GST"&&cash.length)rows.push({...b,kind:k,mode:"CASH"});
      if(k==="CASH"&&other.length)for(const l of other)rows.push({...b,kind:k,mode:String(l.mode).toUpperCase()});
    }
    if(!rows.length)return true;
    const sum=a=>r2(a.reduce((t,l)=>t+(Number(l.amount)||0),0));
    const one=rows.length===1?rows[0]:null;
    const payAmt=one?(isCashMode(one.mode)?sum(cash):sum(other.filter(l=>String(l.mode).toUpperCase()===one.mode))):0;
    const body=one?`<div class="lbt-cmp"><div><small>BILL ${esc(one.no||one.order_no||"")}</small>${tag(one.kind)}<b>${rs(one.amount)}</b></div>
        <div><small>PAYMENT</small>${isCashMode(one.mode)?`<span class="lbt c">💵 CASH</span>`:`<span class="lbt g">${esc(MODE[one.mode]||one.mode).toUpperCase()}</span>`}<b>${rs(payAmt||one.amount)}</b></div></div>`
      :`<div class="lbt-rows">${rows.map(r=>`<div><b>${esc(r.no||r.order_no||"")}</b>${tag(r.kind)}<span>←</span>${isCashMode(r.mode)?`<span class="lbt c">💵 CASH</span>`:`<span class="lbt g">${esc((MODE[r.mode]||r.mode).toUpperCase())}</span>`}<span class="a">${rs(r.amount)}</span></div>`).join("")}</div>`;
    const why=["Party paid this way only (it is OK)","Wrong mode chosen, I will change it","Bill was made as the wrong kind (Admin to check)","Other"];
    return new Promise(res=>{
      const ov=dialog(`<h3>⚠ Payment mode not matching the bill</h3>${body}
        <p>GST bill = Bank / UPI / Cheque. Cash bill = Cash.</p>
        <label for="lbtW">What happened? *</label><select id="lbtW">${why.map(w=>`<option>${esc(w)}</option>`).join("")}</select>
        <input id="lbtO" maxlength="250" placeholder="Write what happened" hidden style="margin-top:6px">
        <div class="lbt-err" hidden></div>
        <div class="lbt-f"><button type="button" class="p" data-ok>Save + tell Admin / Sales Head</button><button type="button" class="s" data-b>Change mode</button></div>`);
      const q=s=>ov.querySelector(s),sel=q("#lbtW"),oth=q("#lbtO"),err=q(".lbt-err");
      const done=v=>{ov.remove();document.removeEventListener("keydown",key,true);res(v)};
      const key=e=>{if(e.key==="Escape"){e.stopPropagation();e.preventDefault();done(false)}};
      document.addEventListener("keydown",key,true);
      sel.onchange=()=>{oth.hidden=sel.value!=="Other";q("[data-ok]").textContent=sel.selectedIndex===1?"Go back and change":"Save + tell Admin / Sales Head";if(!oth.hidden)oth.focus()};
      q("[data-b]").onclick=()=>done(false);
      q("[data-ok]").onclick=async()=>{
        if(sel.selectedIndex===1)return done(false);
        const reason=sel.value==="Other"?oth.value.trim():sel.value;
        if(!reason||reason.length<3){err.textContent="Write what happened.";err.hidden=false;return}
        const b=q("[data-ok]");b.disabled=true;
        const {error}=await o.client.rpc("lwb_bill_pay_mismatch",{p_rows:rows.map(r=>({order_id:r.order_id,mode:r.mode,amount:r2(r.amount)})),p_reason:reason});
        if(error&&!/lwb_bill_pay_mismatch|schema cache|does not exist/i.test(error.message||"")){b.disabled=false;err.textContent="Not saved: "+error.message;err.hidden=false;return}
        done(true)};
      setTimeout(()=>sel.focus(),30);
    });
  }

  // Approve popup (Mohit, 28 Nov 2026): every Approve asks GST or Cash first.
  // choose({title, html, note, current, def, canDefault, okWord}) -> {type, setDefault} or null (Cancel)
  function choose(o){
    return new Promise(res=>{
      const pre=String(o.current||o.def||"").toUpperCase();
      const btn=(t,ic,txt)=>`<button type="button" class="lbt-big ${t==="GST"?"g":"c"}${pre===t?" on":""}" data-t="${t}"><span>${ic}</span><b>${esc(o.okWord||"Approve as")} ${txt}</b>${pre===t?`<small>${o.current?"chosen before":"party default"}</small>`:""}</button>`;
      const ov=dialog(`<h3>${esc(o.title||"GST or Cash bill?")}</h3>${o.html||""}${o.note?`<div class="lbt-note">📝 Salesman note: ${esc(o.note)}</div>`:""}
        <div class="lbt-two">${btn("GST","🧾","GST")}${btn("CASH","💵","Cash")}</div>
        ${o.canDefault?`<label class="lbt-chk"><input type="checkbox" id="lbtDef"> Make it this party's default bill</label>`:""}
        <div class="lbt-f"><button type="button" class="s" data-x>Cancel</button></div>`);
      const q=s=>ov.querySelector(s);
      const done=v=>{ov.remove();document.removeEventListener("keydown",key,true);res(v)};
      const key=e=>{if(e.key==="Escape"){e.stopPropagation();e.preventDefault();done(null)}
        else if(e.key==="g"||e.key==="G"){e.preventDefault();ov.querySelector('[data-t="GST"]').click()}
        else if(e.key==="c"||e.key==="C"){e.preventDefault();ov.querySelector('[data-t="CASH"]').click()}};
      document.addEventListener("keydown",key,true);
      q("[data-x]").onclick=()=>done(null);
      ov.querySelectorAll("[data-t]").forEach(b=>b.onclick=()=>done({type:b.dataset.t,setDefault:!!(q("#lbtDef")&&q("#lbtDef").checked)}));
      setTimeout(()=>{const f=ov.querySelector(".lbt-big.on")||ov.querySelector(".lbt-big");if(f)f.focus()},30);
    });
  }

  window.LWBBillType={load,tag,kindOf,payCheck,askReason,choose,esc};
})();
