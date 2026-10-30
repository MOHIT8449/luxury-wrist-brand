/* LUXURY WRIST BRAND ERP — company / brand filter (Rajnigandha, Coca-Cola ...).
   LWBBrand.load(client)     -> {companies:[{id,name,color,...}], mine:[ids]|null}  (lwb_companies, lwb_company_brand_setup.sql)
   LWBBrand.get() / set(id)  -> chosen company id ("" = all), kept per device
   LWBBrand.chips(list, id, onPick) -> element with "All brands" + one chip per company
   LWBBrand.skuMap(client)   -> Map(SKU key -> company id), to split order lines by brand
   LWBBrand.unitOf(sku, companies) -> "BOX" | "CASE" (SKU's own unit, else its company's, else CASE)
   LWBBrand.qty(cases, boxes)  -> "83 boxes · 20 cases" (Rajnigandha sells in boxes, Coca-Cola in cases)
   A brand-limited Sales Head / Salesman only gets his companies back from the database. */
(function(){
  if(window.LWBBrand)return;
  const KEY="lwbBrand";
  const skuKey=v=>String(v==null?"":v).toUpperCase().replace(/\s+/g," ").trim();
  const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  let cache=null,skuCache=null,units=new Map();
  function read(){try{return localStorage.getItem(KEY)||""}catch(e){return ""}}
  function write(v){try{v?localStorage.setItem(KEY,v):localStorage.removeItem(KEY)}catch(e){}}
  async function load(client,fresh){
    if(cache&&!fresh)return cache;
    cache=(async()=>{
      const [c,m]=await Promise.all([client.from("lwb_companies").select("*").order("sort_no").order("name"),client.rpc("lwb_my_companies")]);
      if(c.error)return {companies:[],mine:null,missing:true};
      return {companies:(c.data||[]).filter(x=>x.active!==false),all:c.data||[],mine:m.error?null:(m.data||null)};
    })().catch(()=>({companies:[],mine:null,missing:true}));
    return cache;
  }
  async function skuMap(client){
    if(skuCache)return skuCache;
    skuCache=(async()=>{
      const out=new Map();units=new Map();
      for(let p=0;p<10;p++){
        let r=await client.from("sku_master").select("sku_name,company_id,pack_unit").range(p*1000,p*1000+999);
        if(r.error)r=await client.from("sku_master").select("sku_name,company_id").range(p*1000,p*1000+999);
        if(r.error)return null;
        for(const s of r.data||[]){out.set(skuKey(s.sku_name),s.company_id||"");if(s.pack_unit)units.set(skuKey(s.sku_name),s.pack_unit)}
        if((r.data||[]).length<1000)break;
      }
      return out;
    })().catch(()=>null);
    return skuCache;
  }
  // A saved choice that is no longer one of my companies counts as "all".
  function get(list){const v=read();return list&&!list.some(c=>c.id===v)?"":v}
  function set(v){write(v||"")}
  function chips(list,current,onPick){
    const box=document.createElement("div");box.className="lwb-brands";box.setAttribute("role","group");box.setAttribute("aria-label","Company / brand");
    const opts=[{id:"",name:"All brands",color:"#14253f"}].concat(list||[]);
    box.innerHTML=opts.map(c=>'<button type="button" data-b="'+esc(c.id)+'" aria-pressed="'+(c.id===current)+'" style="--bc:'+esc(c.color||"#2362a4")+'">'+(c.id?'<i></i>':"")+esc(c.name)+"</button>").join("");
    box.onclick=e=>{const b=e.target.closest("button[data-b]");if(!b)return;const v=b.dataset.b;set(v);
      box.querySelectorAll("button").forEach(x=>x.setAttribute("aria-pressed",String(x===b)));onPick&&onPick(v)};
    return box;
  }
  const css=document.createElement("style");
  css.textContent='.lwb-brands{display:flex;gap:6px;flex-wrap:wrap;align-items:center;margin:0 0 12px}'+
    '.lwb-brands button{height:32px;border-radius:99px;border:1.5px solid #d6dde6;background:#fff;color:#22303f;padding:0 12px;font:inherit;font-size:13px;font-weight:600;cursor:pointer;display:inline-flex;align-items:center;gap:6px;white-space:nowrap}'+
    '.lwb-brands button i{width:9px;height:9px;border-radius:50%;background:var(--bc)}'+
    '.lwb-brands button[aria-pressed=true]{border-color:var(--bc);background:color-mix(in srgb,var(--bc) 10%,#fff);color:var(--bc)}';
  (document.head||document.documentElement).appendChild(css);
  function unitOf(sku,list){
    if(sku&&sku.pack_unit)return sku.pack_unit;
    const c=sku&&(list||[]).find(x=>x.id===sku.company_id);return c&&c.pack_unit?c.pack_unit:"CASE";
  }
  const word=(u,n)=>u==="BOX"?(Number(n)===1?"box":"boxes"):(Number(n)===1?"case":"cases");
  const fmt=n=>Math.round(Number(n)||0).toLocaleString("en-IN");
  function qty(cases,boxes){
    const out=[];if(Number(boxes))out.push(fmt(boxes)+" "+word("BOX",boxes));if(Number(cases)||!out.length)out.push(fmt(cases)+" "+word("CASE",cases));
    return out.join(" · ");
  }
  // Unit of an SKU by name, after skuMap() and load(): its own unit, else its company's.
  function unitByName(name,map,list){
    const k=skuKey(name),own=units.get(k);if(own)return own;
    const c=(list||[]).find(x=>x.id===(map&&map.get(k)));return c&&c.pack_unit?c.pack_unit:"CASE";
  }
  window.LWBBrand={load,get,set,chips,skuMap,skuKey,unitOf,unitByName,word,qty};
})();
