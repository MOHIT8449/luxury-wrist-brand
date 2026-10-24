/* LUXURY WRIST BRAND ERP — Excel Export / Template / Import panel shared by master pages.
   The page gives the columns and two functions:
     plan(rows)  -> {add:[], update:[], errors:[], same:n}   (rows are {key:value, _row:n} from the sheet)
     apply(plan, progress) -> message string                    (does the saving)
   Columns are matched by header text, so the column order in Excel does not matter.
   Nothing is saved until the person sees the check result and presses Import. */
(function(){
  const LIB="https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js";
  function lib(){
    if(window.XLSX)return Promise.resolve();
    return new Promise((ok,bad)=>{const s=document.createElement("script");s.src=LIB;s.onload=ok;s.onerror=()=>bad(Error("Excel library load nahi hui. Internet check karo."));document.head.appendChild(s)});
  }
  const norm=v=>String(v==null?"":v).replace(/\*/g,"").replace(/[^A-Za-z0-9%]+/g," ").trim().toUpperCase();
  async function write(file,sheets){
    await lib();const book=XLSX.utils.book_new();
    for(const s of sheets){const ws=XLSX.utils.aoa_to_sheet(s.rows);ws["!cols"]=s.rows[0].map((_,i)=>({wch:Math.min(45,Math.max(10,...s.rows.map(r=>String(r[i]??"").length+2)))}));XLSX.utils.book_append_sheet(book,ws,s.name)}
    XLSX.writeFile(book,file+".xlsx");
  }
  async function read(f,cols){
    await lib();const book=XLSX.read(await f.arrayBuffer());
    const aoa=XLSX.utils.sheet_to_json(book.Sheets[book.SheetNames[0]],{header:1,defval:"",raw:true});
    const want=new Map();for(const c of cols){want.set(norm(c.h),c);for(const a of c.alias||[])want.set(norm(a),c)}
    const hi=aoa.findIndex(r=>r.some(v=>want.has(norm(v))&&want.get(norm(v)).req));
    if(hi<0)throw Error("Header row nahi mili. Template download karke usi me data bharo.");
    const map=aoa[hi].map(v=>want.get(norm(v))||null);
    const missing=cols.filter(c=>c.req&&!map.includes(c)).map(c=>c.h);
    if(missing.length)throw Error("Ye column Excel me nahi hai: "+missing.join(", "));
    const rows=[];
    aoa.slice(hi+1).forEach((r,i)=>{const o={_row:hi+i+2};let any=false;
      map.forEach((c,j)=>{if(!c)return;let v=r[j];if(typeof v==="string")v=v.trim();if(v!==""&&v!=null)any=true;o[c.k]=v===""?null:v});
      if(any)rows.push(o)});
    return rows;
  }
  // opts: {mount, file, columns:[{h,k,req,sample,note,alias}], exportRows(), plan(rows), apply(plan,progress), canImport()}
  function panel(o){
    const box=document.createElement("div");box.className="lwb-xl";
    box.innerHTML='<div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">'
      +'<button type="button" class="secondary" data-a="exp">⬇ Export Excel</button>'
      +'<button type="button" class="secondary" data-a="tpl">⬇ Blank Template</button>'
      +'<label class="secondary" style="cursor:pointer;display:inline-flex;align-items:center;gap:6px;padding:8px 12px;border:1px solid #c9d3e0;border-radius:8px;background:#fff"><input type="file" accept=".xlsx,.xls,.csv" data-a="file" style="display:none">⬆ Import Excel</label>'
      +'<button type="button" data-a="go" disabled>Import karo</button></div>'
      +'<div data-a="info" class="hint" style="margin-top:8px;white-space:pre-wrap"></div>';
    o.mount.appendChild(box);
    const q=a=>box.querySelector('[data-a="'+a+'"]'),info=q("info");let plan=null;
    const say=(t,bad)=>{info.textContent=t;info.style.color=bad?"#b42318":""};
    const head=()=>o.columns.map(c=>c.h+(c.req?" *":""));
    q("exp").onclick=async()=>{try{const rows=o.exportRows();await write(o.file+"-"+new Date().toISOString().slice(0,10),[{name:"Data",rows:[head(),...rows.map(r=>o.columns.map(c=>r[c.k]??""))]}]);say(rows.length+" rows export hue. Isi file me badlav karke wapas Import kar sakte ho.")}catch(e){say(e.message,true)}};
    q("tpl").onclick=async()=>{try{await write(o.file+"-Template",[{name:"Data",rows:[head(),o.columns.map(c=>c.sample??"")]},
      {name:"Help",rows:[["Column","Zaroori?","Kya bharna hai"],...o.columns.map(c=>[c.h,c.req?"Haan":"Nahi",c.note||""]),[],["Pehli sheet (Data) me hi data bharo. Header row mat badlo. Sample row hata do."]]}]);
      say("Template download hua. Data sheet bharo, phir Import Excel se upload karo.")}catch(e){say(e.message,true)}};
    q("file").onchange=async e=>{const f=e.target.files[0];e.target.value="";plan=null;q("go").disabled=true;if(!f)return;
      try{say("File padh rahe hain...");const rows=await read(f,o.columns);plan=o.plan(rows);
        const lines=[f.name+": "+rows.length+" rows",plan.add.length+" naye · "+plan.update.length+" update · "+(plan.same||0)+" pehle se same · "+plan.errors.length+" galat"];
        if(plan.errors.length)lines.push("Galat rows (ye save nahi hongi):\n"+plan.errors.slice(0,30).join("\n")+(plan.errors.length>30?"\n...":""));
        if(plan.add.length+plan.update.length)lines.push("Sab theek lage to 'Import karo' dabao.");
        say(lines.join("\n"),!!plan.errors.length);q("go").disabled=!(o.canImport?o.canImport():true)||!(plan.add.length+plan.update.length);
      }catch(err){say(err.message,true)}};
    q("go").onclick=async()=>{if(!plan||!confirm(plan.add.length+" naye add aur "+plan.update.length+" update karein?"))return;
      q("go").disabled=true;try{say(await o.apply(plan,t=>say(t)))}catch(err){say(err.message,true)}plan=null};
    return box;
  }
  const num=v=>v==null||v===""?null:Number(String(v).replace(/,/g,""));
  window.LWBExcel={lib,write,read,panel,num};
})();
