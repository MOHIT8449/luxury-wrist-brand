/* LUXURY WRIST BRAND ERP — role-wise home Dashboard (Admin, Sales Head, Accounts, Godown Manager, Salesman).
   dashboard.html calls LWBRoleDash.start({client, role, uid, plan}) for these roles; other roles keep the
   old Dashboard. Read-only: it only reads data that the existing pages already read (no SQL of its own).
   Every card loads on its own; a card whose data is not allowed or not installed is simply left out. */
(function(){
  if(window.LWBRoleDash)return;
  const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const num=v=>{const n=Number(v);return Number.isFinite(n)?n:0};
  const fmt=n=>Math.round(num(n)).toLocaleString("en-IN");
  const rs=n=>(num(n)<0?"−":"")+"₹"+Math.abs(Math.round(num(n))).toLocaleString("en-IN");
  const lakh=n=>{n=num(n);const a=Math.abs(n);return a>=1e7?"₹"+(n/1e7).toFixed(2)+" Cr":a>=1e5?"₹"+(n/1e5).toFixed(1)+" L":rs(n)};
  const pct=(a,b)=>b>0?Math.round(a/b*100):null;
  const istDay=v=>{const t=Date.parse(v);return isNaN(t)?"":new Date(t+19800000).toISOString().slice(0,10)};
  const today=()=>istDay(new Date().toISOString());
  const shift=(d,n)=>new Date(Date.parse(d+"T12:00:00Z")+n*864e5).toISOString().slice(0,10);
  const days=(a,b)=>Math.round((Date.parse(b+"T12:00:00Z")-Date.parse(a+"T12:00:00Z"))/864e5);
  const dmy=v=>window.LWBDate?LWBDate.d(v):String(v||"");
  const dm=d=>String(d).slice(8,10)+"/"+String(d).slice(5,7);
  const key=v=>String(v==null?"":v).toUpperCase().replace(/[^A-Z0-9]+/g," ").trim();
  const st=o=>String((o&&o.status)||"").toLowerCase().trim().replace(/[\s-]+/g,"_");
  const WAIT=["","pending","submitted","pending_manager","pending_approval","pending_review","new"];
  const OFF=["cancelled","canceled","rejected"];
  const OPEN=["pending_approval","approved","transport_allocated","loading","loaded"];
  const APPROVAL_HOURS=12;
  const ORDER_COLS="id,order_no,order_date,created_at,customer_name,sales_person,status,total_qty,total_amount,total_weight,created_by,priority";
  let C=null,ROLE="",UID="",PLAN=null,box=null,seq=0;
  // Company / brand filter (brand-filter.js, lwb_company_brand_setup.sql): list = my companies,
  // id = chosen brand ("" = all), map = SKU -> company. Chips for Admin and Sales Head.
  const BR={list:[],id:"",map:null,allow:null,all:[]};
  const BRAND_ROLES=["admin","manager"];

  /* ---------- small helpers ---------- */
  const safe=p=>Promise.resolve(p).then(r=>r&&r.error?null:r?("data" in r?r.data:r):null).catch(()=>null);
  const hidden=()=>{try{return ERPShell.hiddenPages()}catch(e){return []}};
  const can=h=>!hidden().includes(String(h).split(/[?#]/)[0]);
  const go=(h,t)=>h&&can(h)?'<a href="'+esc(h)+'">'+t+"</a>":"";
  // Count card → list popup (erp-list.js). lst(title, sub, rows|loader, cols, page) returns an id
  // the card carries in data-list; paint() makes those cards open the list.
  let LISTS=new Map(),LN=0;
  function lst(title,sub,rows,cols,page){
    const id="l"+(++LN);
    LISTS.set(id,()=>({title,sub,cols:cols||OCOLS,rows:typeof rows==="function"?undefined:rows,load:typeof rows==="function"?rows:undefined,
      page:page&&can(page)?page:undefined,pageText:"Open page →",onRow:cols?undefined:o=>{if(o&&o.id&&can("warehouse-orders.html")&&["admin","manager"].includes(ROLE))location.href="warehouse-orders.html?order="+encodeURIComponent(o.id)}}));
    return id;
  }
  const dlA=id=>id?' data-list="'+id+'"':"";
  function kpi(tone,label,value,foot,href,list){
    const tag=href&&can(href)?'a href="'+esc(href)+'"':"div";
    return "<"+tag+' class="rd-kpi rd-'+tone+'"'+dlA(list)+"><small>"+esc(label)+"</small><b>"+value+"</b><span>"+(foot||"")+"</span></"+tag.split(" ")[0]+">";
  }
  // Card titles start with an emoji; show a matching line icon instead.
  const RD_IC={"⚠️":'<path d="M12 3 2 21h20z"/><path d="M12 10v5M12 18h.01"/>',"✔️":'<path d="M4 12l5 5L20 6"/>',"🌙":'<path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z"/>',
    "🎯":'<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1"/>',"🏆":'<path d="M8 4h8v5a4 4 0 0 1-8 0z"/><path d="M8 6H5a3 3 0 0 0 3 4M16 6h3a3 3 0 0 1-3 4M12 13v4M8 21h8M9 17h6"/>',
    "🏷️":'<path d="M3 3h8l10 10-8 8L3 11z"/><circle cx="7.5" cy="7.5" r="1.5"/>',"💰":'<rect x="2" y="6" width="20" height="13" rx="2"/><path d="M16 12.5h2M2 10h20"/>',"💳":'<rect x="2" y="5" width="20" height="14" rx="2"/><path d="M2 10h20M6 15h4"/>',
    "📅":'<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>',"📈":'<path d="M3 17l6-6 4 4 8-8"/><path d="M15 7h6v6"/>',"📍":'<path d="M12 22s7-7 7-12a7 7 0 0 0-14 0c0 5 7 12 7 12z"/><circle cx="12" cy="10" r="2.5"/>',
    "📝":'<path d="M5 3h10l4 4v14H5z"/><path d="M9 12h6M9 16h6"/>',"📦":'<path d="M3 7l9-4 9 4-9 4-9-4z"/><path d="M3 7v10l9 4 9-4V7M12 11v10"/>',"🔥":'<path d="M12 22a7 7 0 0 0 7-7c0-4-3-6-4-10-2 2-3 4-3 6-1-1-2-2-2-4-2 2-5 5-5 8a7 7 0 0 0 7 7z"/>',
    "🚚":'<path d="M2 6h11v10H2z"/><path d="M13 9h4l4 4v3h-8"/><circle cx="6" cy="18" r="2"/><circle cx="17" cy="18" r="2"/>',"🧾":'<path d="M6 2h12v20l-3-2-3 2-3-2-3 2z"/><path d="M9 7h6M9 11h6M9 15h4"/>'};
  RD_IC["🚛"]=RD_IC["🚚"];
  const rdTitle=t=>{const m=/^(\S+)\s+/.exec(t),p=m&&RD_IC[m[1]];return p?'<span class="rd-ic" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">'+p+"</svg></span>"+t.slice(m[0].length):t};
  const card=(title,link,body,note,id)=>'<section class="rd-card"'+(id?' id="'+id+'"':"")+"><h2>"+rdTitle(title)+(link||"")+"</h2>"+body+(note?'<div class="rd-note">'+note+"</div>":"")+"</section>";
  const badge=(c,t)=>'<span class="rd-b rd-b-'+c+'">'+t+"</span>";
  const bar=(p,c)=>'<div class="rd-bar'+(c?" rd-bar-"+c:"")+'"><i style="width:'+Math.max(0,Math.min(100,p||0))+'%"></i></div>';
  const step=(n,label,extra,hot,href,list)=>{const t=href&&can(href)?'a href="'+esc(href)+'"':"div";
    return "<"+t+' class="rd-step'+(hot?" hot":"")+'"'+dlA(list)+'><b>'+n+"</b><small>"+label+"</small>"+(extra?"<i>"+extra+"</i>":"")+"</"+t.split(" ")[0]+">"};
  const dot=(c,html)=>'<div class="rd-alert"><span class="rd-dot rd-dot-'+c+'"></span><span>'+html+"</span></div>";
  const ago=v=>{const m=Math.max(0,Math.round((Date.now()-Date.parse(v))/6e4));return m<60?m+" min":m<1440?Math.floor(m/60)+" h "+(m%60)+" min":Math.floor(m/1440)+" days"};
  const sum=(a,f)=>a.reduce((n,x)=>n+num(f(x)),0);
  const STN=o=>{const s=st(o);return s===""?"Pending":s.replace(/_/g," ").replace(/\b\w/g,c=>c.toUpperCase())};
  const OCOLS=[{t:"PO No.",v:"order_no"},{t:"Date",v:o=>o.order_date||o.created_at,date:true},{t:"Party",v:"customer_name"},
    {t:"Salesman",v:o=>takerOf(o,TEAM||[])},{t:"Cases",v:"total_qty",num:true,sum:true,dec:0},{t:"Weight kg",v:"total_weight",num:true,sum:true,dec:0},
    {t:"Amount",v:"total_amount",money:true,sum:true},{t:"Status",v:o=>(o.priority&&o.priority!=="NORMAL"?o.priority+" · ":"")+STN(o)}];
  const PCOLS=[{t:"Party",v:"party"},{t:"Due",v:"due",money:true,sum:true},{t:"Oldest bill (days)",v:"oldest",num:true,dec:0}];
  const SCOLS=[{t:"SKU",v:"sku"},{t:"In godown",v:"have",num:true,sum:true,dec:0},{t:"Ordered",v:"need",num:true,sum:true,dec:0},{t:"Short",v:"short",num:true,sum:true,dec:0},{t:"Coming",v:"transit",num:true,sum:true,dec:0}];
  const ACOLS=[{t:"Date",v:"date",date:true},{t:"Head",v:"category"},{t:"Party",v:"party"},{t:"Mode",v:"mode"},{t:"PO / Ref",v:l=>[l.order_no,l.ref].filter(Boolean).join(" · ")},{t:"Remark",v:"remark"},{t:"Amount",v:"amount",money:true,sum:true}];
  const delivered=(from,to)=>async()=>{const r=await C.rpc("lwb_po_summary_orders",{p_bucket:"delivered",p_from:from,p_to:to});if(r.error)throw r.error;return r.data||[]};
  const live=o=>!OFF.includes(st(o));

  async function ordersFrom(from){
    const out=[];
    for(let page=0;page<20;page++){
      const r=await C.from("orders").select(ORDER_COLS).gte("order_date",from+"T00:00:00+05:30").order("order_date").range(page*1000,page*1000+999);
      if(r.error)throw r.error;
      out.push(...(r.data||[]));if((r.data||[]).length<1000)break;
    }
    return out;
  }
  // This month (and the last 7 days) plus every order still open, however old.
  async function loadOrders(){
    const t=today(),from=[t.slice(0,8)+"01",shift(t,-6)].sort()[0];
    const [a,b]=await Promise.all([ordersFrom(from).catch(()=>null),safe(C.from("orders").select(ORDER_COLS).in("status",OPEN).limit(3000))]);
    if(!a&&!b)return null;
    const m=new Map();for(const o of (a||[]).concat(b||[]))m.set(o.id,o);
    return [...m.values()].map(o=>({...o,day:istDay(o.order_date||o.created_at)}));
  }
  async function itemsOf(ids,cols){
    const out=[];
    for(let i=0;i<ids.length;i+=150){
      const r=await C.from("order_items").select(cols||"order_id,sku_name,ordered_qty,approved_qty,loaded_qty,rate").in("order_id",ids.slice(i,i+150));
      if(r.error)return null;out.push(...(r.data||[]));
    }
    return out;
  }
  const qtyOf=it=>it.approved_qty!=null?num(it.approved_qty):num(it.ordered_qty);
  // Pack unit: Rajnigandha boxes, Coca-Cola cases. "cs" / "box" per SKU; totals say cases,
  // boxes, or qty when the shown brands sell in both.
  const uOf=sku=>BR.map&&window.LWBBrand&&LWBBrand.unitByName(sku,BR.map,BR.all)==="BOX"?"box":"cs";
  const qWord=()=>{const L=BR.allow?BR.all.filter(c=>BR.allow.has(c.id)):BR.all.filter(c=>c.active!==false),b=L.filter(c=>c.pack_unit==="BOX").length;
    return !b?"cases":b===L.length?"boxes":"qty"};
  const brandOf=sku=>BR.map?(BR.map.get(LWBBrand.skuKey(sku))||""):"";
  const inBrand=sku=>!BR.allow||BR.allow.has(brandOf(sku));
  // With a brand chosen, each order keeps only that brand's share (by line value) of its amount, cases and weight.
  async function brandOrders(orders){
    if(!orders||!BR.allow||!BR.map)return orders;
    const items=await itemsOf(orders.map(o=>o.id));if(!items)return orders;
    const by=new Map();for(const it of items){const x=by.get(it.order_id)||{all:0,mine:0,cs:0};const v=qtyOf(it)*num(it.rate);x.all+=v;if(inBrand(it.sku_name)){x.mine+=v;x.cs+=qtyOf(it)}by.set(it.order_id,x)}
    return orders.map(o=>{const x=by.get(o.id);if(!x||!x.cs)return null;const f=x.all>0?x.mine/x.all:1;
      return {...o,total_amount:num(o.total_amount)*f,total_qty:x.cs,total_weight:num(o.total_weight)*f}}).filter(Boolean);
  }
  // Company targets of the chosen brands as one list: company total (else salesmen summed) + per salesman.
  function brandTargets(list){
    const rows=(list||[]).filter(x=>BR.allow.has(x.company_id)),by=new Map();let total=0;
    for(const c of BR.allow){const r=rows.filter(x=>x.company_id===c),co=r.find(x=>!x.salesman_id);total+=co?num(co.target_amount):sum(r.filter(x=>x.salesman_id),x=>x.target_amount)}
    for(const x of rows)if(x.salesman_id)by.set(x.salesman_id,(by.get(x.salesman_id)||0)+num(x.target_amount));
    return [{salesman_id:null,target_amount:total}].concat([...by].map(([k,v])=>({salesman_id:k,target_amount:v})));
  }
  const loadOrdersB=()=>loadOrders().then(brandOrders);
  async function overview(){
    if(!BR.list.length)return null;
    const t=today();return safe(C.rpc("lwb_company_overview",{p_from:t.slice(0,8)+"01",p_to:t}));
  }
  // Brand-wise: this month's sales vs target, market outstanding, money to pay the company.
  function brandCard(ov){
    if(!ov||!ov.companies||!ov.companies.length)return "";
    const pay=!!ov.payable,out=!!ov.outstanding,G=(o,id)=>(o&&o[id])||{};
    const rows=ov.companies.map(c=>{const M=G(ov.month_sales,c.id),T=G(ov.targets,c.id),D=G(ov.outstanding,c.id),P=G(ov.payable,c.id),p=pct(num(M.amount),num(T.amount));
      return "<tr"+(BR.id===c.id?' class="rd-hl"':"")+'><td><span class="rd-dot" style="background:'+esc(c.color)+'"></span><b>'+esc(c.name)+"</b>"+(num(T.amount)?bar(p,p<50?"red":p<75?"amb":""):"")+'</td><td class="n">'+lakh(M.amount)+"<small>"+(num(T.amount)?p+"% of "+lakh(T.amount):"no target")+"</small></td>"+
        (out?'<td class="n">'+lakh(D.due)+(num(D.overdue)?'<small class="dn">'+lakh(D.overdue)+" late</small>":"")+"</td>":"")+
        (pay?'<td class="n">'+lakh(P.balance)+(num(P.overdue)?'<small class="dn">'+lakh(P.overdue)+" late</small>":P.next_due?"<small>by "+dmy(P.next_due)+"</small>":"")+"</td>":"")+"</tr>"}).join("");
    const none=num(ov.skus_without_company);
    return card("🏷️ Brand-wise — "+new Date().toLocaleDateString("en-IN",{month:"long"}),go("companies.html","Company / Brand →"),'<div class="rd-scroll"><table class="rd-brand"><thead><tr><th>Brand</th><th class="n">Sales</th>'+(out?'<th class="n">To collect</th>':"")+(pay?'<th class="n">To pay co.</th>':"")+"</tr></thead><tbody>"+rows+"</tbody></table></div>",
      !ov.limited&&none?none+" SKU"+(none==1?"":"s")+" without company · set in SKU Master":"Late = past party / company udhari days");
  }
  // Cases ordered on approved / not yet loaded orders vs godown stock (lwb_po_stock).
  async function stockCheck(orders){
    if(!orders)return null;
    const open=orders.filter(o=>["approved","transport_allocated","loading"].includes(st(o)));
    const [stock,items]=await Promise.all([safe(C.rpc("lwb_po_stock")),itemsOf(open.map(o=>o.id))]);
    if(!stock||!stock.length||!items)return null;
    const g=new Map(stock.map(s=>[key(s.sku_name),s])),need=new Map();
    for(const it of items){if(!inBrand(it.sku_name))continue;const k=key(it.sku_name);const x=need.get(k)||{sku:String(it.sku_name||"").trim(),cases:0};x.cases+=qtyOf(it);need.set(k,x)}
    if(BR.allow&&BR.map)for(const s of stock)if(!need.has(key(s.sku_name))&&!inBrand(s.sku_name))g.delete(key(s.sku_name));
    return [...need.entries()].map(([k,x])=>{const s=g.get(k),have=s?num(s.godown_cases):0;return {sku:x.sku,need:x.cases,have,transit:s?num(s.transit_cases):0,short:Math.max(0,x.cases-have)}})
      .filter(x=>x.need>0).sort((a,b)=>b.short-a.short||(a.have-a.need)-(b.have-b.need));
  }
  async function salesTeam(){
    const t=today(),[team,tg]=await Promise.all([safe(C.rpc("lwb_sales_team")),safe(C.from("lwb_sales_targets").select("*").eq("month",t.slice(0,8)+"01"))]);
    return {team:team||[],targets:tg||[]};
  }
  // Order is credited to the login that took it, else to its sales person text, else Office.
  function takerOf(o,team){const t=team.find(x=>x.user_id===o.created_by);return t?t.full_name:String(o.sales_person||"").trim()||"Office"}
  const monthDays=()=>{const t=today(),y=+t.slice(0,4),m=+t.slice(5,7);return new Date(Date.UTC(y,m,0)).getUTCDate()};
  const daysLeft=()=>monthDays()-Number(today().slice(8,10))+1;
  function companyTarget(targets){
    const c=targets.find(x=>!x.salesman_id);if(c&&num(c.target_amount))return num(c.target_amount);
    return sum(targets.filter(x=>x.salesman_id),x=>x.target_amount);
  }
  async function verifyQueue(){return safe(C.rpc("lwb_my_verify_queue"))}
  const queueItem=(q,item)=>(q||[]).find(r=>r.item===item)||null;
  function outstanding(PI){
    if(!PI)return null;
    const t=PI.today||today(),age={a:0,b:0,c:0,d:0},parties=[];
    for(const p of PI.parties.values()){
      const net=Math.max(0,p.due-p.advance);if(net<1)continue;
      let left=p.advance;
      for(const b of p.bills){let due=num(b.due);const use=Math.min(left,due);left-=use;due-=use;if(due<0.5)continue;
        const d=b.invoice_date?days(String(b.invoice_date).slice(0,10),t):0;age[d<=15?"a":d<=30?"b":d<=60?"c":"d"]+=due}
      parties.push({party:p.party,due:net,oldest:p.oldest?days(String(p.oldest).slice(0,10),t):null});
    }
    parties.sort((a,b)=>b.due-a.due);
    return {total:sum(parties,p=>p.due),over30:age.c+age.d,age,parties};
  }
  function accTotals(D){
    const t={cashIn:0,cashOut:0,dep:0,upi:0,bank:0,cheque:0};
    for(const l of (D&&D.lines)||[]){const a=num(l.amount);
      if(l.kind==="IN"){if(l.mode==="CASH")t.cashIn+=a;else if(l.mode==="UPI")t.upi+=a;else if(l.mode==="CHEQUE")t.cheque+=a;else t.bank+=a}
      else if(l.kind==="OUT"&&l.mode==="CASH")t.cashOut+=a;else if(l.kind==="DEPOSIT")t.dep+=a}
    return t;
  }
  const chequesSoon=list=>(list||[]).filter(c=>c.status==="IN_HAND"&&c.cheque_date&&String(c.cheque_date)<=shift(today(),7)).sort((a,b)=>String(a.cheque_date).localeCompare(String(b.cheque_date)));
  function sevenDays(orders){
    const t=today(),out=[];
    for(let i=6;i>=0;i--){const d=shift(t,-i);out.push({d,v:sum(orders.filter(o=>live(o)&&o.day===d),o=>o.total_amount)})}
    const max=Math.max(1,...out.map(x=>x.v));
    return '<div class="rd-chart">'+out.map((x,i)=>'<div class="'+(i===6?"t":"")+'" title="'+dmy(x.d)+": "+rs(x.v)+'"><em>'+(x.v?lakh(x.v).replace("₹",""):"")+'</em><i style="height:'+Math.max(2,Math.round(x.v/max*100))+'%"></i>'+dm(x.d)+"</div>").join("")+"</div>";
  }
  function orderRow(o,extra){return '<tr><td><b class="rd-po">'+esc(o.order_no||"—")+"</b></td><td>"+esc(o.customer_name||"—")+"</td>"+extra+"</tr>"}

  /* ---------- order profit (Admin / Sales Head) ----------
     Profit of a line = (PO rate − landing per case) × cases (approved, else ordered).
     Landing = Rate & Scheme pack of the SKU, without ROI: same formula as order-entry.html calcLanding,
     with the MEPD scheme of the SKU category on the order date. Rate packs are readable only by
     Admin / Manager (RLS), so for anyone else this returns null and the card is left out. */
  let LAND=null,TEAM=[];
  async function landingData(){
    if(LAND&&Date.now()-LAND.at<3e5)return LAND;
    const [s,p,l,m,k]=await Promise.all([safe(C.from("lwb_rate_settings").select("mepd_pct,roi_main,roi_landing").eq("id",1).maybeSingle()),
      safe(C.from("lwb_rate_packs").select("*")),safe(C.from("lwb_rate_pack_skus").select("sku_key,pack_id")),
      safe(C.from("lwb_mepd_schemes").select("categories,mepd_pct,valid_from,valid_to,created_at")),safe(C.from("sku_master").select("sku_name,category"))]);
    if(!s||!p||!p.length||!l)return null;
    const packs=new Map(p.filter(x=>x.active!==false).map(x=>[x.id,x])),bySku=new Map(),cat=new Map();
    for(const x of l){const q=packs.get(x.pack_id);if(q)bySku.set(String(x.sku_key||"").trim().toUpperCase(),q)}
    for(const x of k||[])cat.set(String(x.sku_name||"").trim().toUpperCase(),x.category);
    LAND={at:Date.now(),S:{mepd_pct:num(s.mepd_pct),roi_main:num(s.roi_main)},bySku,cat,schemes:m||[]};
    return LAND;
  }
  function landingOf(R,sku,day){
    const u=String(sku||"").trim().toUpperCase(),r=R.bySku.get(u);if(!r)return null;
    const c=R.cat.get(u);let sc=null;
    if(c)for(const x of R.schemes)if(x.valid_from<=day&&day<=x.valid_to&&(x.categories||[]).some(y=>String(y||"").replace(/\s+/g," ").trim().toUpperCase()===String(c).replace(/\s+/g," ").trim().toUpperCase())&&(!sc||String(x.created_at)>String(sc.created_at)))sc=x;
    const S=R.S,C2=num(r.case_config),D=num(r.gr),F=num(r.free_bottle),H=num(r.qps),I=S.roi_main;
    const E=D*(sc?num(sc.mepd_pct):r.mepd_pct===""||r.mepd_pct==null?S.mepd_pct:num(r.mepd_pct))/100;
    if(F>0&&C2){const base=D-E-H-I-((D/C2)-1)*F,O=Math.round(((num(r.slab3_rate)-base)/(1+F/C2))*100)/100;return D-E-((((D/C2)-1)*F)-((O/C2)*F))-H-I}
    return D-E-num(r.oms)-H-I;
  }
  async function profitOf(list){
    const R=await landingData();if(!R)return null;
    const items=list.length?await itemsOf(list.map(o=>o.id),"order_id,sku_name,ordered_qty,approved_qty,rate"):[];
    if(!items)return null;
    const by=new Map(list.map(o=>[o.id,{o,sale:0,cost:0,profit:0,cases:0,missing:0,lines:[]}]));
    for(const it of items){const x=by.get(it.order_id);if(!x||!inBrand(it.sku_name))continue;
      const q=qtyOf(it),rate=num(it.rate),land=landingOf(R,it.sku_name,x.o.day),line={sku:String(it.sku_name||"").trim(),q,rate,land,p:land==null?null:(rate-land)*q};
      x.lines.push(line);x.cases+=q;x.sale+=rate*q;
      if(land==null)x.missing++;else{x.cost+=land*q;x.profit+=line.p}}
    const rows=[...by.values()].filter(x=>x.lines.length);
    const known=rows.reduce((a,x)=>a+x.sale-x.lines.filter(l=>l.land==null).reduce((b,l)=>b+l.rate*l.q,0),0);
    return {rows,profit:sum(rows,x=>x.profit),sale:sum(rows,x=>x.sale),known,missing:sum(rows,x=>x.missing)};
  }
  // Manage Users > Pages > "See profit": unticked = "dashboard.html#profit" in the user's hidden list.
  const profitOk=()=>!hidden().includes("dashboard.html#profit");
  const margin=(p,s)=>s>0?(Math.round(p/s*1000)/10)+"%":"—";
  function profitKpi(P,n,tone){
    if(!P)return "";
    return '<button type="button" class="rd-kpi rd-'+tone+' rd-tap" data-profit="1"><small>Today\'s Profit</small><b>'+rs(P.profit)+"</b><span>"+
      (P.rows.length?margin(P.profit,P.known)+" margin · "+fmt(n)+" order"+(n==1?"":"s")+" · tap to see order-wise":"No order yet today")+"</span></button>";
  }
  async function ordersOn(day){
    const r=await C.from("orders").select(ORDER_COLS).gte("order_date",day+"T00:00:00+05:30").lt("order_date",shift(day,1)+"T00:00:00+05:30").order("order_date").limit(2000);
    if(r.error)throw r.error;
    return (r.data||[]).map(o=>({...o,day:istDay(o.order_date||o.created_at)})).filter(live);
  }
  let PDAY="",pseq=0,open=new Set();
  function pop(){
    let el=document.getElementById("rdProfit");
    if(el)return el;
    el=document.createElement("div");el.id="rdProfit";el.className="rd-pop";el.hidden=true;
    el.innerHTML='<div class="rd-pop-box rd-card" role="dialog" aria-modal="true" aria-labelledby="rdProfitT"><h2 id="rdProfitT">💰 Order-wise profit<span class="rd-day"><button type="button" data-pd="-1" aria-label="Previous day">‹</button><b></b><button type="button" data-pd="1" aria-label="Next day">›</button></span><button type="button" class="rd-x" aria-label="Close">×</button></h2><div class="rd-pop-in"></div></div>';
    el.addEventListener("click",e=>{
      if(e.target===el||e.target.closest(".rd-x")){el.hidden=true;document.body.classList.remove("rd-lock");return}
      const d=e.target.closest("[data-pd]");if(d&&!d.disabled){showProfit(shift(PDAY,Number(d.dataset.pd)));return}
      const tr=e.target.closest("tr[data-oid]");if(tr){const id=tr.dataset.oid;open.has(id)?open.delete(id):open.add(id);tr.classList.toggle("on");const nx=tr.nextElementSibling;if(nx&&nx.classList.contains("rd-lines"))nx.hidden=!open.has(id)}
    });
    document.addEventListener("keydown",e=>{if(e.key==="Escape"&&!el.hidden){el.hidden=true;document.body.classList.remove("rd-lock")}});
    document.body.appendChild(el);
    return el;
  }
  async function showProfit(day){
    if(!profitOk())return;
    const el=pop(),my=++pseq,inn=el.querySelector(".rd-pop-in");
    PDAY=day;open=new Set();el.hidden=false;document.body.classList.add("rd-lock");
    el.querySelector(".rd-day b").textContent=dmy(day)+(day===today()?" · Today":"");
    el.querySelector('[data-pd="1"]').disabled=day>=today();
    inn.innerHTML='<div class="rd-empty">Loading…</div>';
    let P=null;try{P=await profitOf(await ordersOn(day))}catch(e){console.error(e)}
    if(my!==pseq)return;
    if(!P){inn.innerHTML='<div class="rd-empty">Profit could not load. Landing (Rate & Scheme) is seen only by Admin and Sales Head.</div>';return}
    const rows=P.rows.slice().sort((a,b)=>b.profit-a.profit),tone=v=>v<0?"rd-neg":v>0?"rd-pos":"";
    const lines=x=>'<tr class="rd-lines" hidden><td colspan="7"><table><thead><tr><th>SKU</th><th class="n">Cases</th><th class="n">Rate ₹</th><th class="n">Landing ₹</th><th class="n hide-sm">Per case ₹</th><th class="n">Profit ₹</th></tr></thead><tbody>'+
      x.lines.map(l=>"<tr><td>"+esc(l.sku)+'</td><td class="n">'+fmt(l.q)+'</td><td class="n">'+l.rate.toFixed(2)+'</td><td class="n">'+(l.land==null?badge("a","Not set"):l.land.toFixed(2))+'</td><td class="n hide-sm '+(l.land==null?"":tone(l.rate-l.land))+'">'+(l.land==null?"—":(l.rate-l.land).toFixed(2))+'</td><td class="n '+tone(l.p)+'">'+(l.p==null?"—":rs(l.p))+"</td></tr>").join("")+"</tbody></table></td></tr>";
    inn.innerHTML='<div class="rd-psum"><div><small>Orders</small><b>'+fmt(rows.length)+'</b></div><div><small>Sale</small><b>'+rs(P.sale)+'</b></div><div><small>Profit</small><b class="'+tone(P.profit)+'">'+rs(P.profit)+'</b></div><div><small>Margin</small><b>'+margin(P.profit,P.known)+"</b></div></div>"+
      (rows.length?'<div class="rd-scroll"><table class="rd-ptab"><thead><tr><th>PO No.</th><th>Party</th><th class="hide-sm">Salesman</th><th class="n hide-sm">Cases</th><th class="n">Sale ₹</th><th class="n">Profit ₹</th><th class="n hide-sm">%</th></tr></thead><tbody>'+
        rows.map(x=>'<tr data-oid="'+esc(x.o.id)+'"><td><b class="rd-po">'+esc(x.o.order_no||"—")+"</b>"+(x.missing?" "+badge("a",x.missing+" SKU no landing"):"")+"</td><td>"+esc(x.o.customer_name||"—")+'</td><td class="hide-sm">'+esc(takerOf(x.o,TEAM))+'</td><td class="n hide-sm">'+fmt(x.cases)+'</td><td class="n">'+fmt(x.sale)+'</td><td class="n '+tone(x.profit)+'"><b>'+fmt(x.profit)+'</b></td><td class="n hide-sm">'+margin(x.profit,x.sale-x.lines.filter(l=>l.land==null).reduce((b,l)=>b+l.rate*l.q,0))+"</td></tr>"+lines(x)).join("")+"</tbody></table></div>"
        :'<div class="rd-empty">No order on this day.</div>')+
      '<div class="rd-note">'+'<button type="button" class="erp-i" aria-label="Info" title="Info" data-tip="Profit = (PO rate − landing per case) × cases. Landing is from Rate &amp; Scheme, without ROI. Tap an order to see SKU-wise. Cancelled / rejected orders are not counted.">i</button>'+(P.missing?" <b>"+fmt(P.missing)+" SKU line"+(P.missing==1?"":"s")+"</b> have no landing (link the SKU in Rate & Scheme), so they are left out of profit.":"")+"</div>";
  }

  /* ---------- layout ---------- */
  // Pending Work (dashboard.html's lwb_my_verify_queue card) sits on top of the side column;
  // it is lifted out first so a repaint never deletes it.
  function paint(html){
    const v=document.getElementById("verifyCard"),home=document.querySelector(".side-col");
    if(v&&home&&box.contains(v))home.prepend(v);
    box.innerHTML=html;
    if(window.ERPList)box.querySelectorAll("[data-list]").forEach(el=>ERPList.card(el,()=>{const m=LISTS.get(el.dataset.list);return m&&m()},el.classList.contains("rd-step")?false:undefined));
    if(BRAND_ROLES.includes(ROLE)&&BR.list.length>1&&window.LWBBrand&&box.querySelector(".rd-kpis"))box.prepend(LWBBrand.chips(BR.list,BR.id,()=>render()));
    const s=document.getElementById("rdSide");if(v&&s)s.prepend(v);
  }
  function shell(kpis,main,side){
    return ('<div class="rd-kpis'+(kpis.length>5?" rd-k6":"")+'">'+kpis.join("")+'</div><div class="rd-grid"><div class="rd-col">'+main.filter(Boolean).join("")+'</div><div class="rd-col" id="rdSide">'+side.filter(Boolean).join("")+"</div></div>");
  }
  const ROLES={
    /* ===== Admin: whole business ===== */
    async admin(){
      const t=today(),y=shift(t,-1);
      const [orders,sumy,acc,PI,cq,team,ov]=await Promise.all([loadOrdersB(),safe(C.rpc("lwb_po_approval_summary",{p_from:t,p_to:t})),
        safe(C.rpc("lwb_acc_dashboard",{p_from:t,p_to:t})),window.LWBPartyPay?LWBPartyPay.load(C).catch(()=>null):null,safe(C.rpc("lwb_acc_cheque_list")),salesTeam(),overview()]);
      const O=orders||[],L=O.filter(live),td=L.filter(o=>o.day===t),yd=L.filter(o=>o.day===y),mo=L.filter(o=>o.day>=t.slice(0,8)+"01");
      TEAM=team.team;
      const [stock,PR]=await Promise.all([stockCheck(orders),orders&&profitOk()?profitOf(td).catch(()=>null):null]);
      const tv=sum(td,o=>o.total_amount),yv=sum(yd,o=>o.total_amount),mv=sum(mo,o=>o.total_amount),tgt=BR.id?num(ov&&ov.targets&&ov.targets[BR.id]&&ov.targets[BR.id].amount):companyTarget(team.targets);
      const ch=yv?Math.round((tv-yv)/yv*100):null,A=acc?accTotals(acc):null,short=stock?stock.filter(x=>x.short>0):null;
      const bo=BR.id&&ov&&ov.outstanding?ov.outstanding[BR.id]||{due:0,overdue:0}:null,out=bo?{total:num(bo.due),over:num(bo.overdue),brand:1}:outstanding(PI);
      const k=[
        kpi("green","Today's Sales",rs(tv),(ch==null?"":'<span class="'+(ch>=0?"up":"dn")+'">'+(ch>=0?"▲ ":"▼ ")+Math.abs(ch)+"%</span> ")+"vs yesterday "+rs(yv),"sales-tracking.html",orders&&lst("Today's Sales","Orders taken today (cancelled not counted)",td,null,"sales-tracking.html")),
        profitKpi(PR,td.length,"violet"),
        kpi("blue",new Date().toLocaleDateString("en-IN",{month:"long"})+" Sales",rs(mv),tgt?pct(mv,tgt)+"% of "+lakh(tgt)+" target":fmt(mo.length)+" orders","sales-tracking.html",orders&&lst(new Date().toLocaleDateString("en-IN",{month:"long"})+" Sales","Orders this month (cancelled not counted)",mo,null,"sales-tracking.html")),
        kpi("red","Total Outstanding",out?rs(out.total):"—",out?(out.brand?'<span class="dn">'+rs(out.over)+"</span> past udhari days":'<span class="dn">'+rs(out.over30)+"</span> over 30 days"):"Billing & Outstanding","party-billing.html",out&&out.parties&&lst("Total Outstanding","Party-wise due after advance",out.parties,PCOLS,"party-billing.html")),
        kpi("teal","Cash in Hand",acc&&acc.closing_set?rs(acc.closing):"—",A?"Bank deposit today "+rs(A.dep):"Accounts Dashboard","accounts-dashboard.html",acc&&lst("Today's cash book","All money entries today",acc.lines||[],ACOLS,"accounts-dashboard.html")),
        kpi("amber","Short Stock SKUs",short?fmt(short.length):"—",short?(short.length?"Less than open orders":"All open orders covered"):"Stock not available","inventory.html",short&&lst("Short Stock SKUs","Godown stock less than approved, not yet loaded orders",short,SCOLS,"inventory.html"))];
      const c=s=>O.filter(o=>st(o)===s).length,wait=O.filter(o=>WAIT.includes(st(o))&&live(o));
      const late=wait.filter(o=>Date.now()-Date.parse(o.created_at||o.order_date)>APPROVAL_HOURS*36e5).length;
      const flow=orders&&card("🚚 Order Flow",go("warehouse-orders.html","Open PO Approval →"),'<div class="rd-bd"><div class="rd-flow">'+
        step(wait.length,"Waiting approval",late?late+" late":"",late,"warehouse-orders.html",lst("Waiting approval","Orders waiting for Sales Head approval",wait,null,"warehouse-orders.html"))+
        step(c("approved"),"Approved","",0,"warehouse-orders.html",lst("Approved","Approved, driver not assigned yet",O.filter(o=>st(o)==="approved"),null,"warehouse-orders.html"))+
        step(c("transport_allocated"),"Driver assigned","",0,"loading-dispatch.html",lst("Driver assigned","Waiting for loading",O.filter(o=>st(o)==="transport_allocated"),null,"loading-dispatch.html"))+
        step(c("loading"),"Loading now","",c("loading")>0,"loading-dispatch.html",lst("Loading now","On the vehicle now",O.filter(o=>st(o)==="loading"),null,"loading-dispatch.html"))+
        step(c("loaded"),"Loaded, to bill","",0,"accounts-invoice.html",lst("Loaded, to bill","Loaded orders waiting for the Tally bill",O.filter(o=>st(o)==="loaded"),null,"accounts-invoice.html"))+
        step(sumy?num(sumy.delivered&&sumy.delivered.count):"—","Delivered today","",0,"",sumy&&lst("Delivered today","Delivery reported today",delivered(t,t)))+"</div></div>",
        "Approval is late after "+APPROVAL_HOURS+" hours.");
      const chart=orders?card("📈 Sales — last 7 days","",'<div class="rd-bd">'+sevenDays(O)+"</div>"):"";
      // Salesman today: share of his daily target (month target ÷ days in month), else of the best seller.
      const g=new Map();for(const o of td){const n=takerOf(o,team.team);g.set(n,(g.get(n)||0)+num(o.total_amount))}
      const top=Math.max(1,...g.values()),rows=[...g.entries()].sort((a,b)=>b[1]-a[1]).slice(0,8);
      const daily=n=>{const m=team.team.find(x=>x.full_name===n),tr=m&&team.targets.find(x=>x.salesman_id===m.user_id);return tr?num(tr.target_amount)/monthDays():0};
      const anyTarget=rows.some(r=>daily(r[0])>0);
      const board=orders?card("🏆 Salesman — today",go("sales-tracking.html","Sales Tracking →"),'<div class="rd-bd">'+(rows.length?rows.map(([n,v])=>{const d=daily(n),p=d?pct(v,d):Math.round(v/top*100);
        return '<div class="rd-rowp"><span>'+esc(n)+"</span>"+bar(p,p<50?"amb":"")+"<b>"+rs(v)+"</b></div>"}).join(""):'<div class="rd-empty">No order yet today.</div>')+"</div>",
        rows.length?(anyTarget?"Bar = today's sale vs daily target (month target ÷ "+monthDays()+" days)":"Bar = compared with today's best salesman (no target set)"):""):"";
      const al=[];
      if(sumy&&sumy.late_approval&&num(sumy.late_approval.count))al.push(dot("red",'<b>'+fmt(sumy.late_approval.count)+"</b> order"+(sumy.late_approval.count==1?"":"s")+" waiting approval over "+APPROVAL_HOURS+" h (oldest "+fmt(sumy.late_approval.max_hours)+" h)"));
      if(sumy&&sumy.late_delivery&&num(sumy.late_delivery.count))al.push(dot("red",'<b>'+fmt(sumy.late_delivery.count)+"</b> order"+(sumy.late_delivery.count==1?"":"s")+" not delivered in 36 h · "+rs(sumy.late_delivery.amount)));
      (short||[]).slice(0,3).forEach(x=>al.push(dot("amb",esc(x.sku)+": only <b>"+fmt(x.have)+" "+uOf(x.sku)+"</b> in godown, "+fmt(x.need)+" "+uOf(x.sku)+" ordered")));
      const cs=chequesSoon(cq).filter(x=>String(x.cheque_date)<=shift(t,1));
      if(cs.length)al.push(dot("amb",fmt(cs.length)+" cheque"+(cs.length==1?"":"s")+" to deposit by "+dmy(shift(t,1))+" · "+rs(sum(cs,x=>x.amount))));
      if(acc&&acc.last_close&&String(acc.last_close)<y)al.push(dot("blu","Night cash handover not closed since "+dmy(shift(String(acc.last_close),1))));
      const alerts=card("⚠️ Alerts","",al.length?al.join(""):'<div class="rd-empty">✓ No alerts right now.</div>');
      return shell(k.filter(Boolean),[flow,chart,board],[brandCard(ov),alerts]);
    },

    /* ===== Sales Head: approvals, team target, delivery ===== */
    async manager(){
      const t=today();
      const [orders,team0,acts,dl,ov,cm]=await Promise.all([loadOrdersB(),salesTeam(),safe(C.rpc("lwb_party_activity")),
        safe(C.from("lwb_delivery_reports").select("order_id,delivery_status,reported_at,delivery_note").gte("reported_at",t+"T00:00:00+05:30")),overview(),
        BR.allow?safe(C.rpc("lwb_company_month",{p_month:t.slice(0,8)+"01"})):null]);
      // With a brand chosen (or a brand-wise Sales Head) the targets are those companies' targets.
      const team=BR.allow&&cm?{team:team0.team,targets:brandTargets(cm.targets)}:team0;
      const O=orders||[],L=O.filter(live),td=L.filter(o=>o.day===t),mo=L.filter(o=>o.day>=t.slice(0,8)+"01");
      TEAM=team.team;
      const PR=orders&&profitOk()?await profitOf(td).catch(()=>null):null;
      const wait=O.filter(o=>WAIT.includes(st(o))&&live(o)),age=o=>Date.now()-Date.parse(o.created_at||o.order_date);
      const late=wait.filter(o=>age(o)>APPROVAL_HOURS*36e5),oldest=wait.reduce((a,o)=>!a||age(o)>age(a)?o:a,null);
      const tgt=companyTarget(team.targets),mv=sum(mo,o=>o.total_amount);
      const noOrder=acts?acts.filter(p=>!p.last_order_date||days(String(p.last_order_date).slice(0,10),t)>=5).length:null;
      const k=[
        kpi("amber","Waiting for my approval",fmt(wait.length),wait.length?(late.length?'<span class="dn">'+late.length+" late</span> · ":"")+"oldest "+ago(oldest.created_at||oldest.order_date):"Nothing waiting","warehouse-orders.html",orders&&lst("Waiting for my approval","Orders waiting for approval",wait,null,"warehouse-orders.html")),
        kpi("green","Team sales today",rs(sum(td,o=>o.total_amount)),fmt(sum(td,o=>o.total_qty))+" "+qWord()+" · "+fmt(td.length)+" orders","sales-tracking.html",orders&&lst("Team sales today","Orders taken today",td,null,"sales-tracking.html")),
        profitKpi(PR,td.length,"teal"),
        kpi("blue",new Date().toLocaleDateString("en-IN",{month:"long"})+" target",tgt?pct(mv,tgt)+"%":"Not set",lakh(mv)+(tgt?" of "+lakh(tgt):" sold"),"sales-tracking.html",orders&&lst(new Date().toLocaleDateString("en-IN",{month:"long"})+" sales","Orders this month",mo,null,"sales-tracking.html")),
        kpi("violet","Driver to assign",fmt(O.filter(o=>st(o)==="approved").length),"Approved, no vehicle yet","warehouse-orders.html",orders&&lst("Driver to assign","Approved, no vehicle yet",O.filter(o=>st(o)==="approved"),null,"warehouse-orders.html")),
        kpi("red","No order 5+ days",noOrder==null?"—":fmt(noOrder),"parties · Call list","party-calls.html",acts&&lst("No order 5+ days","Parties with no order for 5 days or more",acts.filter(p=>!p.last_order_date||days(String(p.last_order_date).slice(0,10),t)>=5),
          [{t:"Party",v:"customer_name"},{t:"City",v:"city"},{t:"Salesman",v:"salesman_name"},{t:"Last order",v:"last_order_date",date:true},{t:"Last PO",v:"last_order_no"},{t:"Orders 30 d",v:"orders_30d",num:true,dec:0}],"party-calls.html"))];
      const P={URGENT:0,HIGH:1};
      const q=wait.slice().sort((a,b)=>(P[a.priority]??2)-(P[b.priority]??2)||age(b)-age(a)).slice(0,8);
      const queue=orders&&card("✔️ PO Approval queue",go("warehouse-orders.html","Open all →"),q.length?'<div class="rd-scroll"><table><thead><tr><th>PO No.</th><th>Party</th><th class="hide-sm">Salesman</th><th class="n">Cases</th><th class="n">Amount ₹</th><th>Waiting</th></tr></thead><tbody>'+
        q.map(o=>{const h=age(o)/36e5;return orderRow(o,'<td class="hide-sm">'+esc(takerOf(o,team.team))+'</td><td class="n">'+fmt(o.total_qty)+'</td><td class="n">'+fmt(o.total_amount)+"</td><td>"+
          (o.priority&&o.priority!=="NORMAL"?badge("r",esc(o.priority))+" ":"")+badge(h>APPROVAL_HOURS?"r":h>APPROVAL_HOURS/2?"a":"g",ago(o.created_at||o.order_date))+"</td>")}).join("")+"</tbody></table></div>"
        :'<div class="rd-empty">✓ No PO waiting for approval.</div>',wait.length>q.length?"Showing "+q.length+" of "+wait.length+" · urgent first, then oldest":"");
      // Target per salesman this month (orders credited to the login that took them).
      const g=new Map();for(const o of mo){const n=takerOf(o,team.team);g.set(n,(g.get(n)||0)+num(o.total_amount))}
      const people=team.team.filter(x=>x.active!==false&&x.kind).map(x=>({n:x.full_name,v:g.get(x.full_name)||0,t:num((team.targets.find(y=>y.salesman_id===x.user_id)||{}).target_amount)}));
      for(const [n,v] of g)if(!people.some(p=>p.n===n))people.push({n,v,t:0});
      people.sort((a,b)=>(pct(b.v,b.t)??-1)-(pct(a.v,a.t)??-1)||b.v-a.v);
      const left=daysLeft(),need=tgt>mv&&left?(tgt-mv)/left:0;
      const target=orders?card("🎯 Team target — "+new Date().toLocaleDateString("en-IN",{month:"long"}),go("sales-tracking.html","Sales Tracking →"),'<div class="rd-bd">'+
        (people.length?people.slice(0,10).map(p=>{const v=pct(p.v,p.t);return '<div class="rd-rowp"><span>'+esc(p.n)+"</span>"+bar(v==null?0:v,v==null?"":v<50?"red":v<75?"amb":"")+'<b class="sm">'+lakh(p.v)+(p.t?" / "+lakh(p.t):"")+"</b></div>"}).join(""):'<div class="rd-empty">No sale this month yet.</div>')+"</div>",
        left+" day"+(left==1?"":"s")+" left"+(need?" · need "+lakh(need)+" per day to reach "+lakh(tgt):tgt&&mv>=tgt?" · target reached 🎉":"")):"";
      let delivery="";
      if(dl){const byId=new Map(O.map(o=>[o.id,o])),n=s=>dl.filter(r=>r.delivery_status===s).length,bad=dl.filter(r=>r.delivery_status==="NOT_DELIVERED").slice(0,4);
        const dOf=s=>lst("Today's delivery · "+s.replace("_"," ").toLowerCase(),"Driver reports today",dl.filter(r=>r.delivery_status===s).map(r=>({...(byId.get(r.order_id)||{order_no:"PO"}),delivery_note:r.delivery_note,reported_at:r.reported_at})),
          [{t:"PO No.",v:"order_no"},{t:"Party",v:"customer_name"},{t:"Cases",v:"total_qty",num:true,sum:true,dec:0},{t:"Amount",v:"total_amount",money:true,sum:true},{t:"Reported",v:r=>r.reported_at?new Date(r.reported_at).toLocaleTimeString("en-IN",{hour:"2-digit",minute:"2-digit"}):""},{t:"Note",v:"delivery_note"}]);
        delivery=card("📦 Today's delivery","",'<div class="rd-bd"><div class="rd-flow rd-flow3">'+step('<span class="g">'+n("DELIVERED")+"</span>","Delivered","",0,"",dOf("DELIVERED"))+step('<span class="a">'+n("PARTIAL")+"</span>","Part delivered","",0,"",dOf("PARTIAL"))+step('<span class="r">'+n("NOT_DELIVERED")+"</span>","Not delivered","",0,"",dOf("NOT_DELIVERED"))+"</div></div>"+
          bad.map(r=>{const o=byId.get(r.order_id);return dot("red","<b>"+esc(o?o.order_no:"PO")+"</b> "+esc(o?o.customer_name:"")+(r.delivery_note?" — "+esc(r.delivery_note):""))}).join(""))}
      let skus="";
      const it=td.length?await itemsOf(td.map(o=>o.id)):[];
      if(it&&it.length){const m=new Map();for(const x of it){if(!inBrand(x.sku_name))continue;const k=key(x.sku_name);const v=m.get(k)||{n:x.sku_name,q:0};v.q+=qtyOf(x);m.set(k,v)}
        skus=card("🔥 Top SKUs today","","<table><tbody>"+[...m.values()].sort((a,b)=>b.q-a.q).slice(0,6).map(x=>"<tr><td>"+esc(x.n)+'</td><td class="n">'+fmt(x.q)+" "+uOf(x.n)+"</td></tr>").join("")+"</tbody></table>")}
      return shell(k.filter(Boolean),[queue,target],[brandCard(ov),delivery,skus]);
    },

    /* ===== Accounts: cash, bank, bills, outstanding ===== */
    async accounts(){
      const t=today();
      const [acc,PI,cq,vq,ov]=await Promise.all([safe(C.rpc("lwb_acc_dashboard",{p_from:t,p_to:t})),window.LWBPartyPay?LWBPartyPay.load(C).catch(()=>null):null,safe(C.rpc("lwb_acc_cheque_list")),verifyQueue(),overview()]);
      const A=acc?accTotals(acc):null,out=outstanding(PI),drv=queueItem(vq,"DRIVER_PAYMENT"),tb=queueItem(vq,"TALLY_BILL");
      const toBill=PI?(PI.raw.orders||[]).filter(o=>!o.invoice_no&&!OFF.includes(st(o))).sort((a,b)=>String(a.dispatch_date||"").localeCompare(String(b.dispatch_date||""))):null;
      const nb=toBill?toBill.length:tb?num(tb.cnt):null;
      const k=[
        kpi("teal","Cash in Hand now",acc&&acc.closing_set?rs(acc.closing):"—",acc?(acc.opening_set?"Opening "+rs(acc.opening):"Set opening cash first"):"Accounts Dashboard","accounts-dashboard.html",acc&&lst("Today's cash book","All money entries today",acc.lines||[],ACOLS,"accounts-dashboard.html")),
        kpi("green","Cash In today",A?rs(A.cashIn):"—",A?"UPI "+rs(A.upi)+" · Bank "+rs(A.bank)+(A.cheque?" · Cheque "+rs(A.cheque):""):"","accounts-dashboard.html",acc&&lst("Money In today","Cash, UPI, bank and cheque received today",(acc.lines||[]).filter(l=>l.kind==="IN"),ACOLS,"accounts-dashboard.html")),
        kpi("red","Cash Out today",A?rs(A.cashOut):"—",A?"Bank deposit "+rs(A.dep):"","accounts-dashboard.html",acc&&lst("Money Out today","Expenses and bank deposits today",(acc.lines||[]).filter(l=>l.kind!=="IN"),ACOLS,"accounts-dashboard.html")),
        kpi("blue","With drivers",drv?rs(drv.amount):"₹0",drv?fmt(drv.cnt)+" to receive":"Nothing to receive",drv?drv.page:"driver-collections.html"),
        kpi("amber","Bills to make",nb==null?"—":fmt(nb),"Loaded POs · Tally","party-billing.html",toBill&&lst("Bills to make (Tally)","Loaded POs without a Tally bill, oldest first",toBill,
          [{t:"PO No.",v:"order_no"},{t:"Party",v:"party"},{t:"Dispatch",v:"dispatch_date",date:true},{t:"ERP amount",v:"erp_amount",money:true,sum:true}],"party-billing.html"))];
      const ageBox=out?'<div class="rd-bd"><div class="rd-age"><div class="g">0–15 days<b>'+rs(out.age.a)+'</b></div><div class="b">16–30 days<b>'+rs(out.age.b)+'</b></div><div class="a">31–60 days<b>'+rs(out.age.c)+'</b></div><div class="r">60+ days<b>'+rs(out.age.d)+"</b></div></div></div>":"";
      const ost=out?card("💳 Outstanding to collect · "+rs(out.total),go("party-billing.html","Billing & Outstanding →"),ageBox+(out.parties.length?'<div class="rd-scroll"><table><thead><tr><th>Party</th><th class="n">Due ₹</th><th class="n">Oldest bill</th></tr></thead><tbody>'+
        out.parties.slice(0,8).map(p=>"<tr><td>"+esc(p.party)+'</td><td class="n">'+fmt(p.due)+'</td><td class="n">'+(p.oldest==null?"—":badge(p.oldest>60?"r":p.oldest>30?"a":"g",p.oldest+" days"))+"</td></tr>").join("")+"</tbody></table></div>":'<div class="rd-empty">✓ Nothing due.</div>'),"After advance; age counted from the Tally bill date."):"";
      const bills=toBill?card("🧾 Bills to make (Tally)",go("party-billing.html","Open →"),toBill.length?'<div class="rd-scroll"><table><thead><tr><th>PO No.</th><th>Party</th><th class="n">ERP amount ₹</th><th class="hide-sm n">Dispatch</th></tr></thead><tbody>'+
        toBill.slice(0,8).map(o=>orderRow({order_no:o.order_no,customer_name:o.party},'<td class="n">'+fmt(o.erp_amount)+'</td><td class="hide-sm n">'+dmy(o.dispatch_date)+"</td>")).join("")+"</tbody></table></div>":'<div class="rd-empty">✓ Every loaded PO has its bill.</div>',toBill.length>8?"Showing 8 of "+toBill.length+", oldest first":""):"";
      const cs=chequesSoon(cq);
      const cheques=cq?card("📅 Cheques to deposit",go("accounts-dashboard.html","Cheques →"),cs.length?"<table><tbody>"+cs.slice(0,6).map(c=>"<tr><td>"+(String(c.cheque_date)<=t?badge("a",dmy(c.cheque_date)):dmy(c.cheque_date))+"</td><td>"+esc(c.party||"—")+'</td><td class="n">'+rs(c.amount)+"</td></tr>").join("")+"</tbody></table>":'<div class="rd-empty">No cheque due in the next 7 days.</div>'):"";
      let night="";
      if(acc){const c=(acc.closes||[]).find(x=>x.date===t&&!x.is_start);
        night=card("🌙 Night cash handover","",'<div class="rd-bd rd-line">'+(c?badge("g","Closed")+"<span>Counted "+rs(c.counted)+(c.handed_to_name?" · with "+esc(c.handed_to_name):"")+"</span>":badge("a","Not closed")+"<span>Close today after counting the notes</span>"+go("accounts-dashboard.html",'<span class="rd-btn">Close day</span>'))+"</div>")}
      return shell(k,[ost,bills],[brandCard(ov),cheques,night]);
    },

    /* ===== Godown Manager: loading, vehicles, stock, returns ===== */
    async warehouse(){
      const t=today();
      const [orders,veh,gr,tr,vq]=await Promise.all([loadOrders(),safe(C.from("lwb_vehicles").select("vehicle_no,vehicle_type,capacity_kg")),
        safe(C.from("lwb_godown_reports").select("*").eq("report_date",t).order("created_at",{ascending:false})),safe(C.from("lwb_stock_transit").select("sku_name,cases,status").eq("status","OPEN")),verifyQueue()]);
      const O=orders||[],load=O.filter(o=>["transport_allocated","loading","loaded"].includes(st(o)));
      const ids=load.map(o=>o.id),asg=[];
      for(let i=0;i<ids.length;i+=100){const r=await safe(C.from("dispatch_assignments").select("order_id,vehicle_no,driver_name,id").in("order_id",ids.slice(i,i+100)));if(r)asg.push(...r)}
      const stock=await stockCheck(orders),short=stock?stock.filter(x=>x.short>0):null;
      const aOf=new Map();for(const a of asg.sort((x,y)=>String(x.id).localeCompare(String(y.id))))aOf.set(a.order_id,a);
      const toLoad=load.filter(o=>st(o)==="transport_allocated"),loading=load.filter(o=>st(o)==="loading");
      const vehNo=o=>{const a=aOf.get(o.id);return a&&a.vehicle_no?String(a.vehicle_no).toUpperCase():"No vehicle"};
      const inside=gr?gr.filter(x=>x.kind==="VEHICLE"&&["ARRIVED","WORKING"].includes(x.vehicle_status)):null;
      const ret=queueItem(vq,"RETURN_RECEIVE"),loadingVeh=[...new Set(loading.map(vehNo))];
      const k=[
        kpi("amber","To load today",fmt(toLoad.length)+" order"+(toLoad.length==1?"":"s"),fmt(sum(toLoad,o=>o.total_qty))+" "+qWord()+" · "+fmt(sum(toLoad,o=>o.total_weight))+" kg","loading-dispatch.html",orders&&lst("To load","Driver assigned, waiting for loading",toLoad.map(o=>({...o,vehicle:vehNo(o)})),
          [{t:"PO No.",v:"order_no"},{t:"Party",v:"customer_name"},{t:"Vehicle",v:"vehicle"},{t:"Cases",v:"total_qty",num:true,sum:true,dec:0},{t:"Weight kg",v:"total_weight",num:true,sum:true,dec:0}],"loading-dispatch.html")),
        kpi("blue","Loading now",fmt(loadingVeh.length)+" vehicle"+(loadingVeh.length==1?"":"s"),esc(loadingVeh.slice(0,3).join(" · "))||"No vehicle loading","loading-dispatch.html",orders&&lst("Loading now","Orders on the vehicle now",loading.map(o=>({...o,vehicle:vehNo(o)})),
          [{t:"Vehicle",v:"vehicle"},{t:"PO No.",v:"order_no"},{t:"Party",v:"customer_name"},{t:"Cases",v:"total_qty",num:true,sum:true,dec:0},{t:"Weight kg",v:"total_weight",num:true,sum:true,dec:0}],"loading-dispatch.html")),
        kpi("teal","Vehicles at godown",inside?fmt(inside.length):"—",inside&&inside.length?esc(inside.slice(0,2).map(x=>x.vehicle_no).filter(Boolean).join(" · ")):"From Godown Report","godown-report.html",inside&&lst("Vehicles at godown","Arrived / working today",inside,
          [{t:"Vehicle",v:"vehicle_no"},{t:"Status",v:"vehicle_status"},{t:"Person",v:"person_name"},{t:"Note",v:"note"}],"godown-report.html")),
        kpi("red","Returns to receive",ret?fmt(ret.cnt):"0",ret&&num(ret.amount)?"Value "+rs(ret.amount):"From drivers","driver-returns.html"),
        kpi("violet","Short stock SKUs",short?fmt(short.length):"—",short?(short.length?"Less than open orders":"All open orders covered"):"Stock not available","inventory.html",short&&lst("Short stock SKUs","Godown stock less than open orders",short,SCOLS,"inventory.html"))];
      const vm=new Map((veh||[]).map(v=>[String(v.vehicle_no||"").toUpperCase(),v])),g=new Map();
      for(const o of load){const n=vehNo(o),a=aOf.get(o.id);const x=g.get(n)||{n,driver:a&&a.driver_name||"",orders:[]};x.orders.push(o);g.set(n,x)}
      const vs=[...g.values()].map(x=>{const s=x.orders.map(st),state=s.includes("loading")?"Loading":s.every(v=>v==="loaded")?"Loaded":"Waiting";return {...x,state,cases:sum(x.orders,o=>o.total_qty),kg:sum(x.orders,o=>o.total_weight),cap:num((vm.get(x.n)||{}).capacity_kg),type:(vm.get(x.n)||{}).vehicle_type||""}})
        .sort((a,b)=>({Loading:0,Waiting:1,Loaded:2})[a.state]-({Loading:0,Waiting:1,Loaded:2})[b.state]);
      const queue=orders?card("🚛 Loading queue — vehicle wise",go("loading-dispatch.html","Loading & Dispatch →"),vs.length?'<div class="rd-bd"><div class="rd-vehs">'+vs.slice(0,10).map(v=>{const p=v.cap?pct(v.kg,v.cap):null;
        return '<div class="rd-veh"><div class="h"><b>'+esc(v.n)+"</b>"+badge(v.state==="Loading"?"a":v.state==="Loaded"?"g":"r",v.state)+"</div><small>"+esc([v.driver,v.type].filter(Boolean).join(" · ")||"—")+" · "+v.orders.length+" PO"+(v.orders.length==1?"":"s")+"</small>"+
          (p!=null?bar(p,p>100?"red":p>85?"amb":"blu")+"<small>"+fmt(v.kg)+" / "+fmt(v.cap)+" kg filled ("+p+"%) · "+fmt(v.cases)+" cs</small>":"<small>"+fmt(v.cases)+" cs · "+fmt(v.kg)+" kg</small>")+"</div>"}).join("")+"</div></div>":'<div class="rd-empty">No vehicle to load right now.</div>'):"";
      const sc=stock?card("📦 Stock check for open orders",go("inventory.html","Inventory →"),stock.length?'<div class="rd-scroll"><table><thead><tr><th>SKU</th><th class="n">In godown</th><th class="n">Ordered</th><th class="n">Status</th></tr></thead><tbody>'+
        stock.slice(0,8).map(x=>"<tr><td>"+esc(x.sku)+'</td><td class="n">'+fmt(x.have)+" "+uOf(x.sku)+'</td><td class="n">'+fmt(x.need)+" "+uOf(x.sku)+'</td><td class="n">'+(x.short?badge("r","Short "+fmt(x.short)):x.have-x.need<x.need*0.2?badge("a","Low after"):badge("g","OK"))+(x.transit?" "+badge("b","+"+fmt(x.transit)+" coming"):"")+"</td></tr>").join("")+"</tbody></table></div>":'<div class="rd-empty">No approved order waiting.</div>',"Ordered = approved, not yet loaded orders."):"";
      const trans=tr&&tr.length?card("🚚 Goods coming (in transit)",go("stock-transit.html","Stock in Transit →"),'<div class="rd-bd">'+fmt(tr.length)+" line"+(tr.length==1?"":"s")+" · "+fmt(sum(tr,x=>x.cases))+" cases on the way</div>"):"";
      const KIND={VEHICLE:["blu","Vehicle"],DAMAGE:["red","Damage"],ABSENT:["amb","Staff absent"],ISSUE:["amb","Issue"]};
      const rep=gr?card("📝 Godown report — today",go("godown-report.html","Godown Report →"),(gr.length?gr.slice(0,5).map(x=>{const k2=KIND[x.kind]||["blu",x.kind];
        return dot(k2[0],"<b>"+k2[1]+":</b> "+esc([x.vehicle_no,x.sku_name,x.cases?x.cases+" cs":"",x.pcs?x.pcs+" pcs":"",x.person_name,x.note].filter(Boolean).join(" · ")||"—")+(x.review_status&&x.review_status!=="OPEN"?" "+badge("g",esc(String(x.review_status).replace(/_/g," ").toLowerCase())):""))}).join(""):'<div class="rd-empty">No report today.</div>')+
        (can("godown-report.html")?'<div class="rd-bd rd-line"><a class="rd-btn" href="godown-report.html">+ New report</a></div>':"")):"";
      return shell(k,[queue,sc],[trans,rep]);
    },

    /* ===== Salesman: plan, target, my orders (phone first) ===== */
    async sales(){
      const t=today(),m0=t.slice(0,8)+"01";
      const [mine,tg0,bills,pl,cm]=await Promise.all([safe(C.rpc("lwb_my_orders",{p_days:45})),safe(C.from("lwb_sales_targets").select("target_amount").eq("month",m0).eq("salesman_id",UID).maybeSingle()),
        safe(C.rpc("lwb_party_bills")),PLAN?PLAN:safe(C.rpc("lwb_my_sales_plan")),safe(C.rpc("lwb_company_month",{p_month:m0}))]);
      // Brand targets (Company / Brand page): used when no overall target is set, and shown brand-wise.
      const myT=cm&&cm.targets?cm.targets.filter(x=>x.salesman_id===UID&&num(x.target_amount)>0):[];
      const tg=tg0&&num(tg0.target_amount)?tg0:myT.length?{target_amount:sum(myT,x=>x.target_amount)}:tg0;
      const plan=pl&&typeof pl==="object"?pl:null;
      const M=Array.isArray(mine)?mine:[],L=M.filter(live).map(o=>({...o,day:istDay(o.order_date)}));
      const mo=L.filter(o=>o.day>=m0),td=L.filter(o=>o.day===t),mv=sum(mo,o=>o.total_amount),tgt=tg?num(tg.target_amount):0,p=pct(mv,tgt);
      const left=daysLeft(),need=tgt>mv?(tgt-mv)/left:0;
      const QA=[["order-entry.html","🛒","New PO"],["party-calls.html","📞","Call list"],["market-report.html","📊","Market report"],["party-ledger.html","📒","Party ledger"]].filter(x=>can(x[0]));
      const qa=QA.length?'<div class="rd-qa">'+QA.map(x=>'<a href="'+x[0]+'"><span>'+x[1]+"</span>"+x[2]+"</a>").join("")+"</div>":"";
      const r=15.9,arc=p==null?0:Math.min(100,p),tone=p==null?"#6b7785":p>=75?"#147d4c":p>=50?"#956000":"#b3263f";
      const ring=card("🎯 My target","",'<div class="rd-bd rd-ring"><svg viewBox="0 0 36 36" aria-hidden="true"><circle cx="18" cy="18" r="'+r+'" fill="none" stroke="#eef1f5" stroke-width="3.4"/>'+
        (p!=null?'<circle cx="18" cy="18" r="'+r+'" fill="none" stroke="'+tone+'" stroke-width="3.4" stroke-dasharray="'+arc+' 100" pathLength="100" stroke-linecap="round" transform="rotate(-90 18 18)"/>':"")+
        '<text x="18" y="20.5" text-anchor="middle" font-size="7.5" font-weight="700" fill="'+tone+'">'+(p==null?"—":p+"%")+'</text></svg><div class="t"><small>'+new Date().toLocaleDateString("en-IN",{month:"long"})+"</small><b>"+lakh(mv)+"</b><small>"+(tgt?"of "+lakh(tgt)+(need?" · need "+rs(need)+" / day":" · target done 🎉"):"Target not set · ask Sales Head")+
        '</small><div class="rd-today"><small>Today</small><b>'+rs(sum(td,o=>o.total_amount))+"</b><small>"+fmt(td.length)+" order"+(td.length==1?"":"s")+" · "+fmt(sum(td,o=>o.total_qty))+" "+qWord()+"</small></div></div></div>");
      const pp=(plan&&plan.parties)||[],notes=(plan&&plan.notes)||[];
      const planCard=plan?card("📍 Today's plan",go("my-sales.html","My Sales →"),(notes.length?'<div class="rd-alert rd-headnote"><span>📢</span><span><b>Sales Head:</b> '+notes.map(esc).join(" · ")+"</span></div>":"")+
        (pp.length?pp.slice(0,8).map(x=>'<div class="rd-alert">'+badge(x.days==null||x.days>=10?"r":x.days>=5?"a":"b",x.days==null?"New":x.days+" days")+"<span><b>"+esc(x.name)+"</b><br><small>"+(x.city?esc(x.city)+" · ":"")+(x.days==null?"No order yet":"Last order "+dmy(x.last_order_date))+"</small></span>"+
          go("order-entry.html?party="+encodeURIComponent(x.name),'<span class="rd-btn">+ PO</span>')+"</div>").join(""):'<div class="rd-empty">'+(plan.setup===false?"Sales Head has not set up your parties yet.":"✓ Every party has ordered recently. Good work!")+"</div>"),
        pp.length>8?"Showing 8 of "+pp.length+" parties due":pp.length?"Parties with no order for "+(plan.due_after_days||3)+"+ days":""):"";
      const done=o=>o.delivery_status==="DELIVERED"||o.delivery_status==="PARTIAL",s2=st;
      const waiting=L.filter(o=>WAIT.includes(s2(o))),appr=L.filter(o=>s2(o)==="approved"||s2(o)==="transport_allocated"),way=L.filter(o=>["loading","loaded","invoiced","dispatched"].includes(s2(o))&&!done(o)),week=Date.now()-7*864e5;
      const stage=o=>o.delivery_status==="DELIVERED"?badge("g","Delivered"):o.delivery_status==="PARTIAL"?badge("a","Part delivered"):o.delivery_status==="NOT_DELIVERED"?badge("r","Not delivered"):
        WAIT.includes(s2(o))?badge("a","Waiting"):s2(o)==="approved"?badge("b","Approved"):s2(o)==="transport_allocated"?badge("b","Driver assigned"):s2(o)==="loading"?badge("b","Loading"):badge("b","On the way");
      const orders=mine?card("🧾 My orders",go("my-sales.html#orders","All →"),'<div class="rd-bd"><div class="rd-flow rd-flow4">'+step(waiting.length,"Waiting approval","",waiting.length>0,"my-sales.html#orders",lst("Waiting approval","My orders waiting for Sales Head",waiting))+step(appr.length,"Approved","",0,"",lst("Approved","My approved orders",appr))+step(way.length,"On the way","",0,"",lst("On the way","Loaded / dispatched, not delivered yet",way))+
        step('<span class="g">'+L.filter(o=>done(o)&&Date.parse(o.delivered_at)>=week).length+"</span>","Delivered (7 d)","",0,"",lst("Delivered (7 days)","My orders delivered in the last 7 days",L.filter(o=>done(o)&&Date.parse(o.delivered_at)>=week)))+"</div></div>"+(L.length?"<table><tbody>"+L.slice(0,5).map(o=>'<tr><td><b class="rd-po">'+esc(o.order_no||"—")+"</b> "+esc(o.customer_name||"")+'</td><td class="n">'+stage(o)+"</td></tr>").join("")+"</tbody></table>":'<div class="rd-empty">No order in the last 45 days.</div>')):"";
      // To collect: outstanding of parties this salesman ordered for (45 days) or has in his plan.
      let coll="";
      if(Array.isArray(bills)){const mineP=new Set(M.map(o=>key(o.customer_name)).concat(pp.map(x=>key(x.name)))),g=new Map();
        for(const b of bills){const k2=key(b.customer_name);if(!mineP.has(k2))continue;g.set(k2,{n:b.customer_name,v:(g.get(k2)||{v:0}).v+num(b.outstanding_amount)})}
        const list=[...g.values()].filter(x=>x.v>=1).sort((a,b)=>b.v-a.v);
        if(list.length)coll=card("💰 My parties — to collect",go("party-ledger.html","Ledger →"),"<table><tbody>"+list.slice(0,6).map(x=>"<tr><td>"+esc(x.n)+'</td><td class="n">'+rs(x.v)+"</td></tr>").join("")+"</tbody></table>","Total "+rs(sum(list,x=>x.v))+" · "+list.length+" part"+(list.length==1?"y":"ies"))}
      let brands="";
      if(myT.length&&window.LWBBrand){const bl=(await LWBBrand.load(C).catch(()=>({companies:[]}))).companies||[];
        brands=card("🏷️ My brand targets","","<div class=\"rd-bd\">"+myT.map(x=>{const c=bl.find(y=>y.id===x.company_id)||{name:"Brand",color:"#2362a4"},v=sum((cm.sales||[]).filter(s=>s.company_id===x.company_id),s=>s.amount),q=pct(v,num(x.target_amount));
          return '<div class="rd-rowp"><span><span class="rd-dot" style="background:'+esc(c.color)+'"></span>'+esc(c.name)+"</span>"+bar(q,q<50?"red":q<75?"amb":"")+'<b class="sm">'+lakh(v)+" / "+lakh(x.target_amount)+"</b></div>"}).join("")+"</div>")}
      return (qa+'<div class="rd-grid"><div class="rd-col">'+ring+brands+planCard+'</div><div class="rd-col" id="rdSide">'+orders+coll+"</div></div>");
    }
  };

  async function brands(){
    BR.list=[];BR.id="";BR.map=null;BR.allow=null;BR.all=[];
    if(!window.LWBBrand)return;
    const b=await LWBBrand.load(C).catch(()=>null);BR.all=(b&&b.all)||[];
    if(BR.all.some(c=>c.pack_unit==="BOX"))BR.map=await LWBBrand.skuMap(C);
    if(!["admin","manager","accounts"].includes(ROLE))return;
    BR.list=(b&&b.companies)||[];
    // A Sales Head tied to one company always sees only it; chips choose between several.
    if(BRAND_ROLES.includes(ROLE)&&BR.list.length>1)BR.id=LWBBrand.get(BR.list);
    if(BR.id)BR.allow=new Set([BR.id]);else if(b&&b.mine&&b.mine.length&&ROLE!=="accounts")BR.allow=new Set(b.mine);
    if(BR.allow)BR.map=await LWBBrand.skuMap(C);
  }
  async function render(){
    const my=++seq;
    LISTS=new Map();
    try{await brands();const html=await ROLES[ROLE]();if(my===seq)paint(html)}catch(e){console.error(e);if(my===seq&&!box.querySelector(".rd-card"))paint('<div class="rd-empty">Dashboard could not load. Tap refresh.</div>')}
  }
  window.LWBRoleDash={
    roles:Object.keys(ROLES),
    has:role=>Object.prototype.hasOwnProperty.call(ROLES,role),
    start(o){C=o.client;ROLE=o.role;UID=o.uid||"";PLAN=o.plan||null;box=o.box;
      if(!box.dataset.rdTap){box.dataset.rdTap="1";document.addEventListener("erp:access",()=>{if(ROLE)render()});box.addEventListener("click",e=>{if(e.target.closest("[data-profit]"))showProfit(today())})}if(!box.querySelector(".rd-card"))paint('<div class="rd-empty">Loading your dashboard…</div>');return render()},
    refresh(){if(ROLE)return render()}
  };
})();
