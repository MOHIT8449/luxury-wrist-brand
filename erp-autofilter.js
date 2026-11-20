/* LUXURY WRIST BRAND ERP — Excel-style filter on every list table of every page (Mohit, 20 Nov 2026).
   Loaded by erp-shell.js. Works on the table already drawn by the page, so no page code changes:
     - click a column name: sort, search, tick one or many values (popup from erp-colfilter.js)
     - phone (table head hidden as cards): "Filter columns" grid above the list
     - a page with no search box of its own gets "Search anything on this page" above its first list
   Skipped: edit grids (inputs in rows), print areas, tables with fewer than 2 rows, and tables
   that already use LWBCol themselves (PO / Sales). Add data-cf-off on a table to skip it. */
(function(){
  if(window.LWBAuto)return;
  const D=document,SKIP_HEAD=/^(#|sr\.?( no\.?)?|action|actions|select|)$/i;
  let cf=null,busy=false,mo=null,searchBox=null,searchQ="";
  const tables=new Map(); // table -> {key, head, idx[] (column index used), labels}
  const norm=s=>String(s||"").replace(/\s+/g," ").trim();
  const NUM=/^(?:₹|rs\.?)?\s*-?[\d,]*\d(?:\.\d+)?\s*(?:kg|cs|pcs|pc|%|ltr|l|km|hrs?|days?|cases?|bottles?)?$/i;
  const DATE=/^(\d{1,2})[\/.-](\d{1,2})[\/.-](\d{4})/;
  function cellVal(td){
    const t=norm(td.innerText||td.textContent);
    if(!t||t==="-"||t==="—")return "";
    const d=t.match(DATE);if(d)return d[3]+"-"+d[2].padStart(2,"0")+"-"+d[1].padStart(2,"0");
    if(NUM.test(t)){const n=Number(t.replace(/[^\d.-]/g,""));if(Number.isFinite(n))return n}
    return t;
  }
  function skipTable(t){
    if(t.hasAttribute("data-cf-off")||t.closest("[data-cf-off],.lwb-cf-pop,[id*=print i],[class*=print i],.erp-top,nav"))return true;
    const th=t.tHead;if(!th||!th.rows.length)return true;
    if(th.querySelector("[data-cf]:not([data-cfa])"))return true;   // page's own LWBCol
    const b=t.tBodies[0];if(!b)return true;
    if(b.querySelector("input:not([type=checkbox]),select,textarea"))return true;   // edit grid
    return false;
  }
  function dataRows(t,n){
    const out=[];for(const b of t.tBodies)for(const tr of b.rows){if(tr.cells.length===n&&![...tr.cells].some(c=>c.colSpan>1)&&!tr.classList.contains("lwb-cfa-x"))out.push(tr)}
    return out;
  }
  function headOf(t){
    const hr=t.tHead.rows[t.tHead.rows.length-1],cells=[...hr.cells];
    if(cells.some(c=>c.colSpan>1))return null;
    return cells.map(c=>c.dataset.cfaLabel!=null?c.dataset.cfaLabel:norm(c.innerText||c.textContent));
  }
  function keyOf(t,head){
    const host=t.id||(t.closest("[id]")||{}).id||"";
    return location.pathname+"|"+host+"|"+head.join("/");
  }
  // Put the click-to-filter button on each column name.
  function dressHead(t,info){
    const hr=t.tHead.rows[t.tHead.rows.length-1];
    info.idx.forEach(i=>{
      const c=hr.cells[i];if(!c)return;
      if(c.dataset.cfaLabel==null){
        c.dataset.cfaLabel=info.head[i];
        // Only plain text heads become one button; a head with a checkbox etc. gets a ▾ next to it.
        c.dataset.cfaPlain=c.querySelector("input,button,select,a")?"0":"1";
      }
      const html=cf.th(info.key,info.head,i,c.dataset.cfaPlain==="1"?c.dataset.cfaLabel:null).replace("<button ",'<button data-cfa="" ');
      const old=c.querySelector("[data-cfa]");
      if(old&&old.outerHTML===html)return;
      if(c.dataset.cfaPlain==="1")c.innerHTML=html;
      else{if(old)old.remove();c.insertAdjacentHTML("beforeend",html)}
    });
    // Phone: the head is hidden when rows show as cards -> grid of filter boxes above the table.
    const hidden=getComputedStyle(t.tHead).display==="none";
    let g=t.previousElementSibling&&t.previousElementSibling.classList.contains("lwb-cfa-grid")?t.previousElementSibling:null;
    if(hidden){
      const html=cf.chips(info.key,info.head).replace(/<label>([^<]*)<button[^>]*data-cf="(\d+)"[\s\S]*?<\/button><\/label>/g,(m,l,i)=>info.idx.includes(Number(i))?m:"");
      if(!g){g=D.createElement("div");g.className="lwb-cfa-grid";t.parentNode.insertBefore(g,t)}
      if(g.dataset.h!==html){const was=g.querySelector("details");const op=was&&was.open;g.innerHTML=html;g.dataset.h=html;if(op)g.querySelector("details").open=true}
    }else if(g)g.remove();
  }
  function rowText(tr){return norm(tr.innerText||tr.textContent).toLowerCase()}
  function unmark(root){root.querySelectorAll("mark.lwb-hit").forEach(m=>m.replaceWith(D.createTextNode(m.textContent)));root.normalize&&root.normalize()}
  function applyTable(t,info){
    const rows=dataRows(t,info.head.length);
    const items=rows.map(tr=>({tr,data:[...tr.cells].map(cellVal)}));
    const out=cf.apply(info.key,info.head,items,{list:info.dateCols});
    const words=searchQ?searchQ.toLowerCase().split(/\s+/).filter(Boolean):[];
    const keep=new Set(out.filter(r=>!words.length||words.every(w=>rowText(r.tr).includes(w))).map(r=>r.tr));
    const sorted=cf.count(info.key)>0;
    rows.forEach(tr=>{const on=keep.has(tr);if(tr.hidden===on)tr.hidden=!on});
    if(sorted&&out.length>1){const b=out[0].tr.parentNode;const ord=out.map(r=>r.tr).filter(tr=>tr.parentNode===b);
      let cur=ord[0];for(let k=1;k<ord.length;k++){if(cur.nextElementSibling!==ord[k])cur.after(ord[k]);cur=ord[k]}}
    for(const b of t.tBodies)unmark(b);
    if(searchQ)for(const b of t.tBodies)LWBCol.mark(b,searchQ);
    let note=t.nextElementSibling&&t.nextElementSibling.classList.contains("lwb-cfa-note")?t.nextElementSibling:null;
    const n=cf.count(info.key)+(words.length?1:0);
    if(n&&keep.size<rows.length){
      if(!note){note=D.createElement("div");note.className="lwb-cfa-note";t.after(note)}
      note.innerHTML="Showing <b>"+keep.size+"</b> of "+rows.length+' rows <button type="button">✕ Clear filters</button>';
      note.querySelector("button").onclick=()=>{cf.clear(info.key);if(searchBox){searchBox.value="";searchQ=""}scan()};
    }else if(note)note.remove();
  }
  function scan(){
    if(busy)return;busy=true;
    try{
      for(const t of D.querySelectorAll("table")){
        if(skipTable(t)){tables.delete(t);continue}
        const head=headOf(t);if(!head||head.length<2){tables.delete(t);continue}
        const rows=dataRows(t,head.length);
        if(rows.length<2&&!tables.has(t))continue;
        const idx=head.map((h,i)=>i).filter(i=>!SKIP_HEAD.test(head[i]));
        if(!idx.length)continue;
        const dateCols=idx.filter(i=>rows.slice(0,20).some(tr=>/^\d{4}-\d{2}-\d{2}$/.test(String(cellVal(tr.cells[i])))));
        const info={key:keyOf(t,head),head,idx,dateCols};tables.set(t,info);
        applyTable(t,info);dressHead(t,info);
      }
      addSearch();
    }finally{if(mo)mo.takeRecords();busy=false}
  }
  // One search for the whole page, only where the page has no search box of its own.
  function addSearch(){
    if(searchBox&&D.contains(searchBox))return;
    const first=[...tables.keys()].find(t=>t.offsetParent!==null);if(!first)return;
    const own=[...D.querySelectorAll("input[type=search],input[type=text],input:not([type])")].some(i=>
      i.offsetParent!==null&&!i.closest(".erp-top,.erp-side,.erp-shell-top,header,nav,[role=dialog],.lwb-cf-pop")&&/search|find|खोज/i.test((i.placeholder||"")+" "+(i.getAttribute("aria-label")||"")));
    if(own)return;
    const host=first.closest(".table-wrap,.table-card,.card,section")||first;
    const w=D.createElement("div");w.className="lwb-cfa-search";
    w.innerHTML='<input type="search" placeholder="🔍 Search anything on this page..." aria-label="Search this page" autocomplete="off">';
    host.parentNode.insertBefore(w,host);
    searchBox=w.querySelector("input");
    let tm=0;searchBox.addEventListener("input",()=>{clearTimeout(tm);tm=setTimeout(()=>{searchQ=norm(searchBox.value);scan()},120)});
  }
  function start(){
    if(!window.LWBCol)return;
    cf=LWBCol.create({onChange:()=>scan()});
    const st=D.createElement("style");st.textContent=`
.lwb-cfa-note{display:flex;align-items:center;gap:8px;flex-wrap:wrap;padding:6px 10px;font-size:12.5px;color:#6b7280;background:#fffbea;border-top:1px solid #f1e3a6}
.lwb-cfa-note b{color:#002f37}
.lwb-cfa-note button{border:1px solid #fca5a5;background:#fff;color:#b91c1c;border-radius:6px;padding:2px 8px;font:inherit;font-size:12px;font-weight:600;cursor:pointer}
.lwb-cfa-search{margin:0 0 8px}
.lwb-cfa-search input{width:100%;box-sizing:border-box;height:38px;border:1.5px solid #d5dde8;border-radius:8px;padding:0 12px;font:inherit;font-size:14px;background:#fff}
.lwb-cfa-search input:focus{outline:none;border-color:#002f37;box-shadow:0 0 0 3px rgba(0,47,55,.12)}
.lwb-cfa-grid .lwb-cf-grid{display:block;background:#fff;border:1px solid #e4e4e4;border-radius:10px;margin-bottom:8px}`;
    D.head.appendChild(st);
    let raf=0;mo=new MutationObserver(()=>{if(busy||raf)return;raf=requestAnimationFrame(()=>{raf=0;scan()})});
    mo.observe(D.body,{childList:true,subtree:true,characterData:true});
    window.addEventListener("resize",()=>{clearTimeout(start.t);start.t=setTimeout(scan,200)});
    scan();
  }
  function boot(){
    if(window.LWBCol)return start();
    const cur=D.querySelector('script[src*="erp-autofilter.js"]'),base=cur?cur.src.replace(/[^/]*$/,""):"";
    const s=D.createElement("script");s.src=base+"erp-colfilter.js";s.onload=start;D.head.appendChild(s);
  }
  window.LWBAuto={scan};
  if(D.readyState==="loading")D.addEventListener("DOMContentLoaded",boot);else boot();
})();
