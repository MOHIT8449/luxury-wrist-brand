/* LUXURY WRIST BRAND ERP — SKU lists: best-selling first.
   Mohit (6 Nov 2026): in every SKU drop-down the SKU that sells the most comes first,
   SKUs that do not sell go last.

   LWBSkuRank.load(db)  -> Promise<Map(SKU NAME UPPER -> cases sold, last 90 days)>; cached per page.
   LWBSkuRank.sort(list, nameOf?) -> new array, most sold first, then never sold (A-Z inside each tie).
   Source: lwb_sku_sales_rank() (lwb_sku_sales_rank_setup.sql). Until that SQL runs, the latest
   1000 PO lines this login can read are counted instead. Any error = the list stays A-Z. */
(function(){
  if(window.LWBSkuRank)return;
  const key=s=>String(s||"").trim().toUpperCase();
  let rank=new Map(),loading=null;
  async function fetchRank(db){
    const m=new Map();
    const r=await db.rpc("lwb_sku_sales_rank",{p_days:90}).then(x=>x,()=>({error:true}));
    if(!r.error&&Array.isArray(r.data)){
      r.data.forEach(x=>m.set(key(x.sku_key),Number(x.qty)||0));
      return m;
    }
    const f=await db.from("order_items").select("*").order("id",{ascending:false}).limit(1000).then(x=>x,()=>({error:true}));
    (f.data||[]).forEach(i=>{
      const k=key(i.sku_name);if(!k)return;
      const q=Math.max(Number(i.loaded_qty??i.approved_qty??i.ordered_qty)||0,0);
      m.set(k,(m.get(k)||0)+q);
    });
    return m;
  }
  function load(db){
    if(!db)return Promise.resolve(rank);
    if(!loading)loading=fetchRank(db).then(m=>(rank=m),()=>rank);
    return loading;
  }
  const qtyOf=name=>rank.get(key(name))||0;
  function sort(list,nameOf){
    const nm=nameOf||(x=>x);
    return [...(list||[])].sort((a,b)=>(qtyOf(nm(b))-qtyOf(nm(a)))||String(nm(a)||"").localeCompare(String(nm(b)||""),"en",{numeric:true}));
  }
  window.LWBSkuRank={load,sort,qty:qtyOf};
})();
