/* LUXURY WRIST BRAND ERP — party ledger as short text (Copy) and as a clean image for WhatsApp (Mohit, 28 Nov 2026).
   Only Date, Invoice no., Debit, Credit + closing balance. Invoice no.: GST (pakka) bill = Tally bill no., Cash (kachha) bill = PO no.
   d = {party, period:"01/04/2026 to 28/11/2026", brand, open, rows:[{date, inv, dr, cr}], dr, cr, close}
   LWBLedgerShare.text(d) -> WhatsApp text      LWBLedgerShare.copyText(d) -> copies it
   LWBLedgerShare.draw(d) -> canvas             LWBLedgerShare.show(d) -> popup with preview + Share / Copy image / Download */
(function(){
  if(window.LWBLedgerShare)return;
  const n=v=>{const x=Number(v);return Number.isFinite(x)?x:0};
  const r2=v=>Math.round(n(v)*100)/100;
  const fmt=v=>new Intl.NumberFormat("en-IN",{maximumFractionDigits:2}).format(Math.abs(r2(v)));
  const dc=v=>Math.abs(r2(v))<0.5?"":r2(v)>0?" Dr":" Cr";
  const say=(t,k)=>{if(window.ERPShell&&ERPShell.toast)ERPShell.toast(t,k||"success");else alert(t)};

  function text(d){
    const L=["*"+d.party+"*","Ledger "+d.period+(d.brand?" · "+d.brand:""),"Date | Invoice no. | Debit | Credit"];
    if(Math.abs(r2(d.open))>=0.5)L.push(d.from+" | Opening | "+(d.open>0?fmt(d.open):"-")+" | "+(d.open<0?fmt(d.open):"-"));
    for(const r of d.rows)L.push(r.date+" | "+(r.inv||"-")+" | "+(r.dr?fmt(r.dr):"-")+" | "+(r.cr?fmt(r.cr):"-"));
    L.push("*Total* | | "+fmt(d.dr)+" | "+fmt(d.cr));
    L.push("*Closing balance: ₹"+fmt(d.close)+dc(d.close)+"*");
    return L.join("\n");
  }
  async function copyText(d){
    const t=text(d);
    try{await navigator.clipboard.writeText(t)}
    catch(e){const a=document.createElement("textarea");a.value=t;a.style.cssText="position:fixed;left:-9999px";document.body.appendChild(a);a.select();
      const ok=document.execCommand("copy");a.remove();if(!ok)throw Error("Copy is not allowed here.")}
    return t;
  }

  // Same look as the PO image (po-share.js): navy bar, light blue labels, grid lines.
  const NAVY="#0b3d91",BLUE="#dbe7fb",PALE="#f2f6fd",LINE="#8fa9d6",INK="#0f2347",GREEN="#0d7a3e",RED="#c8102e";
  const FONT=(b,sz)=>(b?"bold ":"")+sz+'px "Bahnschrift","Segoe UI","Arial Narrow",Arial,sans-serif';
  function draw(d){
    const C=[130,190,150,150],W=C.reduce((a,b)=>a+b,0),X=[0];C.forEach((w,i)=>X.push(X[i]+w));
    const hasOpen=Math.abs(r2(d.open))>=0.5,info=[["PARTY",d.party],["PERIOD",d.period]].concat(d.brand?[["BRAND",d.brand]]:[]);
    const rowH=38,nrows=1+info.length+1+(hasOpen?1:0)+d.rows.length+2,H=nrows*rowH+2;
    const sc=nrows>180?1.5:nrows>90?2:3;
    const cv=document.createElement("canvas");cv.width=W*sc;cv.height=H*sc;
    const x=cv.getContext("2d");x.scale(sc,sc);x.fillStyle="#fff";x.fillRect(0,0,W,H);
    const cell=(c1,c2,cy,bg,txt,color,bold,align,h)=>{
      h=h||rowH;const cx=X[c1],w=X[c2+1]-X[c1];txt=String(txt==null?"":txt);
      x.fillStyle=bg;x.fillRect(cx,cy,w,h);x.strokeStyle=LINE;x.lineWidth=1;x.strokeRect(cx+.5,cy+.5,w-1,h-1);
      let sz=16;x.font=FONT(bold,sz);while(x.measureText(txt).width>w-14&&sz>9){sz--;x.font=FONT(bold,sz)}
      x.fillStyle=color;x.textBaseline="middle";x.textAlign=align==="l"?"left":align==="r"?"right":"center";
      x.fillText(txt,align==="l"?cx+10:align==="r"?cx+w-10:cx+w/2,cy+h/2+1);
    };
    let y=1;
    cell(0,3,y,NAVY,"LUXURY WRIST BRAND · LEDGER","#fff",true,"c");y+=rowH;
    info.forEach(([a,b])=>{cell(0,0,y,BLUE,a,INK,true,"c");cell(1,3,y,PALE,b,INK,true,"c");y+=rowH});
    ["DATE","INVOICE NO.","DEBIT","CREDIT"].forEach((t,i)=>cell(i,i,y,NAVY,t,"#fff",true,"c"));y+=rowH;
    const line=(a,b,dr,cr,bg,bold)=>{cell(0,0,y,bg,a,"#1c2533",bold,"c");cell(1,1,y,bg,b,"#1c2533",true,"c");
      cell(2,2,y,bg,dr?"₹ "+fmt(dr):"","#1c2533",bold,"r");cell(3,3,y,bg,cr?"₹ "+fmt(cr):"",GREEN,bold,"r");y+=rowH};
    if(hasOpen)line(d.from,"OPENING",d.open>0?d.open:0,d.open<0?-d.open:0,PALE,false);
    d.rows.forEach((r,i)=>line(r.date,r.inv||"-",r.dr,r.cr,i%2?"#f7f9fc":"#fff",false));
    cell(0,1,y,BLUE,"TOTAL",INK,true,"c");cell(2,2,y,BLUE,"₹ "+fmt(d.dr),INK,true,"r");cell(3,3,y,BLUE,"₹ "+fmt(d.cr),GREEN,true,"r");y+=rowH;
    const cl=r2(d.close),ccol=cl>0.5?RED:cl<-0.5?GREEN:INK;
    cell(0,1,y,BLUE,"CLOSING BALANCE",INK,true,"c");cell(2,3,y,"#fff","₹ "+fmt(cl)+dc(cl),ccol,true,"c");
    x.strokeStyle=ccol;x.lineWidth=2;x.strokeRect(X[2]+1,y+1,X[4]-X[2]-2,rowH-2);
    return cv;
  }

  const blob=cv=>new Promise(ok=>cv.toBlob(ok,"image/png"));
  const fileName=d=>("Ledger "+(d.party||"")).replace(/[\\/:*?"<>|]+/g," ").trim()+".png";
  async function copyImg(cv){if(!navigator.clipboard||!window.ClipboardItem)throw Error("no clipboard");await navigator.clipboard.write([new ClipboardItem({"image/png":blob(cv)})])}
  async function download(cv,name){const u=URL.createObjectURL(await blob(cv)),a=document.createElement("a");a.href=u;a.download=name;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(u),2000)}
  async function share(cv,name){const f=new File([await blob(cv)],name,{type:"image/png"});
    if(navigator.canShare&&navigator.canShare({files:[f]})){try{await navigator.share({files:[f]})}catch(e){if(e.name!=="AbortError")throw e}return true}return false}

  function css(){
    if(document.getElementById("lwbLedShareCss"))return;
    const s=document.createElement("style");s.id="lwbLedShareCss";
    s.textContent=".lls-bg{position:fixed;inset:0;background:rgba(15,25,45,.55);z-index:10050;display:flex;align-items:center;justify-content:center;padding:12px}"+
      ".lls-box{background:#fff;border-radius:12px;width:min(520px,100%);max-height:calc(100dvh - 24px);display:flex;flex-direction:column;box-shadow:0 12px 40px rgba(0,0,0,.3)}"+
      ".lls-head{display:flex;align-items:center;gap:8px;padding:9px 12px;border-bottom:1px solid #e3e8ef}.lls-head b{flex:1;font-size:15px;color:#0f2347;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}"+
      ".lls-x{border:0;background:none;font-size:20px;line-height:1;cursor:pointer;color:#5b6675;padding:4px 6px}"+
      ".lls-img{overflow:auto;padding:8px 10px;background:#f5f7fb;flex:1 1 auto;min-height:0}.lls-img img{display:block;width:100%;height:auto;border-radius:4px}"+
      ".lls-acts{display:flex;gap:6px;padding:9px 12px;border-top:1px solid #e3e8ef}.lls-acts button{flex:1;min-width:0;padding:9px 4px;border-radius:8px;border:1px solid #c9d3e3;background:#fff;color:#0f2347;font:600 13px system-ui,sans-serif;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}"+
      ".lls-acts button.main{background:#0b3d91;border-color:#0b3d91;color:#fff}";
    document.head.appendChild(s);
  }
  function show(d){
    css();
    const cv=draw(d),name=fileName(d);
    const canFile=(()=>{try{return !!(navigator.canShare&&navigator.canShare({files:[new File([new Blob()],"a.png",{type:"image/png"})]}))}catch(e){return false}})();
    const bg=document.createElement("div");bg.className="lls-bg";
    bg.innerHTML='<div class="lls-box" role="dialog" aria-modal="true" aria-label="Ledger image"><div class="lls-head"><b></b><button type="button" class="lls-x" aria-label="Close">✕</button></div>'+
      '<div class="lls-img"><img alt="Ledger image"></div><div class="lls-acts">'+(canFile?'<button type="button" class="main" data-a="share">📲 Share</button>':"")+
      '<button type="button" class="'+(canFile?"":"main")+'" data-a="copy">Copy image</button><button type="button" data-a="dl">⬇ Download</button><button type="button" data-a="txt">📋 Copy text</button></div></div>';
    bg.querySelector(".lls-head b").textContent="Ledger image · "+d.party;
    bg.querySelector("img").src=cv.toDataURL("image/png");
    const close=()=>{bg.remove();document.removeEventListener("keydown",esc,true)};
    const esc=e=>{if(e.key==="Escape"){e.preventDefault();e.stopPropagation();close()}};
    document.addEventListener("keydown",esc,true);
    bg.addEventListener("click",async e=>{
      if(e.target===bg||e.target.closest(".lls-x")){close();return}
      const a=e.target.closest("[data-a]");if(!a)return;
      try{
        if(a.dataset.a==="share"){if(!await share(cv,name)){await download(cv,name);say("Image downloaded. Attach it in WhatsApp.")}}
        else if(a.dataset.a==="copy"){try{await copyImg(cv);say("Ledger image copied. Paste it in WhatsApp (Ctrl+V).")}catch(err){await download(cv,name);say("Copy is not allowed here, so the image was downloaded.")}}
        else if(a.dataset.a==="txt"){await copyText(d);say("Ledger text copied.")}
        else{await download(cv,name);say("Image downloaded.")}
      }catch(err){say("Could not share: "+(err.message||err),"error")}
    });
    document.body.appendChild(bg);
    const first=bg.querySelector(".lls-acts button");first&&first.focus();
  }
  window.LWBLedgerShare={text,copyText,draw,show};
})();
