/* LUXURY WRIST BRAND ERP — PO as a clean image for a WhatsApp group (no order no.).
   LWBPoShare.draw({date, party, trans, lines:[{sku,cases,pallet,rate,amount,weight}]}) -> canvas (blue / white)
   LWBPoShare.fromOrder(client, orderId) -> same object, loaded from orders + order_items
   LWBPoShare.open(client, orderId) / LWBPoShare.show(data) -> popup with preview + Share / Copy / Download
   LWBPoShare.quick(client, orderId) -> one tap: computer copies the image, phone downloads it (Mohit, 5 Nov)
   LWBPoShare.ICON -> small image icon for the list / popup button
   Colour by who made the PO (Mohit, 6 Nov): Admin navy, Sales Head green, each salesman his own colour (by name),
   name in the top bar. A line below the min rate (landing + margin) is red with "LOW" and a red count at the end. */
(function(){
  // [dark bar, label cell, value cell, grid line, label text]. Red stays free for a low rate.
  const TH=(d,l,p,g,i)=>({d,l,p,g,i});
  const ADMIN=TH("#0b3d91","#dbe7fb","#f2f6fd","#8fa9d6","#0f2347"),HEAD=TH("#146c43","#d5efe0","#f1faf4","#86c3a1","#0d3b25");
  const SALES=[TH("#5b2a9b","#e7dcf7","#f6f1fd","#b29ad9","#2e1552"),TH("#0f6e78","#d3eef0","#f0fafb","#86c4ca","#073a40"),
    TH("#b35a00","#fbe6cf","#fdf6ee","#e2b380","#4d2700"),TH("#a3166b","#f7d6e9","#fdf1f7","#dc93bd","#4d0a32"),
    TH("#3d4f63","#dde3ea","#f4f6f9","#a3b0bf","#1b2733"),TH("#5e6b12","#e8edcc","#f7f9ec","#b7c27c","#2a3006"),
    TH("#7a4a1f","#efe1d3","#faf5ef","#c9a582","#3a210a")];
  function theme(o){
    const r=String(o.role||"").trim().toLowerCase(),nm=String(o.by||"").trim().toUpperCase();
    if(r==="admin")return ADMIN;if(r==="manager")return HEAD;if(!nm)return ADMIN;
    let h=2166136261;for(const c of nm){h^=c.charCodeAt(0);h=Math.imul(h,16777619)>>>0}return SALES[h%SALES.length];
  }
  const RED="#c8102e",RED_BG="#fde4e4";
  const FONT=(b,sz)=>(b?"bold ":"")+sz+'px "Bahnschrift","Segoe UI","Arial Narrow",Arial,sans-serif';
  const n=v=>{const x=Number(v);return Number.isFinite(x)?x:0};
  const fmt=v=>new Intl.NumberFormat("en-IN",{maximumFractionDigits:2}).format(n(v));
  const r2=v=>Math.round(n(v)*100)/100;
  const dt=v=>window.LWBDate&&LWBDate.dt?LWBDate.dt(v):new Date(v).toLocaleString("en-IN");

  const isLow=l=>l.min!=null&&l.rate!=null&&n(l.rate)<n(l.min);
  function draw(o){
    const lines=o.lines||[],th=theme(o),NAVY=th.d,BLUE=th.l,PALE=th.p,LINE=th.g,INK=th.i,low=lines.filter(isLow).length;
    const T=lines.reduce((a,l)=>({cases:a.cases+n(l.cases),pallet:a.pallet+n(l.pallet),amount:a.amount+n(l.amount),weight:a.weight+n(l.weight)}),{cases:0,pallet:0,amount:0,weight:0});
    const hasPal=lines.some(l=>l.pallet!=null);
    const C=[300,90,90,130],W=C.reduce((a,b)=>a+b,0),X=[0];C.forEach((w,i)=>X.push(X[i]+w));
    const rowH=40,sc=3,info=[["DATE",o.date||"-"],["CUSTOMER",o.party||"-"],["TRANSPORT",o.trans||"-"]];
    const nrows=1+info.length+1+lines.length+3+(low?1:0),H=nrows*rowH+2;
    const cv=document.createElement("canvas");cv.width=W*sc;cv.height=H*sc;
    const x=cv.getContext("2d");x.scale(sc,sc);
    x.fillStyle="#fff";x.fillRect(0,0,W,H);
    const cell=(c1,c2,cy,bg,txt,color,bold,align,rp)=>{
      const cx=X[c1],w=X[c2+1]-X[c1];txt=String(txt);
      x.fillStyle=bg;x.fillRect(cx,cy,w,rowH);x.strokeStyle=LINE;x.lineWidth=1;x.strokeRect(cx+.5,cy+.5,w-1,rowH-1);
      let sz=17;x.font=FONT(bold,sz);while(x.measureText(txt).width>w-14-(rp||0)&&sz>9){sz--;x.font=FONT(bold,sz)}
      x.fillStyle=color;x.textBaseline="middle";
      x.textAlign=align==="l"?"left":align==="r"?"right":"center";
      x.fillText(txt,align==="l"?cx+10:align==="r"?cx+w-10:cx+w/2,cy+rowH/2+1);
    };
    let y=1;
    cell(0,3,y,NAVY,"LUXURY WRIST BRAND","#fff",true,"c");
    if(o.by){x.font=FONT(true,12);x.fillStyle="rgba(255,255,255,.85)";x.textAlign="right";x.fillText(String(o.by).toUpperCase().slice(0,18),W-10,y+rowH/2+1)}
    y+=rowH;
    info.forEach(([a,b])=>{cell(0,0,y,BLUE,a,INK,true,"c");cell(1,3,y,PALE,b,INK,true,"c");y+=rowH});
    ["PRODUCT NAME","QTY","RATE","AMOUNT"].forEach((t,i)=>cell(i,i,y,NAVY,t,"#fff",true,"c"));y+=rowH;
    lines.forEach(l=>{const lo=isLow(l),bg=lo?RED_BG:"#fff",ink=lo?RED:"#1c2533";
      cell(0,0,y,bg,l.sku,ink,lo,"l",lo?46:0);
      if(lo){x.fillStyle=RED;x.fillRect(X[1]-46,y+11,38,18);x.font=FONT(true,11);x.fillStyle="#fff";x.textAlign="center";x.fillText("LOW",X[1]-27,y+21)}
      cell(1,1,y,bg,fmt(l.cases),ink,lo,"c");
      cell(2,2,y,bg,l.rate==null?"":fmt(l.rate),ink,lo,"c");cell(3,3,y,bg,fmt(l.amount),ink,lo,"r");
      if(lo){x.strokeStyle=RED;x.lineWidth=2;x.strokeRect(1,y+1,W-2,rowH-2)}
      y+=rowH});
    [["TOTAL QTY",fmt(T.cases)+" case"+(hasPal?" ("+fmt(r2(T.pallet))+" pallet)":"")],["TOTAL AMOUNT","₹ "+fmt(T.amount)],["WEIGHT",fmt(T.weight)+" KG"]]
      .forEach(([a,b])=>{cell(0,0,y,BLUE,a,INK,true,"c");cell(1,3,y,PALE,b,INK,true,"c");y+=rowH});
    if(low){cell(0,3,y,RED,"RATE BELOW MIN: "+low+" LINE"+(low>1?"S":"")+" (ADMIN OK NEEDED)","#fff",true,"c");y+=rowH}
    return cv;
  }

  // Min rate by SKU (lwb_sale_rates: any active user); loaded once per page.
  let mins=null;
  async function minRates(client){
    if(mins)return mins;
    try{const r=await client.rpc("lwb_sale_rates");mins=new Map((r.error?[]:r.data||[]).filter(x=>x.min_rate!=null).map(x=>[String(x.sku_key).trim().toUpperCase(),n(x.min_rate)]))}
    catch(e){mins=new Map()}
    return mins;
  }
  async function maker(client,uid){
    if(!uid)return "";
    try{const r=await client.from("user_profiles").select("role").eq("id",uid).maybeSingle();return r.error||!r.data?"":String(r.data.role||"")}catch(e){return ""}
  }
  async function fromOrder(client,id){
    const [o,it,mn]=await Promise.all([client.from("orders").select("*").eq("id",id).maybeSingle(),client.from("order_items").select("*").eq("order_id",id).order("id"),minRates(client)]);
    if(o.error)throw o.error;if(it.error)throw it.error;if(!o.data)throw Error("Order not found.");
    const role=await maker(client,o.data.created_by);
    const items=it.data||[];
    let cpp=new Map();
    const names=[...new Set(items.filter(i=>!n(i.cases_per_pallet_snapshot)).map(i=>i.sku_name).filter(Boolean))];
    if(names.length){const s=await client.from("sku_master").select("sku_name,cases_per_pallet").in("sku_name",names);
      if(!s.error)(s.data||[]).forEach(r=>cpp.set(String(r.sku_name).trim().toUpperCase(),n(r.cases_per_pallet)))}
    const lines=items.map(i=>{
      const q=i.approved_qty!=null?n(i.approved_qty):n(i.ordered_qty);
      const per=n(i.cases_per_pallet_snapshot)||cpp.get(String(i.sku_name||"").trim().toUpperCase())||0;
      const uw=n(i.unit_weight)||(n(i.ordered_qty)?n(i.total_weight)/n(i.ordered_qty):0);
      const sku=String(i.sku_name||"").trim(),mr=mn.get(sku.toUpperCase());
      return {sku,cases:q,pallet:per?r2(q/per):null,rate:i.rate==null?null:n(i.rate),amount:q*n(i.rate),weight:q*uw,min:mr==null?null:mr};
    }).filter(l=>l.sku&&l.cases>0);
    const d=o.data;
    return {party:d.customer_name||"-",trans:d.transportation||"-",date:dt(d.order_date||d.created_at),lines,by:String(d.sales_person||"").trim(),role};
  }

  const blob=cv=>new Promise(ok=>cv.toBlob(ok,"image/png"));
  const say=(t,k)=>{if(window.ERPShell&&ERPShell.toast)ERPShell.toast(t,k||"success");else alert(t)};
  const fileName=d=>("Order "+(d.party||"")).replace(/[\\/:*?"<>|]+/g," ").trim()+".png";
  async function copy(cv){
    if(!navigator.clipboard||!window.ClipboardItem)throw Error("no clipboard");
    await navigator.clipboard.write([new ClipboardItem({"image/png":blob(cv)})]);
  }
  async function download(cv,name){
    const u=URL.createObjectURL(await blob(cv)),a=document.createElement("a");a.href=u;a.download=name;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(u),2000);
  }
  async function share(cv,name){
    const f=new File([await blob(cv)],name,{type:"image/png"});
    if(navigator.canShare&&navigator.canShare({files:[f]})){try{await navigator.share({files:[f]})}catch(e){if(e.name!=="AbortError")throw e}return true}
    return false;
  }

  function css(){
    if(document.getElementById("lwbPoShareCss"))return;
    const s=document.createElement("style");s.id="lwbPoShareCss";
    s.textContent=".pos-bg{position:fixed;inset:0;background:rgba(15,25,45,.55);z-index:10050;display:flex;align-items:center;justify-content:center;padding:12px}"+
      ".pos-box{background:#fff;border-radius:12px;width:min(480px,100%);max-height:calc(100vh - 24px);display:flex;flex-direction:column;box-shadow:0 12px 40px rgba(0,0,0,.3)}"+
      ".pos-head{display:flex;align-items:center;gap:8px;padding:10px 12px;border-bottom:1px solid #e3e8ef}.pos-head b{flex:1;font-size:15px;color:#0f2347}"+
      ".pos-x{border:0;background:none;font-size:20px;line-height:1;cursor:pointer;color:#5b6675;padding:4px 6px}"+
      ".pos-img{overflow:auto;padding:10px 12px;background:#f5f7fb}.pos-img img{display:block;width:100%;height:auto;border-radius:4px}"+
      ".pos-note{font-size:12px;color:#5b6675;padding:6px 12px 0}"+
      ".pos-acts{display:flex;gap:6px;padding:10px 12px}.pos-acts button{flex:1;min-width:0;padding:10px 6px;border-radius:8px;border:1px solid #c9d3e3;background:#fff;color:#0f2347;font:600 13px system-ui,sans-serif;cursor:pointer;white-space:nowrap}"+
      ".pos-acts button.main{background:#0b3d91;border-color:#0b3d91;color:#fff}";
    document.head.appendChild(s);
  }
  function show(d){
    css();
    const cv=draw(d),name=fileName(d);
    if(!d.lines.length){say("This order has no SKU line to share.","error");return}
    const canFile=(()=>{try{return !!(navigator.canShare&&navigator.canShare({files:[new File([new Blob()],"a.png",{type:"image/png"})]}))}catch(e){return false}})();
    const bg=document.createElement("div");bg.className="pos-bg";
    bg.innerHTML='<div class="pos-box" role="dialog" aria-modal="true" aria-label="Share order image"><div class="pos-head"><b>Share order image</b><button type="button" class="pos-x" aria-label="Close">✕</button></div>'+
      '<div class="pos-img"><img alt="Order image"></div><div class="pos-note">Order no. is not shown on the image.</div>'+
      '<div class="pos-acts">'+(canFile?'<button type="button" class="main" data-a="share">Share</button>':"")+
      '<button type="button" class="'+(canFile?"":"main")+'" data-a="copy">Copy image</button><button type="button" data-a="dl">Download</button></div></div>';
    bg.querySelector("img").src=cv.toDataURL("image/png");
    const close=()=>{bg.remove();document.removeEventListener("keydown",esc,true)};
    const esc=e=>{if(e.key==="Escape"){e.preventDefault();e.stopPropagation();close()}};
    document.addEventListener("keydown",esc,true);
    bg.addEventListener("click",async e=>{
      if(e.target===bg||e.target.closest(".pos-x")){close();return}
      const a=e.target.closest("[data-a]");if(!a)return;
      try{
        if(a.dataset.a==="share"){if(!await share(cv,name)){await download(cv,name);say("Image downloaded. Attach it in WhatsApp.")}}
        else if(a.dataset.a==="copy"){try{await copy(cv);say("Image copied. Paste it in the WhatsApp group.")}catch(err){await download(cv,name);say("Copy is not allowed here, so the image was downloaded.")}}
        else{await download(cv,name);say("Image downloaded.")}
      }catch(err){say("Could not share: "+(err.message||err),"error")}
    });
    document.body.appendChild(bg);
    const first=bg.querySelector(".pos-acts button");first&&first.focus();
  }
  async function open(client,id){
    try{show(await fromOrder(client,id))}catch(e){say("Could not make the image: "+(e.message||e),"error")}
  }
  const phone=()=>{try{return matchMedia("(pointer:coarse)").matches||/Android|iPhone|iPad/i.test(navigator.userAgent)}catch(e){return false}};
  let busy=false;
  async function quick(client,id){
    if(busy)return;busy=true;
    try{
      const d=await fromOrder(client,id);
      if(!d.lines.length){say("This order has no SKU line to copy.","error");return}
      const cv=draw(d),name=fileName(d);
      if(phone()){await download(cv,name);say("Order image downloaded. Attach it in WhatsApp.");return}
      try{await copy(cv);say("Order image copied. Paste it in the WhatsApp group (Ctrl+V).")}
      catch(e){await download(cv,name);say("Copy is not allowed here, so the image was downloaded.")}
    }catch(e){say("Could not make the image: "+(e.message||e),"error")}
    finally{busy=false}
  }
  const ICON='<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="vertical-align:-3px"><rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="9" cy="10" r="2"/><path d="M21 16l-5-5-9 9"/></svg>';
  window.LWBPoShare={draw,fromOrder,show,open,quick,ICON,copy,download,share,theme,isLow};
})();
