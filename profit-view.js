/* LUXURY WRIST BRAND ERP — "Profit" ON/OFF in the top bar (Mohit, 7 Nov 2026).
   Admin always may see the profit of a SKU line (sale rate − landing, e.g. 465 − 440 = ₹25 per case);
   anyone else only when Admin allows that person (Manage Users > "Profit" button, or Rate List >
   Who can see Landing & Profit). The landing comes from lwb_profit_landing() (lwb_profit_view_setup.sql);
   a person who is not allowed gets nothing from the database, so nothing can show for them.
   Loaded by erp-shell.js. Pages use:
     LWBProfit.on()                 true when allowed and the switch is ON
     LWBProfit.landing(sku)         landing per case / box, or null
     LWBProfit.tag(sku, rate, qty)  small coloured tag HTML ("" when off / no landing)
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
  function total(lines){
    let profit=0,known=0,missing=0;
    for(const x of lines||[]){const l=landing(x.sku),q=num(x.qty);if(!q||!k(x.sku))continue;if(l==null){missing++;continue}profit+=(num(x.rate)-l)*q;known++}
    return {profit,known,missing,text:rs(profit)};
  }
  function fire(){document.body.classList.toggle("lwb-profit-on",on());document.dispatchEvent(new CustomEvent("lwb:profit",{detail:{on:on()}}))}
  function paint(){
    if(!btn)return;
    const v=switchOn();
    btn.setAttribute("aria-pressed",String(v));
    btn.title=v?"Profit is shown on PO screens. Tap to hide.":"Profit is hidden. Tap to show.";
    btn.innerHTML='<i aria-hidden="true"></i><span>Profit</span><b>'+(v?"ON":"OFF")+'</b>';
  }
  function css(){
    if(document.getElementById("lwb-pf-css"))return;
    const s=document.createElement("style");s.id="lwb-pf-css";
    s.textContent=
      ".lwb-pf-btn{display:inline-flex;align-items:center;gap:5px;height:32px;padding:0 10px;margin:0;border-radius:16px;border:1px solid rgba(201,178,106,.55);background:rgba(255,255,255,.08);color:#e8efee;font:600 12px 'Segoe UI',Roboto,Arial,sans-serif;cursor:pointer;white-space:nowrap;flex:none;box-shadow:none;width:auto}"+
      ".lwb-pf-btn i{width:8px;height:8px;border-radius:50%;background:#8a9aa0}"+
      ".lwb-pf-btn b{font-size:10.5px;letter-spacing:.4px;padding:1px 5px;border-radius:8px;background:rgba(255,255,255,.12)}"+
      ".lwb-pf-btn[aria-pressed=true]{border-color:#c4a5f5;background:rgba(124,58,237,.28)}"+
      ".lwb-pf-btn[aria-pressed=true] i{background:#c4f5a5}.lwb-pf-btn[aria-pressed=true] b{background:#7c3aed;color:#fff}"+
      "@media(max-width:560px){.lwb-pf-btn{height:28px;padding:0 7px;gap:4px}.lwb-pf-btn span{display:none}.lwb-pf-btn::before{content:'₹';font-weight:700}}"+
      ".lwb-pf{display:inline-block;margin-top:3px;padding:1px 7px;border-radius:10px;background:#f3e8ff;color:#6b21a8;border:1px solid #d8b4fe;font:700 11.5px 'Segoe UI',Roboto,Arial,sans-serif;white-space:nowrap;line-height:1.5}"+
      ".lwb-pf small{font-weight:600;font-size:10.5px;opacity:.85}"+
      ".lwb-pf.neg{background:#fde4e4;color:#b3261e;border-color:#f3a5a5}"+
      ".lwb-pf-sum{color:#6b21a8!important}.lwb-pf-sum.neg{color:#b3261e!important}"+
      "body:not(.lwb-profit-on) .lwb-pf-only,.lwb-pf-only[hidden]{display:none!important}"+
      ".pf-slot{display:block;line-height:1}.pf-slot:empty{display:none}";
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
      btn=document.createElement("button");btn.type="button";btn.className="lwb-pf-btn";
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
  window.LWBProfit={init,ready,on,landing,tag,total,allow,money:rs,
    get allowed(){return allowed},get admin(){return admin},get viewers(){return viewers}};
})();
