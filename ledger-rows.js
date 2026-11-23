/* Party ledger rows for the pages (Ledger & Outstanding, Party & Collections, Party Ledger, Sales Outstanding).
   The website API sends at most 1000 rows of a call; the ledger is bigger than that (1039 rows on 23 Nov 2026),
   so the newest entries were cut. lwb_party_ledger_bj() (lwb_party_ledger_all_rows_fix.sql) gives all rows as
   one json value. Until that SQL is in, the old calls are read 1000 rows at a time.
   LWBLedgerRows(client) -> {data:[...], error, brand:true|false}  (brand=false: old lwb_party_ledger, no company_id) */
(function(){
  "use strict";
  async function paged(client,fn){
    const out=[];
    for(let p=0;p<100;p++){
      const r=await client.rpc(fn).range(p*1000,p*1000+999);
      if(r.error)return {error:r.error};
      out.push(...(r.data||[]));
      if((r.data||[]).length<1000)break;
    }
    return {data:out};
  }
  window.LWBLedgerRows=async function(client){
    const j=await client.rpc("lwb_party_ledger_bj");
    if(!j.error&&Array.isArray(j.data))return {data:j.data,error:null,brand:true};
    let a=await paged(client,"lwb_party_ledger_b");
    if(!a.error)return {data:a.data,error:null,brand:true};
    a=await paged(client,"lwb_party_ledger"); // brand SQL not run yet
    return {data:a.data||[],error:a.error||null,brand:false};
  };
  window.LWBLedgerRows.paged=paged;   // any other list call, 1000 rows at a time
})();
