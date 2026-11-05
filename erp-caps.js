/* LUXURY WRIST BRAND ERP — CAPITAL letters for typed text.
   Whatever a user types (or pastes) in a text box or a notes box turns into CAPITAL letters,
   on every ERP page, and is saved that way. Loaded by erp-shell.js; a page without the shell
   can load it directly.
   Not touched (case matters there): password, email, website/link, Supabase key, username
   and login boxes, number/date/file boxes. A box that picks from a list (<datalist>) keeps
   the picked option exactly as listed, so the page still finds it.
   Search / filter boxes only SHOW capitals; what they search with is not changed.
   A box (or a block around it) with data-nocaps keeps the text as typed. */
(function(){
  if(window.ERPCaps)return;
  const SKIP=/pass|e-?mail|url|website|web site|link|token|secret|publishable|api.?key|^key|keyinput|user.?name|login|otp/i;
  const FIND=/search|filter|find/i;
  const attrs=el=>[el.id,el.name,el.getAttribute("placeholder"),el.getAttribute("autocomplete"),el.getAttribute("aria-label")].filter(Boolean).join(" ");
  // "save" = change the value, "view" = only show capitals, "" = leave alone
  function kind(el){
    if(!el||el.disabled||el.readOnly)return "";
    if(el.closest&&el.closest("[data-nocaps]"))return "";
    let t;
    if(el.tagName==="TEXTAREA")t="text";
    else if(el.tagName==="INPUT")t=(el.getAttribute("type")||"text").toLowerCase();
    else return "";
    if(t!=="text"&&t!=="search")return "";
    const a=attrs(el),ac=(el.getAttribute("autocapitalize")||"").toLowerCase();
    if(SKIP.test(a)||ac==="off"||ac==="none")return "";
    const im=(el.getAttribute("inputmode")||"").toLowerCase();
    if(im==="email"||im==="url")return "";
    if(t==="search"||FIND.test(a)||FIND.test(el.className||""))return "view";
    return "save";
  }
  function listHas(el,v){
    const l=el.list;if(!l)return false;
    for(const o of l.options)if(o.value===v)return true;
    return false;
  }
  function fix(el){
    const k=kind(el);
    if(k==="view"){el.classList.add("erp-caps-view");return}
    if(k!=="save")return;
    const v=el.value,u=v.toUpperCase();
    if(u===v||listHas(el,v))return;
    let s=null,e=null;try{s=el.selectionStart;e=el.selectionEnd}catch(x){}
    el.value=u;
    // same length in practice (Indian/English text), so the cursor stays where it was
    if(s!=null&&u.length===v.length){try{el.setSelectionRange(s,e)}catch(x){}}
  }
  let composing=false;
  // capture on document: runs before the page's own input handlers, so they see capitals
  document.addEventListener("compositionstart",()=>{composing=true},true);
  document.addEventListener("compositionend",ev=>{composing=false;fix(ev.target)},true);
  document.addEventListener("input",ev=>{if(!composing&&!ev.isComposing)fix(ev.target)},true);
  document.addEventListener("focusin",ev=>{if(kind(ev.target)==="view")ev.target.classList.add("erp-caps-view")},true);
  function addCss(){
    if(document.getElementById("erp-caps-css"))return;
    const s=document.createElement("style");s.id="erp-caps-css";
    s.textContent="input[type=search],.erp-caps-view{text-transform:uppercase}"+
      "input[type=search]::placeholder,.erp-caps-view::placeholder{text-transform:none}";
    (document.head||document.documentElement).appendChild(s);
  }
  addCss();
  window.ERPCaps={kind,fix};
})();
