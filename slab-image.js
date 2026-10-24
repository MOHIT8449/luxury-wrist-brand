/* LUXURY WRIST BRAND ERP — Slab rate list as a PNG image for WhatsApp.
   LWBSlabImage.draw({date, heads:[[tone,"SLAB 1"],...], rows:[{name, rates:[..]}]}) -> canvas
   LWBSlabImage.copy(canvas) puts it on the clipboard; download(canvas, file) saves it. */
(function(){
  const FONT='"Arial Narrow","Roboto Condensed",Arial,sans-serif';
  // Row colour by pack family, same idea as the market sheet
  function shade(name){
    const s=String(name).toUpperCase();
    if(/TONIC/.test(s))return"#c5d9f1";
    if(/MONSTER|PEDEATOR/.test(s)&&/CAN/.test(s))return"#ffe699";
    if(/ZERO|RIMZIM|PEADETOR|\bMZ\b|MMPO/.test(s))return"#f8cbad";
    if(/\bKS\b|\bKW\b/.test(s))return"#ffe699";
    return"#c6e0b4";
  }
  function draw(o){
    const W=[46,424,152,152,152].slice(0,2+o.heads.length),TW=W.reduce((a,b)=>a+b,0);
    const H1=46,H2=46,H3=48,RH=46,TH=H1+H2+H3+RH*o.rows.length,S=2;
    const cv=document.createElement("canvas");cv.width=(TW+1)*S;cv.height=(TH+1)*S;
    const g=cv.getContext("2d");g.scale(S,S);
    g.fillStyle="#fff";g.fillRect(0,0,TW,TH);
    const xs=[0];W.forEach(w=>xs.push(xs[xs.length-1]+w));
    const text=(t,x,y,w,h,size,color,weight)=>{g.fillStyle=color||"#000";g.font=(weight||"bold")+" "+size+"px "+FONT;g.textAlign="center";g.textBaseline="middle";
      let s=size;while(g.measureText(t).width>w-10&&s>12){s--;g.font=(weight||"bold")+" "+s+"px "+FONT}g.fillText(t,x+w/2,y+h/2+1)};
    const box=(x,y,w,h,fill)=>{if(fill){g.fillStyle=fill;g.fillRect(x,y,w,h)}g.strokeStyle="#000";g.lineWidth=1;g.strokeRect(x+.5,y+.5,w,h)};
    // date block over # and PACK, two header rows high
    box(0,0,xs[2],H1+H2);text(o.date,0,0,xs[2],H1+H2,40,"#000");
    o.heads.forEach((hd,i)=>{const x=xs[2+i],w=W[2+i];box(x,0,w,H1);text(hd[0],x,0,w,H1,22,"#000");box(x,H1,w,H2);text(hd[1],x,H1,w,H2,26,"#000","normal")});
    let y=H1+H2;box(0,y,W[0],H3,"#ffff00");box(xs[1],y,W[1],H3,"#ffff00");text("PACK",xs[1],y,W[1],H3,30,"#000");
    o.heads.forEach((_,i)=>{box(xs[2+i],y,W[2+i],H3,"#ffff00");text("MGR RATE",xs[2+i],y,W[2+i],H3,30,"#000")});
    y+=H3;
    o.rows.forEach((r,k)=>{box(0,y,W[0],RH);text(String(k+1),0,y,W[0],RH,26,"#000","normal");
      box(xs[1],y,W[1],RH,shade(r.name));text(r.name,xs[1],y,W[1],RH,27,"#000");
      r.rates.forEach((v,i)=>{box(xs[2+i],y,W[2+i],RH);text(v==null?"":String(v),xs[2+i],y,W[2+i],RH,28,i?"#1f1fd6":"#000",i?"bold":"normal")});
      y+=RH});
    return cv;
  }
  const blob=cv=>new Promise(ok=>cv.toBlob(ok,"image/png"));
  async function copy(cv){
    if(!navigator.clipboard||!window.ClipboardItem)throw Error("Is browser me image copy nahi hoti. Download dabao.");
    await navigator.clipboard.write([new ClipboardItem({"image/png":blob(cv)})]);
  }
  async function download(cv,file){
    const u=URL.createObjectURL(await blob(cv)),a=document.createElement("a");a.href=u;a.download=file+".png";document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(u),2000);
  }
  window.LWBSlabImage={draw,copy,download,shade};
})();
