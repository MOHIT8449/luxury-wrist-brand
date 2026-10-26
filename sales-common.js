/* LUXURY WRIST BRAND ERP — shared helpers for Sales Team, Sales Tracking and My Sales.
   Database RLS / RPC checks stay the real permission check. */
(function(){
  const client=supabase.createClient("https://txkbhadzdbxpieunfvox.supabase.co","sb_publishable_W4I3Q5ODf0g17sq5uDml2Q_sLolXYEk");
  const el=id=>document.getElementById(id);
  const esc=s=>String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const num=v=>{const n=Number(v);return Number.isFinite(n)?n:0};
  const fmt=n=>Number(n||0).toLocaleString("en-IN",{maximumFractionDigits:0});
  const rupees=n=>"₹"+Number(n||0).toLocaleString("en-IN",{maximumFractionDigits:0});
  // ₹1.25 Cr / ₹12.50 L for big numbers.
  const short=n=>{n=num(n);const a=Math.abs(n);
    if(a>=1e7)return "₹"+(n/1e7).toLocaleString("en-IN",{maximumFractionDigits:2})+" Cr";
    if(a>=1e5)return "₹"+(n/1e5).toLocaleString("en-IN",{maximumFractionDigits:2})+" L";
    return rupees(n)};
  const pct=(a,b)=>b>0?Math.round(a/b*1000)/10:null;
  const isoDay=d=>d.toLocaleDateString("en-CA",{timeZone:"Asia/Kolkata"});
  const istDay=v=>{if(!v)return "";const d=new Date(v);return isNaN(d)?String(v).slice(0,10):isoDay(d)};
  const shortDate=v=>{if(!v)return "—";const d=new Date(String(v).length===10?v+"T00:00:00+05:30":v);return isNaN(d)?String(v):d.toLocaleDateString("en-IN",{day:"2-digit",month:"short",timeZone:"Asia/Kolkata"})};
  const key=v=>String(v||"").toUpperCase().replace(/\s+/g," ").trim();
  const daysBetween=(a,b)=>Math.round((Date.parse(b+"T00:00:00Z")-Date.parse(a+"T00:00:00Z"))/864e5);
  const SKIP=["cancelled","canceled","rejected"],DONE=["loaded","invoiced","delivered"];
  const status=o=>String(o.status||"").toLowerCase().trim();

  async function start(allowed){
    const {data:{session}}=await client.auth.getSession();
    if(!session){location.replace("login.html");return null}
    const {data:p}=await client.from("user_profiles").select("full_name,role,active").eq("id",session.user.id).single();
    const real=String((p&&p.role)||"").toLowerCase().trim();
    // A page of another role that Admin ticked for this user opens as that role.
    const role=!p||allowed.includes(real)?real:await ERPShell.pageRoleFresh(real);
    if(!p||p.active!==true||!allowed.includes(role)){location.replace("dashboard.html");return null}
    const me={user:session.user,role,realRole:real,name:p.full_name||session.user.email};
    ERPShell.mount({role:real,name:me.name,onLogout:async()=>{await client.auth.signOut();location.replace("login.html")}});
    return me;
  }
  async function inChunks(table,col,ids,sel){
    const out=[];
    for(let i=0;i<ids.length;i+=100){
      const r=await client.from(table).select(sel||"*").in(col,ids.slice(i,i+100));
      if(r.error)throw r.error;out.push(...(r.data||[]));
    }
    return out;
  }
  // Orders between two IST days (inclusive), cancelled / rejected left out. Paged past the 1000-row API limit.
  async function orders(from,to,sel){
    const next=isoDay(new Date(Date.parse(to+"T12:00:00+05:30")+864e5)),out=[];
    for(let page=0;page<50;page++){
      const r=await client.from("orders").select(sel||"id,order_no,order_date,created_at,customer_name,sales_person,status,total_qty,total_amount,created_by")
        .gte("order_date",from+"T00:00:00+05:30").lt("order_date",next+"T00:00:00+05:30").order("order_date").range(page*1000,page*1000+999);
      if(r.error)throw r.error;
      out.push(...(r.data||[]));if((r.data||[]).length<1000)break;
    }
    return out.filter(o=>!SKIP.includes(status(o)));
  }
  function monthRange(m){
    const [y,mo]=m.split("-").map(Number),last=new Date(Date.UTC(y,mo,0)).getUTCDate();
    const end=m+"-"+String(last).padStart(2,"0"),today=isoDay(new Date());
    return {from:m+"-01",to:end>today?today:end,end,days:last};
  }
  // Cases and value of one order line: Loaded basis uses loaded cases of loaded / billed POs.
  function lineQty(it,o,basis){
    if(basis==="loaded")return DONE.includes(status(o))?num(it.loaded_qty):0;
    return it.approved_qty!=null?num(it.approved_qty):num(it.ordered_qty);
  }
  // Same formula as Rate & Scheme LANDING (excl. ROI) and PO Entry.
  function landing(pack,settings,scheme){
    const n=num,C=n(pack.case_config),D=n(pack.gr),F=n(pack.free_bottle),H=n(pack.qps),I=n(settings.roi_main);
    const blank=v=>v===""||v==null;
    const E=D*(scheme?n(scheme.mepd_pct):blank(pack.mepd_pct)?n(settings.mepd_pct):n(pack.mepd_pct))/100;
    const base=D-E-H-I-((C?D/C:0)-1)*F,P=n(pack.slab3_rate);
    if(F>0&&C){const O=Math.round((P-base)/(1+F/C)*100)/100,G=(((D/C)-1)*F)-((O/C)*F);return D-E-G-H-I}
    return D-E-n(pack.oms)-H-I;
  }
  // Landing per SKU for Admin / Sales Head (rate tables are readable only by them).
  async function loadLanding(){
    const [st,pk,ln,sc]=await Promise.all([
      client.from("lwb_rate_settings").select("mepd_pct,roi_main,roi_landing").eq("id",1).maybeSingle(),
      client.from("lwb_rate_packs").select("*"),
      client.from("lwb_rate_pack_skus").select("sku_key,pack_id"),
      client.from("lwb_mepd_schemes").select("categories,mepd_pct,valid_from,valid_to,created_at")
    ]);
    if(st.error||pk.error||ln.error||!st.data)return null;
    const packs=new Map((pk.data||[]).map(p=>[p.id,p])),bySku=new Map();
    for(const l of ln.data||[]){const p=packs.get(l.pack_id);if(p&&p.active!==false)bySku.set(key(l.sku_key),p)}
    const settings=st.data,schemes=sc.error?[]:(sc.data||[]);
    return {has:k=>bySku.has(key(k)),cost:(sku,category,day)=>{
      const p=bySku.get(key(sku));if(!p)return null;
      const s=window.LWBMepd?LWBMepd.find(schemes,category,day):null;
      return landing(p,settings,s);
    }};
  }
  function loadScript(src){return new Promise((ok,fail)=>{const t=document.createElement("script");t.src=src;t.onload=ok;t.onerror=()=>fail(Error("Could not load Excel tool. Check internet."));document.head.appendChild(t)})}
  async function excel(file,sheets){
    if(!window.XLSX)await loadScript("https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js");
    const book=XLSX.utils.book_new();
    for(const s of sheets){const ws=XLSX.utils.aoa_to_sheet([[s.title],[],s.head,...s.rows]);ws["!cols"]=s.head.map(h=>({wch:/Party|SKU|Salesman|Name/.test(h)?28:14}));XLSX.utils.book_append_sheet(book,ws,s.name.slice(0,31))}
    XLSX.writeFile(book,file+".xlsx");
  }
  // Table helper: head [label], rows [[cells]] (cells already escaped HTML), num = right-aligned column indexes.
  function table(head,rows,numCols,foot){
    const c=i=>(numCols||[]).includes(i)?' class="num"':"";
    let h='<table class="erp-table"><thead><tr>'+head.map((x,i)=>"<th"+c(i)+">"+esc(x)+"</th>").join("")+"</tr></thead><tbody>";
    for(const r of rows)h+="<tr"+(r.attr||"")+">"+(r.cells||r).map((x,i)=>"<td"+c(i)+">"+x+"</td>").join("")+"</tr>";
    h+="</tbody>";
    if(foot)h+="<tfoot><tr>"+foot.map((x,i)=>"<td"+c(i)+">"+x+"</td>").join("")+"</tr></tfoot>";
    return h+"</table>";
  }
  function bar(p){const v=p==null?0:Math.max(0,Math.min(100,p));return '<span class="sl-bar"><i style="width:'+v+'%" class="'+(p==null?"":p>=100?"ok":p>=60?"mid":"low")+'"></i></span>'}
  window.LWBSales={client,el,esc,num,fmt,rupees,short,pct,isoDay,istDay,shortDate,key,daysBetween,SKIP,DONE,status,start,inChunks,orders,monthRange,lineQty,loadLanding,excel,table,bar};
})();
