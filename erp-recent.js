/* LUXURY WRIST BRAND ERP — "latest first" for every list.
   Mohit asked (31 Oct 2026): in every list the record that was added, edited,
   modified, cancelled or approved last must come first.

   ERPRecent.sort(rows)                 // sorts in place, newest change first, returns rows
   ERPRecent.sort(rows, "verified_at")  // extra time fields to look at for this list
   ERPRecent.time(row)                  // the time used (ms), 0 when the row has none
   await ERPRecent.attach(client, "table", rows[, rowKey, tableKey])  // adds created_at / updated_at when the page read only some columns

   A row's time is the LATEST of its change times (updated_at, created_at,
   cancelled_at, approved_at, ...). The database sets updated_at on every edit
   (lwb_latest_first_setup.sql). Rows with no time keep their old order, at the end. */
(function(){
  if(window.ERPRecent)return;
  const KEYS=["updated_at","modified_at","edited_at","created_at","entered_at","submitted_at","assigned_at",
    "approved_at","rejected_at","verified_at","cancelled_at","deleted_at","reviewed_at","posted_at",
    "last_activity_at","changed_at"];
  function ms(v){
    if(v==null||v==="")return 0;
    if(v instanceof Date)return v.getTime()||0;
    const n=Date.parse(String(v).replace(" ","T"));
    return Number.isFinite(n)?n:0;
  }
  function time(r,extra){
    if(!r||typeof r!=="object")return 0;
    let t=0;
    for(const k of KEYS){const x=ms(r[k]);if(x>t)t=x}
    if(extra)for(const k of extra){const x=ms(typeof k==="function"?k(r):r[k]);if(x>t)t=x}
    return t;
  }
  function sort(rows,...extra){
    if(!Array.isArray(rows))return rows;
    const keyed=rows.map((r,i)=>[time(r,extra),i,r]);
    keyed.sort((a,b)=>(b[0]-a[0])||(a[1]-b[1]));
    for(let i=0;i<keyed.length;i++)rows[i]=keyed[i][2];
    return rows;
  }
  // compare function for code that sorts by its own rule first (e.g. priority), then latest first
  function cmp(a,b){return time(b)-time(a)}
  // For pages that read only some columns: fetch id + created_at/updated_at of `table`
  // and copy them onto `rows` (matched by id). Never throws; missing columns are skipped.
  async function attach(client,table,rows,key,tableKey){
    key=key||"id";tableKey=tableKey||key;
    if(!client||!Array.isArray(rows)||!rows.length)return rows;
    const by=new Map(rows.map(r=>[String(r[key]),r]));
    for(const cols of ["created_at,updated_at","updated_at","created_at"]){
      let ok=true;
      for(let p=0;p<50;p++){
        let r;
        try{r=await client.from(table).select(tableKey+","+cols).order(tableKey).range(p*1000,p*1000+999)}catch(e){r={error:e}}
        if(r.error){ok=false;break}
        for(const x of r.data||[]){const row=by.get(String(x[tableKey]));if(row)for(const c of cols.split(","))if(x[c]!=null)row[c]=x[c]}
        if((r.data||[]).length<1000)break;
      }
      if(ok)break;
    }
    return rows;
  }
  window.ERPRecent={sort,time,cmp,attach};
})();
