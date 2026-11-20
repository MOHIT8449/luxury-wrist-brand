/* LUXURY WRIST BRAND ERP — ONE date filter for the whole site (Mohit, 20 Nov 2026).
   The top bar (erp-shell.js) draws Today / Yesterday / 7 Days / 30 Days / This Month / Custom next to the
   brand picker; the date filters inside pages are gone and every page follows this one.
   Kept per device (localStorage lwbPeriod = {k, f, t}); other tabs follow.
     LWBPeriod.get()         -> {key, from, to, label, short, text, days}   (from / to = "YYYY-MM-DD", India day)
     LWBPeriod.set(key,f,t)  -> choose a range (key: today | yday | 7 | 30 | month | custom)
     LWBPeriod.on(fn)        -> fn(range) after every change (also event "lwb:period" on document)
     LWBPeriod.day()         -> one day for single-day pages (= the range's last day)
     LWBPeriod.bind(fromEl, toEl, {hide, run}) -> keeps a page's own From / To inputs filled from the top bar,
                                hides `hide` (element / selector / list), calls run() (or fires "change" on toEl)
     LWBPeriod.hide(...els)  -> hide old page filter boxes
     LWBPeriod.has(day)      -> is a "YYYY-MM-DD" / timestamp inside the range
   A page that loads this file gets the date picker in its top bar; pages without dates do not show it
   (data-roles on the script tag: only those roles, e.g. the Dashboard = Admin's Business Overview). */
(function(){
  if(window.LWBPeriod)return;
  // <script src="erp-period.js" data-roles="admin manager"> = the top bar picker shows only for those roles.
  const ROLES=((document.currentScript&&document.currentScript.dataset.roles)||"").toLowerCase().split(/[\s,]+/).filter(Boolean);
  const KEY="lwbPeriod";
  const R=[["today","Today","Today"],["yday","Yesterday","Yday"],["7","7 Days","7D"],["30","30 Days","30D"],["month","This Month","Month"],["custom","Custom","Custom"]];
  const istDay=v=>{const t=v instanceof Date?v.getTime():Date.parse(v);return isNaN(t)?"":new Date(t+19800000).toISOString().slice(0,10)};
  const today=()=>istDay(new Date());
  const shift=(d,n)=>new Date(Date.parse(d+"T12:00:00Z")+n*864e5).toISOString().slice(0,10);
  const span=(a,b)=>Math.round((Date.parse(b+"T12:00:00Z")-Date.parse(a+"T12:00:00Z"))/864e5)+1;
  const isDay=v=>/^\d{4}-\d{2}-\d{2}$/.test(String(v||""))&&v>="2020-01-01";
  const dm=d=>String(d).slice(8,10)+"/"+String(d).slice(5,7);
  function read(){
    let s=null;try{s=JSON.parse(localStorage.getItem(KEY)||"null")}catch(e){}
    if(!s||!R.some(r=>r[0]===s.k))s={k:"7"};
    return s;
  }
  function calc(s){
    const t=today();let from,to=t;const k=s.k;
    if(k==="custom"){
      from=isDay(s.f)&&s.f<=t?s.f:shift(t,-6);to=isDay(s.t)&&s.t<=t?s.t:t;if(to<from)[from,to]=[to,from];
    }else if(k==="yday")from=to=shift(t,-1);
    else from=k==="today"?t:k==="7"?shift(t,-6):k==="30"?shift(t,-29):t.slice(0,8)+"01";
    const r=R.find(x=>x[0]===k);
    const text=from===to?dm(from):dm(from)+"–"+dm(to);
    // phone: "10–18/11" (same month) / one day "10/11" / else "Custom"
    const sh=from===to?dm(from):from.slice(0,7)===to.slice(0,7)?from.slice(8,10)+"–"+dm(to):"Custom";
    return {key:k,from,to,label:k==="custom"?text:r[1],short:k==="custom"?sh:r[2],text,days:span(from,to),today:t};
  }
  const subs=[];let last=null;
  function get(){return calc(read())}
  function fire(){
    const r=get(),sig=r.key+r.from+r.to;if(sig===last)return;last=sig;
    for(const f of subs.slice()){try{f(r)}catch(e){console.error(e)}}
    try{document.dispatchEvent(new CustomEvent("lwb:period",{detail:r}))}catch(e){}
  }
  function set(k,f,t){
    const s={k:R.some(r=>r[0]===k)?k:"7"};if(s.k==="custom"){s.f=f;s.t=t}
    try{localStorage.setItem(KEY,JSON.stringify(s))}catch(e){}
    fire();
  }
  function on(fn){subs.push(fn);return get()}
  const day=()=>get().to;
  function has(v){if(!v)return false;const d=/^\d{4}-\d{2}-\d{2}$/.test(String(v))?String(v):istDay(v);const r=get();return d>=r.from&&d<=r.to}
  const els=x=>!x?[]:typeof x==="string"?[...document.querySelectorAll(x)]:x.length!=null&&!x.tagName?[...x]:[x];
  function hide(...list){for(const x of list)for(const e of els(x)){e.hidden=true;e.classList.add("lwb-per-off")}}
  function bind(fromEl,toEl,o){
    o=o||{};const f=typeof fromEl==="string"?document.getElementById(fromEl):fromEl,t=typeof toEl==="string"?document.getElementById(toEl):toEl;
    hide(o.hide===undefined?[f,t]:o.hide);
    const fill=r=>{if(f)f.value=r.from;if(t)t.value=r.to};
    fill(get());
    on(r=>{fill(r);if(o.run)o.run(r);else if(t||f)(t||f).dispatchEvent(new Event("change",{bubbles:true}))});
    return get();
  }
  // One-day reports (Daily Summary, Godown report ...): the last day of the range, with a short note when the range is longer.
  function oneDay(noteEl){
    const r=get(),n=typeof noteEl==="string"?document.querySelector(noteEl):noteEl;
    if(n){n.hidden=r.days<2;n.classList.add("lwb-per-note");n.textContent=r.days<2?"":"One-day report: showing "+dm(r.to)+"/"+r.to.slice(0,4)+" (last day of "+r.label+"). Pick Today / Yesterday / Custom on top for another day."}
    return r.to;
  }
  window.addEventListener("storage",e=>{if(e.key===KEY)fire()});
  // A new day: relative ranges move on by themselves.
  setInterval(()=>{const r=get();if(last&&r.key+r.from+r.to!==last)fire()},60000);
  last=(r=>r.key+r.from+r.to)(get());

  const css=document.createElement("style");
  css.textContent='.lwb-per-off{display:none!important}.lwb-per-note{margin:0 0 8px;padding:6px 10px;border-radius:6px;background:#fff7e0;border:1px solid #f0dca0;color:#7a5a00;font-size:12.5px;font-weight:600}.lwb-per-note[hidden]{display:none}';
  (document.head||document.documentElement).appendChild(css);

  // Top bar picker (called by erp-shell.js after the brand picker).
  const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  function mountTop(top,role){
    if(!top||top.querySelector(".erp-datepick"))return;
    if(ROLES.length&&!ROLES.includes(String(role||"").toLowerCase()))return;
    const box=document.createElement("div");box.className="erp-datepick";box.setAttribute("data-nosearch","");
    // Right next to Module Search (Mohit, 20 Nov 2026); phone (no search box) = same place, before the bell.
    const after=top.querySelector(".erp-search")||top.querySelector(".erp-brandpick")||top.querySelector(".erp-crumb");if(!after)return;
    after.after(box);top.classList.add("has-date");
    box.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/></svg><span class="dp-l"></span>'+
      '<select aria-label="Date (whole site)" title="Date for every page"></select><button type="button" class="dp-c" title="Change custom dates"></button>'+
      '<div class="dp-pop" hidden><div class="dp-h">Custom dates</div><label>From<input type="date" class="dp-f"></label><label>To<input type="date" class="dp-t"></label>'+
      '<div class="dp-b"><button type="button" class="dp-x">Cancel</button><button type="button" class="dp-ok">Apply</button></div></div>';
    const sel=box.querySelector("select"),lab=box.querySelector(".dp-l"),cbtn=box.querySelector(".dp-c"),pop=box.querySelector(".dp-pop"),fi=box.querySelector(".dp-f"),ti=box.querySelector(".dp-t");
    const paint=()=>{
      const r=get();
      sel.innerHTML=R.map(x=>'<option value="'+x[0]+'">'+esc(x[0]==="custom"?(r.key==="custom"?"Custom: "+r.text:"Custom…"):x[1])+"</option>").join("")+(r.key==="custom"?'<option value="edit">✎ Change dates…</option>':"");
      sel.value=r.key;lab.textContent=r.short;cbtn.textContent=r.text;box.classList.toggle("cus",r.key==="custom");
      box.title=r.key==="custom"?"Custom "+r.text:r.label+" · "+r.text;
    };
    const open=()=>{const r=get();fi.value=r.from;ti.value=r.to;fi.max=ti.max=r.today;fi.min=ti.min="2020-01-01";pop.hidden=false;box.classList.add("open");setTimeout(()=>{try{fi.showPicker?fi.focus():fi.focus()}catch(e){}},30)};
    const close=()=>{pop.hidden=true;box.classList.remove("open");paint()};
    sel.onchange=()=>{const v=sel.value;if(v==="custom"||v==="edit"){open();return}close();set(v)};
    cbtn.onclick=e=>{e.stopPropagation();pop.hidden?open():close()};
    fi.onchange=()=>{if(!ti.value||ti.value<fi.value)ti.value=fi.value;ti.min=fi.value};
    box.querySelector(".dp-x").onclick=close;
    box.querySelector(".dp-ok").onclick=()=>{let f=fi.value,t=ti.value||f;if(!isDay(f)){fi.focus();return}if(t<f)[f,t]=[t,f];pop.hidden=true;box.classList.remove("open");set("custom",f,t);paint()};
    document.addEventListener("click",e=>{if(!pop.hidden&&!box.contains(e.target))close()});
    document.addEventListener("keydown",e=>{if(e.key==="Escape"&&!pop.hidden)close()});
    on(paint);paint();
  }
  window.LWBPeriod={get,set,on,day,oneDay,has,bind,hide,mountTop,ranges:R,istDay,today,shift,span};
})();
