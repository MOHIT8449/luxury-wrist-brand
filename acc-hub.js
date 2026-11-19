/* Accounts in one place (Mohit, 19 Nov 2026).
   Billing & Outstanding (party-billing.html) and the Accounts Dashboard (accounts-dashboard.html) show one
   "Accounts" header: one row of buttons, short alerts, six cards and ONE tab row. Billing tabs live in
   party-billing.html, Cash & Bank tabs in accounts-dashboard.html; a tab of the other half opens that file
   with ?tab=, so for the user it is one page. Each page fills the cards it already has data for and this file
   loads the rest (cash figures on the billing half, bills on the cash half) with the same rules.

   LWBAccHub.mount({page:"bill"|"cash", tab, onTab(t), onAct(a)})   page draws #hubActs/#hubTabs/#hubKpis/#hubAls
   LWBAccHub.setTab(t) · counts({make,chg,chq,verify}) · kpis({make,due,adv,coll,chq,hand}) · alerts([...])
   LWBAccHub.cashFrom(D,C,from,to)  -> cards + alerts from lwb_acc_dashboard + lwb_acc_cheque_list
   LWBAccHub.billFrom(PI,marks,early,brand) -> cards from LWBPartyPay.load
   LWBAccHub.loadCash(client) / loadBill(client,PI)  -> the other half's cards */
(function(){
  "use strict";
  const T={make:"Bills to make",made:"Bills made",due:"To collect",led:"Ledger",pay:"Payments",ret:"Returns",
    book:"Day book",cheques:"Cheques",verify:"Bank check",sum:"Summary",chg:"PO changes",
    grp:"Party groups",close:"Cash handover",staff:"Staff ledger",veh:"Vehicles",setup:"Heads & Banks"};
  const BILL=["make","made","due","led","pay","ret","chg","grp"];
  const ROW=[["Billing",["make","made","due","led","pay","ret"]],["Cash & Bank",["book","cheques","verify","sum"]],["",["chg"]]];
  const MORE=["grp","close","staff","veh","setup"];
  const FILE={bill:"party-billing.html",cash:"accounts-dashboard.html"};
  const pageOf=t=>BILL.includes(t)?"bill":"cash";
  const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const r2=n=>Math.round((Number(n)||0)*100)/100;
  const rs=v=>(r2(v)<0?"−":"")+"₹"+Math.abs(r2(v)).toLocaleString("en-IN",{maximumFractionDigits:2});
  const dmy=d=>d?String(d).slice(8,10)+"/"+String(d).slice(5,7)+"/"+String(d).slice(0,4):"";
  const el=id=>document.getElementById(id);
  let o={page:"bill"},tab="",cnt={},K={},AL=[],moreOpen=false;

  const css=`
  .hub-top{display:flex;align-items:center;gap:6px;flex-wrap:wrap;margin:0 0 8px}
  .hub-top h1{margin:0 4px 0 0;font-size:19px}.hub-top .sp{flex:1 1 auto}.hub-top .lwb-brands{margin:0}
  .hub-ico{height:34px;min-width:34px;border:1.5px solid var(--erp-line);background:#fff;border-radius:99px;font:inherit;font-size:15px;cursor:pointer;color:var(--erp-ink)}
  .hub-ico:disabled{opacity:.5}
  .hub-acts{display:flex;gap:6px;margin:0 0 8px}
  .hub-acts button{flex:1 1 0;min-width:0;height:38px;border:0;border-radius:8px;color:#fff;font:inherit;font-weight:700;font-size:14px;cursor:pointer;white-space:nowrap;display:flex;align-items:center;justify-content:center;gap:6px;overflow:hidden}
  .hub-acts em{font-style:normal}.hub-acts .s{display:none}
  .hub-acts [data-hub-a=pay]{background:#13824a}.hub-acts [data-hub-a=IN]{background:#1a9156}.hub-acts [data-hub-a=OUT]{background:#c8102e}
  .hub-acts [data-hub-a=DEPOSIT]{background:#1d5fbf}.hub-acts [data-hub-a=close]{background:#002f37}
  .hub-acts [data-hub-a=ret]{background:#fff;color:var(--erp-ink);border:1px solid var(--erp-line)}
  .hub-als{display:flex;gap:6px;flex-wrap:wrap;margin:0 0 8px}.hub-als:empty{display:none}
  .hub-al{display:flex;align-items:center;gap:8px;flex:1 1 260px;min-width:0;padding:6px 10px;border-radius:8px;border:1px solid #f3d08a;background:#fff7e6;color:#6b4200;font-size:13px}
  .hub-al.blue{background:#eef4ff;border-color:#c5d7f5;color:#1d3f75}.hub-al.grn{background:#ecf8f1;border-color:#bfe5cf;color:#0f5f37}
  .hub-al b{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}.hub-al span{flex:1 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:inherit;opacity:.85}
  .hub-al .go{border:0;background:none;padding:0;font:inherit;font-weight:700;color:#00434d;text-decoration:underline;cursor:pointer;white-space:nowrap;margin-left:auto}
  .hub-al input{height:30px;width:120px;border:1.5px solid #c9d4e2;border-radius:7px;padding:0 8px;font:inherit;font-size:14px;margin-left:auto}
  .hub-al .btn{height:30px;border:0;border-radius:7px;background:#00434d;color:#fff;font:inherit;font-weight:700;font-size:13px;padding:0 10px;cursor:pointer;white-space:nowrap}
  .hub-al .btn.grn{background:#13824a}
  body.erp-compact .erp-main .hub-al .go{min-height:0;padding:4px 0}body.erp-compact .erp-main .hub-al .btn{min-height:0}
  body.erp-compact .erp-main .hub-al input{min-height:0;font-size:15px}
  .hub-kpis{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:8px;margin:0 0 8px}
  .hub-k{background:#fff;border:1px solid var(--erp-line);border-left:4px solid var(--c);border-radius:9px;padding:7px 10px;min-width:0;text-align:left;font:inherit;color:inherit;cursor:pointer}
  .hub-k:hover{border-color:#9fb3c8;border-left-color:var(--c)}
  .hub-k h3{margin:0;font-size:12px;color:#4b5763;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .hub-k b{display:block;font-size:19px;font-weight:800;line-height:1.25;color:var(--v,var(--erp-ink));font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .hub-k small{display:block;font-size:11.5px;color:var(--erp-muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .hub-k.dk{background:#002f37;border-color:#002f37;color:#fff}.hub-k.dk h3,.hub-k.dk small{color:#cfe3e6}.hub-k.dk b{color:#fff}
  .hub-tabs{display:flex;gap:5px;flex-wrap:wrap;align-items:center;margin:0 0 8px;position:relative}
  .hub-tabs .g{font-size:11px;font-weight:800;color:var(--erp-muted);letter-spacing:.4px;text-transform:uppercase;margin:0 1px 0 2px}
  .hub-tabs .bar{width:1px;height:22px;background:var(--erp-line);margin:0 3px}
  .hub-tabs button{height:32px;border:1.5px solid var(--erp-line);background:#fff;border-radius:99px;padding:0 11px;font:inherit;font-size:13.5px;cursor:pointer;white-space:nowrap;color:var(--erp-ink)}
  .hub-tabs button[aria-pressed=true]{background:#002f37;border-color:#002f37;color:#fff;font-weight:700}
  .hub-tabs .n{display:inline-block;background:#c8102e;color:#fff;border-radius:9px;padding:0 6px;font-size:11px;font-weight:700;margin-left:4px;line-height:17px}
  .hub-more{position:absolute;z-index:30;right:0;top:100%;margin-top:4px;background:#fff;border:1px solid #d5dbe3;border-radius:10px;box-shadow:0 10px 24px rgba(0,0,0,.14);padding:4px;min-width:200px}
  .hub-more button{display:block;width:100%;text-align:left;border:0;border-radius:7px;height:36px;padding:0 12px;background:#fff}
  .hub-more button:hover,.hub-more button[aria-pressed=true]{background:#eef4ff;color:var(--erp-ink);font-weight:700}
  .hub-more .ph{display:none}
  .hub-q{display:flex;gap:6px;margin:0 0 8px}.hub-q input{flex:1;min-width:0;height:34px;border:1.5px solid var(--erp-line);border-radius:8px;padding:0 10px;font:inherit;font-size:14px}
  .hub-q button{height:34px;border:1px solid var(--erp-line);background:#fff;color:var(--erp-ink);border-radius:8px;padding:0 10px;font:inherit;font-weight:600;cursor:pointer;white-space:nowrap}
  @media(min-width:601px) and (max-width:1100px){.hub-kpis{grid-template-columns:repeat(3,minmax(0,1fr))}.hub-tabs .g{display:none}}
  @media(max-width:600px){
    .hub-top h1,.hub-top .sp{display:none}.hub-top{gap:5px}.hub-top>div:empty{display:none}
    .hub-acts{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:5px}
    .hub-acts button{height:46px;flex-direction:column;gap:0;font-size:11.5px;line-height:1.15}.hub-acts em{font-size:16px}
    .hub-acts .l{display:none}.hub-acts .s{display:inline}.hub-acts [data-hub-a=ret]{display:none}
    .hub-als{flex-direction:column;gap:4px}.hub-al{flex:none;width:100%;padding:5px 8px;font-size:12.5px}.hub-al span{display:none}.hub-al input{width:96px}
    .hub-kpis{grid-template-columns:repeat(3,minmax(0,1fr));gap:5px}.hub-k{padding:6px 7px;border-left-width:3px}
    .hub-k h3{font-size:11px}.hub-k b{font-size:15px}.hub-k small{font-size:10.5px}
    .hub-tabs{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:4px}.hub-tabs .g,.hub-tabs .bar{display:none}
    .hub-tabs button{padding:0 4px;font-size:12.5px;height:31px;overflow:hidden;text-overflow:ellipsis}.hub-tabs .n{margin-left:3px;padding:0 4px;font-size:10px}
    .hub-more{left:0;right:0}.hub-more .ph{display:block}
  }`;
  function style(){if(el("hubCss"))return;const s=document.createElement("style");s.id="hubCss";s.textContent=css;document.head.appendChild(s)}

  /* ---------- actions ---------- */
  const ACTS=[["pay","💰","Party payment","Party pay"],["IN","＋","Cash In","Cash In"],["OUT","−","Cash Out","Cash Out"],["DEPOSIT","🏦","Bank Deposit","Deposit"],["close","🌙","Close Day","Close Day"],["ret","↩","Return","Return"]];
  function drawActs(){const b=el("hubActs");if(!b)return;
    b.innerHTML=ACTS.map(([a,i,l,s])=>'<button type="button" data-hub-a="'+a+'"><em>'+i+'</em><span class="l">'+l+'</span><span class="s">'+s+'</span></button>').join("")}
  // pay is on both halves; cash entries / Close Day on the cash half; Return on the billing half
  function act(a){
    const here=a==="pay"||(a==="ret"?o.page==="bill":o.page==="cash");
    if(here){o.onAct&&o.onAct(a);return}
    location.href=a==="ret"?FILE.bill+"?tab=ret&new=ret":FILE.cash+"?new="+a;
  }

  /* ---------- tabs ---------- */
  const badge=t=>{const n={make:cnt.make,chg:cnt.chg,cheques:cnt.chq,verify:cnt.verify}[t];return n?'<span class="n">'+n+'</span>':""};
  const tb=t=>'<button type="button" data-hub-t="'+t+'" aria-pressed="'+(t===tab)+'">'+esc(T[t])+badge(t)+'</button>';
  function drawTabs(){const b=el("hubTabs");if(!b)return;
    const inMore=MORE.includes(tab);
    b.innerHTML=ROW.map(([g,l],i)=>(i?'<span class="bar"></span>':"")+(g?'<span class="g">'+g+'</span>':"")+l.map(tb).join("")).join("")+
      '<button type="button" id="hubMoreBtn" aria-pressed="'+inMore+'" aria-expanded="'+moreOpen+'">'+(inMore?esc(T[tab]):"More")+' ▾</button>'+
      (moreOpen?'<div class="hub-more" role="menu">'+MORE.map(tb).join("")+'<button type="button" class="ph" data-hub-a="ret">↩ Return (goods back)</button></div>':"")}
  function go(t){
    if(t==="out")t="due";   // old "Party outstanding" tab = To collect
    moreOpen=false;
    if(pageOf(t)!==o.page){location.href=FILE[pageOf(t)]+"?tab="+t;return}
    tab=t;drawTabs();o.onTab&&o.onTab(t);
  }

  /* ---------- cards ---------- */
  const DEF=[["make","#c8102e","Bills to make","make",""],["due","#b3122b","To collect","due","#b3122b"],["coll","#13824a","Collected today","book","#13824a"],
    ["chq","#9a5b00","Cheques not in bank","cheques",""],["adv","#13824a","Advance with us","due",""],["hand","#002f37","Cash in hand","book",""]];
  function drawKpis(){const b=el("hubKpis");if(!b)return;
    b.innerHTML=DEF.map(([k,c,h,t,v])=>{const x=K[k]||{};
      return '<button type="button" class="hub-k'+(k==="hand"?" dk":"")+'" data-hub-t="'+t+'" style="--c:'+c+(v?";--v:"+v:"")+'" title="'+esc(x.tip||"")+'"><h3>'+esc(x.h||h)+'</h3><b>'+(x.v==null?"…":x.v)+'</b><small>'+(x.s||"&nbsp;")+'</small></button>'}).join("")}
  function drawAlerts(){const b=el("hubAls");if(!b)return;
    b.innerHTML=AL.map(a=>'<div class="hub-al '+(a.c||"")+'"><b>'+a.b+'</b>'+(a.s?'<span>'+a.s+'</span>':"")+(a.html||"")+
      (a.t?'<button type="button" class="go" data-hub-t="'+a.t+'">'+esc(a.go||"Open")+'</button>':"")+'</div>').join("")}

  /* ---------- figures ---------- */
  const isEntryMoney=l=>l.kind==="IN"&&l.src!=="ENTRY";
  function cashFrom(D,C,from,to){
    from=from||D.today;to=to||D.today;C=C||[];
    const one=from===to,isToday=one&&to===D.today,L=D.lines||[];
    const coll=L.filter(isEntryMoney),cm={};coll.forEach(l=>{const m=l.mode==="RTGS"?"BANK":l.mode;cm[m]=(cm[m]||0)+Number(l.amount)});
    const collT=coll.reduce((a,l)=>a+Number(l.amount),0);
    let cin=0,cout=0,dep=0,wd=0;
    for(const l of L){const a=Number(l.amount)||0;if(/^contra\b/i.test(String(l.category||"")))continue;
      if(l.kind==="IN"&&l.mode==="CASH")cin+=a;else if(l.kind==="OUT"&&l.mode==="CASH")cout+=a;else if(l.kind==="DEPOSIT")dep+=a;else if(l.kind==="WITHDRAW")wd+=a}
    const ch=C.filter(c=>c.status==="IN_HAND"),cd=C.filter(c=>c.status==="DEPOSITED"),sum=a=>a.reduce((x,c)=>x+Number(c.amount),0);
    const lastClose=(D.closes||[]).find(c=>c.date===to);
    const handH=isToday?"Cash in hand now":one?"Cash in hand at night":"Cash in hand on "+dmy(to);
    const md=k=>rs(cm[k]||0).replace("₹","");
    return {
      coll:{h:isToday?"Collected today":one?"Collected "+dmy(to):"Collected "+dmy(from)+" – "+dmy(to),v:rs(collT),
        s:"Cash "+md("CASH")+" · UPI "+md("UPI")+" · Bank "+md("BANK")+" · Chq "+md("CHEQUE"),tip:"Party money in every mode (cash, UPI, bank, cheque, driver money)"},
      chq:{v:rs(sum(ch)+sum(cd)),s:(ch.length+cd.length)+" cheque"+(ch.length+cd.length===1?"":"s")+" · "+cd.length+" deposited"},
      hand:{h:handH,v:D.closing_set?rs(D.closing):"—",s:(lastClose&&!lastClose.is_start?"Counted · ":"")+"In "+rs(cin+wd).replace("₹","")+" · Out "+rs(cout).replace("₹","")+" · Bank "+rs(dep).replace("₹",""),
        tip:"Opening "+(D.opening_set?rs(D.opening):"not set")+" + Cash In − Cash Out − Bank deposit"},
      counts:{verify:(D.pending||[]).length,chq:C.filter(c=>c.status==="DEPOSITED"||(c.status==="IN_HAND"&&c.cheque_date<=D.today)).length}
    };
  }
  // short alerts; here = drawn on the cash half (opening box / cash back button work there)
  function cashAlerts(D,C,here){
    const A=[];C=C||[];
    if(!D.opening_set&&!D.last_close)A.push(here?{c:"blue",b:"Set opening cash",s:"count the cash in hand once",
      html:'<input id="startAmt" type="text" inputmode="decimal" placeholder="₹ cash"><button type="button" class="btn" id="startBtn">Set</button>'}
      :{c:"blue",b:"Opening cash not set",s:"count the cash in hand once",t:"book",go:"Set"});
    const ho=(D.closes||[]).find(c=>c.date===D.last_close&&c.handed_to&&!c.returned_at);
    if(ho)A.push(here?{b:"☀ "+rs(ho.counted)+" cash with "+esc(ho.handed_to_name),s:"handed over "+dmy(ho.date)+" night",html:'<button type="button" class="btn grn" data-return="'+ho.id+'">Received back</button>'}
      :{b:"☀ "+rs(ho.counted)+" cash with "+esc(ho.handed_to_name),s:"handed over "+dmy(ho.date)+" night",t:"close",go:"Open"});
    const P=D.pending||[],pa=P.reduce((a,p)=>a+Number(p.amount),0);
    if(P.length)A.push({c:D.is_admin?"":"blue",b:(D.is_admin?"🔔 ":"⏳ ")+P.length+" bank entr"+(P.length===1?"y":"ies")+" · "+rs(pa),
      s:D.is_admin?"UPI / bank / cheque to verify":"waiting for Admin's bank check",t:"verify",go:D.is_admin?"Verify":"See"});
    const due=C.filter(c=>c.status==="DEPOSITED"||(c.status==="IN_HAND"&&c.cheque_date<=D.today));
    if(due.length){const late=due.filter(c=>c.status==="IN_HAND").length;
      A.push({b:"🧾 "+due.length+" cheque"+(due.length===1?"":"s")+" · "+rs(due.reduce((a,c)=>a+Number(c.amount),0)),s:late?late+" to deposit (date reached)":"not in bank yet",t:"cheques",go:"Open"})}
    return A;
  }
  function billFrom(PI,marks,early,brand){
    const LP=window.LWBPartyPay,V=p=>brand?LP.slice(p,brand):p,parties=[...PI.parties.values()].map(V);
    const mk=(PI.raw.orders||[]).filter(x=>(!brand||(x.company_id||"")===brand)&&LP.needsBill(x,marks)).concat(brand?[]:(early||[]));
    const bn=brand&&PI.brandOf?((PI.brandOf(brand)||{}).name||""):"";
    return billKpis({make:mk.length,makeAmt:mk.reduce((a,x)=>a+Number(x.erp_amount||0),0),early:mk.filter(x=>x.early).length,
      due:parties.reduce((a,p)=>a+Math.max(0,p.net),0),dueN:parties.filter(p=>p.net>0.5).length,
      adv:parties.reduce((a,p)=>a+Math.max(0,-p.net),0),advN:parties.filter(p=>p.net<-0.5).length,brand:bn});
  }
  function billKpis(x){
    const pre=x.brand?esc(x.brand)+" · ":"";
    return {make:{v:String(x.make),s:rs(x.makeAmt)+(x.early?" · "+x.early+" not loaded":"")},
      due:{v:rs(x.due),s:x.dueSub||pre+x.dueN+" parties"},adv:{v:rs(x.adv),s:x.advSub||pre+x.advN+" parties"}};
  }

  async function loadCash(client){
    try{
      const [d,c]=await Promise.all([client.rpc("lwb_acc_dashboard",{p_from:null,p_to:null}),client.rpc("lwb_acc_cheque_list")]);
      if(d.error)throw d.error;
      const D=d.data||{};D.lines=D.lines||[];D.pending=D.pending||[];const C=c.error?[]:(c.data||[]);
      const f=cashFrom(D,C);counts(f.counts);kpis({coll:f.coll,chq:f.chq,hand:f.hand});alerts(cashAlerts(D,C,false));
    }catch(e){kpis({coll:{v:"—",s:"open Day book"},chq:{v:"—",s:""},hand:{v:"—",s:""}})}
  }
  async function loadBill(client,PI){
    try{
      const LP=window.LWBPartyPay;if(!PI)PI=await LP.load(client);
      const [mk,early,chg]=await Promise.all([client.rpc("lwb_admin_order_marks",{p_ids:null}),client.rpc("lwb_bills_before_loading"),client.rpc("lwb_bill_change_list",{p_days:30})]);
      const marks=new Map((mk.error?[]:(mk.data||[])).map(m=>[m.order_id,1]));
      const brand=PI.branded&&window.LWBBrand?LWBBrand.get(PI.companies):"";
      kpis(billFrom(PI,marks,early.error?[]:(early.data||[]).map(x=>({...x,early:true})),brand));
      const L=(PI.raw.orders||[]).filter(x=>LP.needsBill(x,marks)).length+(brand?0:(early.error?0:(early.data||[]).length));
      counts({make:L,chg:(chg.error?[]:(chg.data||[])).filter(c=>c.status==="WAITING").length});
    }catch(e){kpis({make:{v:"—",s:""},due:{v:"—",s:""},adv:{v:"—",s:""}})}
  }

  /* ---------- public ---------- */
  function counts(x){Object.assign(cnt,x);drawTabs()}
  function kpis(x){Object.assign(K,x);drawKpis()}
  function alerts(list){AL=list||[];drawAlerts()}
  function setTab(t){if(t!==tab){tab=t;drawTabs()}}
  function mount(opts){
    o=opts||{};tab=o.tab||"";style();drawActs();drawTabs();drawKpis();drawAlerts();
    document.addEventListener("click",e=>{
      const m=e.target.closest("#hubMoreBtn");if(m){moreOpen=!moreOpen;drawTabs();return}
      const t=e.target.closest("[data-hub-t]");if(t){e.preventDefault();go(t.dataset.hubT);return}
      const a=e.target.closest("[data-hub-a]");if(a){if(moreOpen){moreOpen=false;drawTabs()}act(a.dataset.hubA);return}
      if(moreOpen&&!e.target.closest(".hub-more")){moreOpen=false;drawTabs()}
    });
    document.addEventListener("keydown",e=>{if(e.key==="Escape"&&moreOpen){moreOpen=false;drawTabs()}});
  }
  window.LWBAccHub={mount,setTab,counts,kpis,alerts,cashFrom,cashAlerts,billFrom,billKpis,loadCash,loadBill,go,T};
})();
