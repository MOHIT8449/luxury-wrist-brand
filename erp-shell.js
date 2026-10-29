/* LUXURY WRIST BRAND ERP — shared app shell.
   ERPShell.mount({role, name, onLogout}) adds the top bar (menu button,
   breadcrumb, module search, user) and the role-based side menu.
   Menu visibility is navigation only; Supabase RLS/RPC checks stay the
   real permission check on every page. */
(function(){
  const ICON={
    home:'<path d="M3 11l9-8 9 8v9a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z"/>',
    cart:'<path d="M3 4h2l2.4 11h10.2L20 7H6.2"/><circle cx="9" cy="19" r="1.5"/><circle cx="17" cy="19" r="1.5"/>',
    check:'<path d="M4 12l5 5L20 6"/>',
    box:'<path d="M3 7l9-4 9 4-9 4-9-4z"/><path d="M3 7v10l9 4 9-4V7"/><path d="M12 11v10"/>',
    truck:'<path d="M2 6h11v10H2z"/><path d="M13 9h4l4 4v3h-8"/><circle cx="6" cy="18" r="2"/><circle cx="17" cy="18" r="2"/>',
    bill:'<path d="M6 2h12v20l-3-2-3 2-3-2-3 2z"/><path d="M9 7h6M9 11h6M9 15h4"/>',
    cash:'<rect x="2" y="6" width="20" height="12" rx="2"/><circle cx="12" cy="12" r="3"/>',
    book:'<path d="M4 4h10a4 4 0 0 1 4 4v12H8a4 4 0 0 1-4-4z"/><path d="M8 8h6"/>',
    pin:'<path d="M12 22s7-7 7-12a7 7 0 0 0-14 0c0 5 7 12 7 12z"/><circle cx="12" cy="10" r="2.5"/>',
    undo:'<path d="M9 14L4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 0 12h-3"/>',
    note:'<path d="M5 3h10l4 4v14H5z"/><path d="M9 12h6M9 16h6"/>',
    users:'<circle cx="9" cy="8" r="3.5"/><path d="M2 20c0-3.5 3-6 7-6s7 2.5 7 6"/><circle cx="17" cy="9" r="2.5"/><path d="M16 14c3 0 6 2 6 5"/>',
    tag:'<path d="M3 3h8l10 10-8 8L3 11z"/><circle cx="7.5" cy="7.5" r="1.5"/>',
    inbox:'<path d="M3 13l3-9h12l3 9v7H3z"/><path d="M3 13h5l1 3h6l1-3h5"/>',
    factory:'<path d="M3 21V10l6 4V10l6 4V5h6v16z"/>',
    layers:'<path d="M12 3l9 5-9 5-9-5z"/><path d="M3 13l9 5 9-5"/>',
    gear:'<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
    stock:'<path d="M3 21V9l9-5 9 5v12"/><path d="M7 21v-8h10v8"/><path d="M7 17h10"/>',
    chart:'<path d="M4 20V11"/><path d="M10 20V5"/><path d="M16 20v-6"/><path d="M2 20h20"/>',
    chat:'<path d="M4 5h16v11H9l-5 4z"/><path d="M8 9h8M8 12h5"/>',
    lock:'<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>'
  };
  const svg=(name)=>'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">'+(ICON[name]||ICON.box)+'</svg>';

  // Same role lists as the dashboard cards and each page's own role check.
  const MENU=[
    {group:"",items:[{t:"Dashboard",h:"dashboard.html",i:"home",r:"*"},
      {t:"Complaint Box",h:"complaint-box.html",i:"chat",r:"*"}]},
    {group:"Sales",items:[
      {t:"PO / Sales Order Entry",h:"order-entry.html",i:"cart",r:"admin manager sales"},
      {t:"PO Approval & Driver",h:"warehouse-orders.html",i:"check",r:"admin manager"},
      {t:"My Sales",h:"my-sales.html",i:"chart",r:"sales"},
      {t:"Outside Market Stock",h:"market-report.html",i:"pin",r:"admin manager sales"},
      {t:"Sales Tracking",h:"sales-tracking.html",i:"chart",r:"admin manager"},
      {t:"Sales Team Setup",h:"sales-team.html",i:"users",r:"admin manager"}]},
    {group:"Dispatch",items:[
      {t:"Godown Report",h:"godown-report.html",i:"note",r:"admin manager warehouse"},
      {t:"Loading & Dispatch",h:"loading-dispatch.html",i:"box",r:"admin manager warehouse"},
      {t:"Transport Assignment",h:"transport-allocation.html",i:"truck",r:"admin manager transport"},
      {t:"Sheet & Pallet Ledger",h:"sheet-pallet.html",i:"layers",r:"admin manager accounts warehouse"}]},
    {group:"Delivery",items:[
      {t:"Driver Delivery / POD",h:"driver-delivery.html",i:"pin",r:"admin manager driver accounts"},
      {t:"Driver Collections",h:"driver-collections.html",i:"cash",r:"admin manager accounts"}]},
    {group:"Reports",items:[
      {t:"Daily Summary",h:"daily-report.html",i:"stock",r:"admin manager accounts"},
      {t:"Team Work Report",h:"team-report.html",i:"users",r:"admin manager"}]},
    {group:"Accounts",items:[
      {t:"Money Overview",h:"money-overview.html",i:"cash",r:"admin accounts"},
      {t:"Tally Bill & Invoice No.",h:"accounts-invoice.html",i:"bill",r:"admin accounts"},
      {t:"Tally Bill Check",h:"tally-check.html",i:"bill",r:"admin accounts"},
      {t:"Tally Party Mapping",h:"party-mapping.html",i:"users",r:"admin accounts"},
      {t:"Cashbook",h:"cashbook.html",i:"cash",r:"admin",hide:1}]},
    {group:"Returns",items:[
      {t:"Driver Returns Approval",h:"driver-returns.html",i:"undo",r:"admin accounts manager warehouse"},
      {t:"Sales Return",h:"sales-return.html",i:"undo",r:"admin sales warehouse"},
      {t:"Credit Note Preview",h:"credit-note.html",i:"note",r:"admin accounts"}]},
    {group:"Inventory",items:[
      {t:"Inventory / Stock Report",h:"inventory.html",i:"stock",r:"admin manager warehouse accounts"},
      {t:"Goods in Transit",h:"stock-transit.html",i:"truck",r:"admin manager warehouse"},
      {t:"Goods Inward (Purchase)",h:"goods-inward.html",i:"inbox",r:"admin manager"},
      {t:"Purchase Register",h:"purchase-register.html",i:"inbox",r:"admin"},
      {t:"Purchase Claims",h:"purchase-claims.html",i:"inbox",r:"admin manager"},
      {t:"Opening Stock",h:"opening-stock.html",i:"box",r:"admin"}]},
    {group:"Masters",items:[
      {t:"Customer / Party Master",h:"customer-master.html",i:"users",r:"admin manager"},
      {t:"SKU Master",h:"sku-master.html",i:"tag",r:"admin manager"},
      {t:"Supplier Master",h:"supplier-master.html",i:"factory",r:"admin manager"},
      {t:"Vehicle Master",h:"fleet-master.html#vehicles",i:"truck",r:"admin manager transport warehouse"},
      {t:"Driver Master",h:"fleet-master.html#drivers",i:"users",r:"admin manager transport warehouse"},
      {t:"Group Loading",h:"group-party-loading.html",i:"layers",r:"admin"}]},
    {group:"Settings",items:[
      {t:"Settings",h:"settings.html",i:"gear",r:"admin manager"},
      {t:"Manage Users",h:"users.html",i:"lock",r:"admin"},
      {t:"Rate & Scheme",h:"rates.html",i:"tag",r:"admin manager"}]}
  ];


  // ERP popups. window.alert / confirm / prompt are replaced by styled popups
  // that return Promises, so callers use: await alert(..), if(!await confirm(..)).
  const nativeAlert=window.alert.bind(window),nativeConfirm=window.confirm.bind(window),nativePrompt=window.prompt.bind(window);
  let queue=Promise.resolve();
  function kindOf(text){
    const t=String(text||"").toLowerCase();
    if(/(fail|error|could not|cannot|can't|not saved|not completed|invalid|required|only for|access only|not found|inactive|must |exceeds|unable|maximum|please select|please enter|enter a valid|\benter |at least one)/.test(t))return "error";
    if(/(success|saved|submitted|approved|posted|created|updated|completed|done|cleared|assigned)/.test(t))return "success";
    return "info";
  }
  const TITLE={success:"Done",error:"Please check",info:"Message",confirm:"Please confirm",danger:"Please confirm",prompt:"Enter details"};
  const MARK={success:'<path d="M5 12.5l4.5 4.5L19 7.5"/>',error:'<path d="M12 7v6"/><path d="M12 17h.01"/>',info:'<path d="M12 11v6"/><path d="M12 7h.01"/>',
    confirm:'<path d="M9.5 9a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.6v.6"/><path d="M12 17h.01"/>',prompt:'<path d="M4 20h4L19 9l-4-4L4 16z"/>'};
  MARK.danger=MARK.error;
  function open(kind,text,opts){
    opts=opts||{};
    return new Promise(done=>{
      const back=document.createElement("div");back.className="erp-dlg-back";
      const box=document.createElement("div");box.className="erp-dlg "+kind;box.setAttribute("role",kind==="confirm"||kind==="danger"||kind==="prompt"?"alertdialog":"dialog");box.setAttribute("aria-modal","true");
      const ic=document.createElement("div");ic.className="erp-dlg-ic";ic.innerHTML='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">'+MARK[kind]+'</svg>';
      const h=document.createElement("h3");h.textContent=opts.title||TITLE[kind];
      const lines=String(text==null?"":text).split("\n");
      const first=document.createElement("p");first.className="erp-dlg-lead";
      const rest=document.createElement("p");rest.className="erp-dlg-text";
      // First paragraph is the headline; details below in a softer box.
      const cut=lines.findIndex(l=>!l.trim());
      first.textContent=(cut>0?lines.slice(0,cut):lines).join("\n");
      const detail=cut>0?lines.slice(cut).join("\n").trim():"";
      rest.textContent=detail;
      box.append(ic,h,first);if(detail)box.append(rest);
      let input=null;
      if(kind==="prompt"){input=document.createElement("textarea");input.rows=2;input.className="erp-dlg-input";input.placeholder=opts.placeholder||"Type here";input.value=opts.value||"";box.append(input)}
      const row=document.createElement("div");row.className="erp-dlg-actions";
      const ok=document.createElement("button");ok.type="button";ok.className="erp-dlg-ok";
      ok.textContent=opts.ok||(kind==="danger"?"Yes, continue":kind==="confirm"?"Yes, continue":kind==="prompt"?"Submit":"OK");
      const asks=kind==="confirm"||kind==="danger"||kind==="prompt";
      let no=null;
      if(asks){no=document.createElement("button");no.type="button";no.className="erp-dlg-no";no.textContent=opts.cancel||"Cancel";row.append(no)}
      row.append(ok);box.append(row);back.append(box);
      const last=document.activeElement;
      document.body.append(back);
      requestAnimationFrame(()=>back.classList.add("show"));
      (input||ok).focus();
      function close(v){
        back.classList.remove("show");document.removeEventListener("keydown",key,true);
        setTimeout(()=>back.remove(),160);
        try{last&&last.focus&&last.focus()}catch(e){}
        done(v);
      }
      function key(e){
        if(e.key==="Escape"){e.preventDefault();close(kind==="prompt"?null:asks?false:undefined)}
        else if(e.key==="Enter"&&!(input&&e.shiftKey)){e.preventDefault();ok.click()}
        else if(e.key==="Tab"){const f=[input,no,ok].filter(Boolean),i=f.indexOf(document.activeElement);e.preventDefault();f[(i+(e.shiftKey?f.length-1:1))%f.length].focus()}
      }
      document.addEventListener("keydown",key,true);
      ok.onclick=()=>close(kind==="prompt"?input.value:asks?true:undefined);
      if(no)no.onclick=()=>close(kind==="prompt"?null:false);
      if(!asks)back.addEventListener("click",e=>{if(e.target===back)close()});
    });
  }
  function show(kind,text,opts){
    if(!document.body)return Promise.resolve(kind==="prompt"?nativePrompt(text):kind==="confirm"||kind==="danger"?nativeConfirm(text):nativeAlert(text));
    const run=queue.then(()=>open(kind,text,opts));
    queue=run.then(()=>{},()=>{});
    return run;
  }
  const DANGER=/(cancel|reject|remove|delete|clear)/i;
  function erpAlert(text,opts){return show((opts&&opts.kind)||kindOf(text),text,opts)}
  function erpConfirm(text,opts){return show((opts&&opts.danger)||(!opts&&DANGER.test(String(text).split("\n")[0]))?"danger":"confirm",text,opts)}
  function erpPrompt(text,value,opts){return show("prompt",text,Object.assign({value:typeof value==="string"?value:""},opts||{}))}
  window.alert=erpAlert;window.confirm=erpConfirm;window.prompt=erpPrompt;

  // Small green toast when a page shows a success message after a click.
  let lastAct=0;
  ["click","keydown","submit"].forEach(t=>document.addEventListener(t,()=>{lastAct=Date.now()},true));
  function toast(text,kind){
    let wrap=document.querySelector(".erp-toasts");
    if(!wrap){wrap=document.createElement("div");wrap.className="erp-toasts";wrap.setAttribute("aria-live","polite");document.body.append(wrap)}
    const t=document.createElement("div");t.className="erp-toast "+(kind||"success");
    t.innerHTML='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round">'+MARK[kind||"success"]+'</svg>';
    const span=document.createElement("span");span.textContent=text;t.append(span);
    wrap.append(t);requestAnimationFrame(()=>t.classList.add("show"));
    setTimeout(()=>{t.classList.remove("show");setTimeout(()=>t.remove(),250)},4200);
  }
  const seen=new WeakMap();
  function watchSuccess(){
    const root=document.querySelector(".erp-main");if(!root||!window.MutationObserver)return;
    const check=n=>{
      if(!(n instanceof Element)||!/(^|\s)success(\s|$)/.test(n.className)||n.closest(".erp-dlg-back,.erp-toasts"))return;
      const text=(n.textContent||"").trim();
      if(!text||seen.get(n)===text||Date.now()-lastAct>15000||n.hidden||getComputedStyle(n).display==="none")return;
      seen.set(n,text);toast(text.length>160?text.slice(0,157)+"...":text,"success");
    };
    new MutationObserver(list=>list.forEach(m=>{
      const t=m.target.nodeType===1?m.target:m.target.parentElement;
      if(t){check(t);const p=t.closest&&t.closest(".success");if(p)check(p)}
    })).observe(root,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:["class","hidden","style"]});
  }

  function allowed(item,role){return item.r==="*"||item.r.split(" ").includes(role)}
  // menuFor(role) = the role's default pages; menuFor(role,hidden) also drops
  // the pages Admin unticked for one user (Manage Users > Pages).
  // extra = pages of OTHER roles Admin ticked for this user.
  function menuFor(role,hidden,extra){
    const off=new Set(hidden||[]),plus=new Set(extra||[]);
    return MENU.map(g=>({group:g.group,items:g.items.filter(i=>(allowed(i,role)&&!off.has(i.h))||plus.has(i.h))})).filter(g=>g.items.length);
  }
  const allPages=()=>MENU.map(g=>({group:g.group,items:g.items.map(i=>({t:i.t,h:i.h}))}));

  // Pages hidden from the logged-in user. Cached so the menu is right at once,
  // then re-read from lwb_user_page_access on every page.
  const ACCESS_KEY="lwbHiddenPages";
  function sessionUid(){
    try{const t=JSON.parse(localStorage.getItem("sb-txkbhadzdbxpieunfvox-auth-token")||"null");return(t&&t.user&&t.user.id)||""}catch(e){return""}
  }
  function access(){
    try{const c=JSON.parse(localStorage.getItem(ACCESS_KEY)||"null");const sid=sessionUid();if(c&&Array.isArray(c.hidden)&&(!sid||c.uid===sid))return c}catch(e){}
    return null;
  }
  function hiddenPages(){const c=access();return c?c.hidden:[]}
  function extraPages(){const c=access();return c&&Array.isArray(c.extra)?c.extra:[]}
  // hide:1 pages (Cashbook) are never listed in the menu, search or dashboard; they open only
  // from their own private link. menuFor still has them, so Manage Users can tick them.
  function menuForMe(role){return menuFor(role,hiddenPages(),extraPages()).map(g=>({group:g.group,items:g.items.filter(i=>!i.hide)})).filter(g=>g.items.length)}
  const herePage=()=>(location.pathname.split("/").pop()||"dashboard.html").replace(/^$/,"dashboard.html");
  const withHtml=p=>/\.html$/.test(p)?p:p+".html";
  // Role a page should treat this user as. His own role when the page is his;
  // when Admin ticked this page of another role for him, that page's role.
  function pageRole(role,page){
    page=withHtml(page||herePage());
    const items=MENU.flatMap(g=>g.items).filter(i=>i.h.split("#")[0]===page);
    if(!items.length||items.some(i=>allowed(i,role)))return role;
    if(!extraPages().some(h=>h.split("#")[0]===page))return role;
    const rs=items[0].r.split(" ");return rs.find(r=>r!=="admin")||rs[0];
  }
  // Same, but re-reads the ticks first when the cached ones do not open this page.
  async function pageRoleFresh(role,page){
    const r=pageRole(role,page);if(r!==role)return r;
    await refreshAccess();return pageRole(role,page);
  }
  function esc(v){return String(v==null?"":v).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]))}

  // Phone: "Add to Home screen" opens the ERP like an app.
  function appMeta(){
    if(document.querySelector('link[rel="manifest"]'))return;
    const add=(tag,attrs)=>{const n=document.createElement(tag);for(const k in attrs)n.setAttribute(k,attrs[k]);document.head.appendChild(n)};
    add("link",{rel:"manifest",href:"manifest.webmanifest"});
    add("meta",{name:"theme-color",content:"#c8102e"});
    add("link",{rel:"apple-touch-icon",href:"app-icon-192.png"});
    add("meta",{name:"apple-mobile-web-app-capable",content:"yes"});
  }

  function mount(opts){
    appMeta();
    const role=String(opts.role||"").toLowerCase();
    const page=(location.pathname.split("/").pop()||"dashboard.html").replace(/^$/,"dashboard.html");
    if(blocked(role,page,hiddenPages()))return {menu:[]};
    let groups=menuForMe(role);
    let current=null,currentGroup="";
    MENU.forEach(g=>g.items.forEach(i=>{if(!current&&allowed(i,role)&&i.h.split("#")[0]===page){current=i;currentGroup=g.group}}));
    const title=opts.title||(current&&current.t)||document.title.split("|")[0].trim();
    const group=opts.group!=null?opts.group:currentGroup;

    document.body.classList.add("erp");
    const top=document.createElement("div");
    top.className="erp-top";
    top.innerHTML=
      '<button class="erp-burger" type="button" aria-label="Menu"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M4 6h16M4 12h16M4 18h16"/></svg></button>'+
      '<div class="erp-crumb" aria-label="Breadcrumb">'+(group?'<a class="mid" href="dashboard.html" style="text-decoration:none">'+esc(group)+'</a><span>/</span>':'')+'<b>'+esc(title)+'</b></div>'+
      '<div class="erp-search"><input type="search" placeholder="Module Search" aria-label="Module Search">'+
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg><div class="erp-results"></div></div>'+
      '<div class="erp-user"><div class="who"><b>'+esc(opts.name||"User")+'</b><small>'+esc(role.toUpperCase())+'</small></div>'+
      '<div class="erp-avatar">'+esc((opts.name||"U").trim().charAt(0).toUpperCase())+'</div>'+
      '<button class="erp-logout" type="button">Logout</button></div>';

    const side=document.createElement("aside");
    side.className="erp-side";
    function drawSide(){
      let html='<div class="erp-brand"><b>LUXURY WRIST BRAND</b><small>BUSINESS ERP</small></div>';
      groups.forEach(g=>{
        if(g.group)html+='<div class="erp-group">'+esc(g.group)+'</div>';
        g.items.forEach(i=>{html+='<a class="erp-link'+(current&&i.h===current.h?' active':'')+'" href="'+esc(i.h)+'">'+svg(i.i)+'<span>'+esc(i.t)+'</span></a>'});
      });
      side.innerHTML=html;
    }
    drawSide();
    const shade=document.createElement("div");shade.className="erp-shade";
    document.body.prepend(top,side,shade);

    const narrow=()=>window.matchMedia("(max-width:980px)").matches;
    let closed=false;
    try{closed=localStorage.getItem("erpSideClosed")==="1"}catch(e){}
    if(closed&&!narrow())document.body.classList.add("side-closed");
    top.querySelector(".erp-burger").onclick=()=>{
      if(narrow()){document.body.classList.toggle("side-open");return}
      const c=document.body.classList.toggle("side-closed");
      try{localStorage.setItem("erpSideClosed",c?"1":"0")}catch(e){}
    };
    shade.onclick=()=>document.body.classList.remove("side-open");
    side.addEventListener("click",e=>{if(e.target.closest("a"))document.body.classList.remove("side-open")});
    top.querySelector(".erp-logout").onclick=opts.onLogout||(()=>{location.href="login.html"});

    // Module search: type, then click or press Enter.
    const input=top.querySelector(".erp-search input"),box=top.querySelector(".erp-results");
    let flat=groups.flatMap(g=>g.items.map(i=>({...i,g:g.group})));
    let hits=[],pos=0;
    function show(){
      const q=input.value.toLowerCase().trim();
      hits=q?flat.filter(i=>(i.t+" "+i.g).toLowerCase().includes(q)):[];
      pos=0;
      box.innerHTML=hits.map((i,n)=>'<a href="'+esc(i.h)+'"'+(n===0?' class="active"':'')+'>'+esc(i.t)+'<small>'+esc(i.g||"Home")+'</small></a>').join("")||(q?'<a>No module found</a>':"");
      box.classList.toggle("open",!!q);
    }
    input.addEventListener("input",show);
    input.addEventListener("keydown",e=>{
      if(e.key==="Enter"&&hits[pos]){location.href=hits[pos].h}
      // Cashbook code word (e.g. 401): no module has that name, so it opens the Cashbook with the code;
      // the database checks the code (lwb_cashbook_ok), a wrong one shows nothing
      else if(e.key==="Enter"&&/^[A-Za-z0-9_-]{3,64}$/.test(input.value.trim())){location.href="cashbook.html#k="+input.value.trim()}
      if(e.key==="Escape"){input.value="";show()}
      if((e.key==="ArrowDown"||e.key==="ArrowUp")&&hits.length){
        e.preventDefault();pos=(pos+(e.key==="ArrowDown"?1:hits.length-1))%hits.length;
        [...box.children].forEach((a,n)=>a.classList.toggle("active",n===pos));
      }
    });
    document.addEventListener("click",e=>{if(!e.target.closest(".erp-search"))box.classList.remove("open")});
    if(role==="sales")bottomNav(page);
    // Driver page has its own bottom bar and Submit bar; it needs the same keyboard handling.
    if(role==="driver")watchKeyboard();
    watchSuccess();
    if(role)idleLogout();
    bell(top,role);
    refreshAccess().then(changed=>{
      if(!changed)return;
      if(blocked(role,page,hiddenPages()))return;
      groups=menuForMe(role);flat=groups.flatMap(g=>g.items.map(i=>({...i,g:g.group})));drawSide();
      document.dispatchEvent(new CustomEvent("erp:access"));
    });
    return {menu:groups};
  }

  // Salesman on a phone: the four things he does most, always one tap away.
  function bottomNav(page){
    const hidden=hiddenPages(),open=h=>!hidden.includes(h);
    const items=[["Home","dashboard.html","home"],["New Order","order-entry.html","cart"],["My Orders","my-sales.html#orders","box"],["My Sales","my-sales.html","chart"]]
      .filter(i=>open(i[1].split("#")[0]));
    if(items.length<2)return;
    const here=page+(page==="my-sales.html"&&location.hash==="#orders"?"#orders":"");
    const nav=document.createElement("nav");nav.className="erp-bnav";nav.setAttribute("aria-label","Quick menu");
    nav.innerHTML=items.map(([t,h,i])=>'<a href="'+h+'" class="'+(h==="order-entry.html"?"new":"")+(h===here?" active":"")+'">'+svg(i)+"<span>"+esc(t)+"</span></a>").join("");
    document.body.appendChild(nav);document.body.classList.add("has-bnav");
    window.addEventListener("hashchange",()=>{const now=page+(location.hash==="#orders"?"#orders":"");nav.querySelectorAll("a").forEach(a=>a.classList.toggle("active",a.getAttribute("href")===now))});
    watchKeyboard();
  }

  // While typing, the phone keyboard pushes fixed bars up over the page; hide them until typing ends.
  function watchKeyboard(){
    const typing=el=>el&&(el.tagName==="TEXTAREA"||el.tagName==="SELECT"||el.isContentEditable||(el.tagName==="INPUT"&&!/^(button|submit|reset|checkbox|radio|file|range|color|image|hidden)$/i.test(el.type)));
    // Keyboard open = a text box has focus AND the visible screen is clearly shorter than
    // the full screen. A box that keeps focus after the keyboard is closed (iPhone Chrome)
    // no longer hides the bars.
    let fullH=0,fullW=0;
    const keyboardUp=()=>{
      const vv=window.visualViewport;if(!vv)return true;
      if(window.innerWidth!==fullW){fullW=window.innerWidth;fullH=0}
      fullH=Math.max(fullH,window.innerHeight,vv.height*vv.scale);
      return vv.height*vv.scale<fullH-150;
    };
    const sync=()=>document.body.classList.toggle("kb-open",typing(document.activeElement)&&keyboardUp());
    document.addEventListener("focusin",()=>{sync();setTimeout(sync,400)});
    document.addEventListener("focusout",()=>setTimeout(sync,60));
    if(window.visualViewport){window.visualViewport.addEventListener("resize",sync);window.visualViewport.addEventListener("scroll",sync)}
    window.addEventListener("scroll",sync,{passive:true});
  }

  // An ERP page whose menu entries are all unticked for this user: go to the
  // first page still open to them.
  function blocked(role,page,hidden){
    const mine=MENU.flatMap(g=>g.items).filter(i=>allowed(i,role)&&i.h.split("#")[0]===page);
    if(!mine.length||!mine.every(i=>hidden.includes(i.h)))return false;
    const first=menuFor(role,hidden,extraPages()).flatMap(g=>g.items)[0];
    if(first){location.replace(first.h);return true}
    document.body.innerHTML='<div style="font:16px system-ui;padding:40px 16px;text-align:center"><b>No ERP page is open for your login.</b><br>Please ask Admin to tick your pages in Manage Users.<br><br><a href="login.html">Back to Login</a></div>';
    return true;
  }

  async function refreshAccess(){
    try{
      if(!window.supabase)return false;
      const c=window.__lwbBellClient||(window.__lwbBellClient=window.supabase.createClient(URL_,KEY_));
      const {data}=await c.auth.getSession();const user=data&&data.session&&data.session.user;if(!user)return false;
      let r=await c.from("lwb_user_page_access").select("hidden,extra").eq("user_id",user.id).maybeSingle();
      if(r.error)r=await c.from("lwb_user_page_access").select("hidden").eq("user_id",user.id).maybeSingle();
      if(r.error)return false; // setup SQL not run yet: role defaults only
      const before=JSON.stringify([hiddenPages(),extraPages()]),hidden=(r.data&&r.data.hidden)||[],extra=(r.data&&r.data.extra)||[];
      try{localStorage.setItem(ACCESS_KEY,JSON.stringify({uid:user.id,hidden,extra}))}catch(e){}
      return JSON.stringify([hiddenPages(),extraPages()])!==before;
    }catch(e){return false}
  }

  // Auto logout after 15 minutes with no tap, key or scroll. The time is shared by every ERP tab of
  // this browser, and is checked again when a phone comes back to the app. login.html sets it on login.
  const IDLE_MS=15*60e3,IDLE_KEY="lwbLastActive";
  let idleOn=false;
  function idleLogout(){
    if(idleOn)return;idleOn=true;
    const read=()=>{try{return Number(localStorage.getItem(IDLE_KEY))||0}catch(e){return 0}};
    let last=0,out=false;
    const mark=()=>{const now=Date.now();if(out||now-last<10e3)return;last=now;try{localStorage.setItem(IDLE_KEY,String(now))}catch(e){}};
    async function check(){
      const t=read();
      if(out||!t||Date.now()-t<IDLE_MS)return false;
      out=true;
      try{const c=window.__lwbBellClient||(window.__lwbBellClient=window.supabase.createClient(URL_,KEY_));await c.auth.signOut({scope:"local"})}catch(e){}
      try{localStorage.removeItem(IDLE_KEY)}catch(e){}
      location.replace("login.html?idle=1");
      return true;
    }
    check().then(gone=>{if(!gone)mark()});
    // Only real input counts: the browser also fires mousemove / scroll when the page itself changes.
    const real=e=>{if(e.isTrusted&&(e.type!=="mousemove"||e.movementX||e.movementY))mark()};
    ["pointerdown","keydown","touchstart","mousemove","wheel"].forEach(ev=>document.addEventListener(ev,real,{passive:true,capture:true}));
    document.addEventListener("visibilitychange",()=>{if(!document.hidden)check().then(gone=>{if(!gone)mark()})});
    setInterval(check,30e3);
  }

  // 🔔 ERP notifications on every page, for every logged-in role (Driver too).
  async function bell(top,role){
    try{
      if(!window.supabase)return;
      const c=window.__lwbBellClient||(window.__lwbBellClient=window.supabase.createClient(URL_,KEY_));
      const {data}=await c.auth.getSession();const user=data&&data.session&&data.session.user;if(!user)return;
      if(!window.LWBOperationsNotifications)await new Promise((ok,bad)=>{const s=document.createElement("script");s.src="erp-operations-notifications.js";s.onload=ok;s.onerror=bad;document.head.appendChild(s)});
      window.LWBOperationsNotifications.init({db:c,user,role,mount:top.querySelector(".erp-user"),pages:menuForMe(role).flatMap(g=>g.items.map(i=>i.h.split("#")[0]))});
    }catch(e){}
  }

  // Older pages: <script src="erp-shell.js" data-auto defer>. Hides the page's
  // own header, wraps the page in the shell and reads the logged-in profile.
  const URL_="https://txkbhadzdbxpieunfvox.supabase.co",KEY_="sb_publishable_W4I3Q5ODf0g17sq5uDml2Q_sLolXYEk";
  async function auto(){
    const old=document.querySelector("body > header, body > .header");
    if(old)old.classList.add("erp-old-header");
    const wrap=document.createElement("div");wrap.className="erp-main";
    [...document.body.childNodes].forEach(n=>{if(!(n.nodeType===1&&n.tagName==="SCRIPT"))wrap.appendChild(n)});
    document.body.prepend(wrap);
    let role="",name="",client=null;
    try{
      client=window.supabase.createClient(URL_,KEY_);
      const {data}=await client.auth.getSession();
      const user=data&&data.session&&data.session.user;
      // Not logged in on this site (e.g. a new preview link): go to Login instead of showing page errors.
      if(!user){location.replace("login.html");return}
      if(user){
        const p=await client.from("user_profiles").select("role,full_name").eq("id",user.id).single();
        role=String((p.data&&p.data.role)||"").toLowerCase().trim();
        name=(p.data&&p.data.full_name)||user.email||"";
      }
    }catch(e){}
    mount({role,name,onLogout:async()=>{try{await client.auth.signOut()}catch(e){}location.replace("login.html")}});
  }
  window.ERPShell={mount,menuFor,menuForMe,hiddenPages,extraPages,pageRole,pageRoleFresh,allPages,icon:svg,alert:erpAlert,confirm:erpConfirm,prompt:erpPrompt,toast};
  const me=document.currentScript;
  if(me&&me.hasAttribute("data-auto")){
    if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",auto);else auto();
  }
})();
