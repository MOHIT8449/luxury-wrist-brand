/* LUXURY WRIST BRAND ERP — every drop-down searches like the SKU box in New PO.
   Mohit (5 Nov 2026): wherever a drop-down picks a party, vehicle, employee, supplier, head ...
   the user must be able to type and the list must narrow down, the same way the SKU box in
   New PO / Sales Order works. Loaded by erp-shell.js (all ERP pages); cashbook.html loads it directly.

   How: the page keeps its own <select> (same look, same value, same onchange). When it is tapped,
   clicked, or a letter is typed on it, a search box opens right on top of it with the list under it.
   Typing narrows the list (every word anywhere in the name). ↑ ↓ move, Enter picks (and goes to the
   next field), Esc / tap outside closes. The pick sets select.value and fires input + change, so
   page code runs exactly as when the option was picked by hand.
   Only drop-downs with MIN options or more; not multi-selects. Opt out: data-nosearch on the
   select (or a block around it). */
(function(){
  if(window.LWBSelect)return;
  const D=document,MIN=6,MAX_SHOW=250;
  const css=`
.lwb-sel-pop{position:fixed;z-index:2147483000;display:flex;flex-direction:column;background:#fff;color:#111827;border:1px solid #c9a227;border-radius:10px;box-shadow:0 10px 30px rgba(0,0,0,.22);overflow:hidden;font:14px/1.3 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;box-sizing:border-box}
.lwb-sel-pop.up{flex-direction:column-reverse}
.lwb-sel-pop input{flex:0 0 auto;width:100%;box-sizing:border-box;margin:0;border:0!important;border-bottom:1px solid #e5e7eb!important;box-shadow:none!important;border-radius:0!important;padding:0 10px;font:inherit;font-size:16px;background:#fffbea;color:#111827;outline:none;min-width:0}
.lwb-sel-pop.up input{border-bottom:0!important;border-top:1px solid #e5e7eb!important}
.lwb-sel-pop ul{list-style:none;margin:0;padding:4px 0;overflow-y:auto;overflow-x:hidden;overscroll-behavior:contain;-webkit-overflow-scrolling:touch}
.lwb-sel-pop li{padding:8px 10px;cursor:pointer;white-space:normal;word-break:break-word}
.lwb-sel-pop li.hi{background:#fef3c7}
.lwb-sel-pop li.on{font-weight:700}
.lwb-sel-pop li.on::after{content:" ✓";color:#a16207}
.lwb-sel-pop li.grp{padding:6px 10px 2px;font-size:11px;font-weight:700;color:#6b7280;text-transform:uppercase;cursor:default}
.lwb-sel-pop li.off{color:#9ca3af;cursor:default}
.lwb-sel-pop li.none{color:#6b7280;cursor:default;font-style:italic}
.lwb-sel-pop li.more{color:#6b7280;cursor:default;font-size:12px}
.lwb-sel-pop mark{background:none;color:#a16207;font-weight:700}`;
  let styled=false;
  function style(){if(styled)return;styled=true;const s=D.createElement("style");s.id="lwb-sel-css";s.textContent=css;(D.head||D.documentElement).appendChild(s)}

  const norm=s=>String(s||"").toLowerCase().replace(/\s+/g," ").trim();
  function want(s){
    if(!s||s.tagName!=="SELECT"||s.multiple||s.size>1||s.disabled)return false;
    if(s.closest("[data-nosearch]"))return false;
    return s.options.length>=MIN;
  }
  let cur=null;
  function items(sel){
    const out=[];let grp=null;
    for(const o of sel.options){
      if(o.hidden)continue;
      const g=o.parentElement&&o.parentElement.tagName==="OPTGROUP"?o.parentElement.label:"";
      out.push({o,text:o.text,n:norm(o.text+" "+(o.value!==o.text?o.value:"")),g,blank:o.value===""});
    }
    return out;
  }
  function mark(li,text,words){
    if(!words.length){li.textContent=text;return}
    const lo=text.toLowerCase();let best=-1,len=0;
    for(const w of words){const i=lo.indexOf(w);if(i>=0&&(best<0||i<best)){best=i;len=w.length}}
    if(best<0){li.textContent=text;return}
    li.append(text.slice(0,best));const m=D.createElement("mark");m.textContent=text.slice(best,best+len);li.append(m,text.slice(best+len));
  }
  function render(){
    const c=cur;if(!c)return;
    const q=norm(c.inp.value),words=q?q.split(" "):[];
    let list=c.all;
    if(words.length){
      list=list.filter(x=>!x.blank&&words.every(w=>x.n.includes(w)));
      // Names that start with what was typed come first, the rest keep the page's order.
      const a=[],b=[];for(const x of list)(x.n.startsWith(q)?a:b).push(x);list=a.concat(b);
    }
    c.shown=list.filter(x=>!x.o.disabled);
    c.ul.textContent="";
    if(!list.length){const li=D.createElement("li");li.className="none";li.textContent="No match for \""+c.inp.value.trim()+"\"";c.ul.appendChild(li);c.hi=-1;return}
    let lastG=null,n=0;
    for(const x of list){
      if(n>=MAX_SHOW){const li=D.createElement("li");li.className="more";li.textContent="+"+(list.length-MAX_SHOW)+" more · type to narrow";c.ul.appendChild(li);break}
      if(!words.length&&x.g&&x.g!==lastG){const g=D.createElement("li");g.className="grp";g.textContent=x.g;c.ul.appendChild(g)}
      lastG=x.g;
      const li=D.createElement("li");li.setAttribute("role","option");
      mark(li,x.text||" ",words);
      if(x.o.disabled)li.className="off";else li._x=x;
      if(x.o.value===c.sel.value&&x.o.selected)li.classList.add("on");
      c.ul.appendChild(li);n++;
    }
    const lis=[...c.ul.querySelectorAll("li")].filter(l=>l._x);
    c.lis=lis;
    let h=words.length?0:lis.findIndex(l=>l._x.o.selected);
    if(h<0)h=0;
    hilite(h,true);
  }
  function hilite(i,center){
    const c=cur;if(!c||!c.lis||!c.lis.length){if(c)c.hi=-1;return}
    i=Math.max(0,Math.min(c.lis.length-1,i));
    if(c.hi>=0&&c.lis[c.hi])c.lis[c.hi].classList.remove("hi");
    c.hi=i;const li=c.lis[i];li.classList.add("hi");
    const ul=c.ul,t=li.offsetTop,b=t+li.offsetHeight;
    if(center)ul.scrollTop=Math.max(0,t-ul.clientHeight/2+li.offsetHeight/2);
    else if(t<ul.scrollTop)ul.scrollTop=t;else if(b>ul.scrollTop+ul.clientHeight)ul.scrollTop=b-ul.clientHeight;
  }
  function place(){
    const c=cur;if(!c)return;
    if(!c.sel.isConnected||!c.sel.getClientRects().length){close();return}
    const vv=window.visualViewport,vw=D.documentElement.clientWidth||innerWidth;
    const vTop=vv?vv.offsetTop:0,vH=vv?vv.height:innerHeight;
    const r=c.sel.getBoundingClientRect();
    const h=Math.max(38,Math.round(r.height));
    const w=Math.min(vw-16,Math.max(Math.round(r.width),240));
    const left=Math.max(8,Math.min(Math.round(r.left),vw-w-8));
    const below=vTop+vH-r.top-h-8,above=r.bottom-h-vTop-8;
    const up=below<200&&above>below;
    const room=Math.max(120,Math.min(320,up?above:below));
    c.pop.classList.toggle("up",up);
    c.inp.style.height=h+"px";
    c.ul.style.maxHeight=room+"px";
    c.pop.style.width=w+"px";c.pop.style.left=left+"px";
    if(up){c.pop.style.top="";c.pop.style.bottom=Math.round(innerHeight-r.bottom)+"px"}
    else{c.pop.style.bottom="";c.pop.style.top=Math.round(r.top)+"px"}
  }
  function open(sel,seed){
    if(cur&&cur.sel===sel)return;
    close();style();
    const pop=D.createElement("div");pop.className="lwb-sel-pop";pop.setAttribute("data-keys","off");pop.setAttribute("data-nocaps","");
    const inp=D.createElement("input");inp.type="text";inp.autocomplete="off";inp.spellcheck=false;
    inp.setAttribute("autocapitalize","off");inp.setAttribute("enterkeyhint","done");inp.setAttribute("role","combobox");
    const lab=(sel.getAttribute("aria-label")||(sel.labels&&sel.labels[0]&&sel.labels[0].textContent)||"").replace(/[*:]/g,"").trim();
    inp.placeholder="Type to search…";
    inp.setAttribute("aria-label","Search "+(lab||"list"));
    const ul=D.createElement("ul");ul.setAttribute("role","listbox");
    pop.append(inp,ul);
    cur={sel,pop,inp,ul,all:items(sel),hi:-1,lis:[]};
    D.body.appendChild(pop);
    if(seed)inp.value=seed;
    place();render();
    inp.focus({preventScroll:true});
    try{const n=inp.value.length;inp.setSelectionRange(n,n)}catch(e){}
    inp.addEventListener("input",render);
    inp.addEventListener("keydown",key);
    ul.addEventListener("mousedown",e=>e.preventDefault());
    ul.addEventListener("click",e=>{const li=e.target.closest("li");if(li&&li._x)pick(li._x,false)});
    sel.setAttribute("aria-expanded","true");
  }
  function close(refocus){
    const c=cur;if(!c)return;cur=null;
    c.pop.remove();c.sel.removeAttribute("aria-expanded");
    if(refocus)try{c.sel.focus({preventScroll:true})}catch(e){}
  }
  function pick(x,next){
    const c=cur;if(!c)return;const sel=c.sel;
    close(true);
    if(!x.o.selected||sel.value!==x.o.value){
      x.o.selected=true;
      sel.dispatchEvent(new Event("input",{bubbles:true}));
      sel.dispatchEvent(new Event("change",{bubbles:true}));
    }
    if(next&&window.LWBKeys&&LWBKeys.next){
      // Tally style: Enter on a pick goes on to the next field.
      setTimeout(()=>{if(D.activeElement!==sel)return;const n=LWBKeys.next(sel);if(n&&n.focus)try{n.focus()}catch(e){}},0);
    }
  }
  function key(e){
    const c=cur;if(!c)return;
    const k=e.key;
    if(k==="ArrowDown"){e.preventDefault();hilite(c.hi+1)}
    else if(k==="ArrowUp"){e.preventDefault();hilite(c.hi-1)}
    else if(k==="PageDown"){e.preventDefault();hilite(c.hi+8)}
    else if(k==="PageUp"){e.preventDefault();hilite(c.hi-8)}
    else if(k==="Enter"){e.preventDefault();e.stopPropagation();const li=c.lis[c.hi];if(li)pick(li._x,true);else close(true)}
    else if(k==="Escape"||k==="Esc"){e.preventDefault();e.stopPropagation();close(true)}
    else if(k==="Tab"){e.preventDefault();const li=c.lis[c.hi];if(li&&c.inp.value.trim())pick(li._x,false);else close(true)}
  }

  // Desktop: a click on the drop-down opens the search instead of the long native list.
  D.addEventListener("mousedown",e=>{
    if(cur&&!cur.pop.contains(e.target)){const same=e.target===cur.sel;close();if(same){e.preventDefault();return}}
    if(e.button!==0||e.ctrlKey||e.metaKey)return;
    const s=e.target&&e.target.closest&&e.target.closest("select");
    if(!want(s))return;
    e.preventDefault();
    try{s.focus({preventScroll:true})}catch(_){}
    open(s);
  },true);
  // Phone: a tap (not a scroll) opens it; the native picker is not shown.
  let tx=0,ty=0,tsel=null;
  D.addEventListener("touchstart",e=>{
    const t=e.touches[0];tsel=null;if(!t)return;
    if(cur&&!cur.pop.contains(e.target)&&e.target!==cur.sel)close();
    const s=e.target&&e.target.closest&&e.target.closest("select");
    if(want(s)){tsel=s;tx=t.clientX;ty=t.clientY}
  },{capture:true,passive:true});
  D.addEventListener("touchend",e=>{
    const s=tsel;tsel=null;if(!s)return;
    const t=e.changedTouches[0];if(!t||Math.abs(t.clientX-tx)>10||Math.abs(t.clientY-ty)>10)return;
    if(!want(s))return;
    e.preventDefault();
    if(cur&&cur.sel===s){close(true);return}
    open(s);
  },{capture:true,passive:false});
  // Keyboard: a letter / number on a focused drop-down starts the search with it;
  // Space, F4 or Alt+↓ opens the list. Enter still goes to the next field (erp-keys.js).
  D.addEventListener("keydown",e=>{
    const s=e.target;
    if(!s||s.tagName!=="SELECT"||e.defaultPrevented||e.isComposing||!want(s))return;
    const k=e.key;
    if(k.length===1&&k!==" "&&!e.ctrlKey&&!e.metaKey&&!e.altKey){e.preventDefault();open(s,k)}
    else if(k===" "||k==="F4"||(e.altKey&&(k==="ArrowDown"||k==="ArrowUp"))){e.preventDefault();open(s)}
  },true);
  addEventListener("resize",()=>cur&&place());
  if(window.visualViewport){visualViewport.addEventListener("resize",()=>cur&&place());visualViewport.addEventListener("scroll",()=>cur&&place())}
  D.addEventListener("scroll",e=>{if(cur&&!cur.pop.contains(e.target))place()},true);

  window.LWBSelect={open,close,want,MIN};
})();
