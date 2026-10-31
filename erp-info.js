/* LUXURY WRIST BRAND ERP — small "i" info icon.
   Pages stay clean: a help text lives behind an icon and opens on click.
   Markup: <button type="button" class="erp-i" data-tip="Help text">i</button>
   From JS: ERPInfo.html("Help text") returns that markup.
   Loaded by erp-shell.js; a page without the shell can load it directly. */
(function(){
  if(window.ERPInfo)return;
  const esc=v=>String(v==null?"":v).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
  const css="button.erp-i.erp-i{display:inline-flex!important;align-items:center;justify-content:center;width:18px!important;height:18px!important;min-width:18px!important;max-width:18px!important;min-height:18px!important;max-height:18px!important;margin:0 0 0 6px!important;padding:0!important;border:1.5px solid #94a3b8!important;border-radius:50%!important;background:#fff!important;color:#475569!important;font:italic 700 11px/1 Georgia,serif!important;letter-spacing:0!important;text-transform:none!important;cursor:pointer;vertical-align:middle;box-shadow:none!important;flex:0 0 auto!important;transform:none!important;opacity:1!important}"+
    "button.erp-i.erp-i::before,button.erp-i.erp-i::after{content:none!important;display:none!important}"+
    "button.erp-i.erp-i:hover,button.erp-i.erp-i[aria-expanded=true]{border-color:#0f766e!important;color:#0f766e!important;background:#f0fdfa!important}"+
    ".erp-i:focus-visible{outline:2px solid #0f766e;outline-offset:2px}"+
    ".erp-i-pop{position:absolute;z-index:100000;max-width:min(340px,calc(100vw - 24px));padding:10px 12px;border-radius:10px;background:#0f2a33;color:#f8fafc;font:500 13px/1.45 system-ui,-apple-system,Segoe UI,sans-serif;box-shadow:0 10px 30px rgba(0,20,24,.3);white-space:pre-line;text-align:left;text-transform:none;letter-spacing:normal}"+
    "@media print{.erp-i,.erp-i-pop{display:none!important}}";
  function addCss(){
    if(document.getElementById("erp-info-css"))return;
    const s=document.createElement("style");s.id="erp-info-css";s.textContent=css;
    (document.head||document.documentElement).appendChild(s);
  }
  let pop=null,owner=null;
  function close(){
    if(pop){pop.remove();pop=null}
    if(owner){owner.setAttribute("aria-expanded","false");owner=null}
  }
  function open(btn){
    close();
    const text=btn.getAttribute("data-tip")||"";
    if(!text)return;
    pop=document.createElement("div");pop.className="erp-i-pop";pop.setAttribute("role","tooltip");
    pop.textContent=text;
    document.body.appendChild(pop);
    owner=btn;btn.setAttribute("aria-expanded","true");
    const r=btn.getBoundingClientRect(),w=pop.offsetWidth,h=pop.offsetHeight;
    let left=r.left+window.scrollX+r.width/2-w/2;
    left=Math.max(window.scrollX+12,Math.min(left,window.scrollX+document.documentElement.clientWidth-w-12));
    let top=r.bottom+window.scrollY+8;
    if(r.bottom+h+16>window.innerHeight&&r.top>h+16)top=r.top+window.scrollY-h-8;
    pop.style.left=left+"px";pop.style.top=top+"px";
  }
  document.addEventListener("click",e=>{
    const btn=e.target.closest&&e.target.closest(".erp-i");
    if(btn){e.preventDefault();e.stopPropagation();if(owner===btn)close();else open(btn);return}
    if(pop&&!pop.contains(e.target))close();
  },true);
  document.addEventListener("keydown",e=>{if(e.key==="Escape"&&pop)close()});
  window.addEventListener("resize",close);
  if(document.head)addCss();else document.addEventListener("DOMContentLoaded",addCss);
  window.ERPInfo={
    html:text=>'<button type="button" class="erp-i" aria-label="Info" title="Info" data-tip="'+esc(text)+'">i</button>',
    close
  };
})();
