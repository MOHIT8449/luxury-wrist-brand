/* LUXURY WRIST BRAND ERP — keyboard first, on every page (Tally style).
   Mohit (4 Nov 2026): 95% of the work must be done with Tab, Enter and the arrows, not the mouse.
   Loaded by erp-shell.js (all ERP pages); cashbook.html loads it directly.
   Pages that already handle a key themselves keep doing it: every rule here runs last
   (window, bubble phase) and does nothing when the page called preventDefault.

   Enter        next field (Tally style). Last field: Save / Submit button gets the focus
                (inside a <form> the form submits, as before). Shift+Enter = previous field.
                Ctrl+Enter in a textarea = next field. In a search box: go into the list.
   ↑ ↓          move between the rows of a list / table (rows and cards you can click
                get the focus too); Enter or Space opens the row.
   ← →          move between buttons that sit in one row (tabs, chips, Today / 7 Days ...).
   / or Ctrl+K  page search            Alt+M  Module Search      Alt+N  "+ New" button
   Ctrl+S/Alt+S Save / Submit          Alt+1..9  tab 1..9         Alt+H  Dashboard
   ? or F1      list of shortcuts      Esc  closes the popup on top (esc-close.js)
   A popup that opens puts the cursor in its first field; Tab stays inside the popup and the
   cursor goes back where it was when the popup closes.
   Opt out: data-keys="off" on an element (or a parent) leaves its keys to the page. */
(function(){
  if(window.LWBKeys)return;
  const D=document;
  const FIELD='input:not([type=hidden]):not([type=button]):not([type=submit]):not([type=reset]):not([type=image]):not([type=file]),select,textarea';
  const TABBABLE='a[href],button,input:not([type=hidden]),select,textarea,summary,[tabindex],[contenteditable="true"]';
  const SEARCH=/search|find|filter|खोज|ढूं?ढ|सर्च/i;
  const off=el=>!!(el&&el.closest&&el.closest('[data-keys="off"]'));
  function shown(el){
    if(!el||!el.isConnected||el.hidden)return false;
    if(!el.getClientRects().length)return false;
    const cs=getComputedStyle(el);return cs.visibility!=="hidden"&&cs.display!=="none";
  }
  function usable(el){
    if(!el||el.disabled||el.tabIndex<0||!shown(el))return false;
    if(el.closest("[inert],[aria-hidden=true],fieldset[disabled]"))return false;
    return true;
  }
  const isField=el=>!!(el&&el.matches&&el.matches(FIELD));
  const typing=el=>!!(el&&((el.tagName==="INPUT"&&!/^(checkbox|radio|button|submit|reset|range|color)$/i.test(el.type))||el.tagName==="SELECT"||el.tagName==="TEXTAREA"||el.isContentEditable));
  const isSearch=el=>!!(el&&el.tagName==="INPUT"&&(el.type==="search"||SEARCH.test((el.placeholder||"")+" "+(el.id||"")+" "+(el.name||"")+" "+(el.getAttribute("aria-label")||"")+" "+(typeof el.className==="string"?el.className:""))));
  // A search box over a list (not a name picker inside a form): the next thing after it is a list row,
  // not another field (filter drop-downs and ticks in between are skipped).
  function listSearch(el){
    if(!isSearch(el)||el.form||el.getAttribute("list")||el.getAttribute("role")==="combobox")return false;
    const all=tabbables(scopeOf(el));
    for(const x of all.slice(all.indexOf(el)+1)){
      if(rowOf(x))return true;
      if(isField(x)&&x.tagName!=="SELECT"&&!/^(checkbox|radio|date)$/i.test(x.type)&&writable(x)&&!isSearch(x))return false;
    }
    return false;
  }
  const txt=el=>String(el.value&&el.tagName==="INPUT"?el.value:el.textContent||"").replace(/\s+/g," ").trim();
  const main=()=>D.querySelector(".erp-main main, main.erp-main, .erp-main")||D.querySelector("main")||D.body;
  const chrome=el=>!!(el&&el.closest(".erp-top,.erp-side,.erp-bnav"));

  // The popup on top (backdrop / dialog), not a dropdown list. Uses esc-close.js when loaded.
  function popup(){
    try{
      const m=D.querySelector("dialog:modal");if(m)return m;
      const p=window.LWBEsc&&LWBEsc.info&&LWBEsc.info();
      if(p&&(p.kind==="overlay"||p.kind==="dialog"))return p.el;
    }catch(e){}
    return null;
  }
  function scopeOf(el){
    const p=popup();if(p&&p.contains(el))return p;
    const f=el.form||el.closest("form,dialog,[role=dialog]");if(f)return f;
    if(chrome(el))return el.closest(".erp-top,.erp-side,.erp-bnav");
    return main();
  }
  function tabbables(root,fieldsOnly){
    const out=[];
    for(const el of root.querySelectorAll(fieldsOnly?FIELD:TABBABLE)){
      if(!usable(el))continue;
      if(root===main()&&chrome(el))continue;
      if(el.tagName==="INPUT"&&el.type==="radio"&&!el.checked&&root.querySelector('input[type=radio][name="'+CSS.escape(el.name)+'"]:checked'))continue;
      out.push(el);
    }
    return out;
  }
  const writable=el=>!(el.readOnly&&el.tagName!=="SELECT");

  // Save / Submit button of a scope (best guess from type, class and text).
  const GOOD=/(^|\s|[^a-z])(save|submit|update|book|confirm|create|add|post|apply|send|ok|done|start|next|go|proceed|approve|record|generate|सेव|जमा|पक्का|आगे)(\b|$)/i;
  const BAD=/(cancel|close|back|delete|remove|clear|reset|discard|undo|print|excel|export|download|logout|×|✕|✖|रद्द|बंद|हटा)/i;
  function primary(root,after,before){
    let best=null,bs=0;
    for(const b of root.querySelectorAll('button,input[type=submit],input[type=button],[role=button]')){
      if(!usable(b)||(root===main()&&chrome(b)))continue;
      if(before&&!(after.compareDocumentPosition(b)&Node.DOCUMENT_POSITION_FOLLOWING&&b.compareDocumentPosition(before)&Node.DOCUMENT_POSITION_FOLLOWING))continue;
      const t=txt(b)+" "+(b.getAttribute("aria-label")||"");if(BAD.test(t))continue;
      const cls=typeof b.className==="string"?b.className:"";
      let s=0;
      if(b.type==="submit"&&b.form)s+=3;
      if(/(^|[-_ ])(pri|primary|save|submit|main|ok|go|cta|btn-dark|dark|green|gold)([-_ ]|$)/i.test(cls))s+=2;
      if(GOOD.test(t))s+=2;
      if(after&&(after.compareDocumentPosition(b)&Node.DOCUMENT_POSITION_FOLLOWING))s+=1;
      if(s>bs){bs=s;best=b}
    }
    if(before&&(bs<5||/^\s*[+＋]/.test(txt(best))))return null; // in between: only a clear Save / Submit
    return bs>=2?best:null;
  }
  function focus(el,select){
    if(!el)return false;
    try{el.focus({preventScroll:true})}catch(e){el.focus()}
    try{el.scrollIntoView({block:"nearest",inline:"nearest"})}catch(e){}
    if(select&&el.select&&/^(text|search|number|tel|email|url|)$/i.test(el.type||""))try{el.select()}catch(e){}
    return D.activeElement===el;
  }

  // Rows of a list / table: the row itself (when it opens something) or a control inside it.
  function rowOf(el){
    const r=el.closest('tbody tr,[role=row],li,[data-lwbk-row]');
    if(!r||chrome(r))return null;
    return r;
  }
  function rowStops(r){return [r,...r.querySelectorAll(TABBABLE)].filter(x=>usable(x)&&x.tabIndex>=0&&(x!==r||x.hasAttribute("tabindex")))}
  function rowSibling(r,dir){
    const all=[...(r.parentElement?r.parentElement.children:[])].filter(x=>x.matches&&x.matches(r.tagName)&&shown(x));
    let i=all.indexOf(r)+dir;
    for(;i>=0&&i<all.length;i+=dir)if(rowStops(all[i]).length)return all[i];
    return null;
  }
  function moveRow(from,dir){
    const r=rowOf(from);if(!r)return false;
    const n=rowSibling(r,dir);if(!n)return false;
    const st=rowStops(r),k=Math.max(0,st.indexOf(from)),ns=rowStops(n);
    return focus(ns[Math.min(k,ns.length-1)]);
  }
  // First row of the list that comes after a search box.
  function firstRowAfter(el){
    const root=scopeOf(el);
    for(const r of root.querySelectorAll('tbody tr,[role=row],li,[data-lwbk-row]')){
      if(!(el.compareDocumentPosition(r)&Node.DOCUMENT_POSITION_FOLLOWING)||chrome(r)||!shown(r))continue;
      const s=rowStops(r);if(s.length)return s[0];
    }
    // A card grid / button list right after the box.
    const all=tabbables(root),i=all.indexOf(el);
    return all.slice(i+1).find(x=>!isField(x))||null;
  }

  // Things you click that are not buttons (cards, rows, chips): Tab reaches them, Enter opens.
  const CLICKY='[onclick],[data-href],.erp-drill,.clickable,[data-open],[data-id][class*=card],[data-id][class*=row]';
  const NATIVE='a[href],button,input,select,textarea,summary,label,option,[tabindex],[contenteditable="true"]';
  function mark(el){
    el.tabIndex=0;el.setAttribute("data-lwbk","");
    if(!el.hasAttribute("role")&&el.tagName!=="TR"&&el.tagName!=="LI")el.setAttribute("role","button");
    if(el.tagName==="TR"||el.tagName==="LI")el.setAttribute("data-lwbk-row","");
  }
  function scanClicky(root){
    if(!root||root.nodeType!==1)return;
    const list=[...(root.matches(CLICKY)?[root]:[]),...root.querySelectorAll(CLICKY)];
    for(const el of list){
      if(el.matches(NATIVE)||el.closest("a[href],button,label,summary,svg")||chrome(el))continue;
      if(el===D.body||el.classList.contains("erp-main")||!shown(el))continue;
      mark(el);
    }
    // Pointer cursor on a block = it opens something (the outermost one only; cursor is inherited).
    const tags=root.querySelectorAll("tr,li,div,article,section,td,span");
    if(tags.length>4000)return;
    for(const el of tags){
      if(el.hasAttribute("data-lwbk")||el.matches(NATIVE)||el.closest(NATIVE+",svg,.erp-top,.erp-side,.erp-bnav"))continue;
      const cs=getComputedStyle(el);if(cs.cursor!=="pointer")continue;
      const p=el.parentElement;if(p&&getComputedStyle(p).cursor==="pointer")continue;
      if(el.querySelector("a[href],button,input,select,textarea")&&el.tagName!=="TR")continue;
      if(el.getBoundingClientRect().width<24)continue;
      mark(el);
    }
  }
  let scanT=0,pend=[];
  const mo=new MutationObserver(recs=>{
    for(const r of recs)for(const n of r.addedNodes)if(n.nodeType===1)pend.push(n);
    if(!scanT)scanT=setTimeout(()=>{scanT=0;const p=pend;pend=[];
      if(p.length>60)scanClicky(D.body);else p.forEach(n=>n.isConnected&&scanClicky(n));
      watchPopup();
    },250);
  });

  // A new popup: cursor into its first field; when it closes, back where it was.
  let pop=null,back=null,hist=[];
  D.addEventListener("focusin",e=>{const t=e.target;if(t&&t!==D.body&&t.nodeType===1){hist=hist.filter(x=>x!==t);hist.push(t);if(hist.length>6)hist.shift()}},true);
  // Phone keyboard: the Enter key shows "Next" (go to the next field), "Done" on the last field before
  // Save, "Search" in a search box. Pages that set enterkeyhint themselves keep theirs.
  D.addEventListener("focusin",e=>{
    const t=e.target;
    if(!isField(t)||t.tagName==="SELECT"||t.tagName==="TEXTAREA"||off(t)||(t.hasAttribute("enterkeyhint")&&!t.dataset.ekh))return;
    if(/^(checkbox|radio|date|time|datetime-local|month|file)$/i.test(t.type))return;
    let h="next";
    if(isSearch(t)&&!t.form&&!t.getAttribute("list"))h="search";
    else{const all=tabbables(scopeOf(t),true).filter(x=>x.tagName!=="SELECT"&&writable(x)&&!/^(checkbox|radio|file)$/i.test(x.type));if(all[all.length-1]===t)h="done"}
    t.setAttribute("enterkeyhint",h);t.dataset.ekh="1";
  },true);
  function watchPopup(){
    const p=popup();
    if(p&&p!==pop){
      pop=p;const a=D.activeElement;
      back=hist.slice().reverse().find(x=>x.isConnected&&!p.contains(x))||null;
      if(!p.contains(a)){
        const f=tabbables(p,true).find(x=>writable(x)&&x.type!=="checkbox"&&x.type!=="radio"&&!x.matches("[type=date]"))
          ||primary(p)||tabbables(p).find(x=>!/^(×|✕|✖|x)$/i.test(txt(x)))||tabbables(p)[0];
        if(f)focus(f,true);
        else{if(!p.hasAttribute("tabindex"))p.tabIndex=-1;focus(p)}
      }
    }else if(!p&&pop){
      pop=null;
      const a=D.activeElement;
      if(back&&back.isConnected&&usable(back)&&(!a||a===D.body||!a.isConnected||!shown(a)))focus(back);
      back=null;
    }
  }
  ["click","keyup"].forEach(t=>window.addEventListener(t,()=>{[40,200,600].forEach(ms=>setTimeout(watchPopup,ms))},true));

  // ---------- shortcuts ----------
  function pageSearch(){
    const p=popup(),roots=p?[p]:[main()];
    for(const r of roots){
      const s=[...r.querySelectorAll("input")].filter(x=>usable(x)&&isSearch(x)&&!chrome(x));
      if(s.length)return s[0];
    }
    return p?null:D.querySelector(".erp-top .erp-search input");
  }
  function newButton(){
    const r=popup()||main();
    return [...r.querySelectorAll("button,a[href],[role=button]")].find(b=>usable(b)&&!chrome(b)&&/^(\+|＋|➕)\s*\S|^(new|add)\s/i.test(txt(b))&&txt(b).length<40)||null;
  }
  function saveButton(){
    const a=D.activeElement,p=popup();
    const r=p||(a&&a!==D.body&&a.closest&&a.closest("form"))||main();
    const sv=[...r.querySelectorAll("button,input[type=submit],[role=button]")].filter(b=>usable(b)&&!(r===main()&&chrome(b))&&!BAD.test(txt(b)));
    return sv.find(b=>/(^|\s|💾)(save|submit|update|सेव)/i.test(txt(b)))||primary(r,a&&a!==D.body?a:null);
  }
  function tabGroups(){
    const r=popup()||main();
    const g=[...r.querySelectorAll('[role=tablist],[class*=tabs],[class*=tab-bar],[class*=seg],[class*=pills]')].filter(x=>shown(x)&&!chrome(x));
    for(const x of g){const b=[...x.querySelectorAll('[role=tab],button,a[href]')].filter(usable);if(b.length>=2)return b}
    return [];
  }
  // Buttons in one row: ← → between them.
  function rowButtons(el){
    const p=el.parentElement;if(!p)return [];
    const kids=[...p.children].filter(x=>x.matches('button,a[href],[role=tab],[role=button],[data-lwbk]')&&usable(x));
    return kids.length>=2&&kids.includes(el)?kids:[];
  }

  // The list of keys (? popup and keyboard-shortcuts.html). Keys in one group are pressed together
  // ("Ctrl+S"); groups are alternatives. COMMON works on every ERP page.
  const COMMON=[
    [["Enter"],"Next field · on the last field: Save button"],[["Shift+Enter"],"Previous field"],
    [["Tab","Shift+Tab"],"Forward / back"],[["↑","↓"],"Move up / down the rows of a list or table"],[["Enter","Space"],"Open a row or card"],
    [["↑","↓","Enter"],"Pick from a name list (party / SKU)"],
    [["←","→"],"Buttons in one row (Today, 7 Days, tabs)"],[["/","Ctrl+K"],"Page search"],[["Alt+M"],"Module Search (open any page)"],
    [["Alt+N"],"+ New"],[["Ctrl+S","Alt+S"],"Save / Submit"],[["Alt+1…9"],"Tab 1 … 9"],
    [["Alt+H"],"Dashboard"],[["Esc"],"Close the popup"],[["?","F1"],"List of shortcuts"]];
  // Keys a page adds on top of COMMON (from the page's own code). r = only for these roles.
  const PAGES={
    "dashboard.html":[[["↑","↓","Enter"],"Top search: pick a page / party and open it"],[["Esc"],"Clear the search"]],
    "order-entry.html":[[["↑","↓","Enter"],"Pick the party"],[["Enter"],"Next box in the SKU line · last box: new SKU line"],
      [["Tab"],"After Rate: new SKU line"],[["Enter"],"On an empty last line: go to Submit"],[["Esc"],"Save Draft (if a popup / list is open, it only closes)"]],
    "goods-inward.html":[[["↓","Enter"],"Open the SKU search list"],[["↑","↓","Enter"],"Pick the SKU"],[["Enter"],"On the last line's Amount: new SKU line"]],
    "warehouse-orders.html":[[["↑","↓","Enter"],"Pick from the SKU / PO list"],[["Esc"],"Close the list"]],
    "bank-statement.html":[[["↓","Enter"],"From the search to the first entry"],[["↑","↓"],"Entry up / down"],[["Home","End"],"First / last entry"],
      [["PgUp","PgDn"],"10 entries up / down"],[["Enter"],"Book the entry",["admin"]],[["Space"],"Tick the entry",["admin"]],
      [["Ctrl+A"],"Tick all entries",["admin"]],[["B"],"Ticked entries: choose Book type",["admin"]],[["M"],"See the matching party / bill",["admin"]]],
    "accounts-dashboard.html":[[["↑","↓","Enter"],"Pick the party in an entry"]],
    "party-billing.html":[[["Enter"],"After bill no. / amount: Save"]],
    "complaint-box.html":[[["Enter","Space"],"Open / close a complaint"]],
    "tasks.html":[[["Enter","Space"],"Open / close a task"]]
  };
  const forRole=(rows,role)=>(rows||[]).filter(r=>!r[2]||!role||r[2].includes(role));
  const keys=g=>g.map(k=>'<span class="lwbk-g">'+k.split("+").map(x=>"<kbd>"+x+"</kbd>").join("+")+'</span>').join(" ");
  const table=rows=>'<table>'+rows.map(r=>'<tr><td>'+keys(r[0])+'</td><td>'+r[1]+'</td></tr>').join("")+'</table>';
  const herePage=()=>(location.pathname.split("/").pop()||"dashboard.html");
  const myRole=()=>{const s=D.querySelector(".erp-top .erp-user .who small");return s?s.textContent.trim().toLowerCase():""};

  function help(){
    if(D.getElementById("lwbk-help"))return;
    const pg=forRole(PAGES[herePage()],myRole());
    const b=D.createElement("div");b.id="lwbk-help";b.className="lwbk-back";b.setAttribute("role","dialog");b.setAttribute("aria-label","Keyboard shortcuts");
    b.innerHTML='<div class="lwbk-box"><div class="lwbk-hd"><b>⌨ Keyboard shortcuts</b><button type="button" class="lwbk-x" aria-label="Close">×</button></div>'+
      (pg.length?'<div class="lwbk-sub">This page</div>'+table(pg)+'<div class="lwbk-sub">Every page</div>':'')+table(COMMON)+
      (/keyboard-shortcuts\.html$/.test(location.pathname)?'':'<a class="lwbk-all" href="keyboard-shortcuts.html">See shortcuts for all your pages →</a>')+'</div>';
    const close=()=>b.remove();
    b.addEventListener("click",e=>{if(e.target===b||e.target.closest(".lwbk-x"))close()});
    b.addEventListener("keydown",e=>{if(e.key==="Escape"){e.preventDefault();e.stopPropagation();close()}});
    D.body.appendChild(b);setTimeout(watchPopup,0);
  }

  // A page's own name picker took the Enter (it filled the picked name in): then go on to the next field.
  let pick=null;
  window.addEventListener("keydown",e=>{
    pick=null;const t=e.target;
    if(e.key==="Enter"&&!e.shiftKey&&!e.ctrlKey&&!e.altKey&&!e.metaKey&&isField(t)&&t.tagName!=="TEXTAREA"&&t.tagName!=="SELECT"&&!off(t))pick={t,v:t.value,p:popup()};
  },true);
  window.addEventListener("keydown",e=>{
    const pk=pick;pick=null;
    if(pk&&e.defaultPrevented&&e.key==="Enter")setTimeout(()=>{
      const t=pk.t;
      if(D.activeElement!==t||t.value===pk.v||!t.value||t.getAttribute("aria-expanded")==="true"||popup()!==pk.p||chrome(t))return;
      const fl=tabbables(scopeOf(t),true),nx=fl.slice(fl.indexOf(t)+1).find(writable);
      if(nx)focus(nx,true);
    },30);
  });
  window.addEventListener("keydown",e=>{
    if(e.defaultPrevented||e.isComposing||e.keyCode===229)return;
    const t=D.activeElement&&D.activeElement!==D.body?D.activeElement:null,k=e.key;
    if(t&&off(t))return;
    const inType=typing(t);

    // Shortcuts that work everywhere.
    if((e.ctrlKey||e.metaKey)&&!e.altKey&&(k==="s"||k==="S")){const b=saveButton();if(b){e.preventDefault();b.click()}return}
    if((e.ctrlKey||e.metaKey)&&!e.altKey&&(k==="k"||k==="K")){const s=pageSearch();if(s){e.preventDefault();focus(s,true)}return}
    if(e.altKey&&!e.ctrlKey&&!e.metaKey){
      const c=(e.code||"").replace(/^Key|^Digit/,"");
      if(c==="M"){const s=D.querySelector(".erp-top .erp-search input");if(s&&usable(s)){e.preventDefault();focus(s,true)}}
      else if(c==="N"){const b=newButton();if(b){e.preventDefault();b.click()}}
      else if(c==="S"){const b=saveButton();if(b){e.preventDefault();b.click()}}
      else if(c==="H"){if(!/dashboard\.html$/.test(location.pathname)){e.preventDefault();location.href="dashboard.html"}}
      else if(/^[1-9]$/.test(c)){const g=tabGroups(),b=g[+c-1];if(b){e.preventDefault();b.click();focus(b)}}
      return;
    }
    if(k==="F1"){e.preventDefault();help();return}

    // Tab from nowhere: start in the page, not in the side menu.
    if(k==="Tab"&&!e.ctrlKey){
      const p=popup();
      if(p){ // keep Tab inside the popup
        const all=tabbables(p);if(!all.length)return;
        const i=all.indexOf(t);
        if(i<0||(!e.shiftKey&&i===all.length-1)||(e.shiftKey&&i===0)){e.preventDefault();focus(e.shiftKey?all[all.length-1]:all[0])}
        return;
      }
      if(!t&&!e.shiftKey){const f=tabbables(main())[0];if(f){e.preventDefault();focus(f)}}
      return;
    }

    if(k==="Enter"&&!e.altKey){
      if(!t)return;
      if(t.tagName==="TEXTAREA"&&!(e.ctrlKey||e.metaKey))return;
      if(t.hasAttribute("data-lwbk")&&!e.ctrlKey){e.preventDefault();t.click();return}
      if(!isField(t)||e.ctrlKey&&t.tagName!=="TEXTAREA")return;
      if(t.getAttribute("aria-expanded")==="true")return; // its own list is open
      if(chrome(t))return;
      const sc=scopeOf(t);
      if(listSearch(t)&&!e.shiftKey){const r=firstRowAfter(t);if(r){e.preventDefault();focus(r)}return}
      const fl=tabbables(sc,true),i=fl.indexOf(t);if(i<0)return;
      if(e.shiftKey){const pv=fl.slice(0,i).reverse().find(writable);if(pv){e.preventDefault();focus(pv,true)}return}
      const nx=fl.slice(i+1).find(writable);
      if(nx){
        // A Save button of this block sits before the next block's fields: stop on it first.
        const sv=primary(sc,t,nx);
        e.preventDefault();focus(sv||nx,!sv);return;
      }
      // Last field.
      if(t.form&&t.tagName!=="SELECT"&&t.form.querySelector("[type=submit],button:not([type])"))return; // the form submits, as before
      const b=primary(sc,t);if(b){e.preventDefault();focus(b)}
      return;
    }
    if(k===" "&&t&&t.hasAttribute("data-lwbk")&&!inType){e.preventDefault();t.click();return}

    if(e.ctrlKey||e.metaKey)return;
    if(inType){
      if(k==="ArrowDown"&&listSearch(t)&&!t.getAttribute("aria-expanded")&&!chrome(t)){const r=firstRowAfter(t);if(r&&!isField(r)){e.preventDefault();focus(r)}}
      else if(k==="Escape"&&isSearch(t)&&!popup()&&!e.lwbPopup&&!chrome(t)&&t.value===""){t.blur()}
      return;
    }
    if(k==="/"||k==="?"){
      e.preventDefault();
      if(k==="?")help();else{const s=pageSearch();if(s)focus(s,true)}
      return;
    }
    if(!t)return;
    if(k==="ArrowDown"||k==="ArrowUp"){if(moveRow(t,k==="ArrowDown"?1:-1))e.preventDefault();return}
    if(k==="ArrowRight"||k==="ArrowLeft"){
      const g=rowButtons(t);if(!g.length)return;
      const i=g.indexOf(t),n=g[(i+(k==="ArrowRight"?1:-1)+g.length)%g.length];
      e.preventDefault();focus(n);return;
    }
  });

  const css=D.createElement("style");css.id="lwbk-css";
  css.textContent=`
[data-lwbk]{outline:none}
[data-lwbk]:focus-visible,tr[data-lwbk]:focus-visible,:where(body) :is(button,a,summary,[role=button],[role=tab]):focus-visible{outline:2px solid #c9b26a!important;outline-offset:2px;box-shadow:0 0 0 4px rgba(201,178,106,.25)}
tr:focus-within>td,tr[data-lwbk]:focus>td,[data-lwbk-row]:focus-within{background:#fff8e1!important}
tr[data-lwbk]:focus-visible{outline-offset:-2px}
.lwbk-back{position:fixed;inset:0;z-index:6000;background:rgba(0,30,35,.48);display:grid;place-items:center;padding:16px}
.lwbk-box{background:#fff;border-radius:12px;max-width:440px;width:100%;max-height:calc(100vh - 32px);overflow:auto;padding:12px 14px;box-shadow:0 18px 50px rgba(0,0,0,.25);font:13px/1.35 system-ui,-apple-system,"Segoe UI",sans-serif;color:#0b2b30}
.lwbk-hd{display:flex;align-items:center;justify-content:space-between;margin-bottom:6px;font-size:15px}
.lwbk-x{border:0;background:#f1f3f4;border-radius:8px;width:30px;height:30px;padding:0;font-size:20px;line-height:30px;color:#0b2b30;cursor:pointer}
.lwbk-box table{width:100%!important;min-width:0!important;border-collapse:collapse}
.lwbk-box td{padding:5px 4px;border-top:1px solid #eef0f1;vertical-align:top}
.lwbk-box td:first-child{white-space:nowrap!important;width:1%;padding-right:10px}
.lwbk-box td:last-child{white-space:normal!important;overflow-wrap:anywhere}
.lwbk-g{display:inline-block;white-space:nowrap}
.lwbk-sub{margin:8px 0 2px;font-size:11.5px;font-weight:700;color:#8a7430;text-transform:uppercase;letter-spacing:.4px}
.lwbk-all{display:block;margin-top:8px;padding:8px;border-radius:8px;background:#f7f3e6;color:#0b2b30;font-weight:600;text-align:center;text-decoration:none}
.lwbk-all:hover{background:#efe6c9}
.lwbk-box kbd{display:inline-block;min-width:18px;padding:1px 6px;border:1px solid #cfd6d8;border-bottom-width:2px;border-radius:5px;background:#f7f9f9;font:600 12px/1.4 ui-monospace,Consolas,monospace;text-align:center}
@media (pointer:coarse){.lwbk-tip{display:none!important}}
.lwbk-tip{position:fixed;right:14px;bottom:14px;z-index:5500;background:#0b2b30;color:#fff;border-radius:10px;padding:8px 12px;font:13px/1.3 system-ui,sans-serif;box-shadow:0 8px 24px rgba(0,0,0,.2);display:flex;gap:10px;align-items:center}
.lwbk-tip button{border:0;background:#c9b26a;color:#0b2b30;border-radius:7px;padding:4px 9px;font-weight:700;cursor:pointer}`;

  function start(){
    D.head.appendChild(css);
    mo.observe(D.body,{childList:true,subtree:true});
    setTimeout(()=>scanClicky(D.body),300);
    setTimeout(()=>scanClicky(D.body),1500);
    // Desktop: the cursor starts in the page search, so typing works at once.
    if(matchMedia("(pointer:fine)").matches)setTimeout(()=>{
      if(D.activeElement&&D.activeElement!==D.body)return;
      const s=pageSearch();if(s&&!chrome(s)&&!popup())focus(s);
    },900);
    // One-time tip on a computer.
    let seen="1";try{seen=localStorage.getItem("lwbk-tip")}catch(e){}
    if(!seen&&matchMedia("(pointer:fine)").matches&&!/login\.html$/.test(location.pathname)){
      const tip=D.createElement("div");tip.className="lwbk-tip";
      tip.innerHTML='<span>⌨ Do all work from the keyboard: press <b>?</b></span><button type="button">OK</button>';
      const done=()=>{tip.remove();try{localStorage.setItem("lwbk-tip","1")}catch(e){}};
      tip.querySelector("button").onclick=done;setTimeout(done,12000);
      D.body.appendChild(tip);
    }
  }
  if(D.readyState==="loading")D.addEventListener("DOMContentLoaded",start);else start();
  window.LWBKeys={help,COMMON,PAGES,forRole,keysHtml:keys,scan:()=>scanClicky(D.body),next:el=>{const sc=scopeOf(el),fl=tabbables(sc,true);return fl[fl.indexOf(el)+1]||null}};
})();
