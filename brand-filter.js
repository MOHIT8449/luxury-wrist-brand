/* LUXURY WRIST BRAND ERP — company / brand filter (Rajnigandha, Coca-Cola ...).
   LWBBrand.load(client)     -> {companies:[{id,name,color,...}], mine:[ids]|null}  (lwb_companies, lwb_company_brand_setup.sql)
   LWBBrand.get() / set(id)  -> chosen company id ("" = all), kept per device
   LWBBrand.chips(list, id, onPick) -> element with "All brands" + one chip per company
   LWBBrand.skuMap(client)   -> Map(SKU key -> company id), to split order lines by brand
   LWBBrand.unitOf(sku, companies) -> "BOX" | "CASE" (SKU's own unit, else its company's, else CASE)
   LWBBrand.qty(cases, boxes)  -> "83 boxes · 20 cases" (Rajnigandha sells in boxes, Coca-Cola in cases)
   LWBBrand.short(unit)      -> "IC" | "CS"
   LWBBrand.pack(pcs, perUnit, unit) -> "12 IC + 5 pcs" / "3 CS" (stock in the unit the SKU is sold in)
   LWBBrand.packNum(pcs, perUnit) -> 12.5 (full units, decimal, for Excel / totals)
   LWBBrand.packSum(list)    -> "120 IC · 45 CS" from [{pcs, per, unit}] (totals never mix units)
   LWBBrand.units(client)    -> resolver(sku name | {sku_name, company_id, pack_unit}) -> "BOX" | "CASE"
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
    '.lwb-brandbar{margin:0 0 12px}.lwb-brandbar .lwb-brands{margin:0}'+
    '.lwb-brands button[aria-pressed=true]{border-color:var(--bc);background:color-mix(in srgb,var(--bc) 10%,#fff);color:var(--bc)}';
  (document.head||document.documentElement).appendChild(css);
  function unitOf(sku,list){
    if(sku&&sku.pack_unit)return sku.pack_unit;
    const c=sku&&(list||[]).find(x=>x.id===sku.company_id);return c&&c.pack_unit?c.pack_unit:"CASE";
  }
  const word=(u,n)=>u==="BOX"?"IC":(Number(n)===1?"case":"cases");
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
  // One brand bar for a page: All brands / each company chips, saved choice shared with every page.
  // LWBBrand.mount(client,{into, onChange}) -> {get(), companies, name(id), color(id)}; nothing shown with < 2 brands.
  async function mount(client,o){
    o=o||{};const info=await load(client),list=(info.companies||[]).filter(c=>!info.mine||info.mine.includes(c.id));
    const st={companies:list,value:"",get(){return st.value},name:id=>(list.find(c=>c.id===id)||{}).name||"",color:id=>(list.find(c=>c.id===id)||{}).color||"#8a94a3"};
    if(list.length<2)return st;
    st.value=get(list);
    const bar=document.createElement("div");bar.className="lwb-brandbar";
    bar.appendChild(chips(list,st.value,v=>{st.value=v;o.onChange&&o.onChange(v)}));
    const into=typeof o.into==="string"?document.querySelector(o.into):o.into||document.querySelector("main");
    if(into){if(o.after)into.after(bar);else into.prepend(bar)}
    return st;
  }
  // Brands of POs: Map(order id -> Set of company ids), from their SKU lines (chunks of 150 ids).
  async function orderBrands(client,ids){
    const out=new Map(),map=await skuMap(client);ids=[...new Set((ids||[]).filter(Boolean))];
    if(!map)return out;
    for(let i=0;i<ids.length;i+=150){
      const r=await client.from("order_items").select("order_id,sku_name").in("order_id",ids.slice(i,i+150));
      if(r.error)break;
      for(const x of r.data||[]){const c=map.get(skuKey(x.sku_name));if(!out.has(x.order_id))out.set(x.order_id,new Set());if(c)out.get(x.order_id).add(c)}
    }
    return out;
  }
  // Is a row of brand b? (b "" = all). set: Set / array of companies, or one company id.
  function has(set,b){if(!b)return true;if(!set)return false;if(typeof set==="string")return set===b;return set.has?set.has(b):set.includes(b)}
  // Quantities in the unit the SKU is sold in (Mohit 6 Nov 2026): Rajnigandha in IC, Coca-Cola in CS.
  // Stock is kept in PCS; only the display changes. Loose pieces show after a "+".
  const short=u=>u==="BOX"?"IC":"CS";
  function pack(pcs,per,unit,o){
    per=Math.max(1,Math.round(Number(per)||1));const n=Math.round(Number(pcs)||0),neg=n<0,a=Math.abs(n),c=Math.floor(a/per),l=a%per;
    const t=(c||!l?fmt(c)+" "+short(unit):"")+(c&&l?" + ":"")+(l?fmt(l)+" pcs":"");
    return (neg?"−":o&&o.plus&&n>0?"+":"")+t;
  }
  const packNum=(pcs,per)=>Math.round((Number(pcs)||0)/Math.max(1,Number(per)||1)*100)/100;
  function packSum(list){
    const by=new Map();
    for(const x of list||[]){const u=x.unit==="BOX"?"BOX":"CASE";by.set(u,(by.get(u)||0)+(Number(x.pcs)||0)/Math.max(1,Number(x.per)||1))}
    const out=["BOX","CASE"].filter(u=>by.has(u)&&Math.round(by.get(u)*10)).map(u=>{const v=Math.round(by.get(u)*10)/10;return v.toLocaleString("en-IN")+" "+short(u)});
    return out.join(" · ")||"0";
  }
  async function unitsFor(client){
    const [info,map]=await Promise.all([load(client),skuMap(client)]);
    const list=(info&&(info.all||info.companies))||[];
    return s=>{
      if(s&&typeof s==="object"){if(s.pack_unit)return s.pack_unit;if(s.company_id){const c=list.find(x=>x.id===s.company_id);if(c&&c.pack_unit)return c.pack_unit}s=s.sku_name||s.name}
      return unitByName(s,map,list);
    };
  }
  window.LWBBrand={load,get,set,chips,skuMap,skuKey,unitOf,unitByName,word,qty,mount,orderBrands,has,short,pack,packNum,packSum,units:unitsFor};
})();
