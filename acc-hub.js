/* Accounts in one place (Mohit, 19 Nov 2026).
   Billing & Outstanding (party-billing.html) and the Accounts Dashboard (accounts-dashboard.html) show one
   "Accounts" header: one row of buttons, short alerts, six cards and ONE tab row. Billing tabs live in
   party-billing.html, Cash & Bank tabs in accounts-dashboard.html; a tab of the other half opens that file
   with ?tab=, so for the user it is one page. Each page fills the cards it already has data for and this file
   loads the rest (cash figures on the billing half, bills on the cash half) with the same rules.

   Split by work (Mohit, 20 Nov 2026), three views of the same two files, the view in the URL hash:
     #tally  Accounts (Tally) = role accounts (Yogesh bhai): Tally bills, party Ledger (view only), bank check, GST, cash too
     #cash   Cashier          = role cashier: Cash In / Out, Deposit, Close Day, Day book, cheques, staff, vehicles
     #party  Party & Collections = Admin (or ticked in Manage Users): To collect, Payments, Ledger, Returns, ACRS
   Admin switches between the three with the chips in the header.

   LWBAccHub.mount({page:"bill"|"cash", tab, role, canParty, onTab(t), onAct(a)}) -> {view, tab}
     page draws #hubActs/#hubTabs/#hubKpis/#hubAls; tab = wanted tab (?tab=), may change to fit the view
   LWBAccHub.setTab(t) · counts({make,chg,chq,verify}) · kpis({make,due,adv,coll,chq,hand}) · alerts([...])
   LWBAccHub.cashFrom(D,C,from,to)  -> cards + alerts from lwb_acc_dashboard + lwb_acc_cheque_list
   LWBAccHub.billFrom(PI,marks,early,brand) -> cards from LWBPartyPay.load
   LWBAccHub.loadCash(client) / loadBill(client,PI)  -> the other half's cards */
(function(){
  "use strict";
  const T={make:"Bills to make",made:"Bills made",due:"To collect",led:"Ledger",pay:"Payments",ret:"Returns",
    book:"Day book",cheques:"Cheques",verify:"Bank check",sum:"Summary",chg:"PO changes",
    grp:"Party groups",books:"📒 Ledger & Outstanding ↗",close:"Cash handover",staff:"Staff ledger",veh:"Vehicles",setup:"Heads & Banks",gst:"GST",acrs:"ACRS orders ↗"};
  const BILL=["make","made","due","led","pay","ret","chg","grp","gst"];
  const VIEWS={
    tally:{name:"Accounts · Tally",chip:"Tally",acts:["pay","IN","OUT","DEPOSIT","close","ret"],
      row:[["Tally",["make","made","chg","ret"]],["Party",["books"]],["Bank & GST",["verify","cheques","gst"]],["Cash",["book","sum"]]],more:["grp","close","staff","veh","setup"],
      kpis:["make","verify","gst","chq","coll","hand"],first:"make"},
    cash:{name:"Cashier",chip:"Cashier",acts:["pay","IN","OUT","DEPOSIT","close"],
      row:[["",["book","cheques","close","staff","veh"]]],more:[],kpis:["open","cin","cout","dep","chq","hand"],first:"book"},
    party:{name:"Party & Collections",chip:"Party",acts:["pay","ret"],
      row:[["",["due","pay","ret","grp"]],["",["books","acrs"]]],more:[],kpis:["due","adv","coll","chq"],first:"due"}};
  const FILE={bill:"party-billing.html",cash:"accounts-dashboard.html"};
  const pageOf=t=>BILL.includes(t)?"bill":"cash";
  const tabsOf=v=>VIEWS[v].row.flatMap(r=>r[1]).concat(VIEWS[v].more).filter(t=>t!=="acrs"&&t!=="books");   // acrs = link to ecrs.html, books = accounts-books.html
  // views a login may open: Cashier only cash; Accounts tally (+ party when Admin ticked it); Admin all three
  const viewsFor=(role,canParty)=>role==="cashier"?["cash"]:role==="admin"?["tally","cash","party"]:canParty?["tally","party"]:["tally"];
  const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const r2=n=>Math.round((Number(n)||0)*100)/100;
  const rs=v=>(r2(v)<0?"−":"")+"₹"+Math.abs(r2(v)).toLocaleString("en-IN",{maximumFractionDigits:2});
  const dmy=d=>d?String(d).slice(8,10)+"/"+String(d).slice(5,7)+"/"+String(d).slice(0,4):"";
  const el=id=>document.getElementById(id);
  let o={page:"bill"},tab="",view="tally",views=["tally"],cnt={},K={},AL=[],moreOpen=false;

  const css=`
  .hub-top{display:flex;align-items:center;gap:6px;flex-wrap:wrap;margin:0 0 8px}
  .hub-top h1{margin:0 4px 0 0;font-size:19px}.hub-top .sp{flex:1 1 auto}.hub-top .lwb-brands{margin:0}
  .hub-ico{height:34px;min-width:34px;border:1.5px solid var(--erp-line);background:#fff;border-radius:99px;font:inherit;font-size:15px;cursor:pointer;color:var(--erp-ink)}
  .hub-ico:disabled{opacity:.5}
  .hub-fin{display:inline-flex;align-items:center;height:30px;padding:0 10px;border-radius:99px;background:#e6f0f0;color:#00434d;font-size:13px;font-weight:700;text-decoration:none;white-space:nowrap}
  .hub-acts{display:flex;gap:6px;margin:0 0 8px}
  .hub-views{display:inline-flex;background:#fff;border:1px solid var(--erp-line);border-radius:99px;padding:2px;gap:2px}
  .hub-views a{display:inline-flex;align-items:center;height:28px;padding:0 11px;border-radius:99px;font-size:13px;font-weight:700;color:#4b5763;text-decoration:none;white-space:nowrap}
  .hub-views a.on{background:#002f37;color:#fff}.hub-views a:not(.on):hover{background:#eef2f7}
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
  .hub-kpis{display:grid;grid-template-columns:repeat(var(--n,6),minmax(0,1fr));gap:8px;margin:0 0 8px}
  .hub-k{background:#fff;border:1px solid var(--erp-line);border-left:4px solid var(--c);border-radius:9px;padding:7px 10px;min-width:0;text-align:left;font:inherit;color:inherit;cursor:pointer}
  .hub-k:hover{border-color:#9fb3c8;border-left-color:var(--c)}
  .hub-k h3{margin:0;font-size:12px;color:#4b5763;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .hub-k b{display:block;font-size:19px;font-weight:800;line-height:1.25;color:var(--v,var(--erp-ink));font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .hub-k small{display:block;font-size:11.5px;color:var(--erp-muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .hub-k.dk{background:#002f37;border-color:#002f37;color:#fff}.hub-k.dk h3,.hub-k.dk small{color:#cfe3e6}.hub-k.dk b{color:#fff}
  .hub-tabs{display:flex;gap:5px;flex-wrap:wrap;align-items:center;margin:0 0 8px;position:relative}
  .hub-tabs .g{font-size:11px;font-weight:800;color:var(--erp-muted);letter-spacing:.4px;text-transform:uppercase;margin:0 1px 0 2px}
  .hub-tabs .bar{width:1px;height:22px;background:var(--erp-line);margin:0 3px}
  .hub-tabs a.x{display:inline-flex;align-items:center;height:32px;border:1.5px dashed var(--erp-line);border-radius:99px;padding:0 11px;font-size:13.5px;color:#00434d;font-weight:700;text-decoration:none;white-space:nowrap}
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
    .hub-acts{display:grid;grid-template-columns:repeat(var(--n,5),minmax(0,1fr));gap:5px}.hub-views a{padding:0 9px;font-size:12.5px}
    .hub-acts button{height:46px;flex-direction:column;gap:0;font-size:11.5px;line-height:1.15}.hub-acts em{font-size:16px}
    .hub-acts .l{display:none}.hub-acts .s{display:inline}.hub-acts.many [data-hub-a=ret]{display:none}
    .hub-als{flex-direction:column;gap:4px}.hub-al{flex:none;width:100%;padding:5px 8px;font-size:12.5px}.hub-al span{display:none}.hub-al input{width:96px}
    .hub-kpis{grid-template-columns:repeat(3,minmax(0,1fr));gap:5px}.hub-kpis.n4{grid-template-columns:repeat(2,minmax(0,1fr))}.hub-k{padding:6px 7px;border-left-width:3px}
    .hub-k h3{font-size:11px}.hub-k b{font-size:15px}.hub-k small{font-size:10.5px}
    .hub-tabs{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:4px}.hub-tabs .g,.hub-tabs .bar{display:none}
    .hub-tabs button{padding:0 4px;font-size:12.5px;height:31px;overflow:hidden;text-overflow:ellipsis}.hub-tabs .n{margin-left:3px;padding:0 4px;font-size:10px}
    .hub-more{left:0;right:0}.hub-more .ph{display:block}
  }`;
  function style(){if(el("hubCss"))return;const s=document.createElement("style");s.id="hubCss";s.textContent=css;document.head.appendChild(s)}

  /* ---------- actions ---------- */
  const ACTS=[["pay","💰","Party payment","Party pay"],["IN","＋","Cash In","Cash In"],["OUT","−","Cash Out","Cash Out"],["DEPOSIT","🏦","Bank Deposit","Deposit"],["close","🌙","Close Day","Close Day"],["ret","↩","Return","Return"]];
  function drawActs(){const b=el("hubActs");if(!b)return;
    const A=ACTS.filter(x=>VIEWS[view].acts.includes(x[0]));
    // phone: one row; Return is hidden there when other buttons are shown (it is in More)
    b.style.setProperty("--n",String(A.filter(x=>x[0]!=="ret"||A.length<3).length));
    b.classList.toggle("many",A.length>=3);
    b.innerHTML=A.map(([a,i,l,s])=>'<button type="button" data-hub-a="'+a+'"><em>'+i+'</em><span class="l">'+l+'</span><span class="s">'+s+'</span></button>').join("")}
  // pay is on both halves; cash entries / Close Day on the cash half; Return on the billing half
  function act(a){
    const here=a==="pay"||(a==="ret"?o.page==="bill":o.page==="cash");
    if(here){o.onAct&&o.onAct(a);return}
    location.href=a==="ret"?FILE.bill+"?tab=ret&new=ret#"+view:FILE.cash+"?new="+a+"#"+view;
  }

  /* ---------- tabs ---------- */
  const badge=t=>{const n={make:cnt.make,chg:cnt.chg,cheques:cnt.chq,verify:cnt.verify}[t];return n?'<span class="n">'+n+'</span>':""};
  const tb=t=>t==="acrs"?'<a class="x" href="ecrs.html">'+esc(T[t])+'</a>':t==="books"?'<a class="x" href="accounts-books.html" title="Ledger, Outstanding, Receipts, Day book (Ctrl+Alt+L)">'+esc(T[t])+'</a>':'<button type="button" data-hub-t="'+t+'" aria-pressed="'+(t===tab)+'">'+esc(T[t])+badge(t)+'</button>';
  function drawTabs(){const b=el("hubTabs");if(!b)return;
    const V=VIEWS[view],MORE=V.more,inMore=MORE.includes(tab),retMore=V.acts.includes("ret")&&V.acts.length>=3;
    const row=V.row.map(([g,l])=>[g,l.filter(t=>t!=="acrs"||o.acrs)]).filter(r=>r[1].length);
    b.innerHTML=row.map(([g,l],i)=>(i?'<span class="bar"></span>':"")+(g?'<span class="g">'+g+'</span>':"")+l.map(tb).join("")).join("")+
      (MORE.length?'<button type="button" id="hubMoreBtn" aria-pressed="'+inMore+'" aria-expanded="'+moreOpen+'">'+(inMore?esc(T[tab]):"More")+' ▾</button>'+
      (moreOpen?'<div class="hub-more" role="menu">'+MORE.map(tb).join("")+(retMore?'<button type="button" class="ph" data-hub-a="ret">↩ Return (goods back)</button>':"")+'</div>':""):"")}
  function go(t){
    if(t==="out")t="due";   // old "Party outstanding" tab = To collect
    if(t==="led"||t==="books"){location.href="accounts-books.html?v=led";return}   // Ledger lives in Ledger & Outstanding now
    moreOpen=false;
    if(!tabsOf(view).includes(t)){const v=views.find(x=>tabsOf(x).includes(t));if(!v){drawTabs();return}view=v}
    if(pageOf(t)!==o.page||location.hash.slice(1)!==view){location.href=FILE[pageOf(t)]+"?tab="+t+"#"+view;return}
    tab=t;drawTabs();o.onTab&&o.onTab(t);
  }
  // Admin (and Accounts with Party ticked): Tally · Cashier · Party chips in the header
  function drawViews(){
    const top=document.querySelector(".hub-top");if(!top)return;
    const h=top.querySelector("h1");if(h)h.textContent=VIEWS[view].name;
    // back to the Finance home (finance.html, Mohit 20 Nov 2026): money now, work waiting, brand-wise
    if(!el("hubFin")){const a=document.createElement("a");a.id="hubFin";a.href="finance.html";a.className="hub-fin";a.title="Finance home (Ctrl+Alt+F)";a.textContent="‹ Finance";top.insertBefore(a,top.firstChild)}
    let b=el("hubViews");
    if(views.length<2){if(b)b.remove();return}
    if(!b){b=document.createElement("nav");b.id="hubViews";b.className="hub-views";b.setAttribute("aria-label","Accounts view");
      const sp=top.querySelector(".sp");top.insertBefore(b,sp||null)}
    b.innerHTML=views.map(v=>{const f=VIEWS[v].first;return '<a href="'+FILE[pageOf(f)]+(f===VIEWS.tally.first||f==="book"?"":"?tab="+f)+"#"+v+'" class="'+(v===view?"on":"")+'"'+(v===view?' aria-current="page"':"")+'>'+esc(VIEWS[v].chip)+'</a>'}).join("");
  }

  /* ---------- cards ---------- */
  const DEF=[["make","#c8102e","Bills to make","make",""],["due","#b3122b","To collect","due","#b3122b"],["coll","#13824a","Collected today","book","#13824a"],
    ["chq","#9a5b00","Cheques not in bank","cheques",""],["adv","#13824a","Advance with us","due",""],["hand","#002f37","Cash in hand","book",""],
    ["verify","#1d5fbf","Bank check","verify","#1d5fbf"],["gst","#6b21a8","GST","gst",""],
    ["open","#5b6672","Opening cash","close",""],["cin","#13824a","Cash In","book","#13824a"],["cout","#c8102e","Cash Out","book","#c8102e"],["dep","#1d5fbf","Bank deposit","book",""]];
  function drawKpis(){const b=el("hubKpis");if(!b)return;
    const L=VIEWS[view].kpis.map(k=>DEF.find(d=>d[0]===k));
    b.style.setProperty("--n",String(L.length));b.classList.toggle("n4",L.length===4);
    b.innerHTML=L.map(([k,c,h,t,v])=>{const x=K[k]||{};
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
    const cnt=f=>L.filter(l=>!/^contra\b/i.test(String(l.category||""))&&f(l)).length,pl=(n,w)=>n+" "+w+(n===1?"":"s");
    const P=D.pending||[],pa=P.reduce((a,p)=>a+Number(p.amount),0),day=isToday?" today":one?" "+dmy(to).slice(0,5):"";
    const chk=D.can_check!=null?D.can_check:D.is_admin;
    return {
      verify:{v:String(P.length),s:P.length?rs(pa)+(chk?" to verify":" waiting"):"all checked ✓",tip:"UPI / bank / cheque / deposit entries waiting for the bank check"},
      open:{h:one?"Opening cash"+(isToday?"":" "+dmy(from).slice(0,5)):"Opening "+dmy(from).slice(0,5),v:D.opening_set?rs(D.opening):"—",s:D.opening_set?"counted last night":"not set yet"},
      cin:{h:"Cash In"+day,v:rs(cin+wd),s:pl(cnt(l=>(l.kind==="IN"&&l.mode==="CASH")||l.kind==="WITHDRAW"),"entry").replace("entrys","entries")},
      cout:{h:"Cash Out"+day,v:rs(cout),s:pl(cnt(l=>l.kind==="OUT"&&l.mode==="CASH"),"entry").replace("entrys","entries")},
      dep:{h:"Bank deposit"+day,v:rs(dep),s:pl(cnt(l=>l.kind==="DEPOSIT"),"deposit")},
      coll:{h:isToday?"Collected today":one?"Collected "+dmy(to):"Collected "+dmy(from).slice(0,5)+" – "+dmy(to).slice(0,5),v:rs(collT),
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
    const chk=D.can_check!=null?D.can_check:D.is_admin;
    // Cashier: no Bank check tab; the entries just wait for Accounts
    if(P.length)A.push({c:chk?"":"blue",b:(chk?"🔔 ":"⏳ ")+P.length+" bank entr"+(P.length===1?"y":"ies")+" · "+rs(pa),
      s:chk?"UPI / bank / cheque to verify":"waiting for the bank check by Accounts",t:tabsOf(view).includes("verify")?"verify":"",go:chk?"Verify":"See"});
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
      // cash cards on the billing half follow the ONE top bar date too (erp-period.js, Mohit 20 Nov 2026)
      const r=window.LWBPeriod?LWBPeriod.get():null,pf=r?r.from:null,pt=r?r.to:null;
      const [d,c]=await Promise.all([client.rpc("lwb_acc_dashboard",{p_from:pf,p_to:pt}),client.rpc("lwb_acc_cheque_list")]);
      if(d.error)throw d.error;
      const D=d.data||{};D.lines=D.lines||[];D.pending=D.pending||[];const C=c.error?[]:(c.data||[]);
      const f=cashFrom(D,C,pf,pt);counts(f.counts);kpis({coll:f.coll,chq:f.chq,hand:f.hand,verify:f.verify});if(view!=="party")alerts(cashAlerts(D,C,false));
    }catch(e){kpis({coll:{v:"—",s:"open Day book"},chq:{v:"—",s:""},hand:{v:"—",s:""},verify:{v:"—",s:""}})}
  }
  // GST card (Tally view): last month = the return due now (GSTR-3B by the 20th)
  const MON=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  const monName=m=>MON[Number(String(m).slice(5,7))-1]+" "+String(m).slice(2,4);
  function gstState(r,today){
    const due=r.gstr3b_on?r2(Number(r.tax_3b||0)-Number(r.itc_used||0)-Number(r.paid||0)):null;
    const next=new Date(String(r.month).slice(0,10)+"T12:00:00Z");next.setUTCMonth(next.getUTCMonth()+1);next.setUTCDate(20);
    const dueDay=next.toISOString().slice(0,10),late=!r.gstr3b_on&&today>dueDay,open=String(today).slice(0,7)===String(r.month).slice(0,7);
    if(!r.gstr3b_on&&!Number(r.sales_bills)&&!Number(r.pur_bills)&&!open)return {c:"t-gry",t:"No ERP bills",due:null,dueDay,late:false};
    if(!r.gstr3b_on)return {c:open?"t-gry":late?"t-red":"t-amb",t:open?"Month running":late?"3B late":"3B due "+dmy(dueDay).slice(0,5),due:null,dueDay,late};
    if(due>1)return {c:"t-amb",t:"Pay "+rs(due),due,dueDay};
    return {c:"t-grn",t:"Filed & paid",due:0,dueDay};
  }
  async function loadGst(client){
    if(!VIEWS[view].kpis.includes("gst"))return null;
    try{
      const {data,error}=await client.rpc("lwb_gst_summary",{p_months:13});if(error)throw error;
      const R=data.rows||[],last=R[1]||R[0];if(!last){kpis({gst:{v:"—",s:""}});return data}
      const st=gstState(last,data.today),net=r2(Number(last.sales_gst)-Number(last.pur_gst));
      const late=R.slice(1).filter(r=>gstState(r,data.today).late).length;
      kpis({gst:{h:"GST "+monName(last.month),v:st.t,s:(late>1?late+" months not filed · ":"")+"ERP net "+rs(Math.round(net)),tip:"Sales GST "+rs(last.sales_gst)+" − purchase GST "+rs(last.pur_gst)}});
      return data;
    }catch(e){kpis({gst:{v:"—",s:"GST not set up yet"}});return null}
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
    o=opts||{};style();
    views=viewsFor(String(o.role||"").toLowerCase(),!!o.canParty);
    const h=location.hash.slice(1);let saved="";try{saved=localStorage.getItem("lwbAccView")||""}catch(e){}
    view=views.includes(h)?h:views.includes(saved)?saved:views[0];
    // the wanted tab decides the view when this view does not have it (old links: ?tab=due, #verify ...)
    let t=o.tab||"";if(t==="out")t="due";
    if(t&&!tabsOf(view).includes(t)){const v=views.find(x=>tabsOf(x).includes(t));if(v)view=v;else t=""}
    if(!t){const f=VIEWS[view].first,mine=tabsOf(view).filter(x=>pageOf(x)===o.page);
      t=pageOf(f)===o.page?f:mine.includes("book")?"book":mine[0]||f}
    try{localStorage.setItem("lwbAccView",view)}catch(e){}
    if(location.hash.slice(1)!==view)history.replaceState(null,"",location.pathname+location.search+"#"+view);
    tab=t;
    // a view whose first tab lives in the other file (Cashier opened on the billing half)
    if(pageOf(tab)!==o.page){location.replace(FILE[pageOf(tab)]+"?tab="+tab+"#"+view);return {view,tab,away:true}}
    drawViews();drawActs();drawTabs();drawKpis();drawAlerts();
    // menu link to another view of the same file only changes the hash: open it fresh
    window.addEventListener("hashchange",()=>{const n=location.hash.slice(1);if(VIEWS[n]&&n!==view)location.reload()});
    document.addEventListener("click",e=>{
      const m=e.target.closest("#hubMoreBtn");if(m){moreOpen=!moreOpen;drawTabs();return}
      const t=e.target.closest("[data-hub-t]");if(t){e.preventDefault();go(t.dataset.hubT);return}
      const a=e.target.closest("[data-hub-a]");if(a){if(moreOpen){moreOpen=false;drawTabs()}act(a.dataset.hubA);return}
      if(moreOpen&&!e.target.closest(".hub-more")){moreOpen=false;drawTabs()}
    });
    document.addEventListener("keydown",e=>{if(e.key==="Escape"&&moreOpen){moreOpen=false;drawTabs()}});
    return {view,tab};
  }
  const has=t=>tabsOf(view).includes(t);
  window.LWBAccHub={mount,setTab,counts,kpis,alerts,cashFrom,cashAlerts,billFrom,billKpis,loadCash,loadBill,loadGst,gstState,monName,go,T,has,
    get view(){return view},VIEWS,viewsFor};
})();
