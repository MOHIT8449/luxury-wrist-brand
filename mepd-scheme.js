/* LUXURY WRIST BRAND ERP — MEPD % for a SKU category on a date.
   Schemes: [{categories:[...], mepd_pct, valid_from:'YYYY-MM-DD', valid_to, created_at}].
   The latest-entered scheme covering the category and date wins; null = no scheme. */
(function(){
  const up=v=>String(v||"").replace(/\s+/g," ").trim().toUpperCase();
  const day=d=>{if(!d)return new Date().toLocaleDateString("en-CA",{timeZone:"Asia/Kolkata"});return String(d).slice(0,10)};
  function find(schemes,category,date){
    const c=up(category),d=day(date);if(!c)return null;
    let best=null;
    for(const s of schemes||[])if(s.valid_from<=d&&d<=s.valid_to&&(s.categories||[]).some(x=>up(x)===c)&&(!best||String(s.created_at)>String(best.created_at)))best=s;
    return best;
  }
  window.LWBMepd={find,day,up};
})();
