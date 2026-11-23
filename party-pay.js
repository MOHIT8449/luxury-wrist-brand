/* LUXURY WRIST BRAND ERP — party payment popup (Billing & Outstanding, Accounts Dashboard).
   Money is received on the MAIN party of a group (Shree Jagdish Traders), split over its bills
   (oldest first, or by hand), the rest stays as advance. Database: lwb_party_group_billing_setup.sql.

   LWBPartyPay.load(client)            -> {raw, parties: Map(main party -> summary), parentOf(name)}
   LWBPartyPay.open({client, info, party, amount, mode, adjust, onSaved})
     info   : result of load()
     adjust : true = only split the advance already received (no new money)
     brand  : company id to start with (Rajnigandha / Coca-Cola). Money of one brand goes only to that
              brand's bills; its advance and opening stay with that brand (lwb_brand_money_setup.sql).
   info.parties: x.brands[companyId | ""] = {bills, due, advance, opening, net, oldest}  ("" = no brand) */
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
    if(/lwb_party_receive_kasar|lwb_kasar_/i.test(m)&&/schema cache|does not exist|Could not find/i.test(m))return "Kasar is being set up (lwb_kasar_setup.sql). Save without the kasar tick, or try again in a few minutes.";
    if(/lwb_party_|schema cache|does not exist/i.test(m))return "Party payment is not set up yet. It sets itself up when this change is merged (lwb_party_group_billing_setup.sql).";
    return m.replace(/^.*?ERROR:\s*/,"")};

  /* ---------- data ---------- */
  async function load(client){
    // Goods returns (lwb_party_return_setup.sql); missing function = none, as before.
    const [{data,error},rt,dl]=await Promise.all([client.rpc("lwb_party_billing",{p_days:400}),client.rpc("lwb_party_return_list",{p_days:400}).then(r=>r,()=>({error:1})),
      client.rpc("lwb_receipt_date_log_list",{p_days:400}).then(r=>r,()=>({error:1}))]);
    if(error)throw Error(errText(error));
    // date changes of receipts (lwb_receipt_date_change_setup.sql); missing function = none
    if(dl&&!dl.error&&Array.isArray(dl.data)&&data&&Array.isArray(data.receipts)){
      const m=new Map();for(const x of dl.data){if(!m.has(x.receipt_id))m.set(x.receipt_id,[]);m.get(x.receipt_id).push(x)}
      for(const r of data.receipts)if(m.has(r.receipt_id))r.date_log=m.get(r.receipt_id);
    }
    const returns=rt&&!rt.error&&Array.isArray(rt.data)?rt.data:[];
    const d=data||{},groups=d.groups||[],adv=d.advance||{},open=d.openings||{},companies=d.companies||[];
    const hasB=Array.isArray(d.advance_b);
    const parentByKey=new Map(groups.map(g=>[key(g.member),g.parent]));
    const parentOf=n=>{let v=String(n||"").trim();for(let i=0;i<4;i++){const p=parentByKey.get(key(v));if(!p||key(p)===key(v))break;v=p}return v};
    const parties=new Map();
    const get=p=>{const k=key(p);if(!parties.has(k))parties.set(k,{party:p,bills:[],due:0,advance:0,opening:0,ret:0,members:[],billed:0,oldest:"",brands:{}});return parties.get(k)};
    const slot=(x,c)=>{c=c||"";return x.brands[c]||(x.brands[c]={company_id:c,bills:[],due:0,advance:0,opening:0,ret:0,net:0,oldest:""})};
    for(const o of d.orders||[]){
      o.parent=o.parent||parentOf(o.party);
      if(!o.invoice_no)continue;
      const due=r2(o.due);
      const x=get(o.parent);x.billed+=Number(o.bill_amount)||0;
      if(due>0.5){x.bills.push(o);x.due+=due;if(!x.oldest||String(o.invoice_date)<x.oldest)x.oldest=String(o.invoice_date||"");
        const b=slot(x,o.company_id);b.bills.push(o);b.due+=due;if(!b.oldest||String(o.invoice_date)<b.oldest)b.oldest=String(o.invoice_date||"")}
    }
    if(hasB){
      for(const a of d.advance_b){const x=get(parentOf(a.parent)),v=Number(a.amount)||0;x.advance+=v;slot(x,a.company_id).advance+=v}
      for(const a of d.openings_b||[]){const x=get(parentOf(a.parent)),v=Number(a.amount)||0;x.opening+=v;slot(x,a.company_id).opening+=v}
    }else{
      for(const [p,a] of Object.entries(adv))get(parentOf(p)).advance+=Number(a)||0;
      for(const [p,a] of Object.entries(open))get(parentOf(p)).opening+=Number(a)||0;
    }
    // New return (not against a bill) = return credit on the main party; one against a bill is in that bill's Due.
    for(const r of returns){if(r.cancelled||r.order_id)continue;const x=get(parentOf(r.parent||r.party)),v=Number(r.amount)||0;x.ret+=v;slot(x,hasB?r.company_id:"").ret+=v}
    for(const g of groups)get(g.parent).members.push(g.member);
    for(const x of parties.values()){
      x.bills.sort((a,b)=>String(a.invoice_date).localeCompare(String(b.invoice_date))||String(a.entered_at).localeCompare(String(b.entered_at))||String(a.order_no).localeCompare(String(b.order_no)));
      x.due=r2(x.due);x.advance=r2(x.advance);x.ret=r2(x.ret);x.net=r2(x.due+x.opening-x.advance-x.ret);
      for(const b of Object.values(x.brands)){b.bills.sort((a,c)=>String(a.invoice_date).localeCompare(String(c.invoice_date))||String(a.order_no).localeCompare(String(c.order_no)));
        b.due=r2(b.due);b.advance=r2(b.advance);b.opening=r2(b.opening);b.ret=r2(b.ret);b.net=r2(b.due+b.opening-b.advance-b.ret)}
    }
    const brandOf=id=>companies.find(c=>c.id===id)||null;
    return {raw:d,parties,parentOf,today:d.today||today(),companies,brandOf,branded:hasB&&companies.length>1,returns};
  }
  // One brand of a party (id "" = money / bills with no brand). Same shape as a party, with its name and bill names.
  const EMPTY={bills:[],due:0,advance:0,opening:0,ret:0,net:0,oldest:""};
  function slice(x,c){if(!x)return null;const b=x.brands&&x.brands[c||""]||EMPTY;return {...b,company_id:c||"",party:x.party,members:x.members,brands:x.brands}}
  // Brands this party has something in (bills due, advance or opening), real brands only.
  const activeBrands=x=>x&&x.brands?Object.values(x.brands).filter(b=>b.company_id&&(b.due>0.5||Math.abs(b.advance)>0.5||Math.abs(b.opening)>0.5)).map(b=>b.company_id):[];
  const savedBrand=()=>{try{return localStorage.getItem("lwbBrand")||""}catch(e){return ""}};
  // One balance per party: bills due + opening − money not yet set against bills.
  // > 0 = still to collect, < 0 = advance (we hold the party's money).
  const balText=p=>{if(!p)return "";const n=r2(p.net!=null?p.net:p.due+(p.opening||0)-p.advance-(p.ret||0));return n>0.5?"due "+rs(n):n<-0.5?"advance "+rs(-n):"settled"};
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
.lpp .lnk{border:0;background:none;color:#00434d;font:inherit;font-weight:600;cursor:pointer;padding:0;font-size:13px}
.lpp .tot{font-size:15px;text-align:right}.lpp .tot b{font-size:18px}
.lpp .seg{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));border:1.5px solid #d5dbe3;border-radius:9px;overflow:hidden}
.lpp .seg button{border:0;border-right:1px solid #d5dbe3;background:#fff;padding:9px 6px;font:inherit;font-size:13px;font-weight:600;cursor:pointer;color:#33404d}
.lpp .seg button:last-child{border-right:0}.lpp .seg button[aria-pressed=true]{background:#002f37;color:#fff}
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
.lpp .ksr{display:flex;align-items:flex-start;gap:9px;background:#fff6d6;border:1.5px solid #e9c46a;border-radius:9px;padding:8px 11px;cursor:pointer;font-size:13.5px;color:#4d3800}
.lpp .ksr.err{background:#ffebeb;border-color:#e0a1a1;color:#9b2020}.lpp .ksr .put{border:1.5px solid #9a6b00;background:#9a6b00;color:#fff;border-radius:8px;font:inherit;font-weight:700;font-size:13px;padding:5px 10px;cursor:pointer;margin-top:6px}
.lpp .kline{background:#fff6d6;border-radius:8px;padding:6px 6px 6px 8px;margin-top:2px}.lpp .kline b{color:#7a5300}.lpp .kline input{border-color:#e9c46a;font-weight:700;color:#7a5300}
.lpp .kseg{display:grid;grid-template-columns:1fr 1fr;border:1.5px solid #e9c46a;border-radius:8px;overflow:hidden;height:40px;box-sizing:border-box}
.lpp .kseg button{border:0;background:#fff;font:inherit;font-size:12.5px;font-weight:600;color:#7a5300;cursor:pointer;padding:0 4px}.lpp .kseg button[aria-pressed=true]{background:#9a6b00;color:#fff}
.lpp .tot span{display:block;font-size:13px;color:#7a5300}
.lpp .ksr b.k{display:inline-block;background:#9a6b00;color:#fff;border-radius:99px;padding:0 8px;font-size:12.5px;margin-right:4px}
.lpp .ksr small{display:block;color:#7a5f1f;font-size:12px;margin-top:1px}
.lpp .ksr.on{background:#fdecb3;border-color:#9a6b00}
.lpp tr.kzr td{background:#fff6d6}.lpp tr.kzr td:first-child{box-shadow:inset 3px 0 0 #9a6b00}
.lpp .kz{display:inline-block;margin-top:3px;border:1px solid #9a6b00;color:#7a5300;background:#fff;border-radius:99px;padding:0 7px;font-size:12px;font-weight:700;white-space:nowrap}
.lpp .kz.on{background:#9a6b00;color:#fff}
.lpp .ksr .go{border:0;background:none;color:#7a5300;font:inherit;font-weight:700;text-decoration:underline;cursor:pointer;padding:0;font-size:12px}
.lpp .cwarn{background:#fff6d6;color:#7a5600;border-radius:8px;padding:6px 10px;font-size:13px;margin:6px 0 0}
.lpp .bpk{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:8px}
.lpp .bpk button{border:2px solid #d5dbe3;background:#fff;border-radius:10px;padding:7px 10px;text-align:left;font:inherit;cursor:pointer;color:var(--bc)}
.lpp .bpk button b{display:flex;align-items:center;gap:6px;font-size:14px}.lpp .bpk button b i{width:9px;height:9px;border-radius:50%;background:var(--bc)}
.lpp .bpk button small{display:block;color:#66788e;font-size:12px;margin-top:1px}
.lpp .bpk button[aria-pressed=true]{border-color:var(--bc);background:color-mix(in srgb,var(--bc) 9%,#fff)}
.lpp .bpk.need button{border-color:#e0a1a1}
.lpp .clist{position:absolute;left:0;right:0;top:100%;z-index:5;background:#fff;border:1px solid #d5dbe3;border-radius:8px;box-shadow:0 10px 24px rgba(0,0,0,.12);max-height:260px;overflow:auto;margin-top:2px}
.lpp .clist button{display:flex;justify-content:space-between;gap:8px;width:100%;text-align:left;border:0;border-bottom:1px solid #f0f2f5;background:#fff;padding:9px 10px;font:inherit;cursor:pointer}
.lpp .clist button.on,.lpp .clist button:hover{background:#eef4ff}.lpp .clist small{color:#66788e;white-space:nowrap}
@media(max-width:560px){.lpp .kline .kseg{grid-column:2}.lpp-back{padding:0;align-items:flex-end}.lpp{border-radius:14px 14px 0 0;max-height:96dvh}
 .lpp .mode{grid-template-columns:72px minmax(0,1fr)}.lpp .mode input.ref{grid-column:2}.lpp .notes{margin-left:0}
 .lpp .sum b{font-size:14px}.lpp td input{width:92px}.lpp .seg button{font-size:12px}}`;
    document.head.appendChild(s);
  }

  /* ---------- popup ---------- */
  function open(o){
    css();
    const info=o.info,adjust=!!o.adjust;
    let party=o.party?info.parentOf(o.party):"",how="auto",busy=false,brand="";
    const BR=info.branded?info.companies:[];
    function pickDefaultBrand(){
      if(!BR.length){brand="";return}
      if(o.brand&&BR.some(c=>c.id===o.brand)){brand=o.brand;return}
      const act=activeBrands(info.parties.get(key(party)));
      if(act.length===1){brand=act[0];return}
      const sv=savedBrand();brand=act.length===0&&BR.some(c=>c.id===sv)?sv:"";
    }
    const names=(()=>{const m=new Map();
      for(const x of info.parties.values())m.set(key(x.party),x.party);
      for(const n of info.raw.parties||[]){const p=info.parentOf(n);if(!m.has(key(p)))m.set(key(p),p)}
      return [...m.values()].sort((a,b)=>{const A=info.parties.get(key(a)),B=info.parties.get(key(b));return Math.abs((B&&B.net)||0)-Math.abs((A&&A.net)||0)||a.localeCompare(b)})})();
    const back=document.createElement("div");back.className="lpp-back";
    back.innerHTML=`<div class="lpp" role="dialog" aria-modal="true" aria-labelledby="lppT">
<header><h3 id="lppT"></h3><button type="button" data-x aria-label="Close">✕</button></header>
<div class="bd">
 <div style="position:relative" data-pbox><label class="l" for="lppP">Party (main party or any name it is billed in)</label>
  <input id="lppP" autocomplete="off" placeholder="Type party name" role="combobox" aria-expanded="false"><div class="clist" hidden></div></div>
 <div data-brand hidden><label class="l">Which brand is this payment for? <span style="color:#b3122b">*</span></label><div class="bpk" data-bpk></div></div>
 <div class="sum" data-sum></div>
 <p class="hint" data-nob hidden></p>
 <div data-money>
  <div class="row2" style="margin-bottom:10px"><div><label class="l">Date received</label><div class="dbx"><input class="dt" inputmode="numeric" maxlength="10" placeholder="DD/MM/YYYY" aria-label="Date received"><button type="button" aria-label="Open calendar">📅</button><input type="date" tabindex="-1" aria-hidden="true"></div></div>
   <div><label class="l" for="lppR">Remark</label><input id="lppR" maxlength="300" autocomplete="off" placeholder="optional"></div></div>
  <label class="l">Money received</label>
  <div class="modes">${MODES.map(([m,t,ph])=>`<div class="mode"><b>${t}</b><input class="amt" data-m="${m}" inputmode="decimal" autocomplete="off" placeholder="₹ 0" aria-label="${t} amount">${m==="CASH"?`<button type="button" class="lnk" data-cnt>Count notes</button>`:`<input class="ref" data-r="${m}" maxlength="100" autocomplete="off" placeholder="${ph}" aria-label="${t} ${ph}">`}</div>${m==="CASH"?`<div class="notes" data-notes hidden>${NOTES.map(n=>`<span>₹${n}×<input data-n="${n}" inputmode="numeric" placeholder="0" aria-label="${n} notes"></span>`).join("")}<span>coins<input data-n="coins" inputmode="decimal" placeholder="0" aria-label="coins"></span></div>`:""}`).join("")}</div>
  <div class="mode kline" data-kline><b>Kasar</b><input class="kin" data-kin inputmode="decimal" autocomplete="off" placeholder="₹ 0" aria-label="Kasar amount"><div class="kseg" data-kmode><button type="button" data-k="LESS" aria-pressed="true">Paid less</button><button type="button" data-k="EXTRA" aria-pressed="false">Paid extra</button></div></div>
  <div class="tot" style="margin-top:8px">Total <b data-tot>₹0</b><span data-ktot></span></div>
  <p class="cwarn" data-cwarn hidden>Cash is ₹2 lakh or more (269ST). It will still save in full.</p>
 </div>
 <div><label class="l">${adjust?"Adjust the advance against":"Use this money for"}</label>
  <div class="seg${adjust?" two":""}" data-how><button type="button" data-h="auto">Oldest bill first</button><button type="button" data-h="pick">Choose bills</button>${adjust?"":`<button type="button" data-h="adv">Keep as advance</button>`}</div></div>
 <div data-bills></div>
 <div class="ksr" data-ksr hidden><span data-kst></span></div>
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

    const whole=()=>info.parties.get(key(party))||{party,bills:[],due:0,advance:0,opening:0,members:[],brands:{}};
    const P=()=>BR.length?slice(whole(),brand):whole();
    const bname=()=>{const c=BR.find(x=>x.id===brand);return c?c.name:""};
    function drawBrand(){
      const box=q("[data-brand]");box.hidden=!BR.length||!party;if(box.hidden)return;
      const w=whole();
      q("[data-bpk]").className="bpk"+(brand?"":" need");
      q("[data-bpk]").innerHTML=BR.map(c=>{const b=slice(w,c.id),n=r2(b.net);
        return `<button type="button" data-b="${esc(c.id)}" aria-pressed="${c.id===brand}" style="--bc:${esc(c.color||"#2362a4")}"><b><i></i>${esc(c.name)}</b><small>${n>0.5?"Due "+rs(n):n<-0.5?"advance "+rs(-n):"Nothing due"}${b.bills.length?" · "+b.bills.length+" bill"+(b.bills.length>1?"s":""):""}</small></button>`}).join("");
      q("[data-bpk]").querySelectorAll("[data-b]").forEach(b=>b.onclick=()=>{brand=b.dataset.b;manual=new Map();drawAll()});
      const nb=slice(w,""),nob=q("[data-nob]"),m=r2(nb.advance),ob=r2(nb.opening);
      nob.hidden=!(Math.abs(m)>0.5||Math.abs(ob)>0.5);
      nob.textContent="Old money with no brand: "+[Math.abs(m)>0.5?"payment "+rs(m):"",Math.abs(ob)>0.5?"opening "+rs(ob):""].filter(Boolean).join(" · ")+". Set its brand in Billing & Outstanding > Payments / Party Ledger.";
      q("[data-ok]").textContent=(adjust?"Save adjustment":"Save "+(bname()?bname()+" ":"")+"payment");
    }
    const money=()=>adjust?P().advance:r2(qa(".amt").reduce((a,i)=>a+num(i.value),0));
    let manual=new Map(),kmode="LESS";
    // Kasar typed by hand (lwb_kasar_setup.sql): Paid less = the party paid this much less, it closes the bill
    // (oldest bill first: the last bill this money reaches; Choose bills: the last bill picked).
    // Paid extra = the party paid this much more; it goes in kasar on that bill instead of advance. Max KMAX.
    const KMAX=500;
    const kas=()=>adjust||!q("[data-kin]")?0:r2(Math.max(0,num(q("[data-kin]").value)));
    // -> {money: Map(order -> money set to it), kasar: [{order_id, amount, kind, bill}], err}
    function split(){
      const p=P(),m=money(),k=kas(),out=new Map(),ks=[];let err="";
      if(how==="adv")return {money:out,kasar:ks,err:k?"Kasar is on a bill: choose Oldest bill first or Choose bills.":""};
      if(how==="pick"){for(const b of p.bills){const v=manual.get(b.order_id);if(v>0)out.set(b.order_id,v)}}
      else{let left=adjust?p.advance:m+(k&&kmode==="LESS"?k:0);
        for(const b of p.bills){if(left<0.01)break;const t=Math.min(r2(b.due),left);out.set(b.order_id,r2(t));left=r2(left-t)}}
      if(!k)return {money:out,kasar:ks,err};
      const picked=p.bills.filter(b=>out.get(b.order_id)>0),last=picked[picked.length-1];
      if(k>KMAX)err="Kasar can be at most "+rs(KMAX)+". Use a credit note for more.";
      else if(!last)err="Enter the money first: kasar goes on the bill this money pays.";
      else if(kmode==="LESS"){
        if(how==="auto"){
          const got=r2([...out.values()].reduce((a,v)=>a+v,0));
          const lastShort=r2(last.due-out.get(last.order_id));
          if(m+k-got>0.009)err=m>=got?"The money already pays all these bills. No kasar is needed.":"Kasar can be at most "+rs(r2(got-m))+" here (bills due "+rs(got)+").";
          else if(lastShort>0.5)err="Money + kasar does not close bill "+(last.invoice_no||last.order_no)+" ("+last.order_no+"): it is still short by "+rs(lastShort)+". Kasar is only for a small difference that closes the bill.";
          else{let r=k;for(const b of picked.slice().reverse()){if(r<0.005)break;const t=r2(Math.min(r,out.get(b.order_id)));out.set(b.order_id,r2(out.get(b.order_id)-t));ks.push({order_id:b.order_id,amount:t,kind:"LESS",bill:b});r=r2(r-t)}
            for(const [id,v] of out)if(v<0.005)out.delete(id)}
        }else{
          const d=r2(last.due-out.get(last.order_id)-k);
          if(Math.abs(d)>0.5)err="Bill "+(last.invoice_no||last.order_no)+" ("+last.order_no+"): money "+rs(out.get(last.order_id))+" + kasar "+rs(k)+" must equal its due "+rs(last.due)+(d>0?" (still short "+rs(d)+").":" (more by "+rs(-d)+").");
          else ks.push({order_id:last.order_id,amount:k,kind:"LESS",bill:last});
        }
      }else{
        const used=r2([...out.values()].reduce((a,v)=>a+v,0));
        if(m-used<k-0.01)err="Paid extra "+rs(k)+" is more than the money left after the bills ("+rs(r2(m-used))+").";
        else ks.push({order_id:last.order_id,amount:k,kind:"EXTRA",bill:last});
      }
      return {money:out,kasar:err?[]:ks,err};
    }
    const plan=()=>split().money;
    function drawSum(){
      const p=P();
      const n=r2(p.due+(p.opening||0)-p.advance-(p.ret||0)),both=p.advance>0.5&&p.bills.length>0;
      q("[data-sum]").innerHTML=party&&(!BR.length||brand)?`<div class="${n>0.5?"due":"adv"}"><small>${bname()?esc(bname())+" · ":""}${n>0.5?"to collect":n<-0.5?"advance with us":"balance"}</small><b>${rs(Math.abs(n))}</b></div><div><small>Bills due (${p.bills.length})</small><b>${rs(p.due)}</b></div>`+
        (both?`<div><small>Paid earlier, not set against bills</small><b>${rs(p.advance)}</b>${adjust?"":`<button type="button" class="lnk" data-adjnow style="display:block;margin-top:2px">Adjust now</button>`}</div>`:p.opening?`<div><small>Opening balance</small><b>${rs(p.opening)}</b></div>`:p.ret>0.5?`<div><small>Goods returned</small><b>${rs(p.ret)}</b></div>`:""):"";
      const a=q("[data-adjnow]");if(a)a.onclick=()=>{close();open({...o,party,brand,adjust:true})};
      q("[data-sum]").hidden=!party||(BR.length&&!brand);
    }
    function drawBills(){
      const p=P(),pl=plan(),box=q("[data-bills]");
      if(!party){box.innerHTML='<p class="hint">Choose the party to see its bills.</p>';return}
      if(BR.length&&!brand){box.innerHTML='<p class="hint">Pick the brand above to see its bills.</p>';return}
      if(!p.bills.length){box.innerHTML='<p class="hint">No '+(bname()?bname()+" ":"")+'bill is due for this party'+(adjust?".":" — the money stays as advance and is adjusted when the next bill is made.")+'</p>';return}
      box.innerHTML=`<div style="overflow:auto;max-height:300px"><table><thead><tr><th>${bname()?esc(bname())+" bill":"PO / bill"}</th><th class="n">Due</th><th class="n">${how==="pick"?"Take now":"Goes to bill"}</th></tr></thead><tbody>${p.bills.map(b=>{
        const v=pl.get(b.order_id)||0;
        return `<tr data-row="${esc(b.order_id)}"><td><b>${esc(b.order_no)}</b> · ${dmy(b.invoice_date)}<small>${esc(billNames(b))}</small></td><td class="n">${rs(b.due)}</td><td class="n">${how==="pick"?`<input data-o="${esc(b.order_id)}" inputmode="decimal" value="${v?r2(v):""}" placeholder="0" aria-label="Amount for ${esc(b.order_no)}"><br><button type="button" class="lnk" data-full="${esc(b.order_id)}">full</button>`:(v?"<b>"+rs(v)+"</b>":"—")}<div class="kz" data-kz="${esc(b.order_id)}" hidden></div></td></tr>`}).join("")}</tbody></table></div>`;
      box.querySelectorAll("[data-o]").forEach(i=>i.oninput=()=>{manual.set(i.dataset.o,num(i.value));drawLeft()});
      box.querySelectorAll("[data-full]").forEach(b=>b.onclick=()=>{const x=p.bills.find(y=>y.order_id===b.dataset.full);manual.set(x.order_id,r2(x.due));drawBills()});
    }
    // Suggestion when no kasar is typed: a bill this money leaves short by <= KMAX (or, Oldest bill first, a little extra).
    function kasarHint(){
      if(adjust||how==="adv"||kas())return [];
      const p=P(),pl=plan(),out=[];
      for(const b of p.bills){const v=pl.get(b.order_id)||0;if(v<=0)continue;const s=r2(b.due-v);if(s>=0.01&&s<=KMAX)out.push({order_id:b.order_id,amount:s,kind:"LESS",bill:b})}
      if(!out.length&&how==="auto"&&pl.size){
        const left=r2(money()-[...pl.values()].reduce((a,v)=>a+v,0)),last=p.bills.filter(b=>pl.get(b.order_id)>0).pop();
        if(last&&left>=0.01&&left<=KMAX)out.push({order_id:last.order_id,amount:left,kind:"EXTRA",bill:last});
      }
      return how==="pick"?out.slice(-1):out.slice(-1);
    }
    let kasarSeen="";
    function drawKasar(){
      const S=split(),k=kas(),box=q("[data-ksr]"),pl=S.money;
      const on=S.kasar.length?S.kasar:kasarHint(),typed=!!S.kasar.length;
      // the bill the kasar is on: marked in the bill list above (yellow row + "Kasar ₹5")
      qa("tr.kzr").forEach(r=>r.classList.remove("kzr"));qa("[data-kz]").forEach(d=>{d.hidden=true;d.textContent=""});
      for(const x of on){const tr=back.querySelector('tr[data-row="'+x.order_id+'"]'),d=back.querySelector('[data-kz="'+x.order_id+'"]');
        if(tr)tr.classList.add("kzr");
        if(d){d.hidden=false;d.className="kz"+(typed?" on":"");d.textContent=x.kind==="EXTRA"?(typed?"✂ Kasar +"+rs(x.amount):"Extra "+rs(x.amount)):(typed?"✂ Kasar "+rs(x.amount):"Short "+rs(x.amount))}}
      const key=on.map(x=>x.order_id+":"+x.amount).join("|");
      if(on.length&&key!==kasarSeen){const tr=back.querySelector('tr[data-row="'+on[0].order_id+'"]');if(tr)tr.scrollIntoView({block:"nearest"})}
      kasarSeen=key;
      const kt=q("[data-ktot]");if(kt)kt.textContent=k&&!S.err?(kmode==="EXTRA"?"of which kasar (paid extra) "+rs(k):"+ kasar "+rs(k)+" = bills closed "+rs(r2(money()+k))):"";
      box.className="ksr"+(S.err?" err":typed?" on":"");
      if(S.err){box.hidden=false;q("[data-kst]").innerHTML="<b>Kasar: </b>"+esc(S.err);return S.kasar}
      box.hidden=!on.length;if(!on.length)return S.kasar;
      const one=x=>`<b>${esc(x.bill.order_no)}</b> · bill ${esc(x.bill.invoice_no||"")} · ${dmy(x.bill.invoice_date)} · due ${rs(x.bill.due)} · money ${rs(pl.get(x.order_id)||0)}`;
      const t=r2(on.reduce((a,x)=>a+x.amount,0));
      q("[data-kst]").innerHTML=typed?
        `<b class="k">Kasar ${rs(t)}</b><b>${on[0].kind==="EXTRA"?"Party paid "+rs(t)+" extra: kept as kasar":on.length>1?on.length+" bills close with kasar":"This bill closes with kasar"}</b><small>${on.map(x=>one(x)+" · kasar "+rs(x.amount)).join("<br>")}</small> <button type="button" class="go" data-kgo>See bill ↑</button>`:
        `<b class="k">${on[0].kind==="EXTRA"?"Extra":"Short"} ${rs(t)}</b><b>${on[0].kind==="EXTRA"?"Party paid "+rs(t)+" more than the bills":"This bill stays short by "+rs(t)}</b><small>${one(on[0])}</small><button type="button" class="put" data-kput>Put ${rs(t)} in Kasar</button> <button type="button" class="go" data-kgo>See bill ↑</button>`;
      const g=q("[data-kgo]");if(g)g.onclick=e=>{e.preventDefault();const tr=back.querySelector('tr[data-row="'+on[0].order_id+'"]');if(tr)tr.scrollIntoView({block:"center",behavior:"smooth"})};
      const pu=q("[data-kput]");if(pu)pu.onclick=()=>{q("[data-kin]").value=t;setKmode(on[0].kind);if(how==="auto")drawBills();drawLeft()};
      return S.kasar;
    }
    function setKmode(m){kmode=m;qa("[data-k]").forEach(b=>b.setAttribute("aria-pressed",String(b.dataset.k===m)))}
    function drawLeft(){
      const ks=drawKasar(),kt=r2(ks.reduce((a,x)=>a+(x.kind==="EXTRA"?x.amount:0),0));
      const m=money(),split=r2([...plan().values()].reduce((a,v)=>a+v,0)+kt),left=r2(m-split);
      q("[data-tot]").textContent=rs(m);
      q("[data-cwarn]").hidden=!(num(q('.amt[data-m="CASH"]').value)>=200000);
      q("[data-left]").innerHTML=adjust?`<span>Advance ${rs(m)}</span><span>Adjusted now <b>${rs(split)}</b></span><span>Advance left <b class="${left<-0.5?"r":"g"}">${rs(left)}</b></span>`:
        `<span>Against bills <b>${rs(split)}</b></span>${ks.length?`<span>Kasar <b style="color:#9a6b00">${rs(ks.reduce((a,x)=>a+x.amount,0))}</b></span>`:""}<span>${left<-0.5?"More than received":"Stays as advance"} <b class="${left<-0.5?"r":"g"}">${rs(Math.abs(left))}</b></span>`;
    }
    function drawAll(){drawBrand();drawSum();qa("[data-h]").forEach(b=>b.setAttribute("aria-pressed",String(b.dataset.h===how)));drawBills();drawLeft()}
    q("[data-kin]").oninput=()=>{if(how==="auto")drawBills();drawLeft()};
    qa("[data-k]").forEach(b=>b.onclick=()=>{setKmode(b.dataset.k);if(how==="auto")drawBills();drawLeft()});
    if(adjust)q("[data-kline]").hidden=true;
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
      list.innerHTML=shown.map((n,i)=>{const x=info.parties.get(key(n));return `<button type="button" data-i="${i}"${i?"":' class="on"'}><span>${esc(n)}${x&&x.members.length?`<small style="display:block">${esc(x.members.slice(0,4).join(", "))}${x.members.length>4?" …":""}</small>`:""}</span><small>${x&&(x.due>0.5||x.advance>0.5||x.opening)?balText(x):""}</small></button>`}).join("")||'<p class="hint" style="padding:9px">Not in the Party Master</p>';
      list.hidden=false;list.querySelectorAll("[data-i]").forEach(b=>b.onmousedown=e=>{e.preventDefault();pick(shown[Number(b.dataset.i)])})}
    function pick(n){party=n;pin.value=n;list.hidden=true;manual=new Map();if(!o.brand||!brand)pickDefaultBrand();drawAll()}
    pin.onfocus=drawList;pin.oninput=()=>{party="";drawList();drawAll()};
    pin.onblur=()=>setTimeout(()=>{list.hidden=true;if(!party&&pin.value.trim()){const p=info.parentOf(pin.value.trim());const m=names.find(n=>key(n)===key(p));if(m)pick(m)}},150);
    pin.onkeydown=e=>{if(list.hidden)return;if(e.key==="ArrowDown"||e.key==="ArrowUp"){e.preventDefault();hi=Math.max(0,Math.min(shown.length-1,hi+(e.key==="ArrowDown"?1:-1)));list.querySelectorAll("[data-i]").forEach((b,i)=>b.classList.toggle("on",i===hi))}
      else if(e.key==="Enter"){e.preventDefault();if(shown[hi])pick(shown[hi])}else if(e.key==="Escape"){e.stopPropagation();list.hidden=true}};
    if(adjust)q("[data-pbox]").hidden=!!party;

    q("[data-ok]").onclick=async()=>{
      if(busy)return;const err=q("[data-err]");err.hidden=true;
      const fail=t=>{err.textContent=t;err.hidden=false;err.scrollIntoView({block:"nearest"})};
      if(!party)return fail("Choose the party.");
      if(BR.length&&!brand)return fail("Pick the brand: is this payment for Rajnigandha or Coca-Cola?");
      const pl=plan(),allocs=[...pl].filter(([,v])=>v>0).map(([id,v])=>({order_id:id,amount:r2(v)}));
      const billSum=allocs.reduce((a,x)=>a+x.amount,0);
      let args;
      if(adjust){
        if(!allocs.length)return fail("Nothing to adjust.");
        if(billSum>P().advance+0.5)return fail("Adjusted "+rs(billSum)+" is more than the advance "+rs(P().advance)+".");
        args=["lwb_party_adjust",{p_party:party,p_allocs:how==="auto"?null:allocs}];
        if(BR.length)args[1].p_company_id=brand;
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
        const m=money();if(billSum>m+0.5)return fail("Bills "+rs(billSum)+" is more than the money received "+rs(m)+".");
        args=["lwb_party_receive",{p_party:party,p_pay_date:date,p_lines:lines,p_allocs:how==="auto"?null:how==="adv"?[]:allocs,p_remark:q("#lppR").value.trim()||null}];
        if(BR.length)args[1].p_company_id=brand;
        const S=split();if(S.err)return fail("Kasar: "+S.err);
        const ks=S.kasar;
        if(ks.length){ // kasar first on the bills, then this exact split (extra kasar raises that bill, so it takes the extra)
          const al=allocs.map(x=>({...x}));
          for(const k of ks)if(k.kind==="EXTRA"){const a=al.find(x=>x.order_id===k.order_id);if(a)a.amount=r2(a.amount+k.amount)}
          args=["lwb_party_receive_kasar",{...args[1],p_allocs:al,p_kasar:ks.map(k=>({order_id:k.order_id,amount:k.amount,kind:k.kind}))}];
          if(!BR.length)args[1].p_company_id=null;
        }
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
    pickDefaultBrand();
    drawAll();
    setTimeout(()=>{(party?(adjust?q("[data-ok]"):q('.amt[data-m="'+(o.mode||"CASH")+'"]')):pin).focus()},60);
    return {close};
  }
  // Change the date of a receipt (wrong day entered). Admin / Accounts. lwb_receipt_date_change_setup.sql
  // changeDate({client, receipt:{receipt_id,total,pay_date,party}, today, onSaved(newDate)})
  const dateLogText=r=>(r&&r.date_log||[]).map(x=>"Date changed "+dmy(x.old_date)+" → "+dmy(x.new_date)+" by "+x.by+" on "+dmy(String(x.at).slice(0,10))+(x.reason?" ("+x.reason+")":"")).join(" · ");
  function changeDate(o){
    css();const r=o.receipt,t=o.today||today(),y=(()=>{const d=new Date(t+"T12:00:00Z");d.setUTCDate(d.getUTCDate()-1);return d.toISOString().slice(0,10)})();
    const back=document.createElement("div");back.className="lpp-back";
    back.innerHTML=`<div class="lpp" role="dialog" aria-modal="true" aria-labelledby="lpdT" style="width:min(440px,100%)">
<header><h3 id="lpdT">Change payment date</h3><button type="button" data-x aria-label="Close">✕</button></header>
<div class="bd">
 <div class="sum" style="grid-template-columns:1fr 1fr"><div><small>${esc(r.party||"")}</small><b class="lpd-amt" style="color:#13824a">${rs(r.total)}</b></div><div><small>Date now</small><b>${dmy(r.pay_date)}</b></div></div>
 <div><label class="l">New date</label><input type="date" class="lpd-d" aria-label="New date" style="font-weight:700;color:#00434d;cursor:pointer">
  <div style="display:flex;gap:6px;margin-top:6px"><button type="button" class="b" data-d="${y}" style="height:32px;font-size:13px">Yesterday ${dmy(y).slice(0,5)}</button><button type="button" class="b" data-d="${t}" style="height:32px;font-size:13px">Today ${dmy(t).slice(0,5)}</button></div></div>
 <div><label class="l" for="lpdR">Reason</label><input id="lpdR" maxlength="300" autocomplete="off" placeholder="optional, e.g. money came yesterday"></div>
 <p style="margin:0;font-size:12.5px;color:#66788e">Only the date moves. Amount, modes, bills and cash book stay the same. The change is kept with your name.</p>
 <div class="err" data-err hidden></div>
</div>
<footer><button type="button" class="b" data-x>Cancel</button><button type="button" class="b pri" data-ok>Save date</button></footer></div>`;
    document.body.appendChild(back);document.body.style.overflow="hidden";
    const q=s=>back.querySelector(s);
    const close=()=>{back.remove();document.body.style.overflow=""};
    back.querySelectorAll("[data-x]").forEach(b=>b.onclick=close);
    back.addEventListener("keydown",e=>{if(e.key==="Escape"){e.stopPropagation();close()}else if(e.key==="Enter"&&e.target.tagName==="INPUT")q("[data-ok]").click()});
    const dp=q(".lpd-d"),err=q("[data-err]");
    const set=d=>{dp.value=d};
    set(String(r.pay_date).slice(0,10)===t?y:String(r.pay_date).slice(0,10));dp.max=t;
    dp.onclick=()=>{try{dp.showPicker()}catch(_){}};
    back.querySelectorAll("[data-d]").forEach(b=>b.onclick=()=>set(b.dataset.d));
    let busy=false;
    q("[data-ok]").onclick=async()=>{
      if(busy)return;err.hidden=true;
      const d=dp.value;
      if(!d){err.textContent="Choose the new date";err.hidden=false;return}
      if(d>t){err.textContent="The date cannot be in the future";err.hidden=false;return}
      if(d===String(r.pay_date).slice(0,10)){err.textContent="The payment is already on "+dmy(d);err.hidden=false;return}
      busy=true;q("[data-ok]").disabled=true;
      try{const {error}=await o.client.rpc("lwb_receipt_set_date",{p_receipt_id:r.receipt_id,p_date:d,p_reason:q("#lpdR").value.trim()||null});
        if(error)throw error;close();if(o.onSaved)o.onSaved(d)}
      catch(e){const m=String((e&&e.message)||e||"");err.textContent=/lwb_receipt_set_date|schema cache|does not exist/i.test(m)?"Date change is not set up yet. It sets itself up when this change is merged.":m.replace(/^.*?ERROR:\s*/,"");err.hidden=false}
      finally{busy=false;q("[data-ok]").disabled=false}
    };
    setTimeout(()=>{dp.focus();try{dp.showPicker()}catch(_){}},60);
    return {close};
  }
  // Same party under another name? "RG. SHIV TOBECO (PARVAT PATIYA)" (Tally / old Party Master name) and
  // "SHIV TOBECO (PARVAT PATIYA)" (main party with the bills) are one shop: money booked on the first one
  // shows as advance with 0 bills while the bills stay due on the second. core() drops the RG / M/S words.
  const SKIP=new Set("RG M S MS MESSRS SHREE SHRI SRI THE".split(" "));
  const core=v=>key(v).split(" ").filter(w=>w&&!SKIP.has(w)).join("");
  // -> the other main party with bills / opening and the same core name, or null
  function lookalike(info,name){if(!info||!info.parties||!name)return null;const k=key(name),c=core(name);if(c.length<4)return null;
    let best=null;for(const x of info.parties.values()){if(key(x.party)===k)continue;
      if(core(x.party)!==c&&!(x.members||[]).some(m=>core(m)===c))continue;
      if(!(x.bills.length||Math.abs(x.opening)>0.5||x.due>0.5))continue;
      if(!best||x.bills.length+Math.abs(x.net)>best.bills.length+Math.abs(best.net))best=x}
    return best}
  // Bills to make (Billing & Outstanding > Bills to make, and the Dashboard count): no Tally bill yet and
  // loaded / invoiced, marked Loaded / Delivered by Admin, or dated on / after MAKE_FROM (old delivered POs from
  // before this screen are left out). One rule for the page and the Dashboard (Mohit, 16 Nov 2026).
  const MAKE_FROM="2026-09-30";
  const needsBill=(o,marks)=>!o.invoice_no&&(["loaded","invoiced"].includes(String(o.status).toLowerCase())||!!(marks&&marks.has(o.order_id))||String(o.dispatch_date||o.order_date||"").slice(0,10)>=MAKE_FROM);
  window.LWBPartyPay={load,open,changeDate,dateLogText,needsBill,billNames,balText,key,rs,dmy,errText,slice,activeBrands,lookalike,core};
})();
