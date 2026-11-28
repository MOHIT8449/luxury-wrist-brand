/* LUXURY WRIST BRAND ERP — party ledger / one bill as short text and as clean images for WhatsApp (Mohit, 28 Nov 2026).
   Ledger: only Date, Invoice no., Debit, Credit + closing. Invoice no.: GST (pakka) bill = Tally bill no., Cash (kachha) = PO no.
   WhatsApp-friendly: at most MAX (25) entries on one image / one text; more = pages 1/3, 2/3 … ("Balance c/f" at the end of
   each page, Total + Closing on the last). PDF = every page in one file (pdf-lib, same as the evening report).
   d = {party, from, period, brand, open, rows:[{date, inv, dr, cr}], dr, cr, close}
   LWBLedgerShare.pages(d) / text(d, page) / draw(d, page) / show(d) (popup: pages, Share / Copy / PNG / PDF / Text) / copyText(d)
   LWBLedgerShare.showBill(b) / billText(b) / billDraw(b) -> one bill: items + payments on it + due (bill popup) */
(function(){
  if(window.LWBLedgerShare)return;
  const MAX=25;
  const n=v=>{const x=Number(v);return Number.isFinite(x)?x:0};
  const r2=v=>Math.round(n(v)*100)/100;
  const fmt=v=>new Intl.NumberFormat("en-IN",{maximumFractionDigits:2}).format(Math.abs(r2(v)));
  const dc=v=>Math.abs(r2(v))<0.5?"":r2(v)>0?" Dr":" Cr";
  const say=(t,k)=>{if(window.ERPShell&&ERPShell.toast)ERPShell.toast(t,k||"success");else alert(t)};

  // Pages of at most MAX entries; carry = balance before the page, bal = balance after it
  function pages(d){
    const out=[],R=d.rows;let bal=r2(d.open);
    for(let i=0;i<Math.max(1,R.length);i+=MAX){const rows=R.slice(i,i+MAX),carry=bal;for(const r of rows)bal=r2(bal+n(r.dr)-n(r.cr));out.push({rows,carry,bal,first:i===0})}
    out.forEach((p,i)=>{p.no=i+1;p.of=out.length;p.last=i===out.length-1});
    return out;
  }
  function text(d,pi){
    const P=pages(d),p=P[pi||0],L=["*"+d.party+"*","Ledger "+d.period+(d.brand?" · "+d.brand:"")+(p.of>1?" · Page "+p.no+"/"+p.of:""),"Date | Invoice no. | Debit | Credit"];
    if(p.first&&Math.abs(r2(d.open))>=0.5)L.push(d.from+" | Opening | "+(d.open>0?fmt(d.open):"-")+" | "+(d.open<0?fmt(d.open):"-"));
    if(!p.first)L.push("Balance b/f: ₹"+fmt(p.carry)+dc(p.carry));
    for(const r of p.rows)L.push(r.date+" | "+(r.inv||"-")+" | "+(r.dr?fmt(r.dr):"-")+" | "+(r.cr?fmt(r.cr):"-"));
    if(p.last){L.push("*Total* | | "+fmt(d.dr)+" | "+fmt(d.cr));L.push("*Closing balance: ₹"+fmt(d.close)+dc(d.close)+"*")}
    else L.push("*Balance c/f: ₹"+fmt(p.bal)+dc(p.bal)+"* (next page "+(p.no+1)+"/"+p.of+")");
    return L.join("\n");
  }
  async function copyText(d,pi){return copyRaw(text(d,pi))}
  async function copyRaw(t){
    try{await navigator.clipboard.writeText(t)}
    catch(e){const a=document.createElement("textarea");a.value=t;a.style.cssText="position:fixed;left:-9999px";document.body.appendChild(a);a.select();
      const ok=document.execCommand("copy");a.remove();if(!ok)throw Error("Copy is not allowed here.")}
    return t;
  }

  // Same look as the PO image (po-share.js): navy bar, light blue labels, grid lines.
  const NAVY="#0b3d91",BLUE="#dbe7fb",PALE="#f2f6fd",LINE="#8fa9d6",INK="#0f2347",GREEN="#0d7a3e",RED="#c8102e";
  const FONT=(b,sz)=>(b?"bold ":"")+sz+'px "Bahnschrift","Segoe UI","Arial Narrow",Arial,sans-serif';
  function draw(d,pi){
    const p=pages(d)[pi||0];
    const C=[130,190,150,150],W=C.reduce((a,b)=>a+b,0),X=[0];C.forEach((w,i)=>X.push(X[i]+w));
    const hasOpen=p.first&&Math.abs(r2(d.open))>=0.5,info=[["PARTY",d.party],["PERIOD",d.period]].concat(d.brand?[["BRAND",d.brand]]:[]);
    const rowH=38,nrows=1+info.length+1+(hasOpen||!p.first?1:0)+p.rows.length+(p.last?2:1),H=nrows*rowH+2,sc=3;
    const cv=document.createElement("canvas");cv.width=W*sc;cv.height=H*sc;
    const x=cv.getContext("2d");x.scale(sc,sc);x.fillStyle="#fff";x.fillRect(0,0,W,H);
    const cell=(c1,c2,cy,bg,txt,color,bold,align)=>{const cx=X[c1],w=X[c2+1]-X[c1];txt=String(txt==null?"":txt);
      x.fillStyle=bg;x.fillRect(cx,cy,w,rowH);x.strokeStyle=LINE;x.lineWidth=1;x.strokeRect(cx+.5,cy+.5,w-1,rowH-1);
      let sz=16;x.font=FONT(bold,sz);while(x.measureText(txt).width>w-14&&sz>9){sz--;x.font=FONT(bold,sz)}
      x.fillStyle=color;x.textBaseline="middle";x.textAlign=align==="l"?"left":align==="r"?"right":"center";
      x.fillText(txt,align==="l"?cx+10:align==="r"?cx+w-10:cx+w/2,cy+rowH/2+1)};
    const balCell=(label,v,y,strong)=>{const col=v>0.5?RED:v<-0.5?GREEN:INK;cell(0,1,y,BLUE,label,INK,true,"c");cell(2,3,y,"#fff","₹ "+fmt(v)+dc(v),col,true,"c");
      if(strong){x.strokeStyle=col;x.lineWidth=2;x.strokeRect(X[2]+1,y+1,X[4]-X[2]-2,rowH-2)}};
    let y=1;
    cell(0,3,y,NAVY,"LUXURY WRIST BRAND · LEDGER"+(p.of>1?" · PAGE "+p.no+"/"+p.of:""),"#fff",true,"c");y+=rowH;
    info.forEach(([a,b])=>{cell(0,0,y,BLUE,a,INK,true,"c");cell(1,3,y,PALE,b,INK,true,"c");y+=rowH});
    ["DATE","INVOICE NO.","DEBIT","CREDIT"].forEach((t,i)=>cell(i,i,y,NAVY,t,"#fff",true,"c"));y+=rowH;
    const line=(a,b,dr,cr,bg)=>{cell(0,0,y,bg,a,"#1c2533",false,"c");cell(1,1,y,bg,b,"#1c2533",true,"c");
      cell(2,2,y,bg,dr?"₹ "+fmt(dr):"","#1c2533",false,"r");cell(3,3,y,bg,cr?"₹ "+fmt(cr):"",GREEN,false,"r");y+=rowH};
    if(hasOpen)line(d.from,"OPENING",d.open>0?d.open:0,d.open<0?-d.open:0,PALE);
    if(!p.first){balCell("BALANCE B/F",p.carry,y,false);y+=rowH}
    p.rows.forEach((r,i)=>line(r.date,r.inv||"-",r.dr,r.cr,i%2?"#f7f9fc":"#fff"));
    if(p.last){cell(0,1,y,BLUE,"TOTAL",INK,true,"c");cell(2,2,y,BLUE,"₹ "+fmt(d.dr),INK,true,"r");cell(3,3,y,BLUE,"₹ "+fmt(d.cr),GREEN,true,"r");y+=rowH;
      balCell("CLOSING BALANCE",r2(d.close),y,true)}
    else balCell("BALANCE C/F · NEXT "+(p.no+1)+"/"+p.of,p.bal,y,false);
    return cv;
  }

  const blob=cv=>new Promise(ok=>cv.toBlob(ok,"image/png"));
  const safe=t=>String(t).replace(/[\\/:*?"<>|]+/g," ").trim();
  async function copyImg(cv){if(!navigator.clipboard||!window.ClipboardItem)throw Error("no clipboard");await navigator.clipboard.write([new ClipboardItem({"image/png":blob(cv)})])}
  async function saveBlob(b,name){const u=URL.createObjectURL(b),a=document.createElement("a");a.href=u;a.download=name;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(u),2000)}
  async function download(cv,name){await saveBlob(await blob(cv),name)}
  async function shareFiles(files){if(navigator.canShare&&navigator.canShare({files})){try{await navigator.share({files})}catch(e){if(e.name!=="AbortError")throw e}return true}return false}
  function loadScript(src){return new Promise((ok,no)=>{const s=document.createElement("script");s.src=src;s.onload=ok;s.onerror=()=>no(Error("Could not load the PDF maker. Check the internet."));document.head.appendChild(s)})}
  // every page image on its own A4-wide page
  async function pdfOf(cvs){
    if(!window.PDFLib)await loadScript("https://cdnjs.cloudflare.com/ajax/libs/pdf-lib/1.17.1/pdf-lib.min.js");
    const doc=await PDFLib.PDFDocument.create();
    for(const cv of cvs){const img=await doc.embedPng(await (await blob(cv)).arrayBuffer()),w=595,h=Math.round(w*cv.height/cv.width),m=20;
      const pg=doc.addPage([w+2*m,h+2*m]);pg.drawImage(img,{x:m,y:m,width:w,height:h})}
    return new Blob([await doc.save()],{type:"application/pdf"});
  }

  function css(){
    if(document.getElementById("lwbLedShareCss"))return;
    const s=document.createElement("style");s.id="lwbLedShareCss";
    s.textContent=".lls-bg{position:fixed;inset:0;background:rgba(15,25,45,.55);z-index:10050;display:flex;align-items:center;justify-content:center;padding:12px}"+
      ".lls-box{background:#fff;border-radius:12px;width:min(520px,100%);max-height:calc(100dvh - 24px);display:flex;flex-direction:column;box-shadow:0 12px 40px rgba(0,0,0,.3)}"+
      ".lls-head{display:flex;align-items:center;gap:8px;padding:9px 12px;border-bottom:1px solid #e3e8ef}.lls-head b{flex:1;font-size:15px;color:#0f2347;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}"+
      ".lls-x{border:0;background:none;font-size:20px;line-height:1;cursor:pointer;color:#5b6675;padding:4px 6px}"+
      ".lls-note{margin:0;padding:6px 12px;background:#fff7e6;border-bottom:1px solid #f3d08a;font:600 12.5px system-ui,sans-serif;color:#7a4b00}"+
      ".lls-pg{display:flex;align-items:center;gap:6px;justify-content:center;padding:6px 12px 0;font:700 13px system-ui,sans-serif;color:#0f2347}.lls-pg button{border:1px solid #c9d3e3;background:#fff;border-radius:8px;width:34px;height:30px;font-size:16px;cursor:pointer;color:#0f2347}.lls-pg button:disabled{opacity:.4;cursor:default}"+
      ".lls-img{overflow:auto;padding:8px 10px;background:#f5f7fb;flex:1 1 auto;min-height:0}.lls-img img{display:block;width:100%;height:auto;border-radius:4px}"+
      ".lls-acts{display:flex;gap:5px;padding:9px 10px;border-top:1px solid #e3e8ef}.lls-acts button{flex:1;min-width:0;padding:9px 2px;border-radius:8px;border:1px solid #c9d3e3;background:#fff;color:#0f2347;font:600 13px system-ui,sans-serif;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}"+
      ".lls-acts button.main{background:#0b3d91;border-color:#0b3d91;color:#fff}";
    document.head.appendChild(s);
  }
  // popup: page preview (‹ 1/3 ›) + Share (all pages) / Copy (this page) / PNG (all) / PDF (all) / Text (this page)
  function popup(o){
    css();
    const cvs=o.canvases,N=cvs.length,names=cvs.map((_,i)=>o.name+(N>1?" "+(i+1)+"-"+N:"")+".png");
    const canFile=(()=>{try{return !!(navigator.canShare&&navigator.canShare({files:[new File([new Blob()],"a.png",{type:"image/png"})]}))}catch(e){return false}})();
    const bg=document.createElement("div");bg.className="lls-bg";let cur=0;
    bg.innerHTML='<div class="lls-box" role="dialog" aria-modal="true" aria-label="Share"><div class="lls-head"><b></b><button type="button" class="lls-x" aria-label="Close">✕</button></div>'+
      (o.note?'<p class="lls-note"></p>':"")+(N>1?'<div class="lls-pg"><button type="button" data-p="-1" aria-label="Previous page">‹</button><span></span><button type="button" data-p="1" aria-label="Next page">›</button></div>':"")+
      '<div class="lls-img"><img alt="Preview"></div><div class="lls-acts">'+(canFile?'<button type="button" class="main" data-a="share">📲 Share</button>':"")+
      '<button type="button" class="'+(canFile?"":"main")+'" data-a="copy" title="Copy this page image">Copy</button><button type="button" data-a="dl" title="Download image'+(N>1?"s":"")+'">⬇ PNG</button><button type="button" data-a="pdf" title="All pages in one PDF">📄 PDF</button><button type="button" data-a="txt" title="Copy this page as text">📋 Text</button></div></div>';
    bg.querySelector(".lls-head b").textContent=o.title;
    if(o.note)bg.querySelector(".lls-note").textContent=o.note;
    const img=bg.querySelector("img");
    const go=i=>{cur=Math.max(0,Math.min(N-1,i));img.src=cvs[cur].toDataURL("image/png");
      if(N>1){bg.querySelector(".lls-pg span").textContent="Page "+(cur+1)+" / "+N;bg.querySelector('[data-p="-1"]').disabled=cur===0;bg.querySelector('[data-p="1"]').disabled=cur===N-1}};
    go(o.page||0);
    const close=()=>{bg.remove();document.removeEventListener("keydown",esc,true)};
    const esc=e=>{if(e.key==="Escape"){e.preventDefault();e.stopPropagation();close()}else if(N>1&&(e.key==="ArrowRight"||e.key==="ArrowLeft")){e.preventDefault();go(cur+(e.key==="ArrowRight"?1:-1))}};
    document.addEventListener("keydown",esc,true);
    bg.addEventListener("click",async e=>{
      if(e.target===bg||e.target.closest(".lls-x")){close();return}
      const pb=e.target.closest("[data-p]");if(pb){go(cur+Number(pb.dataset.p));return}
      const a=e.target.closest("[data-a]");if(!a)return;
      const pgT=N>1?" (page "+(cur+1)+"/"+N+")":"";
      try{
        if(a.dataset.a==="share"){const files=await Promise.all(cvs.map(async(c,i)=>new File([await blob(c)],names[i],{type:"image/png"})));
          if(!await shareFiles(files)){for(let i=0;i<N;i++)await download(cvs[i],names[i]);say("Image"+(N>1?"s":"")+" downloaded. Attach in WhatsApp.")}}
        else if(a.dataset.a==="copy"){try{await copyImg(cvs[cur]);say("Image copied"+pgT+". Paste it in WhatsApp (Ctrl+V).")}catch(err){await download(cvs[cur],names[cur]);say("Copy is not allowed here, so the image was downloaded.")}}
        else if(a.dataset.a==="txt"){await copyRaw(o.text(cur));say("Text copied"+pgT+".")}
        else if(a.dataset.a==="pdf"){a.disabled=true;try{await saveBlob(await pdfOf(cvs),o.name+".pdf");say("PDF downloaded"+(N>1?" ("+N+" pages)":"")+".")}finally{a.disabled=false}}
        else{for(let i=0;i<N;i++)await download(cvs[i],names[i]);say(N>1?N+" images downloaded.":"Image downloaded.")}
      }catch(err){say("Could not share: "+(err.message||err),"error")}
    });
    document.body.appendChild(bg);
    const first=bg.querySelector(".lls-acts button");first&&first.focus();
  }
  function show(d,opt){
    const P=pages(d);
    popup({title:"Ledger · "+d.party,canvases:P.map((_,i)=>draw(d,i)),name:safe("Ledger "+d.party),text:i=>text(d,i),
      note:P.length>1?d.rows.length+" entries: WhatsApp shows "+MAX+" lines well, so this ledger is made in "+P.length+" pages. Share sends all pages; PDF has all pages in one file.":(opt&&opt.note)||""});
  }

  /* ---- one bill: which goods, qty, rate, amount + which payments went to it ----
     b = {party, inv, date, brand, items:[{sku,qty,rate,amt}], bill, cn, got, due, pays:[{date,mode,amount}]} */
  function billText(b){
    const L=["*"+b.party+"*","Bill "+b.inv+" · "+b.date+(b.brand?" · "+b.brand:"")];
    for(const i of b.items)L.push(i.sku+" | "+fmt(i.qty)+" x "+fmt(i.rate)+" = "+fmt(i.amt));
    L.push("*Total: "+fmt(b.items.reduce((a,i)=>a+n(i.qty),0))+" qty · ₹"+fmt(b.bill)+"*");
    if(b.pays.length){L.push("Payments:");for(const y of b.pays)L.push(y.date+" | "+y.mode+" | "+fmt(y.amount))}
    if(Math.abs(r2(b.cn))>=0.5)L.push("Credit note / return: "+fmt(b.cn));
    L.push("Received: "+fmt(b.got));
    L.push("*"+(b.due==null?"":r2(b.due)<=0.5?"Due: 0 (Paid)":"Due: ₹"+fmt(b.due))+"*");
    return L.join("\n");
  }
  function billDraw(b){
    const C=[290,90,110,140],W=C.reduce((a,c)=>a+c,0),X=[0];C.forEach((w,i)=>X.push(X[i]+w));
    const info=[["PARTY",b.party],["INVOICE NO.",b.inv],["BILL DATE",b.date]].concat(b.brand?[["BRAND",b.brand]]:[]);
    const sumR=[["BILL AMOUNT","₹ "+fmt(b.bill),INK]].concat(Math.abs(r2(b.cn))>=0.5?[["CREDIT NOTE / RETURN","₹ "+fmt(b.cn),INK]]:[]).concat([["RECEIVED","₹ "+fmt(b.got),GREEN]]);
    const rowH=38,nrows=1+info.length+1+b.items.length+1+(b.pays.length?2+b.pays.length:0)+sumR.length+(b.due==null?0:1),H=nrows*rowH+2,sc=nrows>90?2:3;
    const cv=document.createElement("canvas");cv.width=W*sc;cv.height=H*sc;
    const x=cv.getContext("2d");x.scale(sc,sc);x.fillStyle="#fff";x.fillRect(0,0,W,H);
    const cell=(c1,c2,cy,bg,txt,color,bold,align)=>{const cx=X[c1],w=X[c2+1]-X[c1];txt=String(txt==null?"":txt);
      x.fillStyle=bg;x.fillRect(cx,cy,w,rowH);x.strokeStyle=LINE;x.lineWidth=1;x.strokeRect(cx+.5,cy+.5,w-1,rowH-1);
      let sz=16;x.font=FONT(bold,sz);while(x.measureText(txt).width>w-14&&sz>9){sz--;x.font=FONT(bold,sz)}
      x.fillStyle=color;x.textBaseline="middle";x.textAlign=align==="l"?"left":align==="r"?"right":"center";
      x.fillText(txt,align==="l"?cx+10:align==="r"?cx+w-10:cx+w/2,cy+rowH/2+1)};
    let y=1;
    cell(0,3,y,NAVY,"LUXURY WRIST BRAND · SALES BILL","#fff",true,"c");y+=rowH;
    info.forEach(([a,v])=>{cell(0,0,y,BLUE,a,INK,true,"c");cell(1,3,y,PALE,v,INK,true,"c");y+=rowH});
    ["PRODUCT NAME","QTY","RATE","AMOUNT"].forEach((t,i)=>cell(i,i,y,NAVY,t,"#fff",true,"c"));y+=rowH;
    b.items.forEach((i,k)=>{const bg=k%2?"#f7f9fc":"#fff";cell(0,0,y,bg,i.sku,"#1c2533",false,"l");cell(1,1,y,bg,fmt(i.qty),"#1c2533",true,"c");
      cell(2,2,y,bg,"₹ "+fmt(i.rate),"#1c2533",false,"r");cell(3,3,y,bg,"₹ "+fmt(i.amt),"#1c2533",false,"r");y+=rowH});
    cell(0,0,y,BLUE,"TOTAL",INK,true,"c");cell(1,1,y,BLUE,fmt(b.items.reduce((a,i)=>a+n(i.qty),0)),INK,true,"c");cell(2,3,y,BLUE,"₹ "+fmt(b.items.reduce((a,i)=>a+n(i.amt),0)),INK,true,"r");y+=rowH;
    if(b.pays.length){
      cell(0,3,y,NAVY,"PAYMENTS ON THIS BILL","#fff",true,"c");y+=rowH;
      ["DATE","MODE","","AMOUNT"].forEach((t,i)=>{if(i===2)return;cell(i,i===1?2:i,y,BLUE,t,INK,true,"c")});y+=rowH;
      b.pays.forEach(p=>{cell(0,0,y,"#fff",p.date,"#1c2533",false,"c");cell(1,2,y,"#fff",p.mode,"#1c2533",true,"c");cell(3,3,y,"#fff","₹ "+fmt(p.amount),GREEN,true,"r");y+=rowH})}
    sumR.forEach(([a,v,c])=>{cell(0,1,y,BLUE,a,INK,true,"c");cell(2,3,y,PALE,v,c,true,"r");y+=rowH});
    if(b.due!=null){const d=r2(b.due),col=d>0.5?RED:GREEN;
      cell(0,1,y,BLUE,"DUE NOW",INK,true,"c");cell(2,3,y,"#fff",d>0.5?"₹ "+fmt(d):"₹ 0 · PAID",col,true,"c");
      x.strokeStyle=col;x.lineWidth=2;x.strokeRect(X[2]+1,y+1,X[4]-X[2]-2,rowH-2)}
    return cv;
  }
  const showBill=b=>popup({title:"Bill "+b.inv+" · "+b.party,canvases:[billDraw(b)],name:safe("Bill "+b.inv+" "+b.party),text:()=>billText(b)});
  window.LWBLedgerShare={MAX,pages,text,copyText,draw,show,billText,billDraw,showBill};
})();
