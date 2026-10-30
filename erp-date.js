/* LUXURY WRIST BRAND ERP — one date style everywhere: DD/MM/YYYY.
   LWBDate.d(v)  -> "30/10/2026"            (v: "2026-10-30", ISO timestamp, Date or ms)
   LWBDate.dt(v) -> "30/10/2026, 02:15 PM"  (India time)
   Native date pickers (<input type="date">, "datetime-local") show the phone or
   browser locale (often 10/30/2026). On Chrome / Android WebView this file paints
   the value as DD/MM/YYYY over the picker; input.value stays YYYY-MM-DD, so page
   code is unchanged. Any plain YYYY-MM-DD text a page prints is also shown as
   DD/MM/YYYY (add class "keep-iso" to an element to skip it). */
(function(){
  if(window.LWBDate)return;
  const pad=n=>String(n).padStart(2,"0");
  const TZ="Asia/Kolkata";
  // "2026-10-30" stays that calendar day; timestamps are read in India time
  function parts(v){
    if(v==null||v==="")return null;
    const m=typeof v==="string"&&/^(\d{4})-(\d{2})-(\d{2})$/.exec(v.trim());
    if(m)return {y:m[1],m:m[2],d:m[3]};
    const t=v instanceof Date?v:new Date(v);
    if(isNaN(t))return null;
    const p={};
    for(const x of new Intl.DateTimeFormat("en-GB",{timeZone:TZ,year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",hour12:false}).formatToParts(t))p[x.type]=x.value;
    return {y:p.year,m:p.month,d:p.day,h:Number(p.hour)%24,mi:p.minute};
  }
  function d(v,blank=""){const p=parts(v);return p?p.d+"/"+p.m+"/"+p.y:(v?String(v):blank)}
  function time(h,mi){return pad(h%12||12)+":"+mi+" "+(h<12?"AM":"PM")}
  function dt(v,blank=""){
    const p=parts(v);if(!p)return v?String(v):blank;
    return p.h==null?d(v):p.d+"/"+p.m+"/"+p.y+", "+time(p.h,p.mi);
  }
  /* ---- plain YYYY-MM-DD text on the page -> DD/MM/YYYY ---- */
  const ISO=/(^|[^\w\/.-])(\d{4})-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])(?![\w\/.:-])/g;
  const text=s=>s.replace(ISO,(_,pre,y,m,dd)=>pre+dd+"/"+m+"/"+y);
  // for Excel / CSV exports: every YYYY-MM-DD inside a cell becomes DD/MM/YYYY
  const cell=v=>typeof v==="string"?text(v):v;
  const rows=list=>list.map(r=>Array.isArray(r)?r.map(cell):cell(r));
  window.LWBDate={d,dt,text,cell,rows};
  // browser pop-ups too
  for(const k of ["alert","confirm","prompt"]){const f=window[k];window[k]=function(m,...a){return f.call(window,typeof m==="string"?text(m):m,...a)}}

  const SKIP=/^(SCRIPT|STYLE|TEXTAREA|INPUT|CODE|PRE|NOSCRIPT)$/;
  function fixText(node){
    const s=node.nodeValue;
    if(!s||s.length<10||!/\d{4}-\d\d-\d\d/.test(s))return;
    for(let e=node.parentElement;e;e=e.parentElement){
      if(SKIP.test(e.tagName)||e.isContentEditable||e.classList.contains("keep-iso"))return;
    }
    const n=text(s);
    if(n!==s)node.nodeValue=n;
  }
  function fixTree(root){
    if(root.nodeType===3)return fixText(root);
    if(root.nodeType!==1&&root.nodeType!==11)return;
    const w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
    for(let n=w.nextNode();n;n=w.nextNode())fixText(n);
  }

  /* ---- date pickers painted as DD/MM/YYYY (Chromium only) ---- */
  const ua=navigator.userAgent;
  const paint=/Chrome\/|Chromium\//.test(ua)&&!/CriOS|FxiOS|EdgiOS/.test(ua);
  const PICK=/^(date|datetime-local)$/;
  function sync(el){
    if(!paint||el.tagName!=="INPUT"||!PICK.test(el.type))return;
    el.classList.add("lwb-dmy");
    const v=el.value;let txt="";
    if(el.type==="date")txt=v?d(v):"dd/mm/yyyy";
    else if(v){const [day,t]=v.split("T"),[h,mi]=(t||"").split(":");txt=d(day)+(t?", "+time(Number(h),mi):"");}
    else txt="dd/mm/yyyy, --:-- --";
    el.setAttribute("data-dmy",txt);
    el.classList.toggle("lwb-dmy-empty",!v);
  }
  function syncTree(root){
    if(!paint||root.nodeType!==1)return;
    if(root.tagName==="INPUT")return sync(root);
    root.querySelectorAll("input[type=date],input[type=datetime-local]").forEach(sync);
  }
  if(paint){
    // page code sets .value without firing events; repaint after every set
    for(const k of ["value","valueAsDate","valueAsNumber"]){
      const ds=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,k);
      if(!ds||!ds.set)continue;
      Object.defineProperty(HTMLInputElement.prototype,k,{configurable:true,enumerable:ds.enumerable,get:ds.get,
        set(x){ds.set.call(this,x);if(PICK.test(this.type))sync(this)}});
    }
    for(const ev of ["input","change"])document.addEventListener(ev,e=>sync(e.target),true);
    document.addEventListener("reset",e=>setTimeout(()=>syncTree(e.target)),true);
    // the text is painted over the picker, so a tap anywhere opens the calendar
    document.addEventListener("click",e=>{
      const el=e.target;
      if(el&&el.classList&&el.classList.contains("lwb-dmy")&&!el.disabled&&!el.readOnly&&el.showPicker){try{el.showPicker()}catch(_){}}
    });
    const css=document.createElement("style");
    css.textContent=`
input.lwb-dmy{position:relative}
input.lwb-dmy::-webkit-datetime-edit{opacity:0}
input.lwb-dmy::before{content:attr(data-dmy);position:absolute;top:50%;transform:translateY(-50%);white-space:nowrap;pointer-events:none;color:inherit}
input.lwb-dmy.lwb-dmy-empty::before{opacity:.55}`;
    (document.head||document.documentElement).appendChild(css);
  }

  function start(){
    fixTree(document.body);syncTree(document.body);
    new MutationObserver(list=>{
      for(const m of list){
        if(m.type==="characterData")fixText(m.target);
        else if(m.type==="attributes")sync(m.target);
        else for(const n of m.addedNodes){fixTree(n);syncTree(n)}
      }
    }).observe(document.body,{childList:true,subtree:true,characterData:true,attributes:true,attributeFilter:["value","type"]});
  }
  if(document.body)start();else document.addEventListener("DOMContentLoaded",start);
})();
