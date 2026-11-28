/* Cash handover slip, A5 print (Mohit, 28 Nov 2026) — lwb_acc_handover_slip_setup.sql
   LWBSlip.html(S)  -> full A5 HTML page of one handover (S = lwb_acc_shift_slip result)
   LWBSlip.print(S) -> prints it from a hidden frame (browser print dialog, A5 portrait)
   LWBSlip.pad(el)  -> a small signature pad: {empty(), png(), clear()} */
(function(){
  "use strict";
  const NOTES=["500","200","100","50","20","10"];
  const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const r2=n=>Math.round((Number(n)||0)*100)/100;
  const rs=v=>(r2(v)<0?"−":"")+"₹"+Math.abs(r2(v)).toLocaleString("en-IN",{maximumFractionDigits:2});
  const dmy=d=>d?String(d).slice(8,10)+"/"+String(d).slice(5,7)+"/"+String(d).slice(0,4):"";
  const hm=t=>t?new Date(t).toLocaleTimeString("en-IN",{hour:"2-digit",minute:"2-digit",hour12:true,timeZone:"Asia/Kolkata"}):"";
  const day=t=>t?new Date(new Date(t).getTime()+330*60e3).toISOString().slice(0,10):"";
  const ROLE={admin:"Admin",accounts:"Accounts",cashier:"Cashier",sales:"Sales",salesman:"Sales",sales_head:"Sales Head",manager:"Sales Head"};
  const role=r=>ROLE[String(r||"").toLowerCase().trim()]||"";
  const cnt=(N,k)=>{const v=N&&N[k];return v==null||v===""?0:Number(v)||0};

  function html(S){
    const N=S.notes||{},L=S.last&&S.last.notes||null,P=S.parts||[];
    const rows=NOTES.map(k=>{const n=Math.floor(cnt(N,k)),l=L?Math.floor(cnt(L,k)):null,d=l==null?null:n-l;
      return '<tr><td><b>₹'+k+'</b></td><td class="n mut">'+(l==null?"—":l)+'</td><td class="n"><b>'+(n||"—")+'</b></td>'+
        '<td class="n">'+(d==null||!d?'<span class="mut">'+(d==null?"":"0")+'</span>':(d>0?"+":"−")+Math.abs(d))+'</td><td class="n"><b>'+(n?rs(n*Number(k)):"—")+'</b></td></tr>'}).join("");
    const coins=r2(cnt(N,"coins")),lc=L?r2(cnt(L,"coins")):null;
    const total=NOTES.reduce((a,k)=>a+Math.floor(cnt(N,k))*Number(k),0)+coins;
    const pcs=NOTES.reduce((a,k)=>a+Math.floor(cnt(N,k)),0);
    const ex=S.extra||[],D=S.diff,em=r2(ex.filter(x=>x.kind==="OFFICE").reduce((a,x)=>a+Number(x.amount),0)),oth=ex.filter(x=>x.kind!=="OFFICE");
    const sign=(img,name,sub,at)=>'<div class="sg"><div class="sgbox">'+(img?'<img src="'+esc(img)+'" alt="">':"")+'</div>'+
      '<div class="sgl"><b>'+esc(name)+'</b>'+(sub?' · '+esc(sub):"")+'</div><div class="sgt">'+(at?"Signed "+dmy(day(at))+" "+hm(at):"Sign here")+'</div></div>';
    return '<!doctype html><html><head><meta charset="utf-8"><title>Cash handover slip #'+esc(S.slip_no)+'</title><style>'+
      '@page{size:A5 portrait;margin:8mm}*{box-sizing:border-box}html,body{margin:0;background:#fff}'+
      'body{font:11px/1.35 Arial,Helvetica,sans-serif;color:#111;-webkit-print-color-adjust:exact;print-color-adjust:exact}'+
      '.pg{width:132mm;margin:0 auto}'+
      '.hd{display:flex;justify-content:space-between;align-items:flex-end;border-bottom:2px solid #002f37;padding-bottom:5px}'+
      '.hd h1{margin:0;font-size:15px;color:#002f37;letter-spacing:.2px}.hd h2{margin:1px 0 0;font-size:12px;font-weight:700}.hd .no{text-align:right;font-size:11px}.hd .no b{font-size:14px}'+
      '.meta{display:grid;grid-template-columns:1fr 1fr;gap:3px 10px;margin:7px 0;padding:6px 8px;border:1px solid #cfd6de;border-radius:5px}'+
      '.meta div{display:flex;gap:5px}.meta span{color:#555;min-width:58px}'+
      'table{width:100%;border-collapse:collapse;margin-top:4px}th,td{border:1px solid #cfd6de;padding:3px 6px}th{background:#eef2f5;font-size:10px;text-align:left}'+
      '.n{text-align:right}.mut{color:#777}tfoot td{font-weight:800;background:#f6f8fa}.big{font-size:14px}'+
      '.sum{display:grid;grid-template-columns:1fr 1fr 1fr;gap:6px;margin:7px 0}.sum div{border:1px solid #cfd6de;border-radius:5px;padding:4px 7px}.sum span{display:block;color:#555;font-size:10px}.sum b{font-size:13px}'+
      '.sum .ok{border-color:#13824a;background:#eaf7ef}.sum .bad{border-color:#c8102e;background:#fdecee}.sum .bad b{color:#c8102e}'+
      '.em{display:flex;justify-content:space-between;align-items:center;margin:5px 0;padding:5px 8px;border:1.5px solid #1d5fbf;border-radius:5px;background:#eaf1fc;font-size:12px}.em>b{font-size:14px;color:#1d5fbf}'+
      '.h3{margin:8px 0 2px;font-size:11px;font-weight:800;color:#002f37;text-transform:uppercase;letter-spacing:.3px}'+
      '.nt{margin:5px 0;padding:4px 7px;border-left:3px solid #e0a800;background:#fff8e1}'+
      '.sgs{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:8px}.sg{border:1px solid #9aa6b2;border-radius:5px;padding:5px 7px}'+
      '.sg .cap{font-size:10px;color:#555;font-weight:700;text-transform:uppercase}.sgbox{height:16mm;border-bottom:1px dashed #9aa6b2;display:flex;align-items:center;justify-content:center}'+
      '.sgs.many{grid-template-columns:repeat(3,1fr);gap:6px}.sgs.many .sgbox{height:12mm}.sgs.many .sgl{font-size:10px}'+
      '.sgbox img{max-height:15mm;max-width:100%}.sgl{margin-top:3px}.sgt{font-size:9.5px;color:#666}'+
      '.ft{margin-top:8px;display:flex;justify-content:space-between;font-size:9.5px;color:#666;border-top:1px solid #cfd6de;padding-top:4px}'+
      '.st{display:inline-block;padding:0 5px;border-radius:3px;font-size:10px;font-weight:700}.st.g{background:#e3f5ea;color:#0b6b3a}.st.a{background:#fff3cd;color:#8a5a00}'+
      '</style></head><body><div class="pg">'+
      '<div class="hd"><div><h1>LUXURY WRIST BRAND</h1><h2>Cash Handover Slip</h2></div><div class="no">Slip no. <b>#'+esc(S.slip_no)+'</b><br>'+dmy(S.day)+' · '+hm(S.at)+'</div></div>'+
      '<div class="meta"><div><span>Date</span><b>'+dmy(S.day)+'</b></div><div><span>Time</span><b>'+hm(S.at)+'</b></div>'+
      '<div><span>Given by</span><b>'+esc(S.by_name)+'</b>'+(role(S.by_role)?' <i class="mut">'+role(S.by_role)+'</i>':"")+'</div>'+
      '<div><span>Bag / seal</span><b>'+(S.bag_no?esc(S.bag_no):"________")+'</b></div>'+
      '<div style="grid-column:1/-1"><span>Given to</span><b>'+P.map(p=>esc(p.to_name)+(P.length>1?" ("+rs(p.amount)+")":"")).join(" + ")+'</b></div></div>'+
      '<div class="h3">Notes count</div>'+
      '<table><thead><tr><th>Note</th><th class="n">Last closing<br><span style="font-weight:400">'+(S.last?dmy(S.last.day).slice(0,5)+" "+hm(S.last.at):"—")+'</span></th><th class="n">Now (pcs)</th><th class="n">Change</th><th class="n">Amount</th></tr></thead><tbody>'+rows+
      '<tr><td><b>Coins</b></td><td class="n mut">'+(lc==null?"—":rs(lc))+'</td><td class="n">—</td><td></td><td class="n"><b>'+(coins?rs(coins):"—")+'</b></td></tr></tbody>'+
      '<tfoot><tr><td>Total</td><td class="n">'+(S.last?rs(S.last.counted):"—")+'</td><td class="n">'+pcs+' pcs</td><td></td><td class="n big">'+rs(total)+'</td></tr></tfoot></table>'+
      '<div class="sum"><div><span>Cash should be (book)</span><b>'+rs(S.book)+'</b></div><div><span>Handed in the bag'+(em?' + emergency':'')+'</span><b>'+rs(S.total!=null?S.total:total)+'</b>'+(em?'<span>+ '+rs(em)+' = '+rs(r2((S.total!=null?S.total:total)+em))+'</span>':'')+'</div>'+
      (D?'<div class="bad"><span>Difference</span><b>'+(D.kind==="SHORT"?"Short ":"Extra ")+rs(D.amount)+'</b></div>':'<div class="ok"><span>Difference</span><b>✓ None</b></div>')+'</div>'+
      (em?'<div class="em"><span>🛟 <b>Emergency fund kept at godown</b> (not in the bag)</span><b>'+rs(em)+'</b></div>':"")+
      (oth.length?'<div class="nt"><b>Given to someone (not in the bag):</b> '+oth.map(x=>esc(x.name)+" "+rs(x.amount)).join(" · ")+'</div>':"")+
      (S.note?'<div class="nt"><b>Note:</b> '+esc(S.note)+'</div>':"")+
      (P.length>1?'<div class="h3">Split</div><table><thead><tr><th>Taken by</th><th class="n">Amount</th><th>Received</th></tr></thead><tbody>'+P.map(p=>'<tr><td><b>'+esc(p.to_name)+'</b></td><td class="n"><b>'+rs(p.amount)+'</b></td><td>'+
        (p.status==="RECEIVED"?'<span class="st g">✓ '+rs(p.received)+'</span> '+hm(p.received_at):'<span class="st a">Waiting</span>')+'</td></tr>').join("")+'</tbody></table>':"")+
      '<div class="sgs'+(P.length>1?' many':'')+'">'+
        '<div><div class="cap" style="font-size:10px;font-weight:700;color:#555">GIVEN BY (CASHIER)</div>'+sign(S.give_sign,S.by_name,role(S.by_role),S.give_signed_at)+'</div>'+
        P.map(p=>'<div><div class="cap" style="font-size:10px;font-weight:700;color:#555">RECEIVED BY'+(P.length>1?" · "+rs(p.amount):"")+'</div>'+
          sign(p.recv_sign,p.to_name,p.status==="RECEIVED"?"got "+rs(p.received):"",p.recv_signed_at||(p.recv_sign?p.received_at:null))+'</div>').join("")+
      '</div>'+
      '<div class="ft"><span>Counted in front of both. Bag sealed and handed over.</span><span>Printed '+dmy(day(S.printed_at))+' '+hm(S.printed_at)+(S.printed_by?" · "+esc(S.printed_by):"")+'</span></div>'+
      '</div></body></html>';
  }

  function print(S){
    const f=document.createElement("iframe");
    f.setAttribute("aria-hidden","true");f.style.cssText="position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden";
    document.body.appendChild(f);
    const d=f.contentDocument;d.open();d.write(html(S));d.close();
    const go=()=>{try{f.contentWindow.focus();f.contentWindow.print()}catch(e){}setTimeout(()=>f.remove(),60000)};
    const imgs=[...d.images];if(!imgs.length)setTimeout(go,150);
    else Promise.all(imgs.map(i=>i.complete?1:new Promise(r=>{i.onload=i.onerror=r}))).then(()=>setTimeout(go,100));
  }

  // signature pad on a <canvas>; finger / mouse / pen
  function pad(cv){
    const ctx=cv.getContext("2d");let draw=false,has=false,last=null;
    function size(){const r=cv.getBoundingClientRect(),k=window.devicePixelRatio||1;if(!r.width)return;
      cv.width=Math.round(r.width*k);cv.height=Math.round(r.height*k);ctx.setTransform(k,0,0,k,0,0);
      ctx.lineWidth=2.2;ctx.lineCap="round";ctx.lineJoin="round";ctx.strokeStyle="#0a2a6b";has=false}
    const pt=e=>{const r=cv.getBoundingClientRect();return {x:e.clientX-r.left,y:e.clientY-r.top}};
    cv.style.touchAction="none";
    cv.addEventListener("pointerdown",e=>{if(!cv.width)size();draw=true;last=pt(e);try{cv.setPointerCapture(e.pointerId)}catch(_){}
      ctx.beginPath();ctx.arc(last.x,last.y,1.1,0,7);ctx.fillStyle=ctx.strokeStyle;ctx.fill();has=true;e.preventDefault()});
    cv.addEventListener("pointermove",e=>{if(!draw)return;const p=pt(e);ctx.beginPath();ctx.moveTo(last.x,last.y);ctx.lineTo(p.x,p.y);ctx.stroke();last=p;has=true;e.preventDefault()});
    const up=()=>{draw=false};cv.addEventListener("pointerup",up);cv.addEventListener("pointercancel",up);cv.addEventListener("pointerleave",up);
    requestAnimationFrame(size);
    return {empty:()=>!has,clear:()=>{ctx.clearRect(0,0,cv.width,cv.height);has=false},
      // small png: white background, max 480 px wide
      png:()=>{const w=Math.min(480,cv.width),h=Math.round(cv.height*w/cv.width),o=document.createElement("canvas");o.width=w;o.height=h;
        const c=o.getContext("2d");c.fillStyle="#fff";c.fillRect(0,0,w,h);c.drawImage(cv,0,0,w,h);return o.toDataURL("image/png")}};
  }

  window.LWBSlip={html,print,pad};
})();
