/* LUXURY WRIST BRAND ERP — Esc closes the popup on top (every page).
   Mohit (3 Nov 2026): on any page, Esc must close an open popup / dropdown / drawer,
   like Back: the top one first, one per press. Pages that already close their own popup
   on Esc keep doing it; this only steps in when a popup is still open after them.
   Loaded by erp-shell.js (all ERP pages); cashbook.html loads it directly.
   event.lwbPopup is set on the Esc keydown when a popup is open, so page shortcuts
   (e.g. order-entry Esc = Save Draft) can skip themselves then. */
(function(){
  if(window.LWBEsc)return;
  const W=()=>innerWidth||document.documentElement.clientWidth,H=()=>innerHeight||document.documentElement.clientHeight;
  const DROP=/(^|[-_ ])(list|lists|options?|menu|menus|results?|drop|dropdown|suggest|suggestions|popover|pop|picker|panel|clist|ac)([-_ ]|$)/i;
  const SKIP=/(^|[-_ ])(erp-top|erp-topbar|erp-side|erp-bnav|toasts?|bottom-bar|dnav|selbar|actions)([-_ ]|$)/i;
  function shown(el){
    if(!el||!el.isConnected||el.hidden)return false;
    const cs=getComputedStyle(el);
    if(cs.display==="none"||cs.visibility==="hidden"||+cs.opacity===0)return false;
    const r=el.getBoundingClientRect();return r.width>1&&r.height>1;
  }
  function names(el){return (typeof el.className==="string"?el.className:"")+" "+(el.id||"")}
  // Stacking order: z-index of each positioned ancestor (outermost first), then DOM order.
  function zPath(el){
    const p=[];
    for(let n=el;n&&n.nodeType===1;n=n.parentElement){
      const cs=getComputedStyle(n);
      if(cs.position!=="static"&&cs.zIndex!=="auto")p.unshift(+cs.zIndex||0);
    }
    return p;
  }
  function above(a,b){
    const pa=a.z,pb=b.z;
    for(let i=0;i<Math.min(pa.length,pb.length);i++)if(pa[i]!==pb[i])return pa[i]>pb[i];
    if(a.el.contains(b.el))return false;if(b.el.contains(a.el))return true;
    return !!(b.el.compareDocumentPosition(a.el)&Node.DOCUMENT_POSITION_FOLLOWING);
  }
  // Every open popup: big fixed backdrops / drawers, role=dialog boxes, non-modal <dialog open>,
  // <details open> menus and positioned dropdown lists.
  function popups(){
    const out=[],w=W(),h=H();
    for(const el of document.body.querySelectorAll("*")){
      const tag=el.tagName;
      if(tag==="SCRIPT"||tag==="STYLE"||tag==="svg"||tag==="path"||tag==="OPTION"||tag==="TR"||tag==="TD")continue;
      if(tag==="DIALOG"){if(el.open)out.push({el,kind:"dialog"});continue}
      if(tag==="DETAILS"){if(el.open&&el.querySelector(":scope>summary")&&/menu|drop|more|pop/i.test(names(el)))out.push({el,kind:"details"});continue}
      const cs=getComputedStyle(el);
      if(cs.position!=="fixed"&&cs.position!=="absolute")continue;
      if(cs.display==="none"||cs.visibility==="hidden"||cs.pointerEvents==="none"||+cs.opacity===0||el.hidden)continue;
      const nm=names(el);if(SKIP.test(nm))continue;
      const r=el.getBoundingClientRect();if(r.width<2||r.height<2)continue;
      const role=(el.getAttribute("role")||"").toLowerCase();
      if(cs.position==="fixed"&&r.width>=w*.5&&r.height>=h*.5){out.push({el,kind:"overlay"});continue}
      if(role==="dialog"||role==="alertdialog"||el.getAttribute("aria-modal")==="true"){out.push({el,kind:"overlay"});continue}
      if(cs.zIndex!=="auto"&&(role==="listbox"||role==="menu"||DROP.test(nm))&&!el.closest("dialog:not([open])"))out.push({el,kind:"drop"});
    }
    // A list inside a found popup is the popup's own; a popup nested in another found one stays separate.
    return out.filter(p=>!(p.kind==="drop"&&out.some(q=>q!==p&&q.kind==="drop"&&q.el.contains(p.el))));
  }
  function topPopup(){
    if(document.body.classList.contains("side-open"))return null; // the shell closes its own side menu
    if(document.querySelector("dialog:modal"))return null;          // the browser closes a modal <dialog>
    let best=null;
    for(const p of popups()){p.z=zPath(p.el);if(!best||above(p,best))best=p}
    return best;
  }
  const CLOSE_TXT=/^(×|✕|✖|✗|╳|x|close|cancel|back|← ?back|बंद|बंद करें|रद्द|रद्द करें|वापस)$/i;
  function closeButton(root){
    const all=[...root.querySelectorAll("button,a,[role=button],input[type=button],.close,.x")].filter(b=>shown(b)&&!b.disabled);
    const txt=b=>String(b.value||b.textContent||"").replace(/[‍️]/g,"").replace(/\s+/g," ").trim();
    const lab=b=>((b.getAttribute("aria-label")||"")+" "+(b.title||"")).toLowerCase();
    return all.find(b=>b.hasAttribute("data-close")||b.hasAttribute("data-dismiss"))
      ||all.find(b=>/^(×|✕|✖|✗|╳|x)$/i.test(txt(b))||/(^|\s)(close|बंद)/.test(lab(b)))
      ||all.find(b=>/(^|[-_ ])(close|btn-close|x-close|closebtn)([-_ ]|$)/i.test(names(b)))
      ||all.find(b=>CLOSE_TXT.test(txt(b))||(txt(b).length<=18&&/^(✕|✖|×)?\s*(close|cancel)\b/i.test(txt(b))));
  }
  // Runs a step and says whether it changed anything (so a fade-out close is not closed twice).
  function changed(el,fn){
    const mo=new MutationObserver(()=>{});
    mo.observe(document.body,{subtree:true,childList:true,attributes:true});
    try{fn()}catch(e){}
    const hit=mo.takeRecords().length>0||!shown(el);mo.disconnect();return hit;
  }
  function hide(el){
    for(const c of ["open","show","shown","active","visible","on","is-open"])if(el.classList.contains(c)){el.classList.remove(c);if(!shown(el))return true}
    if(el.style.display&&el.style.display!=="none"){el.style.display="none";return true}
    el.hidden=true;if(!shown(el))return true;
    el.hidden=false;return false;
  }
  function closePopup(p){
    const el=p.el;
    if(p.kind==="dialog"){el.close();return true}
    if(p.kind==="details"){el.open=false;return true}
    if(p.kind==="overlay"){
      const b=closeButton(el);
      if(b&&changed(el,()=>b.click()))return true;
      // Many popups close on a tap outside the box (on the dark backdrop).
      if(changed(el,()=>{for(const t of ["pointerdown","mousedown","mouseup","click"])el.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,view:window}))}))return true;
    }
    return hide(el);
  }
  // Capture (first): find the top popup and watch the page. Bubble (last): if the page's own
  // Esc code did nothing (no preventDefault, no DOM change), close that popup.
  let seen=null,watch=null;
  const stop=()=>{if(watch){watch.disconnect();watch=null}};
  window.addEventListener("keydown",e=>{
    stop();seen=null;
    if(e.key!=="Escape"&&e.key!=="Esc")return;
    seen=topPopup();if(!seen)return;
    e.lwbPopup=seen.el;
    watch=new MutationObserver(()=>{});
    watch.observe(document.documentElement,{subtree:true,childList:true,attributes:true});
  },true);
  window.addEventListener("keydown",e=>{
    if((e.key!=="Escape"&&e.key!=="Esc")||!seen)return;
    const p=seen,acted=watch&&watch.takeRecords().length>0;seen=null;stop();
    if(e.defaultPrevented||e.isComposing||acted)return;      // the page already handled this Esc
    if(!shown(p.el)||(p.kind==="dialog"&&!p.el.open))return; // or already closed it
    if(closePopup(p))e.preventDefault();
  });
  window.LWBEsc={top:()=>{const p=topPopup();return p&&p.el},info:()=>{const p=topPopup();return p?{el:p.el,kind:p.kind}:null},closeTop:()=>{const p=topPopup();return !!(p&&closePopup(p))}};
})();
