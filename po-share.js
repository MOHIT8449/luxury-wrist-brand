/* LUXURY WRIST BRAND ERP — PO as a clean image for a WhatsApp group (no order no.).
   LWBPoShare.draw({date, party, trans, lines:[{sku,cases,pallet,rate,amount,weight}]}) -> canvas (blue / white)
   LWBPoShare.fromOrder(client, orderId) -> same object, loaded from orders + order_items
   LWBPoShare.open(client, orderId) / LWBPoShare.show(data) -> popup with preview + Share / Copy / Download */
(function(){
  const NAVY="#0b3d91",BLUE="#dbe7fb",PALE="#f2f6fd",LINE="#8fa9d6",INK="#0f2347";
  const FONT=(b,sz)=>(b?"bold ":"")+sz+'px "Bahnschrift","Segoe UI","Arial Narrow",Arial,sans-serif';
  const n=v=>{const x=Number(v);return Number.isFinite(x)?x:0};
  const fmt=v=>new Intl.NumberFormat("en-IN",{maximumFractionDigits:2}).format(n(v));
  const r2=v=>Math.round(n(v)*100)/100;
  const dt=v=>window.LWBDate&&LWBDate.dt?LWBDate.dt(v):new Date(v).toLocaleString("en-IN");

  function draw(o){
    const lines=o.lines||[];
    const T=lines.reduce((a,l)=>({cases:a.cases+n(l.cases),pallet:a.pallet+n(l.pallet),amount:a.amount+n(l.amount),weight:a.weight+n(l.weight)}),{cases:0,pallet:0,amount:0,weight:0});
    const hasPal=lines.some(l=>l.pallet!=null);
    const C=[300,90,90,130],W=C.reduce((a,b)=>a+b,0),X=[0];C.forEach((w,i)=>X.push(X[i]+w));
    const rowH=40,sc=3,info=[["DATE",o.date||"-"],["CUSTOMER",o.party||"-"],["TRANSPORT",o.trans||"-"]];
    const nrows=1+info.length+1+lines.length+3,H=nrows*rowH+2;
    const cv=document.createElement("canvas");cv.width=W*sc;cv.height=H*sc;
    const x=cv.getContext("2d");x.scale(sc,sc);
    x.fillStyle="#fff";x.fillRect(0,0,W,H);
    const cell=(c1,c2,cy,bg,txt,color,bold,align)=>{
      const cx=X[c1],w=X[c2+1]-X[c1];txt=String(txt);
      x.fillStyle=bg;x.fillRect(cx,cy,w,rowH);x.strokeStyle=LINE;x.lineWidth=1;x.strokeRect(cx+.5,cy+.5,w-1,rowH-1);
      let sz=17;x.font=FONT(bold,sz);while(x.measureText(txt).width>w-14&&sz>9){sz--;x.font=FONT(bold,sz)}
      x.fillStyle=color;x.textBaseline="middle";
      x.textAlign=align==="l"?"left":align==="r"?"right":"center";
      x.fillText(txt,align==="l"?cx+10:align==="r"?cx+w-10:cx+w/2,cy+rowH/2+1);
    };
    let y=1;
    cell(0,3,y,NAVY,"LUXURY WRIST BRAND","#fff",true,"c");y+=rowH;
    info.forEach(([a,b])=>{cell(0,0,y,BLUE,a,INK,true,"c");cell(1,3,y,PALE,b,INK,true,"c");y+=rowH});
    ["PRODUCT NAME","QTY","RATE","AMOUNT"].forEach((t,i)=>cell(i,i,y,NAVY,t,"#fff",true,"c"));y+=rowH;
    lines.forEach(l=>{cell(0,0,y,"#fff",l.sku,"#1c2533",false,"l");cell(1,1,y,"#fff",fmt(l.cases),"#1c2533",false,"c");
      cell(2,2,y,"#fff",l.rate==null?"":fmt(l.rate),"#1c2533",false,"c");cell(3,3,y,"#fff",fmt(l.amount),"#1c2533",false,"r");y+=rowH});
    [["TOTAL QTY",fmt(T.cases)+" case"+(hasPal?" ("+fmt(r2(T.pallet))+" pallet)":"")],["TOTAL AMOUNT","₹ "+fmt(T.amount)],["WEIGHT",fmt(T.weight)+" KG"]]
      .forEach(([a,b])=>{cell(0,0,y,BLUE,a,INK,true,"c");cell(1,3,y,PALE,b,INK,true,"c");y+=rowH});
    return cv;
  }

  async function fromOrder(client,id){
    const [o,it]=await Promise.all([client.from("orders").select("*").eq("id",id).maybeSingle(),client.from("order_items").select("*").eq("order_id",id).order("id")]);
    if(o.error)throw o.error;if(it.error)throw it.error;if(!o.data)throw Error("Order not found.");
    const items=it.data||[];
    let cpp=new Map();
    const names=[...new Set(items.filter(i=>!n(i.cases_per_pallet_snapshot)).map(i=>i.sku_name).filter(Boolean))];
    if(names.length){const s=await client.from("sku_master").select("sku_name,cases_per_pallet").in("sku_name",names);
      if(!s.error)(s.data||[]).forEach(r=>cpp.set(String(r.sku_name).trim().toUpperCase(),n(r.cases_per_pallet)))}
    const lines=items.map(i=>{
      const q=i.approved_qty!=null?n(i.approved_qty):n(i.ordered_qty);
      const per=n(i.cases_per_pallet_snapshot)||cpp.get(String(i.sku_name||"").trim().toUpperCase())||0;
      const uw=n(i.unit_weight)||(n(i.ordered_qty)?n(i.total_weight)/n(i.ordered_qty):0);
      return {sku:String(i.sku_name||"").trim(),cases:q,pallet:per?r2(q/per):null,rate:i.rate==null?null:n(i.rate),amount:q*n(i.rate),weight:q*uw};
    }).filter(l=>l.sku&&l.cases>0);
    const d=o.data;
    return {party:d.customer_name||"-",trans:d.transportation||"-",date:dt(d.order_date||d.created_at),lines};
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
  window.LWBPoShare={draw,fromOrder,show,open,copy,download,share};
})();
