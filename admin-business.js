/* LUXURY WRIST BRAND ERP — Admin "Business Overview" on the Dashboard (design A, Mohit 2 Nov 2026).
   role-dashboard.js puts <section id="bzDash"> on the Admin dashboard and calls LWBBizDash.mount(el, ctx).
   Read-only, no SQL of its own: it reads what other pages already read.
     Sales      = order_items qty (approved, else ordered) × rate, by order_date (India day), cancelled / rejected left out.
     Cost       = landing per case / box: Rate & Scheme pack (Coca-Cola, same as Today's Profit), else the
                  Rajnigandha Rate List landing (lwb_price_limits_get). Lines with no landing are left out of profit.
     Purchase   = Goods Inward bills (lwb_goods_inward + items, invoice total) by received date.
     Expenses   = Accounts money OUT entries (lwb_acc_dashboard), without the heads that are not a business expense:
                  Supplier payment (that is purchase), Contra (own bank to own bank), Asset purchase (capital)
                  and GST / Tax paid (tax collected from parties, passed on). NOT_EXPENSE below.
   Every number opens a popup list of what makes it (tap / Enter; erp-list.js), Mohit 4 Nov 2026.
     Stock      = lwb_po_stock godown cases × landing.  Cash + Bank = closing cash + bank balances.
   Range switch Today / Yesterday / 7 Days / 30 Days / This Month / Custom is kept per browser (localStorage lwbBizRange;
   Custom From–To in lwbBizFrom / lwbBizTo). Custom: picking From shows that one day (To = From), then pick To for a range
   (Mohit, 16 Nov 2026). */
(function(){
  if(window.LWBBizDash)return;
  const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const num=v=>{const n=Number(v);return Number.isFinite(n)?n:0};
  const fmt=n=>Math.round(num(n)).toLocaleString("en-IN");
  const rs=n=>(num(n)<0?"−":"")+"₹"+Math.abs(Math.round(num(n))).toLocaleString("en-IN");
  const lakh=n=>{n=num(n);const a=Math.abs(n),s=n<0?"−":"";return a>=1e7?s+"₹"+(a/1e7).toFixed(2)+" Cr":a>=1e5?s+"₹"+(a/1e5).toFixed(2)+" L":rs(n)};
  const istDay=v=>{const t=Date.parse(v);return isNaN(t)?"":new Date(t+19800000).toISOString().slice(0,10)};
  const today=()=>istDay(new Date().toISOString());
  const shift=(d,n)=>new Date(Date.parse(d+"T12:00:00Z")+n*864e5).toISOString().slice(0,10);
  const span=(a,b)=>Math.round((Date.parse(b+"T12:00:00Z")-Date.parse(a+"T12:00:00Z"))/864e5)+1;
  const dm=d=>String(d).slice(8,10)+"/"+String(d).slice(5,7);
  const dmy=d=>dm(d)+"/"+String(d).slice(0,4);
  // SKU key = the SKU's current name (an old PO line of a renamed SKU joins its SKU; the line itself is not changed).
  const key=v=>window.LWBBrand&&LWBBrand.nowKey?LWBBrand.nowKey(v):String(v==null?"":v).toUpperCase().replace(/\s+/g," ").trim();
  const st=o=>String((o&&o.status)||"").toLowerCase().trim().replace(/[\s-]+/g,"_");
  const OFF=["cancelled","canceled","rejected"];
  const safe=p=>Promise.resolve(p).then(r=>r&&r.error?null:r?("data" in r?r.data:r):null).catch(()=>null);
  const sum=(a,f)=>a.reduce((n,x)=>n+num(f(x)),0);
  const pctTxt=(a,b)=>b>0?(Math.round(a/b*1000)/10)+"%":"—";
  // [key, label, short label for phone]
  const RANGES=[["today","Today","Today"],["yday","Yesterday","Yday"],["7","7 Days","7D"],["30","30 Days","30D"],["month","This Month","Month"],["custom","Custom","Custom"]];
  // Range = the ONE date filter in the top bar (erp-period.js, Mohit 20 Nov 2026); old lwbBizRange only when it is missing.
  const getRange=()=>{if(window.LWBPeriod)return LWBPeriod.get().key;try{const v=localStorage.getItem("lwbBizRange");if(RANGES.some(r=>r[0]===v))return v}catch(e){}return "month"};
  const setRange=v=>{try{localStorage.setItem("lwbBizRange",v)}catch(e){}};
  const isDay=v=>/^\d{4}-\d{2}-\d{2}$/.test(String(v||""))&&v>="2020-01-01";
  const MAXDAYS=366;
  function getCustom(){
    const t=today();let f="",to="";
    try{f=localStorage.getItem("lwbBizFrom")||"";to=localStorage.getItem("lwbBizTo")||""}catch(e){}
    if(!isDay(f)||f>t)f=shift(t,-1);
    if(!isDay(to)||to>t)to=f;
    if(to<f)to=f;
    if(span(f,to)>MAXDAYS)f=shift(to,-(MAXDAYS-1));
    return {from:f,to};
  }
  const setCustom=(f,to)=>{try{localStorage.setItem("lwbBizFrom",f);localStorage.setItem("lwbBizTo",to)}catch(e){}};
  const COL={sales:"#00434d",purch:"#c9b26a",gp:"#13824a"};
  const EXC=["#00434d","#c9b26a","#1d5fbf","#b26b00","#13824a","#9aa5a8"];
  // Money-out heads that are not an expense of the business (Mohit, 4 Nov 2026: contra was cutting net profit).
  const NOT_EXPENSE=/^(supplier payment|contra\b.*|asset purchase|gst \/ tax paid|friend swap)$/i;

  let CTX=null,EL=null,seq=0,cache=null;

  function rangeOf(r){
    const t=today();let from,to=t;
    if(r==="custom")({from,to}=window.LWBPeriod?LWBPeriod.get():getCustom());
    else if(r==="yday")from=to=shift(t,-1);
    else from=r==="today"?t:r==="7"?shift(t,-6):r==="30"?shift(t,-29):t.slice(0,8)+"01";
    return {from,to,chartFrom:[from,shift(to,-6)].sort()[0]};
  }
  async function pages(q){
    const out=[];
    for(let p=0;p<20;p++){const r=await q().range(p*1000,p*1000+999);if(r.error)throw r.error;out.push(...(r.data||[]));if((r.data||[]).length<1000)break}
    return out;
  }
  async function chunks(ids,n,f){
    const parts=[];for(let i=0;i<ids.length;i+=n)parts.push(ids.slice(i,i+n));
    const out=[];
    for(let i=0;i<parts.length;i+=4){const rs2=await Promise.all(parts.slice(i,i+4).map(f));for(const r of rs2){if(r.error)throw r.error;out.push(...(r.data||[]))}}
    return out;
  }
  // After loading the loaded qty is what the party got (and what is billed); before it, approved, else ordered.
  const LOADED=["loaded","invoiced","dispatched","delivered"];
  const qtyOf=(it,s)=>LOADED.includes(s)&&it.loaded_qty!=null?num(it.loaded_qty):it.approved_qty!=null?num(it.approved_qty):num(it.ordered_qty);

  async function load(R){
    const C=CTX.C,len=span(R.from,R.to),prevFrom=shift(R.from,-len),start=[prevFrom,R.chartFrom].sort()[0],end=shift(R.to,1);
    const [orders,land,rajni,inward,skus,acc,stock]=await Promise.all([
      pages(()=>C.from("orders").select("id,order_no,order_date,created_at,customer_name,sales_person,status,total_amount").gte("order_date",start+"T00:00:00+05:30").lt("order_date",end+"T00:00:00+05:30").order("order_date")),
      CTX.landingData?CTX.landingData().catch(()=>null):null,
      safe(C.rpc("lwb_price_limits_get")),
      safe(C.from("lwb_goods_inward").select("id,received_date,invoice_no,supplier_name").gte("received_date",R.chartFrom).lte("received_date",R.to).limit(3000)),
      safe(C.from("sku_master").select("id,sku_name,company_id,pcs_per_case")),
      safe(C.rpc("lwb_acc_dashboard",{p_from:R.from,p_to:R.to})),
      safe(C.rpc("lwb_po_stock"))]);
    const O=orders.map(o=>({...o,day:istDay(o.order_date||o.created_at)})).filter(o=>!OFF.includes(st(o)));
    const cur=O.filter(o=>o.day>=R.chartFrom);
    const items=cur.length?await chunks(cur.map(o=>o.id),150,ids=>C.from("order_items").select("order_id,sku_name,ordered_qty,approved_qty,loaded_qty,rate").in("order_id",ids)):[];
    const inItems=inward&&inward.length?await chunks(inward.map(b=>b.id),100,ids=>C.from("lwb_goods_inward_items").select("*").in("inward_id",ids)).catch(()=>null):[];
    return {O,items,land,rajni,inward:inward||null,inItems,skus:skus||[],acc,stock};
  }

  function build(D,R){
    const brandOf=CTX.brandOf,inBrand=CTX.inBrand,uOf=CTX.uOf;
    const rl=new Map();for(const x of (D.rajni&&D.rajni.rows)||[])if(x.landing!=null&&num(x.landing)>0)rl.set(key(x.sku_key),num(x.landing));
    const landing=(sku,day)=>{let v=null;if(D.land&&CTX.landingOf){try{v=CTX.landingOf(D.land,sku,day)}catch(e){v=null}}
      if(v==null||!Number.isFinite(v))v=rl.has(key(sku))?rl.get(key(sku)):null;return v};
    const dayOf=new Map(D.O.map(o=>[o.id,o.day])),stOf=new Map(D.O.map(o=>[o.id,st(o)]));
    const days=[];for(let d=R.chartFrom;d<=R.to;d=shift(d,1))days.push(d);
    const S={sales:0,known:0,gp:0,missing:0},byDay=new Map(days.map(d=>[d,{s:0,p:0,g:0}])),brand=new Map(),sku=new Map();
    // Detail rows behind every number (popups): SKU lines of the POs (CL = whole chart window, L = chosen range).
    const ordOf=new Map(D.O.map(o=>[o.id,o])),CL=[],L=[];
    const B=id=>{if(!brand.has(id))brand.set(id,{sales:0,qty:0,gp:0,known:0,purch:0,stock:0,unit:""});return brand.get(id)};
    for(const it of D.items){
      const day=dayOf.get(it.order_id);if(!day||!inBrand(it.sku_name))continue;
      const q=qtyOf(it,stOf.get(it.order_id)),v=q*num(it.rate);if(!q&&!v)continue;
      const l=landing(it.sku_name,day),g=l==null?0:(num(it.rate)-l)*q,x=byDay.get(day);
      if(x){x.s+=v;x.g+=g}
      const o=ordOf.get(it.order_id)||{},ln={oid:it.order_id,po:o.order_no||"—",day,party:o.customer_name||"",sm:o.sales_person||"",status:o.status||"",
        sku:String(it.sku_name||"").trim(),brand:brandOf(it.sku_name),q,unit:uOf(it.sku_name),rate:num(it.rate),v,land:l,g:l==null?null:g,cost:l==null?null:l*q};
      CL.push(ln);
      if(day<R.from)continue;
      L.push(ln);
      S.sales+=v;if(l==null)S.missing++;else{S.known+=v;S.gp+=g}
      const b=B(brandOf(it.sku_name));b.sales+=v;b.qty+=q;b.unit=uOf(it.sku_name);if(l!=null){b.gp+=g;b.known+=v}
      const k=key(it.sku_name),s=sku.get(k)||{name:String(it.sku_name||"").trim(),unit:uOf(it.sku_name),qty:0,sales:0,gp:0,known:0};
      s.qty+=q;s.sales+=v;if(l!=null){s.gp+=g;s.known+=v}sku.set(k,s);
    }
    // Same-length period before, by order totals (all brands only).
    const len=span(R.from,R.to),pf=shift(R.from,-len);
    const prev=CTX.allBrands?sum(D.O.filter(o=>o.day>=pf&&o.day<R.from),o=>o.total_amount):null;
    const curTot=sum(D.O.filter(o=>o.day>=R.from),o=>o.total_amount);
    // Purchase
    const skuById=new Map(D.skus.map(s=>[String(s.id),s]));
    const bill=new Map((D.inward||[]).map(b=>[b.id,b]));
    const P={total:0,bills:new Set(),ok:!!D.inward&&!!D.inItems,lines:[]};
    for(const it of D.inItems||[]){
      const b=bill.get(it.inward_id),s=skuById.get(String(it.sku_id))||{},name=it.sku_name||s.sku_name||"";
      if(!b||!inBrand(name))continue;
      const v=num(it.total_amount)||num(it.net_amount)||num(it.taxable_amount);
      const x=byDay.get(String(b.received_date).slice(0,10));if(x)x.p+=v;
      if(String(b.received_date)<R.from)continue;
      const br=s.company_id||brandOf(name);P.total+=v;P.bills.add(b.id);B(br).purch+=v;
      P.lines.push({bill:b.id,day:String(b.received_date).slice(0,10),inv:b.invoice_no||"",supplier:b.supplier_name||"",sku:String(name).trim(),brand:br,
        cases:it.cases!=null?num(it.cases):it.received_cases!=null?num(it.received_cases):null,v});
    }
    // Expenses
    const E={total:0,cats:new Map(),ok:!!D.acc,lines:[]};
    for(const l of (D.acc&&D.acc.lines)||[]){
      if(l.kind!=="OUT")continue;const c=String(l.category||"Other expense").trim();if(NOT_EXPENSE.test(c))continue;
      E.total+=num(l.amount);E.cats.set(c,(E.cats.get(c)||0)+num(l.amount));
      E.lines.push({day:String(l.date||"").slice(0,10),cat:c,party:l.party||"",mode:l.mode||"",ref:[l.ref,l.order_no].filter(Boolean).join(" · "),remark:l.remark||"",by:l.by||"",v:num(l.amount)});
    }
    const cats=[...E.cats].sort((a,b)=>b[1]-a[1]),ec=cats.slice(0,5);if(cats.length>5)ec.push(["Other",sum(cats.slice(5),x=>x[1])]);
    // Stock value
    const SV={total:0,ok:!!D.stock,cases:new Map(),rows:[]};
    for(const s of D.stock||[]){
      if(!inBrand(s.sku_name))continue;const c=num(s.godown_cases);SV.cases.set(key(s.sku_name),c);if(c<=0)continue;
      const l=landing(s.sku_name,R.to),row={sku:String(s.sku_name||"").trim(),brand:brandOf(s.sku_name),cases:c,unit:uOf(s.sku_name),land:l,v:l==null?null:c*l};
      SV.rows.push(row);if(l==null)continue;SV.total+=c*l;B(row.brand).stock+=c*l;
    }
    // Cash + bank
    const acc=D.acc,bank=acc?sum((acc.banks||[]).filter(b=>b.active!==false),b=>b.balance):0;
    const cash=acc&&acc.closing_set?num(acc.closing):null;
    const nd=span(R.from,R.to);
    const skus=[...sku.values()].sort((a,b)=>b.sales-a.sales).map(s=>{const c=SV.cases.get(key(s.name));const perDay=s.qty/nd;return {...s,stock:c,days:c==null?null:perDay>0?(c/perDay<1?0.5:Math.floor(c/perDay)):null}});
    return {S,byDay,days,brand,skus,prev,curTot,P,E,ec,cats,SV,cash,bank,acc,L,CL};
  }

  /* ---------- tap / Enter on any number → popup list of what makes that number (Mohit, 4 Nov 2026) ----------
     Every KPI card, P&L row, brand row, expense head and top-SKU row carries data-bzd = a key in DET;
     the popup is erp-list.js (search, total row, Esc closes, phone = cards). A PO row opens its SKU lines. */
  let DET=new Map(),DN=0;
  const dk=f=>{const id="d"+(++DN);DET.set(id,f);return id};
  const da=(f,t)=>f?' data-bzd="'+dk(f)+'" tabindex="0" role="button" title="'+esc(t||"Tap or press Enter to see the list")+'"':"";
  const okPage=h=>h&&(!CTX.can||CTX.can(h))?h:undefined;
  const pct1=(a,b)=>b>0?(Math.round(a/b*1000)/10)+"%":"—";
  const brandName=id=>{const c=(CTX.companies||[]).find(x=>x.id===id);return c?c.name:id?"—":"No brand"};
  const notSet='<small style="color:#b26b00;font-weight:600">Not set</small>';
  function kpi(color,label,value,foot,make){
    const tag=make?'button type="button" data-bzd="'+dk(make)+'" title="Tap or press Enter to see what makes this number"':"div";
    return "<"+tag+' class="bz-k" style="--c:'+color+'"><small>'+esc(label)+"</small><b>"+value+"</b><span>"+foot+"</span></"+tag.split(" ")[0]+">";
  }
  // Key card: label, big number, a small graphic, and one muted line.
  function kpiX(color,label,value,foot,make,viz){
    const tag=make?'button type="button" data-bzd="'+dk(make)+'" title="Tap or press Enter to see what makes this number"':"div";
    return "<"+tag+' class="bz-k bz-kx" style="--c:'+color+'"><small>'+esc(label)+"</small><b>"+value+"</b>"+(viz?'<div class="bz-viz">'+viz+"</div>":"")+"<span>"+foot+"</span></"+tag.split(" ")[0]+">";
  }
  // Split bar: [[value, colour, tooltip], ...]
  function stack(parts){
    const t=sum(parts,p=>p[0]);if(!(t>0))return "";
    return '<div class="bz-stk">'+parts.filter(p=>p[0]>0).map(p=>'<i style="width:'+(p[0]/t*100).toFixed(2)+"%;background:"+p[1]+'" title="'+esc(p[2]||"")+'"></i>').join("")+"</div>";
  }
  const brandColor=id=>{const c=(CTX.companies||[]).find(x=>x.id===id);return (c&&c.color)||"#9aa5a8"};
  // Column sets
  // Profit also follows the top-bar ON/OFF switch (profit-view.js, localStorage lwbProfitOn): OFF hides Gross / Net Profit,
  // the gross line in the chart, the Profit & Loss card and every margin column (Mohit, 18 Nov 2026).
  const swOn=()=>{try{return localStorage.getItem("lwbProfitOn")!=="0"}catch(e){return true}};
  const gpOk=()=>CTX.profitOk!==false&&swOn();
  const LCOLS=(withPo)=>[withPo&&{t:"PO No.",v:"po"},withPo&&{t:"Date",v:"day",date:true},withPo&&{t:"Party",v:"party"},{t:"SKU",v:"sku"},
    {t:"Qty",v:"q",num:true,sum:true,dec:2,html:r=>esc(fmt(r.q)+" "+r.unit)},{t:"Rate ₹",v:"rate",money:true,dec:2},{t:"Sales ₹",v:"v",money:true,sum:true},
    gpOk()&&{t:"Landing ₹",v:"land",money:true,dec:2,html:r=>r.land==null?notSet:esc("₹"+r.land.toLocaleString("en-IN",{maximumFractionDigits:2}))},
    gpOk()&&{t:"Cost ₹",v:"cost",money:true,sum:true},gpOk()&&{t:"Gross profit ₹",v:"g",money:true,sum:true}].filter(Boolean);
  function poRows(lines){
    const m=new Map();
    for(const l of lines){let x=m.get(l.oid);if(!x){x={oid:l.oid,po:l.po,day:l.day,party:l.party,sm:l.sm,status:l.status,q:0,v:0,known:0,g:0,missing:0,lines:[]};m.set(l.oid,x)}
      x.q+=l.q;x.v+=l.v;x.lines.push(l);if(l.land==null)x.missing++;else{x.known+=l.v;x.g+=l.g}}
    return [...m.values()];
  }
  function poLines(r){
    return {title:(/^po/i.test(r.po)?"":"PO ")+r.po+(r.party?" · "+r.party:""),sub:dmy(r.day)+(r.sm?" · "+r.sm:"")+(r.status?" · "+ERPList.pretty(r.status):""),rows:r.lines,cols:LCOLS(false),
      page:okPage("warehouse-orders.html")&&"warehouse-orders.html?order="+encodeURIComponent(r.oid),pageText:"Open PO →",empty:"No SKU line."};
  }
  function poList(title,sub,lines,page,sortBy){
    const rows=poRows(lines).sort(sortBy==="g"?(a,b)=>b.g-a.g:(a,b)=>String(b.day).localeCompare(String(a.day))||b.v-a.v);
    return {title,sub:sub+" · tap a PO to see its SKUs",rows,page:okPage(page),pageText:"Open page →",empty:"No PO in this period.",onRow:r=>ERPList.open(poLines(r)),
      cols:[{t:"PO No.",v:"po",html:r=>"<b>"+esc(r.po)+"</b>"+(gpOk()&&r.missing?' <small style="color:#b26b00">'+r.missing+" no landing</small>":"")},{t:"Date",v:"day",date:true},
        {t:"Party",v:"party"},{t:"Salesman",v:"sm"},{t:"Qty",v:"q",num:true,sum:true,dec:0},{t:"Sales ₹",v:"v",money:true,sum:true},
        gpOk()&&{t:"Gross profit ₹",v:"g",money:true,sum:true},gpOk()&&{t:"Margin",v:r=>pct1(r.g,r.known)}].filter(Boolean)};
  }
  function lineList(title,sub,lines,page){
    return {title,sub,rows:lines.slice().sort((a,b)=>String(b.day).localeCompare(String(a.day))||b.v-a.v),cols:LCOLS(true),page:okPage(page),pageText:"Open page →",
      onRow:l=>{const r=poRows(lines.filter(x=>x.oid===l.oid))[0];if(r)ERPList.open(poLines(r))},empty:"No SKU line in this period."};
  }
  function billList(title,sub,lines){
    const m=new Map();
    for(const l of lines){let x=m.get(l.bill);if(!x){x={bill:l.bill,day:l.day,inv:l.inv,supplier:l.supplier,n:0,v:0,lines:[]};m.set(l.bill,x)}x.n++;x.v+=l.v;x.lines.push(l)}
    return {title,sub:sub+" · tap a bill to see its SKUs",rows:[...m.values()].sort((a,b)=>String(b.day).localeCompare(String(a.day))||b.v-a.v),page:okPage("purchase-register.html"),pageText:"Open Purchase →",empty:"No purchase bill in this period.",
      cols:[{t:"Date",v:"day",date:true},{t:"Invoice",v:"inv"},{t:"Supplier",v:"supplier"},{t:"SKUs",v:"n",num:true,dec:0},{t:"Amount ₹",v:"v",money:true,sum:true}],
      onRow:b=>ERPList.open({title:"Bill "+(b.inv||"—")+" · "+b.supplier,sub:dmy(b.day),rows:b.lines,page:okPage("purchase-register.html"),pageText:"Open Purchase →",
        cols:[{t:"SKU",v:"sku"},{t:"Brand",v:r=>brandName(r.brand)},{t:"Cases",v:"cases",num:true,sum:true,dec:0},{t:"Amount ₹",v:"v",money:true,sum:true}]})};
  }
  function expList(title,sub,lines){
    return {title,sub,rows:lines.slice().sort((a,b)=>String(b.day).localeCompare(String(a.day))||b.v-a.v),page:okPage("accounts-dashboard.html"),pageText:"Open Accounts →",empty:"No expense entered in this period.",
      cols:[{t:"Date",v:"day",date:true},{t:"Head",v:"cat"},{t:"Paid to",v:"party"},{t:"Mode",v:"mode"},{t:"Ref",v:"ref"},{t:"Remark",v:"remark"},{t:"By",v:"by"},{t:"Amount ₹",v:"v",money:true,sum:true}]};
  }
  // SKU-wise summary (brand row, total row): sales, gross, purchase and stock value of each SKU.
  function skuList(title,sub,M,brandId){
    const inB=b=>brandId===undefined||b===brandId,m=new Map();
    const G=(name,unit)=>{const k=key(name);let x=m.get(k);if(!x){x={sku:String(name).trim(),unit:unit||"",q:0,v:0,known:0,g:0,purch:0,stock:null,stockQ:null};m.set(k,x)}return x};
    for(const l of M.L)if(inB(l.brand)){const x=G(l.sku,l.unit);x.q+=l.q;x.v+=l.v;if(l.land!=null){x.known+=l.v;x.g+=l.g}}
    for(const l of M.P.lines)if(inB(l.brand))G(l.sku).purch+=l.v;
    for(const s of M.SV.rows)if(inB(s.brand)){const x=G(s.sku,s.unit);x.stockQ=s.cases;x.stock=s.v;if(!x.unit)x.unit=s.unit}
    return {title,sub:sub+" · tap a SKU to see its PO lines",rows:[...m.values()].sort((a,b)=>b.v-a.v||num(b.stock)-num(a.stock)),page:okPage("sales-tracking.html"),pageText:"Open Sales Tracking →",
      cols:[{t:"SKU",v:"sku"},{t:"Qty sold",v:"q",num:true,sum:true,dec:0,html:r=>r.q?esc(fmt(r.q)+" "+r.unit):""},{t:"Sales ₹",v:"v",money:true,sum:true},
        gpOk()&&{t:"Gross profit ₹",v:"g",money:true,sum:true},gpOk()&&{t:"Margin",v:r=>r.known>0?pct1(r.g,r.known):"—"},
        {t:"Purchase ₹",v:"purch",money:true,sum:true},{t:"Stock",v:"stockQ",num:true,dec:0,html:r=>r.stockQ==null?"":esc(fmt(r.stockQ)+" "+r.unit)},{t:"Stock value ₹",v:"stock",money:true,sum:true}].filter(Boolean),
      onRow:x=>ERPList.open(lineList(x.sku,sub,M.L.filter(l=>key(l.sku)===key(x.sku)&&inB(l.brand)),"sales-tracking.html"))};
  }
  function stockList(title,sub,rows){
    return {title,sub,rows:rows.slice().sort((a,b)=>num(b.v)-num(a.v)),page:okPage("inventory.html"),pageText:"Open Inventory →",empty:"No stock in godown.",
      cols:[{t:"SKU",v:"sku"},{t:"Brand",v:r=>brandName(r.brand)},{t:"In godown",v:"cases",num:true,sum:true,dec:0,html:r=>esc(fmt(r.cases)+" "+r.unit)},
        {t:"Landing ₹",v:"land",money:true,dec:2,html:r=>r.land==null?notSet:esc("₹"+r.land.toLocaleString("en-IN",{maximumFractionDigits:2}))},{t:"Value ₹",v:"v",money:true,sum:true}]};
  }
  // Date-wise column chart (Mohit, 21 Nov 2026: no up-down line). Per day: Sales column (gross profit part
  // in green at its foot) and a thin Purchase column beside it. Tap a day = that day's POs.
  function lineChart(el,days,series){
    const W=Math.max(260,el.clientWidth||600),H=W<500?190:Math.max(210,Math.min(320,(el.parentNode.clientHeight||0)-40)),P={l:44,r:6,t:16,b:22},n=days.length;
    const S=series.find(x=>x.t==="Sales"),PU=series.find(x=>x.t==="Purchase"),G=series.find(x=>x.t==="Gross profit");
    const max=Math.max(1,...S.raw,...(PU?PU.raw:[0]))*1.1,y=v=>P.t+(H-P.t-P.b)*(1-Math.max(0,v)/max),base=H-P.b;
    const slot=(W-P.l-P.r)/Math.max(1,n),bw=Math.max(3,Math.min(26,slot*(PU?.48:.62))),pw=PU?Math.max(2,Math.min(12,slot*.22)):0,gap=PU?Math.min(3,slot*.06):0;
    const cx=i=>P.l+slot*i+slot/2;
    let g="";
    for(let k=0;k<=3;k++){const v=max*k/3;g+='<line x1="'+P.l+'" x2="'+(W-P.r)+'" y1="'+y(v)+'" y2="'+y(v)+'" stroke="#eef0ec"'+(k?' stroke-dasharray="3 3"':"")+'/><text x="'+(P.l-5)+'" y="'+(y(v)+3)+'" font-size="9.5" fill="#55686c" text-anchor="end">'+lakh(v).replace("₹","")+"</text>"}
    const step=Math.max(1,Math.ceil(n/(W<500?7:15))),best=S.raw.indexOf(Math.max(...S.raw));
    days.forEach((d,i)=>{
      const x0=cx(i)-(bw+gap+pw)/2,sv=S.raw[i],gv=G?Math.max(0,Math.min(sv,G.raw[i])):0,pv=PU?PU.raw[i]:0;
      if(sv>0){g+='<rect x="'+x0+'" y="'+y(sv)+'" width="'+bw+'" height="'+(base-y(sv))+'" rx="2" fill="'+S.c+'"'+(i===best?"":' opacity=".85"')+"/>";
        if(gv>0)g+='<rect x="'+x0+'" y="'+y(gv)+'" width="'+bw+'" height="'+(base-y(gv))+'" fill="'+G.c+'"/>'}
      if(pv>0)g+='<rect x="'+(x0+bw+gap)+'" y="'+y(pv)+'" width="'+pw+'" height="'+(base-y(pv))+'" rx="1.5" fill="'+PU.c+'"/>';
      if(sv>0&&(n<=10||i===best))g+='<text x="'+(x0+bw/2)+'" y="'+(y(sv)-4)+'" font-size="9.5" font-weight="700" fill="#10262b" text-anchor="middle">'+lakh(sv).replace("₹","").replace(" ","")+"</text>";
      if(i%step===0||i===n-1&&(n-1)%step>step/2)g+='<text x="'+(i===n-1&&cx(i)+14>W?W-1:cx(i))+'" y="'+(H-6)+'" font-size="9.5" fill="#55686c" text-anchor="'+(i===n-1&&cx(i)+14>W?"end":"middle")+'">'+dm(d)+"</text>";
      g+='<rect data-day="'+d+'" style="cursor:pointer" x="'+(P.l+slot*i)+'" y="'+P.t+'" width="'+slot+'" height="'+(H-P.t-P.b)+'" fill="transparent"><title>'+dmy(d)+"\n"+series.map(s=>s.t+": "+rs(s.raw[i])).join("\n")+"\n(tap to see POs)</title></rect>";
    });
    g+='<line x1="'+P.l+'" x2="'+(W-P.r)+'" y1="'+base+'" y2="'+base+'" stroke="#c9d0cc"/>';
    el.innerHTML='<svg width="'+W+'" height="'+H+'" role="img" aria-label="Sales, purchase and gross profit by day">'+g+"</svg>";
  }
  // Mini columns for the key cards (same style as the big chart).
  function spark(vals,color){
    const n=vals.length;if(n<2)return "";
    const mx=Math.max(1,...vals),w=100/n;
    return '<svg class="bz-spk" viewBox="0 0 100 28" preserveAspectRatio="none" aria-hidden="true">'+vals.map((v,i)=>{const h=Math.max(v>0?1.5:0,v/mx*26);return h?'<rect x="'+(i*w+w*.15).toFixed(2)+'" y="'+(28-h).toFixed(2)+'" width="'+(w*.7).toFixed(2)+'" height="'+h.toFixed(2)+'" rx=".6" fill="'+color+'"'+(i===n-1?"":' opacity=".55"')+"/>":""}).join("")+"</svg>";
  }
  function donut(vals,colors,center){
    const r=46,c=2*Math.PI*r,t=Math.max(1,sum(vals,v=>v));let o=0,g="";
    vals.forEach((v,i)=>{const d=c*v/t;if(d<=0)return;g+='<circle r="'+r+'" cx="60" cy="60" fill="none" stroke="'+colors[i]+'" stroke-width="16" stroke-dasharray="'+Math.max(0,d-1.5)+" "+(c-d+1.5)+'" stroke-dashoffset="'+(-o)+'" transform="rotate(-90 60 60)"/>';o+=d});
    if(!g)g='<circle r="'+r+'" cx="60" cy="60" fill="none" stroke="#eef0ec" stroke-width="16"/>';
    return '<svg width="120" height="120" viewBox="0 0 120 120" aria-hidden="true">'+g+'<text x="60" y="60" text-anchor="middle" font-size="13" font-weight="700" fill="#10262b">'+esc(center[0])+'</text><text x="60" y="74" text-anchor="middle" font-size="9.5" fill="#55686c">'+esc(center[1])+"</text></svg>";
  }

  function paint(M,R){
    const {S,P,E,SV}=M,gpPct=pctTxt(S.gp,S.known),net=S.gp-E.total,ch=M.prev?Math.round((M.curTot-M.prev)/M.prev*100):null;
    const rangeTxt=R.from===R.to?dmy(R.from):dm(R.from)+" – "+dm(R.to);
    const out=CTX.out,short=CTX.short,pend=CTX.pending;
    DET=new Map();
    // Popup makers (each returns ERPList.open options)
    const rt=" · "+rangeTxt,known=M.L.filter(l=>l.land!=null),gp=gpOk();
    const salesD=()=>poList("Sales","PO-wise"+rt+" (cancelled / rejected not counted)",M.L,"sales-tracking.html");
    const purchD=P.ok?()=>billList("Purchase","Goods Inward bills by received date"+rt,P.lines):null;
    const gpD=gp?()=>poList("Gross profit","(PO rate − landing) × qty, PO-wise"+rt+(S.missing?" · "+fmt(S.missing)+" lines without landing left out":""),M.L,"sales-tracking.html","g"):null;
    const costD=gp?()=>Object.assign(lineList("Cost of goods (landing)","Landing × qty of every sold SKU line"+rt,known,"rates.html"),{pageText:"Open Rate List →"}):null;
    const expD=(c,list)=>E.ok?()=>expList(c?c:"Expenses",(c?"Head "+c:"Accounts money-out entries, without Supplier payment / Contra / Asset purchase / GST")+rt,list||E.lines):null;
    const netD=E.ok&&gp?()=>({title:"Net profit",sub:"Gross profit of each PO minus each expense"+rt,page:okPage("accounts-dashboard.html"),pageText:"Open Accounts →",
      rows:poRows(M.L).filter(r=>r.known).map(r=>({type:"Gross profit",day:r.day,ref:r.po,detail:r.party,v:r.g,r})).concat(E.lines.map(l=>({type:"Expense",day:l.day,ref:l.cat,detail:[l.party,l.remark].filter(Boolean).join(" · "),v:-l.v})))
        .sort((a,b)=>a.type.localeCompare(b.type)||b.v-a.v),
      cols:[{t:"Type",v:"type"},{t:"Date",v:"day",date:true},{t:"PO / Head",v:"ref"},{t:"Detail",v:"detail"},{t:"Amount ₹",v:"v",money:true,sum:true}],
      onRow:x=>{if(x.r)ERPList.open(poLines(x.r))}}):null;
    const outD=out?()=>{
      if(out.parties)return {title:"Outstanding",sub:"Party-wise due after advance",rows:out.parties,page:okPage("party-billing.html"),pageText:"Open Accounts →",
        cols:[{t:"Party",v:"party"},{t:"Due ₹",v:"due",money:true,sum:true},{t:"Oldest bill (days)",v:"oldest",num:true,dec:0}]};
      const o=(CTX.ov&&CTX.ov.outstanding)||{};
      return {title:"Outstanding",sub:"Brand-wise due · party list is on Accounts",rows:(CTX.companies||[]).filter(c=>o[c.id]).map(c=>({brand:c.name,due:num(o[c.id].due),over:num(o[c.id].overdue)})),
        page:okPage("party-billing.html"),pageText:"Open Accounts →",cols:[{t:"Brand",v:"brand"},{t:"Due ₹",v:"due",money:true,sum:true},{t:"Past credit days ₹",v:"over",money:true,sum:true}]};
    }:null;
    const stockD=SV.ok?()=>stockList("Stock value","Godown stock × landing (today)",SV.rows):null;
    const cashD=M.acc?()=>({title:"Cash + Bank",sub:"Closing cash in hand and bank balances",page:okPage("accounts-dashboard.html"),pageText:"Open Accounts →",
      rows:[{name:"Cash in hand",acct:M.cash==null?"Opening cash not set":"",v:M.cash}].concat((M.acc.banks||[]).filter(b=>b.active!==false).map(b=>({name:b.name,acct:b.account_no||"",v:num(b.balance)}))),
      cols:[{t:"Cash / Bank",v:"name"},{t:"Account",v:"acct"},{t:"Balance ₹",v:"v",money:true,sum:true}]}):null;
    // Key numbers first (Mohit, 21 Nov 2026): Sales, Purchase, Expenses, Outstanding, Stock Value, each with a small
    // graphic (trend line / split bar). Gross, Net, Pending delivery and Cash + Bank sit in a slimmer row below.
    const sv=M.days.map(d=>M.byDay.get(d).s),pv=M.days.map(d=>M.byDay.get(d).p);
    const bShare=k=>[...M.brand].filter(([,b])=>b[k]>0).sort((a,b)=>b[1][k]-a[1][k]).map(([id,b])=>[b[k],brandColor(id),brandName(id)+" "+lakh(b[k])]);
    const k=[
      kpiX(COL.sales,"Sales",lakh(S.sales),ch==null?esc(rangeTxt):'<em class="'+(ch>=0?"up":"dn")+'">'+(ch>=0?"▲ ":"▼ ")+Math.abs(ch)+"%</em> vs "+(span(R.from,R.to)==1?(R.to===today()?"yesterday":"day before"):"prev "+span(R.from,R.to)+" days"),salesD,spark(sv,COL.sales)),
      kpiX("#a8902f","Purchase",P.ok?lakh(P.total):"—",P.ok?fmt(P.bills.size)+" inward bill"+(P.bills.size==1?"":"s"):"Purchase Register",purchD,P.ok?spark(pv,"#a8902f"):""),
      kpiX("#c62828","Expenses",E.ok?lakh(E.total):"—",E.ok?(CTX.allBrands?"":"All brands · ")+(M.ec[0]?esc(M.ec[0][0])+" "+lakh(M.ec[0][1]):"No expense entered"):"Accounts",expD(),E.ok&&E.total?stack(M.ec.map((x,i)=>[x[1],EXC[i],x[0]+" "+lakh(x[1])])):""),
      kpiX("#b26b00","Outstanding",out?lakh(out.total):"—",out?'<em class="dn">'+lakh(out.over)+"</em> "+(out.brand?"past credit days":"over 30 days"):"Billing & Outstanding",outD,out&&out.total>0?stack([[out.over,"#c62828","Overdue "+lakh(out.over)],[Math.max(0,out.total-out.over),"#e9b949","In credit days "+lakh(Math.max(0,out.total-out.over))]]):""),
      kpiX("#1d5fbf","Stock Value",SV.ok?lakh(SV.total):"—",short?'<em class="dn">'+fmt(short)+" SKU"+(short==1?"":"s")+" short</em>":"Godown stock × landing",stockD,SV.ok&&SV.total>0?stack(bShare("stock")):"")];
    const k2=[
      gp&&kpi(COL.gp,"Gross Profit",lakh(S.gp),gpPct+" margin"+(S.missing?" · "+fmt(S.missing)+" lines no landing":""),gpD),
      gp&&kpi(net>=0?COL.gp:"#c62828","Net Profit",E.ok?lakh(net):"—",E.ok?'<em class="'+(net>=0?"up":"dn")+'">'+pctTxt(net,S.known)+"</em> of sales":"Needs Accounts",netD),
      kpi("#7a3fb0","Pending Delivery",pend?fmt(pend.count)+" PO"+(pend.count==1?"":"s"):"—",pend?'<em class="dn">'+lakh(pend.amount)+"</em>"+(pend.oldest?" · since "+dm(pend.oldest):" to deliver"):"PO / Sales",pend&&pend.list),
      kpi(COL.sales,"Cash + Bank",M.acc?lakh(num(M.cash)+M.bank):"—",M.acc?"Cash "+(M.cash==null?"not set":lakh(M.cash))+" · Bank "+lakh(M.bank):"Accounts",cashD)].filter(Boolean);
    // P&L (every row opens its list)
    const restCats=new Set(M.cats.slice(5).map(x=>x[0]));
    const pl=[["Sales"+(S.missing?" (with landing)":""),rs(S.known),"",gp?()=>poList("Sales (with landing)","PO-wise"+rt,known,"sales-tracking.html"):salesD],
      ["− Cost of goods (landing)",rs(S.known-S.gp),"",costD],["Gross profit",rs(S.gp),"h",gpD]]
      .concat(E.ok?M.ec.map(x=>["− "+x[0],rs(x[1]),"",expD(x[0]==="Other"&&restCats.size?"Other heads":x[0],E.lines.filter(l=>x[0]==="Other"&&restCats.size?restCats.has(l.cat):l.cat===x[0]))]):[["− Expenses","Not available"]])
      .concat([["Net profit",E.ok?rs(net):"—",net>=0?"big":"big neg",netD]]);
    const plH='<table class="bz-pl">'+pl.map(r=>'<tr class="'+(r[2]||"")+'"'+da(r[3])+'><td>'+esc(r[0])+'</td><td class="n">'+r[1]+"</td></tr>").join("")+"</table>"+
      (S.missing?'<div class="bz-note">'+fmt(S.missing)+" SKU line"+(S.missing==1?"":"s")+" ("+lakh(S.sales-S.known)+") have no landing and are left out. Set landing in Rate &amp; Scheme / Rajnigandha Rate List.</div>":"");
    // Brand-wise
    const comp=(CTX.companies||[]).filter(c=>M.brand.has(c.id)||(CTX.allow?CTX.allow.has(c.id):c.active!==false));
    const rows=comp.map(c=>({c,b:M.brand.get(c.id)||{sales:0,qty:0,gp:0,known:0,purch:0,stock:0,unit:c.pack_unit==="BOX"?"IC":"cs"}}));
    const none=M.brand.get("");if(none&&(none.sales||none.purch))rows.push({c:{id:"",name:"No brand",color:"#9aa5a8"},b:none});
    const due=id=>CTX.ov&&CTX.ov.outstanding&&CTX.ov.outstanding[id]?num(CTX.ov.outstanding[id].due):null,hasDue=!!(CTX.ov&&CTX.ov.outstanding);
    const brH='<table class="bz-t"><thead><tr><th>Brand</th><th class="n">Sales</th><th class="n">Qty</th><th class="n bz-hm">Purchase</th>'+(gp?'<th class="n bz-hs">Gross</th><th class="n">Margin</th>':"")+''+(hasDue?'<th class="n bz-hm">To collect</th>':"")+'<th class="n bz-hm">Stock</th></tr></thead><tbody>'+
      rows.map(({c,b})=>{const m=b.known>0?b.gp/b.known*100:null;return '<tr'+da(()=>skuList(c.name,"SKU-wise"+rt+(due(c.id)?" · to collect "+lakh(due(c.id)):""),M,c.id))+'><td><span class="bz-dot" style="background:'+esc(c.color||"#2362a4")+'"></span><b>'+esc(c.name)+'</b></td><td class="n">'+lakh(b.sales)+'</td><td class="n">'+fmt(b.qty)+" "+esc(b.unit||(c.pack_unit==="BOX"?"IC":"cs"))+'</td><td class="n bz-hm">'+lakh(b.purch)+"</td>"+(gp?'<td class="n bz-hs">'+lakh(b.gp)+'</td><td class="n">'+(m==null?"—":'<span class="bz-pill '+(m<0?"r":m<4?"a":"g")+'">'+(Math.round(m*10)/10)+"%</span>")+"</td>":"")+(hasDue?'<td class="n bz-hm">'+(due(c.id)==null?"—":lakh(due(c.id)))+"</td>":"")+'<td class="n bz-hm">'+lakh(b.stock)+"</td></tr>"}).join("")+
      '</tbody><tfoot><tr'+da(()=>skuList("All brands","SKU-wise"+rt,M,undefined))+'><td>Total</td><td class="n">'+lakh(S.sales)+'</td><td class="n">—</td><td class="n bz-hm">'+lakh(P.total)+"</td>"+(gp?'<td class="n bz-hs">'+lakh(S.gp)+'</td><td class="n">'+gpPct+"</td>":"")+(hasDue?'<td class="n bz-hm">'+lakh(sum(rows,r=>due(r.c.id)))+"</td>":"")+'<td class="n bz-hm">'+lakh(SV.total)+"</td></tr></tfoot></table>";
    const bs=bShare("sales"),bsT=sum(bs,x=>x[0]);
    const brShare=bs.length?stack(bs)+'<div class="bz-stl">'+bs.map(x=>'<span><i style="background:'+x[1]+'"></i>'+esc(x[2].replace(/ ₹.*$/,""))+" <b>"+Math.round(x[0]/bsT*100)+"%</b></span>").join("")+"</div>":"";
    // Expenses
    const exH=E.ok?(E.total?'<div class="bz-ex">'+donut(M.ec.map(x=>x[1]),EXC,[lakh(E.total).replace(" L","L"),"total"])+'<div class="bz-exl">'+M.ec.map((x,i)=>'<div'+da(expD(x[0]==="Other"&&restCats.size?"Other heads":x[0],E.lines.filter(l=>x[0]==="Other"&&restCats.size?restCats.has(l.cat):l.cat===x[0])))+'><span><span class="bz-dot" style="background:'+EXC[i]+'"></span>'+esc(x[0])+"</span><b>"+rs(x[1])+"</b></div>").join("")+"</div></div>":'<div class="bz-empty">No expense entered in Accounts for '+esc(rangeTxt)+".</div>")
      :'<div class="bz-empty">Expenses are read from the Accounts Dashboard (Admin / Accounts).</div>';
    // Top SKUs
    const top=M.skus.slice(0,8),mx=Math.max(8,...top.map(s=>s.known>0?s.gp/s.known*100:0));
    const skH=top.length?'<table class="bz-t bz-sk"><thead><tr><th>SKU</th><th class="n bz-hm">Qty</th><th class="n">Sales</th>'+(gp?"<th>Margin</th>":"")+'<th class="n">Stock</th></tr></thead><tbody>'+top.map(s=>{const m=s.known>0?s.gp/s.known*100:null;
      return '<tr'+da(()=>lineList(s.name,"PO lines"+rt,M.L.filter(l=>key(l.sku)===key(s.name)),"sales-tracking.html"),s.name+" · tap to see PO lines")+'><td><span class="bz-dot" style="background:'+esc(CTX.colorOf(s.name))+'"></span>'+esc(s.name)+'</td><td class="n bz-hm">'+fmt(s.qty)+" "+esc(s.unit)+'</td><td class="n">'+lakh(s.sales)+"</td>"+(gp?'<td class="bz-mg">'+(m==null?'<small>no landing</small>':'<div class="bz-bar"><i style="width:'+Math.max(2,Math.min(100,m/mx*100))+"%;background:"+(m<0?"#c62828":m<4?"#b26b00":"#13824a")+'"></i></div><small>'+(Math.round(m*10)/10)+"%</small>")+"</td>":"")+'<td class="n">'+(s.stock==null?"—":s.stock<=0?'<span class="bz-pill r">0 · out</span>':s.days==null?fmt(s.stock)+" "+esc(s.unit):s.days<1?'<span class="bz-pill a">&lt;1 d</span>':s.days<3?'<span class="bz-pill a">'+s.days+" d</span>":s.days+" d")+"</td></tr>"}).join("")+"</tbody></table>"
      :'<div class="bz-empty">No sale in '+esc(rangeTxt)+".</div>";
    const seg='<div class="bz-seg" role="group" aria-label="Period">'+RANGES.map(r=>'<button type="button" data-bz="'+r[0]+'" title="'+r[1]+'"'+(r[0]===R.key?' class="on" aria-pressed="true"':' aria-pressed="false"')+'><span class="bz-fl">'+r[1]+'</span><span class="bz-sh">'+r[2]+"</span></button>").join("")+"</div>";
    const tday=today();
    const cus=R.key==="custom"?'<span class="bz-cus"><label>From <input type="date" id="bzFrom" value="'+R.from+'" max="'+tday+'" min="2020-01-01"></label><label>To <input type="date" id="bzTo" value="'+R.to+'" min="'+R.from+'" max="'+tday+'"></label></span>':"";
    EL.innerHTML='<div class="bz-hd"><h2>Business Overview</h2>'+(window.LWBPeriod?"":seg+cus)+(window.LWBPeriod||!cus?'<span class="bz-rg">'+esc(rangeTxt)+"</span>":"")+'<button type="button" class="erp-i" aria-label="Info" title="Info" data-tip="Sales = SKU qty × PO rate by order date (cancelled not counted). Gross profit = (rate − landing) × qty; landing from Rate &amp; Scheme (Coca-Cola) or Rajnigandha Rate List. Purchase = Goods Inward invoice total by received date. Expenses = Accounts money-out entries, without Supplier payment, Contra (bank transfer), Asset purchase and GST / Tax paid. Stock value = godown stock × landing.">i</button></div>'+
      '<div class="bz-kpis bz-k5">'+k.join("")+"</div>"+
      '<div class="bz-kpis bz-k4">'+k2.join("")+"</div>"+
      '<div class="bz-g bz-r2"><section class="bz-c"><h3>Day-wise Sales<span class="bz-leg"><span><i style="background:'+COL.sales+'"></i>Sales</span>'+(gp?'<span><i style="background:'+COL.gp+'"></i>Gross profit (in sales)</span>':"")+'<span><i style="background:'+COL.purch+'"></i>Purchase</span>'+'</span></h3><div class="bz-chart" id="bzChart"></div></section>'+
      '<section class="bz-c"><h3>Expenses<span class="bz-r">'+esc(rangeTxt)+(!CTX.can||CTX.can("accounts-dashboard.html")?' · <a href="accounts-dashboard.html">Accounts →</a>':"")+'</span></h3>'+exH+"</section></div>"+
      '<div class="bz-g bz-r3"><section class="bz-c"><h3>Brand-wise<span class="bz-r">sales share · qty in own unit</span></h3>'+brShare+brH+"</section>"+
      (gp?'<section class="bz-c"><h3>Profit &amp; Loss<span class="bz-r">'+esc(rangeTxt)+"</span></h3>"+plH+"</section>":'<section class="bz-c"><h3>Needs attention</h3><div class="bz-al">'+(CTX.alerts||'<div class="bz-empty">✓ No alerts right now.</div>')+"</div></section>")+"</div>"+
      '<div class="bz-g bz-r3"><section class="bz-c"><h3>Top SKUs<span class="bz-r">sales · '+(gp?"margin · ":"")+'stock days</span></h3>'+skH+"</section>"+
      (gp?'<section class="bz-c"><h3>Needs attention</h3><div class="bz-al">'+(CTX.alerts||'<div class="bz-empty">✓ No alerts right now.</div>')+"</div></section>":"")+"</div>";
    const draw=()=>{const c=EL.querySelector("#bzChart");if(!c)return;
      lineChart(c,M.days,[{t:"Sales",c:COL.sales,v:M.days.map(d=>M.byDay.get(d).s),raw:M.days.map(d=>M.byDay.get(d).s)},
        {t:"Purchase",c:COL.purch,v:M.days.map(d=>M.byDay.get(d).p),raw:M.days.map(d=>M.byDay.get(d).p)},
        gp&&{t:"Gross profit",c:COL.gp,v:M.days.map(d=>Math.max(0,M.byDay.get(d).g)),raw:M.days.map(d=>M.byDay.get(d).g)}].filter(Boolean))};
    draw();EL._draw=draw;EL._M=M;EL._R=R;
  }

  async function run(){
    if(!EL||!CTX)return;
    const my=++seq,rk=getRange(),R={...rangeOf(rk),key:rk};
    if(!EL.querySelector(".bz-kpis"))EL.innerHTML='<div class="bz-empty">Loading business overview…</div>';
    else EL.classList.add("bz-busy");
    try{
      // Speed (19 Nov 2026): the rows read do not depend on the brand (build() filters by brand), so a brand
      // change draws again from what is already loaded. Each date chip is kept for 2 minutes, and the other
      // chips are read quietly after the first draw, so tapping Today / Yday / 7D / 30D / Month is instant.
      if(CTX.fresh){cache=null;CTX.fresh=false}
      const D=await loadCached(R);
      if(my!==seq)return;
      const fid=document.activeElement&&EL.contains(document.activeElement)?document.activeElement.id:"";
      paint(build(D,R),R);
      if(fid==="bzFrom"||fid==="bzTo"){const f=EL.querySelector("#"+fid);if(f)f.focus()}
    }catch(e){console.error(e);if(my===seq)EL.innerHTML='<div class="bz-empty">Business overview could not load. Tap refresh.</div>'}
    finally{if(my===seq)EL.classList.remove("bz-busy")}
    if(my===seq)prefetch();
  }
  const CACHE_MS=12e4;
  function loadCached(R){
    if(!cache)cache=new Map();
    const ck=R.from+"|"+R.to,h=cache.get(ck);
    if(h&&Date.now()-h.at<CACHE_MS)return h.p;
    const p=load(R);cache.set(ck,{p,at:Date.now()});p.catch(()=>{if(cache&&cache.get(ck)&&cache.get(ck).p===p)cache.delete(ck)});
    return p;
  }
  let pre=0;
  function prefetch(){
    clearTimeout(pre);
    pre=setTimeout(async()=>{
      for(const k of ["today","yday","7","30","month"]){
        if(!EL||!document.body.contains(EL)||document.hidden)return;
        try{await loadCached({...rangeOf(k),key:k})}catch(e){}
      }
    },1500);
  }
  // Top-bar profit ON/OFF tapped: paint again from the numbers already loaded (no new reads).
  document.addEventListener("lwb:profit",()=>{if(EL&&EL._M&&EL._R&&document.body.contains(EL))paint(EL._M,EL._R)});
  let rz=0;
  window.addEventListener("resize",()=>{clearTimeout(rz);rz=setTimeout(()=>{if(EL&&EL._draw&&document.body.contains(EL))EL._draw()},150)});
  window.LWBBizDash={
    mount(el,ctx){
      if(!el)return;EL=el;CTX=ctx;
      if(!el.dataset.bzOn){el.dataset.bzOn="1";
        if(window.LWBPeriod&&!window.__bzPer){window.__bzPer=1;LWBPeriod.on(()=>{if(EL&&document.body.contains(EL))run()})}
        const openD=t=>{const f=DET.get(t.dataset.bzd);if(f&&window.ERPList){const o=f();if(o)ERPList.open(o)}};
        el.addEventListener("click",e=>{
          const b=e.target.closest("button[data-bz]");if(b&&el.contains(b)){setRange(b.dataset.bz);run();return}
          const d=e.target.closest("[data-bzd]");if(d&&el.contains(d)&&!e.target.closest("a[href]")){e.preventDefault();openD(d);return}
          const r=e.target.closest("rect[data-day]");if(r&&el._M&&window.ERPList){const day=r.dataset.day;ERPList.open(poList("Sales "+dmy(day),"PO-wise",el._M.CL.filter(l=>l.day===day),"sales-tracking.html"))}
        });
        // Custom dates: From picks one day (To = From); To then makes it a range. Short wait so typing a date is not cut.
        let ct=0;
        el.addEventListener("change",e=>{
          const t=e.target;if(t.id!=="bzFrom"&&t.id!=="bzTo")return;
          clearTimeout(ct);ct=setTimeout(()=>{
            const fi=el.querySelector("#bzFrom"),ti=el.querySelector("#bzTo");if(!fi||!ti)return;
            let f=fi.value,to=ti.value;const td=today();
            if(!isDay(f)||f>td)return;
            if(t.id==="bzFrom"||!isDay(to)||to<f)to=f;
            if(to>td)to=td;
            setCustom(f,to);run();
          },500);
        });
        el.addEventListener("keydown",e=>{if(e.key!=="Enter"&&e.key!==" ")return;const d=e.target.closest("[data-bzd]");if(!d||d.tagName==="BUTTON"||d!==e.target)return;e.preventDefault();openD(d)});
      }
      return run();
    },
    refresh(){cache=null;return run()}
  };
})();
