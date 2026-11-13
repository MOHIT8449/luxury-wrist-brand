/* LUXURY WRIST BRAND ERP — "Profit" ON/OFF in the top bar (Mohit, 7 Nov 2026).
   Admin always may see the profit of a SKU line (sale rate − landing, e.g. 465 − 440 = ₹25 per case);
   anyone else only when Admin allows that person (Manage Users > "Profit" button, or Rate List >
   Who can see Landing & Profit). The landing comes from lwb_profit_landing() (lwb_profit_view_setup.sql);
   a person who is not allowed gets nothing from the database, so nothing can show for them.
   Loaded by erp-shell.js. Pages use:
     LWBProfit.on()                 true when allowed and the switch is ON
     LWBProfit.landing(sku)         landing per case / box, or null
     LWBProfit.tag(sku, rate, qty)  small coloured tag HTML ("" when off / no landing)
     LWBProfit.loss(sku, rate)      true when rate ≤ landing (the page turns the whole line red)
     LWBProfit.total(lines)         {profit, known} for [{sku, rate, qty}]
     LWBProfit.parts(sku)           what makes up the landing (GR, MEPD, OMS / free bottle, QPS, ROI), or null
     LWBProfit.breakdown(title, lines)  popup with that for every SKU of a PO (Mohit, 13 Nov 2026)
     document "lwb:profit" event    fired when loaded and on every ON/OFF tap */
(function(){
  if(window.LWBProfit)return;
  const KEY="lwbProfitOn";
  let allowed=false,admin=false,land=new Map(),partMap=new Map(),viewers=new Set(),btn=null,client=null,readyOk;
  const ready=new Promise(ok=>{readyOk=ok});
  const k=s=>String(s==null?"":s).trim().toUpperCase();
  const num=v=>{const n=Number(v);return Number.isFinite(n)?n:0};
  const rs=v=>(v<0?"−":"")+"₹"+Math.abs(Math.round(v*100)/100).toLocaleString("en-IN",{maximumFractionDigits:2});
  function switchOn(){try{return localStorage.getItem(KEY)!=="0"}catch(e){return true}}
  function on(){return allowed&&switchOn()}
  function landing(sku){const v=land.get(k(sku));return v==null?null:v}
  function tag(sku,rate,qty){
    if(!on())return "";
    const l=landing(sku);if(l==null||rate===""||rate==null||!Number.isFinite(Number(rate)))return "";
    const per=num(rate)-l,q=num(qty),cls=per>0?"":" neg";
    return '<span class="lwb-pf'+cls+'" title="Landing '+rs(l)+' · Profit '+rs(per)+' per case'+(q?' · '+rs(per*q)+' for '+q:'')+'">'+
      (per>0?"+":"")+rs(per)+(q?'<small> · '+rs(per*q)+'</small>':'')+'</span>';
  }
  // true when the switch is ON and the rate is at or below landing (no profit).
  function loss(sku,rate){
    if(!on())return false;
    const l=landing(sku);if(l==null||rate===""||rate==null||!Number.isFinite(Number(rate)))return false;
    return num(rate)-l<=0;
  }
  function total(lines){
    let profit=0,known=0,missing=0;
    for(const x of lines||[]){const l=landing(x.sku),q=num(x.qty);if(!q||!k(x.sku))continue;if(l==null){missing++;continue}profit+=(num(x.rate)-l)*q;known++}
    return {profit,known,missing,text:rs(profit)};
  }
  const r2=v=>Math.round(v*100)/100;
  const esc=v=>String(v==null?"":v).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
  const nf=v=>(Math.round(v*100)/100).toLocaleString("en-IN",{maximumFractionDigits:2});
  // Same formula as Rate & Scheme LANDING (excl. ROI is landing − ROI): per case.
  function parts(sku){
    const p=partMap.get(k(sku));if(!p)return null;
    const C=num(p.case_config),D=num(p.gr),F=num(p.free_bottle),H=num(p.qps),I=num(p.roi),pct=num(p.mepd_pct),E=D*pct/100;
    let G,gLabel,gTag;
    if(F>0&&C){const base=D-E-H-I-((D/C)-1)*F,O=r2((num(p.slab3_rate)-base)/(1+F/C));G=(((D/C)-1)*F)-((O/C)*F);gLabel="Free bottle";gTag=nf(F)+" free bottle"}
    else{G=num(p.oms);gLabel="Cash off";gTag=G?"cash off":""}
    return {pack:p.pack,category:p.category,gr:D,mepdPct:pct,mepd:E,mepdFrom:p.mepd_from,schemeTo:p.scheme_to,schemeNote:p.scheme_note,
      oms:G,omsLabel:gLabel,omsTag:gTag,qps:H,roi:I,landing:D-E-G-H-I};
  }
  // One short line under the SKU in the PO list: what made the landing (no popup, Mohit 13 Nov 2026).
  function line(sku){
    if(!on()||!k(sku))return "";
    const l=landing(sku),pt=parts(sku);
    if(!pt)return l==null?"":'<span class="lwb-pf-line">Landing <b>'+nf(l)+'</b> (Rate List)</span>';
    const it=[["GR",nf(pt.gr)],["MEPD",nf(pt.mepd)+' <i title="'+(pt.mepdFrom==="scheme"?'MEPD scheme'+(pt.schemeTo?' till '+esc(String(pt.schemeTo).split("-").reverse().join("/")):''):pt.mepdFrom==="pack"?'Pack %':'Default %')+'">('+nf(pt.mepdPct)+'%)</i>']];
    if(pt.oms)it.push([pt.omsTag?esc(pt.omsTag.replace(/^cash off$/,"Cash off")):esc(pt.omsLabel),nf(pt.oms)]);
    if(pt.qps)it.push(["QPS",nf(pt.qps)]);
    if(pt.roi)it.push(["ROI",nf(pt.roi)]);
    const lv=l==null?pt.landing:l,warn=l!=null&&Math.abs(pt.landing-l)>0.5?' <b class="pfw" title="Rate &amp; Scheme today gives ₹'+nf(pt.landing)+'. Save Rate &amp; Scheme to update the landing.">!</b>':"";
    return '<span class="lwb-pf-line">'+it.map(([a,b])=>a+' <b>'+b+'</b>').join(' · ')+' · Landing <b>'+nf(lv)+'</b>'+warn+'</span>';
  }
  // Popup: per SKU, what was taken off the GR to reach the landing, then sale − landing = profit.
  function breakdown(title,lines){
    if(!on())return;
    let dlg=document.getElementById("lwbPfDlg");
    if(!dlg){dlg=document.createElement("dialog");dlg.id="lwbPfDlg";dlg.className="lwb-pf-dlg";document.body.appendChild(dlg);
      dlg.addEventListener("click",e=>{if(e.target===dlg||e.target.closest("[data-pf-close]"))dlg.close()})}
    const T={qty:0,gr:0,mepd:0,oms:0,qps:0,roi:0,land:0,sale:0,profit:0},schemes=new Map();let gap=0,noLand=0,noParts=0;
    const rows=(lines||[]).filter(x=>k(x.sku)&&num(x.qty)>0).map(x=>{
      const q=num(x.qty),rate=num(x.rate),l=landing(x.sku),pt=parts(x.sku),per=l==null?null:rate-l;
      T.qty+=q;T.sale+=q*rate;
      if(l==null)noLand++;else{T.land+=q*l;T.profit+=q*per}
      if(pt){T.gr+=q*pt.gr;T.mepd+=q*pt.mepd;T.oms+=q*pt.oms;T.qps+=q*pt.qps;T.roi+=q*pt.roi;
        if(l!=null&&Math.abs(pt.landing-l)>0.5)gap++;
        if(pt.category)schemes.set(pt.category,pt)}else noParts++;
      const cls=per==null?"":per>0?"":" neg",d=v=>pt?nf(v):"—";
      const warn=pt&&l!=null&&Math.abs(pt.landing-l)>0.5?' <b class="pfw" title="Rate &amp; Scheme today gives ₹'+nf(pt.landing)+'. Save Rate &amp; Scheme to update the landing.">!</b>':"";
      const cells=[
        ["GR",pt?nf(pt.gr):"—"],["MEPD",pt?d(pt.mepd)+' <small>'+nf(pt.mepdPct)+'%</small>':"—"],
        [pt?esc(pt.omsLabel):"OMS",d(pt?pt.oms:0)+(pt&&pt.omsTag?' <small class="pf-gt">'+esc(pt.omsTag)+'</small>':'')],["QPS",d(pt?pt.qps:0)],["ROI",d(pt?pt.roi:0)],
        ["Landing",l==null?"—":nf(l)+warn],["Sale",nf(rate)],["Profit/CS",per==null?"—":(per>0?"+":"")+nf(per)],["Profit",per==null?"—":rs(per*q)]];
      return '<tr class="'+(per!=null&&per<=0?"pfl":"")+'"><td class="sku">'+esc(x.sku)+(pt?'<small>'+esc(pt.pack)+'</small>':l!=null?'<small>Rate List landing</small>':'<small>No landing</small>')+'</td><td class="n q" data-l="Qty">'+nf(q)+'</td>'+
        cells.map(([h,v],i)=>'<td class="n'+(i>=7?' pf'+cls:'')+(i===5?' land':'')+'" data-l="'+h.replace(/<[^>]+>/g,"")+'">'+v+'</td>').join("")+'</tr>';
    }).join("");
    const pctOf=T.sale?r2(T.profit/T.sale*100):0;
    const sch=[...schemes.values()].map(p=>'<span>'+esc(p.category)+': MEPD '+nf(p.mepdPct)+'% '+(p.mepdFrom==="scheme"?'scheme'+(p.schemeTo?' till '+esc(String(p.schemeTo).split("-").reverse().join("/")):'')+(p.schemeNote?' · '+esc(p.schemeNote):''):p.mepdFrom==="pack"?'(pack %)':'(default %)')+'</span>').join("");
    dlg.innerHTML='<div class="pf-card"><div class="pf-head"><b>Profit breakdown'+(title?' · '+esc(title):'')+'</b><button type="button" data-pf-close aria-label="Close">✕</button></div>'+
      '<div class="pf-sum"><span>Sale <b>'+rs(T.sale)+'</b></span><span>Landing <b>'+rs(T.land)+'</b></span><span class="'+(T.profit>0?"":"neg")+'">Profit <b>'+rs(T.profit)+'</b> ('+nf(pctOf)+'%)</span></div>'+
      '<p class="pf-how">Landing = GR − MEPD − OMS / free bottle − QPS − ROI (per case, from Rate &amp; Scheme). Profit = Sale − Landing.</p>'+
      (sch?'<div class="pf-sch">'+sch+'</div>':'')+
      '<div class="pf-wrap"><table><thead><tr><th>SKU</th><th class="n">Qty</th><th class="n">GR</th><th class="n">MEPD</th><th class="n">OMS / Free</th><th class="n">QPS</th><th class="n">ROI</th><th class="n">Landing</th><th class="n">Sale</th><th class="n">Profit/CS</th><th class="n">Profit</th></tr></thead><tbody>'+rows+'</tbody>'+
      '<tfoot><tr><td>Total</td><td class="n" data-l="Qty">'+nf(T.qty)+'</td><td class="n" data-l="GR">'+rs(T.gr)+'</td><td class="n" data-l="MEPD">'+rs(T.mepd)+'</td><td class="n" data-l="OMS / Free">'+rs(T.oms)+'</td><td class="n" data-l="QPS">'+rs(T.qps)+'</td><td class="n" data-l="ROI">'+rs(T.roi)+'</td><td class="n" data-l="Landing">'+rs(T.land)+'</td><td class="n" data-l="Sale">'+rs(T.sale)+'</td><td class="n" data-l="Profit %">'+nf(pctOf)+'%</td><td class="n pf'+(T.profit>0?"":" neg")+'" data-l="Profit">'+rs(T.profit)+'</td></tr></tfoot></table></div>'+
      ((gap||noLand||noParts)?'<p class="pf-note">'+[gap?gap+' SKU: "!" = landing in Rate List is old, save Rate &amp; Scheme once.':'',noLand?noLand+' SKU has no landing, so no profit is counted for it.':'',noParts?noParts+' SKU is not linked to a Rate &amp; Scheme pack (flat landing, no breakdown).':''].filter(Boolean).join(' ')+'</p>':'')+
      '<div class="pf-foot"><button type="button" data-pf-close>Close</button></div></div>';
    dlg.open?null:dlg.showModal();
  }
  function fire(){document.body.classList.toggle("lwb-profit-on",on());document.dispatchEvent(new CustomEvent("lwb:profit",{detail:{on:on()}}))}
  function paint(){
    if(!btn)return;
    const v=switchOn();
    // Just an ON / OFF switch, no "Profit" word (Mohit, 7 Nov 2026); the tooltip says what it does.
    btn.setAttribute("aria-checked",String(v));
    btn.title=v?"Profit ON: shown on PO screens. Tap to hide.":"Profit OFF: hidden. Tap to show.";
    btn.innerHTML='<b>'+(v?"ON":"OFF")+'</b><i aria-hidden="true"></i>';
  }
  function css(){
    if(document.getElementById("lwb-pf-css"))return;
    const s=document.createElement("style");s.id="lwb-pf-css";
    s.textContent=
      ".lwb-pf-btn{position:relative;display:inline-flex;align-items:center;width:58px;height:26px;padding:0;margin:0;border-radius:13px;border:1px solid rgba(201,178,106,.55);background:rgba(255,255,255,.1);cursor:pointer;flex:none;box-shadow:none;transition:background .15s}"+
      ".lwb-pf-btn b{position:absolute;right:8px;font:700 10px 'Segoe UI',Roboto,Arial,sans-serif;letter-spacing:.3px;color:#b9c6c8}"+
      ".lwb-pf-btn i{position:absolute;left:3px;width:20px;height:20px;border-radius:50%;background:#e8efee;box-shadow:0 1px 2px rgba(0,0,0,.3);transition:left .15s}"+
      ".lwb-pf-btn[aria-checked=true]{background:#c9b26a;border-color:#e4d08f}"+
      ".lwb-pf-btn[aria-checked=true] b{right:auto;left:8px;color:#002f37}.lwb-pf-btn[aria-checked=true] i{left:33px}"+
      ".lwb-pf-btn:focus-visible{outline:2px solid #e4d08f;outline-offset:2px}"+
      ".lwb-pf{display:inline-block;margin-top:3px;padding:1px 7px;border-radius:10px;background:#f3e8ff;color:#6b21a8;border:1px solid #d8b4fe;font:700 11.5px 'Segoe UI',Roboto,Arial,sans-serif;white-space:nowrap;line-height:1.5}"+
      ".lwb-pf small{font-weight:600;font-size:10.5px;opacity:.85}"+
      ".lwb-pf.neg{background:#fde4e4;color:#b3261e;border-color:#f3a5a5}"+
      ".lwb-pf-sum{color:#6b21a8!important}.lwb-pf-sum.neg{color:#b3261e!important}"+
      "body:not(.lwb-profit-on) .lwb-pf-only,.lwb-pf-only[hidden]{display:none!important}"+
      ".pf-slot{display:inline-block;vertical-align:middle;margin-left:6px;line-height:1}.pf-slot:empty{display:none}.pf-slot .lwb-pf{margin-top:0}"+
      /* Rate at or below landing: the whole SKU line turns red (Mohit, 7 Nov 2026). */
      "tr.pf-loss,tr.pf-loss>td{background:#fde4e4!important}tr.pf-loss>td:first-child{box-shadow:inset 4px 0 0 #c8102e}"+
      "tr.pf-loss input{border-color:#e89a9a!important;background:#fff7f7!important}tr.pf-loss input.rate,tr.pf-loss input[data-field=rate]{border-color:#c8102e!important;color:#c8102e;font-weight:700}"+
      ".pf-slot .lwb-pf,.lwb-pf-open{cursor:pointer}"+
      ".lwb-pf-line{display:block;margin-top:2px;color:#6b21a8;font:400 11px/1.35 'Segoe UI',Roboto,Arial,sans-serif;white-space:normal}.lwb-pf-line b{font-weight:700}.lwb-pf-line i{font-style:normal;color:#8a94a0}.lwb-pf-line:empty{display:none}"+
      ".lwb-pf-line .pfw{display:inline-grid;place-items:center;width:14px;height:14px;border-radius:50%;background:#fde68a;color:#7a4b00;font-size:10px;cursor:help}"+
      /* Profit breakdown popup */
      ".lwb-pf-dlg{position:fixed;inset:0;margin:auto;height:fit-content;border:0;padding:0;border-radius:12px;width:min(1180px,calc(100vw - 24px));max-height:calc(100vh - 24px);box-shadow:0 20px 50px rgba(0,0,0,.35);font:13px 'Segoe UI',Roboto,Arial,sans-serif;color:#1f2a37}"+
      ".lwb-pf-dlg::backdrop{background:rgba(15,23,42,.45)}"+
      ".lwb-pf-dlg .pf-card{display:flex;flex-direction:column;max-height:calc(100vh - 24px)}"+
      ".lwb-pf-dlg .pf-head{display:flex;align-items:center;justify-content:space-between;gap:8px;padding:10px 14px;border-bottom:2px solid #c9b26a}"+
      ".lwb-pf-dlg .pf-head b{font-size:16px}.lwb-pf-dlg button{border:1px solid #d6dbe1;background:#fff;border-radius:8px;padding:7px 14px;font-weight:600;font-size:13px;font-family:inherit;cursor:pointer;color:#1f2a37;width:auto;margin:0;box-shadow:none}"+
      ".lwb-pf-dlg .pf-head button{padding:4px 10px}"+
      ".lwb-pf-dlg .pf-sum{display:flex;flex-wrap:wrap;gap:6px 16px;padding:8px 14px 0;font-size:13px}.lwb-pf-dlg .pf-sum b{font-size:15px}"+
      ".lwb-pf-dlg .pf-sum span:last-child b{color:#6b21a8}.lwb-pf-dlg .pf-sum .neg b{color:#b3261e}"+
      ".lwb-pf-dlg .pf-how{margin:4px 14px 0;color:#6b7785;font-size:11.5px}"+
      ".lwb-pf-dlg .pf-sch{display:flex;flex-wrap:wrap;gap:4px 6px;padding:6px 14px 0}.lwb-pf-dlg .pf-sch span{background:#f7f1de;color:#7a6420;border:1px solid #e4d08f;border-radius:10px;padding:1px 8px;font-size:11.5px;font-weight:600}"+
      ".lwb-pf-dlg .pf-wrap{overflow:auto;padding:8px 14px;min-height:0}"+
      ".lwb-pf-dlg table{width:100%;min-width:0!important;border-collapse:collapse;margin:0}"+
      ".lwb-pf-dlg tr{background:none}.lwb-pf-dlg th{background:#f3f5f7;color:#5b6672;font-size:11px;text-transform:uppercase;letter-spacing:.3px;padding:7px 6px;text-align:left;white-space:nowrap}"+
      ".lwb-pf-dlg td{padding:7px 6px;border-bottom:1px solid #edf0f3;white-space:nowrap}.lwb-pf-dlg .n{text-align:right}"+
      ".lwb-pf-dlg td.sku{white-space:normal;font-weight:600}.lwb-pf-dlg td.sku small{display:block;font-weight:400;color:#8a94a0;font-size:11px}"+
      ".lwb-pf-dlg td small{color:#8a94a0;font-size:11px}.lwb-pf-dlg td small.pf-gt{color:#0e7490;font-weight:600;white-space:nowrap}.lwb-pf-dlg td.land{font-weight:700}"+
      ".lwb-pf-dlg td.pf{color:#6b21a8;font-weight:700}.lwb-pf-dlg td.pf.neg{color:#b3261e}.lwb-pf-dlg tr.pfl td{background:#fde4e4}"+
      ".lwb-pf-dlg tfoot td{font-weight:700;background:#faf7ee;border-top:2px solid #e4d08f}"+
      ".lwb-pf-dlg .pfw{display:inline-grid;place-items:center;width:15px;height:15px;border-radius:50%;background:#fde68a;color:#7a4b00;font-size:10px;cursor:help}"+
      ".lwb-pf-dlg .pf-note{margin:0 14px;color:#9a6700;font-size:12px}"+
      ".lwb-pf-dlg .pf-foot{display:flex;justify-content:flex-end;gap:8px;padding:8px 14px 12px;border-top:1px solid #edf0f3}"+
      "@media(max-width:760px){.lwb-pf-dlg{width:calc(100vw - 16px)}.lwb-pf-dlg .pf-wrap{padding:6px 8px}"+
        ".lwb-pf-dlg thead{display:none}.lwb-pf-dlg table,.lwb-pf-dlg tbody,.lwb-pf-dlg tfoot{display:block;width:100%}.lwb-pf-dlg tr{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:4px 6px;border:1px solid #e3e7ec;border-radius:8px;padding:7px 8px;margin-bottom:6px}"+
        ".lwb-pf-dlg td{border:0;padding:0;white-space:normal;text-align:left!important;font-size:12.5px}"+
        ".lwb-pf-dlg td[data-l]::before{content:attr(data-l);display:block;font-size:10px;font-weight:600;color:#8a94a0;text-transform:uppercase}"+
        ".lwb-pf-dlg td.sku{grid-column:1/4}.lwb-pf-dlg td.q{grid-column:4;text-align:right!important}"+
        ".lwb-pf-dlg tr.pfl{background:#fde4e4;border-color:#f3a5a5}.lwb-pf-dlg tr.pfl td{background:none}"+
        ".lwb-pf-dlg tfoot td:first-child{grid-column:1/-1}.lwb-pf-dlg tfoot tr{background:#faf7ee}.lwb-pf-dlg tfoot td{background:none;border:0}}";
    (document.head||document.documentElement).appendChild(s);
  }
  async function load(){
    try{
      const {data,error}=await client.rpc("lwb_profit_landing");
      if(error||!data){allowed=false;land=new Map();viewers=new Set()}
      else{allowed=true;admin=data.admin===true;land=new Map(Object.entries(data.landing||{}).map(([s,v])=>[k(s),num(v)]));partMap=new Map(Object.entries(data.parts||{}).map(([s,v])=>[k(s),v]));viewers=new Set(data.viewers||[])}
    }catch(e){allowed=false}
  }
  async function init(opts){
    client=opts&&opts.client;
    if(!client){readyOk(false);return}
    css();
    await load();
    const mount=opts.mount;
    if(allowed&&mount&&!mount.querySelector(".lwb-pf-btn")){
      btn=document.createElement("button");btn.type="button";btn.className="lwb-pf-btn";btn.setAttribute("role","switch");btn.setAttribute("aria-label","Show profit");
      btn.onclick=()=>{const v=!switchOn();try{localStorage.setItem(KEY,v?"1":"0")}catch(e){}paint();fire()};
      paint();mount.prepend(btn);
    }
    readyOk(allowed);fire();
  }
  // Admin's Manage Users button: allow / stop one person.
  async function allow(user,yes){
    const {error}=await client.rpc("lwb_price_viewer_set",{p_user:user,p_on:!!yes});
    if(error)throw error;
    yes?viewers.add(user):viewers.delete(user);
    return !!yes;
  }
  window.LWBProfit={init,ready,on,landing,tag,loss,total,parts,line,breakdown,allow,money:rs,
    get allowed(){return allowed},get admin(){return admin},get viewers(){return viewers}};
})();
