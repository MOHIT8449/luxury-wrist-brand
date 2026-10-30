/* LUXURY WRIST BRAND ERP — party payment popup (Billing & Outstanding, Accounts Dashboard).
   Money is received on the MAIN party of a group (Shree Jagdish Traders), split over its bills
   (oldest first, or by hand), the rest stays as advance. Database: lwb_party_group_billing_setup.sql.

   LWBPartyPay.load(client)            -> {raw, parties: Map(main party -> summary), parentOf(name)}
   LWBPartyPay.open({client, info, party, amount, mode, adjust, onSaved})
     info   : result of load()
     adjust : true = only split the advance already received (no new money) */
(function(){
  if(window.LWBPartyPay)return;
  const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const r2=n=>Math.round((Number(n)||0)*100)/100;
  const num=v=>{const n=Number(String(v==null?"":v).replace(/[,₹\s]/g,""));return Number.isFinite(n)?n:0};
  const rs=v=>(r2(v)<0?"−":"")+"₹"+Math.abs(r2(v)).toLocaleString("en-IN",{maximumFractionDigits:2});
  const key=v=>String(v==null?"":v).toUpperCase().replace(/[^A-Z0-9]+/g," ").trim();
  const dmy=d=>d?String(d).slice(8,10)+"/"+String(d).slice(5,7)+"/"+String(d).slice(0,4):"";
  const today=()=>new Date(Date.now()+330*60e3).toISOString().slice(0,10);
  const parseDmy=t=>{const m=String(t||"").trim().match(/^(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{2}|\d{4})$/);if(!m)return "";
    const y=m[3].length===2?"20"+m[3]:m[3],iso=y+"-"+m[2].padStart(2,"0")+"-"+m[1].padStart(2,"0"),d=new Date(iso+"T12:00:00Z");
    return isNaN(d)||d.toISOString().slice(0,10)!==iso?"":iso};
  const NOTES=["500","200","100","50","20","10"];
  const MODES=[["CASH","Cash",""],["UPI","UPI","UTR / ref"],["BANK","Bank / RTGS","UTR / ref"],["CHEQUE","Cheque","Cheque no."]];
  const errText=e=>{const m=String((e&&e.message)||e||"");
    if(/lwb_party_|schema cache|does not exist/i.test(m))return "Party payment is not set up yet. It sets itself up when this change is merged (lwb_party_group_billing_setup.sql).";
    return m.replace(/^.*?ERROR:\s*/,"")};

  /* ---------- data ---------- */
  async function load(client){
    const {data,error}=await client.rpc("lwb_party_billing",{p_days:400});
    if(error)throw Error(errText(error));
    const d=data||{},groups=d.groups||[],adv=d.advance||{},open=d.openings||{};
    const parentByKey=new Map(groups.map(g=>[key(g.member),g.parent]));
    const parentOf=n=>{let v=String(n||"").trim();for(let i=0;i<4;i++){const p=parentByKey.get(key(v));if(!p||key(p)===key(v))break;v=p}return v};
    const parties=new Map();
    const get=p=>{const k=key(p);if(!parties.has(k))parties.set(k,{party:p,bills:[],due:0,advance:0,opening:0,members:[],billed:0,oldest:""});return parties.get(k)};
    for(const o of d.orders||[]){
      o.parent=o.parent||parentOf(o.party);
      if(!o.invoice_no)continue;
      const due=r2(o.due);
      const x=get(o.parent);x.billed+=Number(o.bill_amount)||0;
      if(due>0.5){x.bills.push(o);x.due+=due;if(!x.oldest||String(o.invoice_date)<x.oldest)x.oldest=String(o.invoice_date||"")}
    }
    for(const [p,a] of Object.entries(adv))get(parentOf(p)).advance+=Number(a)||0;
    for(const [p,a] of Object.entries(open))get(parentOf(p)).opening+=Number(a)||0;
    for(const g of groups)get(g.parent).members.push(g.member);
    for(const x of parties.values()){
      x.bills.sort((a,b)=>String(a.invoice_date).localeCompare(String(b.invoice_date))||String(a.entered_at).localeCompare(String(b.entered_at))||String(a.order_no).localeCompare(String(b.order_no)));
      x.due=r2(x.due);x.advance=r2(x.advance);x.net=r2(x.due+x.opening-x.advance);
    }
    return {raw:d,parties,parentOf,today:d.today||today()};
  }
  const billNames=o=>(o.bills||[]).length?(o.bills||[]).map(b=>(b.firm||o.party)+" · "+b.no+((o.bills||[]).length>1?" · "+rs(b.amount):"")).join("\n"):(o.invoice_no||"");

  /* ---------- styles (once) ---------- */
  function css(){
    if(document.getElementById("lpp-css"))return;
    const s=document.createElement("style");s.id="lpp-css";
    s.textContent=`
.lpp-back{position:fixed;inset:0;background:rgba(15,23,42,.5);z-index:9000;display:flex;align-items:center;justify-content:center;padding:12px}
.lpp{background:#fff;border-radius:14px;width:min(640px,100%);max-height:calc(100dvh - 24px);display:flex;flex-direction:column;box-shadow:0 20px 50px rgba(0,0,0,.25);font-size:14px;color:#1f2a37}
.lpp header{display:flex;align-items:center;gap:10px;padding:14px 16px;border-bottom:1px solid #e3e7ed}
.lpp header h3{margin:0;font-size:17px;flex:1;line-height:1.3}
.lpp header button{border:0;background:#f1f3f6;border-radius:8px;width:36px;height:36px;font-size:18px;cursor:pointer}
.lpp .bd{padding:14px 16px;overflow:auto;display:grid;gap:12px}
.lpp footer{display:flex;gap:8px;justify-content:flex-end;padding:12px 16px;border-top:1px solid #e3e7ed;flex-wrap:wrap}
.lpp label.l{display:block;font-size:13px;font-weight:700;color:#4b5763;margin:0 0 4px}
.lpp input,.lpp select{height:40px;border:1.5px solid #d5dbe3;border-radius:8px;padding:0 10px;font:inherit;font-size:16px;width:100%;box-sizing:border-box;background:#fff}
.lpp .b{height:40px;border-radius:8px;padding:0 14px;font:inherit;font-weight:700;font-size:14px;cursor:pointer;border:1px solid #d5dbe3;background:#fff;color:#1f2a37}
.lpp .b.pri{background:#13824a;border-color:#13824a;color:#fff}.lpp .b:disabled{opacity:.55;cursor:default}
.lpp .sum{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px}
.lpp .sum div{background:#f6f8fa;border-radius:8px;padding:8px 10px}.lpp .sum small{display:block;color:#66788e;font-size:12px}.lpp .sum b{font-size:16px}
.lpp .sum .due b{color:#b3122b}.lpp .sum .adv b{color:#13824a}
.lpp .row2{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.lpp .dbx{display:flex;gap:6px;position:relative}.lpp .dbx input[type=date]{position:absolute;opacity:0;pointer-events:none;width:1px;height:1px;right:0;bottom:0}
.lpp .dbx button{flex:0 0 44px;border:1.5px solid #d5dbe3;background:#fff;border-radius:8px;cursor:pointer;font-size:18px}
.lpp .modes{display:grid;gap:8px}
.lpp .mode{display:grid;grid-template-columns:92px minmax(0,1fr) minmax(0,1fr);gap:8px;align-items:center}
.lpp .mode b{font-size:14px}
.lpp .notes{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:6px;margin:4px 0 0 100px}
.lpp .notes span{display:flex;align-items:center;gap:4px;font-size:13px}.lpp .notes input{height:34px;font-size:15px;padding:0 6px}
.lpp .lnk{border:0;background:none;color:#1769d8;font:inherit;font-weight:600;cursor:pointer;padding:0;font-size:13px}
.lpp .tot{font-size:15px;text-align:right}.lpp .tot b{font-size:18px}
.lpp .seg{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));border:1.5px solid #d5dbe3;border-radius:9px;overflow:hidden}
.lpp .seg button{border:0;border-right:1px solid #d5dbe3;background:#fff;padding:9px 6px;font:inherit;font-size:13px;font-weight:600;cursor:pointer;color:#33404d}
.lpp .seg button:last-child{border-right:0}.lpp .seg button[aria-pressed=true]{background:#14253f;color:#fff}
.lpp .seg.two{grid-template-columns:1fr 1fr}
.lpp table{width:100%;border-collapse:collapse;font-size:13px}
.lpp th,.lpp td{padding:7px 6px;border-bottom:1px solid #eef0f3;text-align:left;vertical-align:top}
.lpp th{font-size:12px;color:#4b5763;background:#f6f8fa}.lpp td.n,.lpp th.n{text-align:right;white-space:nowrap}
.lpp td small{display:block;color:#66788e;white-space:pre-line}
.lpp td input{height:34px;font-size:15px;text-align:right;width:110px}
.lpp .left{display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap;background:#f6f8fa;border-radius:8px;padding:9px 11px}
.lpp .left b.g{color:#13824a}.lpp .left b.r{color:#b3122b}
.lpp .err{background:#ffebeb;color:#9b2020;border-radius:8px;padding:9px 11px;white-space:pre-wrap}
.lpp .hint{color:#66788e;font-size:13px;margin:0}
.lpp .clist{position:absolute;left:0;right:0;top:100%;z-index:5;background:#fff;border:1px solid #d5dbe3;border-radius:8px;box-shadow:0 10px 24px rgba(0,0,0,.12);max-height:260px;overflow:auto;margin-top:2px}
.lpp .clist button{display:flex;justify-content:space-between;gap:8px;width:100%;text-align:left;border:0;border-bottom:1px solid #f0f2f5;background:#fff;padding:9px 10px;font:inherit;cursor:pointer}
.lpp .clist button.on,.lpp .clist button:hover{background:#eef4ff}.lpp .clist small{color:#66788e;white-space:nowrap}
@media(max-width:560px){.lpp-back{padding:0;align-items:flex-end}.lpp{border-radius:14px 14px 0 0;max-height:96dvh}
 .lpp .mode{grid-template-columns:72px minmax(0,1fr)}.lpp .mode input.ref{grid-column:2}.lpp .notes{margin-left:0}
 .lpp .sum b{font-size:14px}.lpp td input{width:92px}.lpp .seg button{font-size:12px}}`;
    document.head.appendChild(s);
  }

  /* ---------- popup ---------- */
  function open(o){
    css();
    const info=o.info,adjust=!!o.adjust;
    let party=o.party?info.parentOf(o.party):"",how="auto",busy=false;
    const names=(()=>{const m=new Map();
      for(const x of info.parties.values())m.set(key(x.party),x.party);
      for(const n of info.raw.parties||[]){const p=info.parentOf(n);if(!m.has(key(p)))m.set(key(p),p)}
      return [...m.values()].sort((a,b)=>{const A=info.parties.get(key(a)),B=info.parties.get(key(b));return ((B&&B.due)||0)-((A&&A.due)||0)||a.localeCompare(b)})})();
    const back=document.createElement("div");back.className="lpp-back";
    back.innerHTML=`<div class="lpp" role="dialog" aria-modal="true" aria-labelledby="lppT">
<header><h3 id="lppT"></h3><button type="button" data-x aria-label="Close">✕</button></header>
<div class="bd">
 <div style="position:relative" data-pbox><label class="l" for="lppP">Party (main party or any name it is billed in)</label>
  <input id="lppP" autocomplete="off" placeholder="Type party name" role="combobox" aria-expanded="false"><div class="clist" hidden></div></div>
 <div class="sum" data-sum></div>
 <div data-money>
  <div class="row2" style="margin-bottom:10px"><div><label class="l">Date received</label><div class="dbx"><input class="dt" inputmode="numeric" maxlength="10" placeholder="DD/MM/YYYY" aria-label="Date received"><button type="button" aria-label="Open calendar">📅</button><input type="date" tabindex="-1" aria-hidden="true"></div></div>
   <div><label class="l" for="lppR">Remark</label><input id="lppR" maxlength="300" autocomplete="off" placeholder="optional"></div></div>
  <label class="l">Money received</label>
  <div class="modes">${MODES.map(([m,t,ph])=>`<div class="mode"><b>${t}</b><input class="amt" data-m="${m}" inputmode="decimal" autocomplete="off" placeholder="₹ 0" aria-label="${t} amount">${m==="CASH"?`<button type="button" class="lnk" data-cnt>Count notes</button>`:`<input class="ref" data-r="${m}" maxlength="100" autocomplete="off" placeholder="${ph}" aria-label="${t} ${ph}">`}</div>${m==="CASH"?`<div class="notes" data-notes hidden>${NOTES.map(n=>`<span>₹${n}×<input data-n="${n}" inputmode="numeric" placeholder="0" aria-label="${n} notes"></span>`).join("")}<span>coins<input data-n="coins" inputmode="decimal" placeholder="0" aria-label="coins"></span></div>`:""}`).join("")}</div>
  <div class="tot" style="margin-top:8px">Total <b data-tot>₹0</b></div>
 </div>
 <div><label class="l">${adjust?"Adjust the advance against":"Use this money for"}</label>
  <div class="seg${adjust?" two":""}" data-how><button type="button" data-h="auto">Oldest bill first</button><button type="button" data-h="pick">Choose bills</button>${adjust?"":`<button type="button" data-h="adv">Keep as advance</button>`}</div></div>
 <div data-bills></div>
 <div class="left" data-left></div>
 <div class="err" data-err hidden></div>
</div>
<footer><button type="button" class="b" data-x>Cancel</button><button type="button" class="b pri" data-ok></button></footer></div>`;
    document.body.appendChild(back);document.body.style.overflow="hidden";
    const q=s=>back.querySelector(s),qa=s=>[...back.querySelectorAll(s)];
    const close=()=>{back.remove();document.body.style.overflow=""};
    qa("[data-x]").forEach(b=>b.onclick=close);
    back.addEventListener("keydown",e=>{if(e.key==="Escape"&&q(".clist").hidden)close()});
    q("[data-ok]").textContent=adjust?"Save adjustment":"Save payment";
    q("#lppT").textContent=adjust?"Adjust advance":"Party payment received";
    if(adjust)q("[data-money]").hidden=true;
    // date box (DD/MM/YYYY)
    const dt=q(".dt"),dp=q(".dbx input[type=date]");
    dt.value=dmy(o.date||info.today);dp.value=o.date||info.today;dp.max=info.today;
    q(".dbx button").onclick=()=>{try{dp.showPicker()}catch(_){dp.click()}};
    dp.onchange=()=>{dt.value=dmy(dp.value)};
    dt.oninput=()=>{const d=dt.value.replace(/\D/g,"");if(/^\d{8}$/.test(d)&&!dt.value.includes("/"))dt.value=d.slice(0,2)+"/"+d.slice(2,4)+"/"+d.slice(4)};
    if(o.amount)q('.amt[data-m="'+(o.mode||"CASH")+'"]').value=r2(o.amount);

    const P=()=>info.parties.get(key(party))||{party,bills:[],due:0,advance:0,opening:0,members:[]};
    const money=()=>adjust?P().advance:r2(qa(".amt").reduce((a,i)=>a+num(i.value),0));
    let manual=new Map();
    function plan(){
      const p=P(),m=money(),out=new Map();
      if(how==="adv")return out;
      if(how==="pick"){for(const b of p.bills){const v=manual.get(b.order_id);if(v>0)out.set(b.order_id,v)}return out}
      let left=adjust?p.advance:m+0;
      for(const b of p.bills){if(left<0.01)break;const t=Math.min(r2(b.due),left);out.set(b.order_id,r2(t));left=r2(left-t)}
      return out;
    }
    function drawSum(){
      const p=P();
      q("[data-sum]").innerHTML=party?`<div class="due"><small>Bills due (${p.bills.length})</small><b>${rs(p.due)}</b></div><div class="adv"><small>Advance with us</small><b>${rs(p.advance)}</b></div><div><small>To collect${p.opening?" (incl. opening)":""}</small><b>${rs(p.due+(p.opening||0)-p.advance)}</b></div>`:"";
      q("[data-sum]").hidden=!party;
    }
    function drawBills(){
      const p=P(),pl=plan(),box=q("[data-bills]");
      if(!party){box.innerHTML='<p class="hint">Choose the party to see its bills.</p>';return}
      if(!p.bills.length){box.innerHTML='<p class="hint">No bill is due for this party'+(adjust?".":" — the money stays as advance and is adjusted when the next bill is made.")+'</p>';return}
      box.innerHTML=`<div style="overflow:auto;max-height:300px"><table><thead><tr><th>PO / bill</th><th class="n">Due</th><th class="n">${how==="pick"?"Take now":"Goes to bill"}</th></tr></thead><tbody>${p.bills.map(b=>{
        const v=pl.get(b.order_id)||0;
        return `<tr><td><b>${esc(b.order_no)}</b> · ${dmy(b.invoice_date)}<small>${esc(billNames(b))}</small></td><td class="n">${rs(b.due)}</td><td class="n">${how==="pick"?`<input data-o="${esc(b.order_id)}" inputmode="decimal" value="${v?r2(v):""}" placeholder="0" aria-label="Amount for ${esc(b.order_no)}"><br><button type="button" class="lnk" data-full="${esc(b.order_id)}">full</button>`:(v?"<b>"+rs(v)+"</b>":"—")}</td></tr>`}).join("")}</tbody></table></div>`;
      box.querySelectorAll("[data-o]").forEach(i=>i.oninput=()=>{manual.set(i.dataset.o,num(i.value));drawLeft()});
      box.querySelectorAll("[data-full]").forEach(b=>b.onclick=()=>{const x=p.bills.find(y=>y.order_id===b.dataset.full);manual.set(x.order_id,r2(x.due));drawBills()});
    }
    function drawLeft(){
      const m=money(),split=r2([...plan().values()].reduce((a,v)=>a+v,0)),left=r2(m-split);
      q("[data-tot]").textContent=rs(m);
      q("[data-left]").innerHTML=adjust?`<span>Advance ${rs(m)}</span><span>Adjusted now <b>${rs(split)}</b></span><span>Advance left <b class="${left<-0.5?"r":"g"}">${rs(left)}</b></span>`:
        `<span>Against bills <b>${rs(split)}</b></span><span>${left<-0.5?"More than received":"Stays as advance"} <b class="${left<-0.5?"r":"g"}">${rs(Math.abs(left))}</b></span>`;
    }
    function drawAll(){drawSum();qa("[data-h]").forEach(b=>b.setAttribute("aria-pressed",String(b.dataset.h===how)));drawBills();drawLeft()}
    qa("[data-h]").forEach(b=>b.onclick=()=>{if(b.dataset.h==="pick"&&!manual.size){how="auto";manual=new Map(plan())}how=b.dataset.h;drawAll()});
    qa(".amt").forEach(i=>i.oninput=()=>{if(how==="auto")drawBills();drawLeft()});
    // cash note count
    const cnt=q("[data-cnt]"),notes=q("[data-notes]");
    cnt.onclick=()=>{notes.hidden=!notes.hidden;if(!notes.hidden)notes.querySelector("input").focus()};
    const readNotes=()=>{const n={};notes.querySelectorAll("[data-n]").forEach(i=>{const v=num(i.value);if(v>0)n[i.dataset.n]=i.dataset.n==="coins"?r2(v):Math.floor(v)});return n};
    notes.querySelectorAll("[data-n]").forEach(i=>i.oninput=()=>{const n=readNotes(),t=Object.entries(n).reduce((a,[k,v])=>a+(k==="coins"?v:Number(k)*v),0);
      q('.amt[data-m="CASH"]').value=t?r2(t):"";cnt.textContent=t?"Notes: "+rs(t):"Count notes";if(how==="auto")drawBills();drawLeft()});
    // party combobox
    const pin=q("#lppP"),list=q(".clist");let shown=[],hi=0;
    pin.value=party;
    if(o.party&&o.lockParty){pin.disabled=true}
    function drawList(){const v=key(pin.value);shown=names.filter(n=>!v||key(n).includes(v)||(info.parties.get(key(n))||{members:[]}).members.some(m=>key(m).includes(v))).slice(0,40);hi=0;
      list.innerHTML=shown.map((n,i)=>{const x=info.parties.get(key(n));return `<button type="button" data-i="${i}"${i?"":' class="on"'}><span>${esc(n)}${x&&x.members.length?`<small style="display:block">${esc(x.members.slice(0,4).join(", "))}${x.members.length>4?" …":""}</small>`:""}</span><small>${x&&x.due?"due "+rs(x.due):""}${x&&x.advance?" · adv "+rs(x.advance):""}</small></button>`}).join("")||'<p class="hint" style="padding:9px">Not in the Party Master</p>';
      list.hidden=false;list.querySelectorAll("[data-i]").forEach(b=>b.onmousedown=e=>{e.preventDefault();pick(shown[Number(b.dataset.i)])})}
    function pick(n){party=n;pin.value=n;list.hidden=true;manual=new Map();drawAll()}
    pin.onfocus=drawList;pin.oninput=()=>{party="";drawList();drawAll()};
    pin.onblur=()=>setTimeout(()=>{list.hidden=true;if(!party&&pin.value.trim()){const p=info.parentOf(pin.value.trim());const m=names.find(n=>key(n)===key(p));if(m)pick(m)}},150);
    pin.onkeydown=e=>{if(list.hidden)return;if(e.key==="ArrowDown"||e.key==="ArrowUp"){e.preventDefault();hi=Math.max(0,Math.min(shown.length-1,hi+(e.key==="ArrowDown"?1:-1)));list.querySelectorAll("[data-i]").forEach((b,i)=>b.classList.toggle("on",i===hi))}
      else if(e.key==="Enter"){e.preventDefault();if(shown[hi])pick(shown[hi])}else if(e.key==="Escape"){e.stopPropagation();list.hidden=true}};
    if(adjust)q("[data-pbox]").hidden=!!party;

    q("[data-ok]").onclick=async()=>{
      if(busy)return;const err=q("[data-err]");err.hidden=true;
      const fail=t=>{err.textContent=t;err.hidden=false;err.scrollIntoView({block:"nearest"})};
      if(!party)return fail("Choose the party.");
      const pl=plan(),allocs=[...pl].filter(([,v])=>v>0).map(([id,v])=>({order_id:id,amount:r2(v)}));
      const split=allocs.reduce((a,x)=>a+x.amount,0);
      let args;
      if(adjust){
        if(!allocs.length)return fail("Nothing to adjust.");
        if(split>P().advance+0.5)return fail("Adjusted "+rs(split)+" is more than the advance "+rs(P().advance)+".");
        args=["lwb_party_adjust",{p_party:party,p_allocs:how==="auto"?null:allocs}];
      }else{
        const date=parseDmy(dt.value);if(!date)return fail("Enter the date as DD/MM/YYYY.");
        if(date>info.today)return fail("The date can not be after today.");
        const lines=[];
        for(const [m,t] of MODES){const a=num(q('.amt[data-m="'+m+'"]').value);if(!a)continue;if(a<0)return fail(t+": amount can not be less than zero.");
          const l={mode:m,amount:r2(a)};
          if(m==="CASH"){const n=readNotes();if(Object.keys(n).length&&!notes.hidden)l.notes=n}
          else{l.ref=q('[data-r="'+m+'"]').value.trim();if(m==="CHEQUE"&&!l.ref)return fail("Enter the cheque number.")}
          lines.push(l)}
        if(!lines.length)return fail("Enter the money received (Cash / UPI / Bank / Cheque).");
        const m=money();if(split>m+0.5)return fail("Bills "+rs(split)+" is more than the money received "+rs(m)+".");
        const cash=lines.filter(l=>l.mode==="CASH").reduce((a,l)=>a+l.amount,0);
        if(cash>=200000)return fail("Cash of ₹2 lakh or more in one receipt is not allowed (Income Tax 269ST). Split it into Bank / UPI.");
        args=["lwb_party_receive",{p_party:party,p_pay_date:date,p_lines:lines,p_allocs:how==="auto"?null:how==="adv"?[]:allocs,p_remark:q("#lppR").value.trim()||null}];
      }
      busy=true;q("[data-ok]").disabled=true;
      try{
        const {data,error}=await o.client.rpc(args[0],args[1]);
        if(error)throw error;
        close();
        if(o.onSaved)o.onSaved(data||{});
      }catch(e){fail(errText(e))}
      finally{busy=false;q("[data-ok]").disabled=false}
    };
    drawAll();
    setTimeout(()=>{(party?(adjust?q("[data-ok]"):q('.amt[data-m="'+(o.mode||"CASH")+'"]')):pin).focus()},60);
    return {close};
  }
  window.LWBPartyPay={load,open,billNames,key,rs,dmy,errText};
})();
