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
     document "lwb:profit" event    fired when loaded and on every ON/OFF tap */
(function(){
  if(window.LWBProfit)return;
  const KEY="lwbProfitOn";
  let allowed=false,admin=false,land=new Map(),viewers=new Set(),btn=null,client=null,readyOk;
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
      ".lwb-pf-btn[aria-checked=true]{background:#7c3aed;border-color:#c4a5f5}"+
      ".lwb-pf-btn[aria-checked=true] b{right:auto;left:8px;color:#fff}.lwb-pf-btn[aria-checked=true] i{left:33px}"+
      ".lwb-pf-btn:focus-visible{outline:2px solid #e4d08f;outline-offset:2px}"+
      ".lwb-pf{display:inline-block;margin-top:3px;padding:1px 7px;border-radius:10px;background:#f3e8ff;color:#6b21a8;border:1px solid #d8b4fe;font:700 11.5px 'Segoe UI',Roboto,Arial,sans-serif;white-space:nowrap;line-height:1.5}"+
      ".lwb-pf small{font-weight:600;font-size:10.5px;opacity:.85}"+
      ".lwb-pf.neg{background:#fde4e4;color:#b3261e;border-color:#f3a5a5}"+
      ".lwb-pf-sum{color:#6b21a8!important}.lwb-pf-sum.neg{color:#b3261e!important}"+
      "body:not(.lwb-profit-on) .lwb-pf-only,.lwb-pf-only[hidden]{display:none!important}"+
      ".pf-slot{display:inline-block;vertical-align:middle;margin-left:6px;line-height:1}.pf-slot:empty{display:none}.pf-slot .lwb-pf{margin-top:0}"+
      /* Rate at or below landing: the whole SKU line turns red (Mohit, 7 Nov 2026). */
      "tr.pf-loss,tr.pf-loss>td{background:#fde4e4!important}tr.pf-loss>td:first-child{box-shadow:inset 4px 0 0 #c8102e}"+
      "tr.pf-loss input{border-color:#e89a9a!important;background:#fff7f7!important}tr.pf-loss input.rate,tr.pf-loss input[data-field=rate]{border-color:#c8102e!important;color:#c8102e;font-weight:700}";
    (document.head||document.documentElement).appendChild(s);
  }
  async function load(){
    try{
      const {data,error}=await client.rpc("lwb_profit_landing");
      if(error||!data){allowed=false;land=new Map();viewers=new Set()}
      else{allowed=true;admin=data.admin===true;land=new Map(Object.entries(data.landing||{}).map(([s,v])=>[k(s),num(v)]));viewers=new Set(data.viewers||[])}
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
  window.LWBProfit={init,ready,on,landing,tag,loss,total,allow,money:rs,
    get allowed(){return allowed},get admin(){return admin},get viewers(){return viewers}};
})();
