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
    lock:'<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>'
  };
  const svg=(name)=>'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">'+(ICON[name]||ICON.box)+'</svg>';

  // Same role lists as the dashboard cards and each page's own role check.
  const MENU=[
    {group:"",items:[{t:"Dashboard",h:"dashboard.html",i:"home",r:"*"}]},
    {group:"Sales",items:[
      {t:"PO / Sales Order Entry",h:"order-entry.html",i:"cart",r:"admin manager sales"},
      {t:"PO Approval & Driver",h:"warehouse-orders.html",i:"check",r:"admin manager"}]},
    {group:"Dispatch",items:[
      {t:"Loading & Dispatch",h:"loading-dispatch.html",i:"box",r:"admin manager warehouse"},
      {t:"Transport Assignment",h:"transport-allocation.html",i:"truck",r:"admin manager transport"}]},
    {group:"Accounts",items:[
      {t:"ERP Bill Create",h:"accounts-invoice.html",i:"bill",r:"admin accounts"},
      {t:"Payment Collection",h:"payment-collection.html",i:"cash",r:"admin manager sales accounts"},
      {t:"Party Ledger / Outstanding",h:"party-ledger.html",i:"book",r:"admin manager sales accounts"}]},
    {group:"Delivery",items:[
      {t:"Driver Delivery / POD",h:"driver-delivery.html",i:"pin",r:"admin manager driver accounts"}]},
    {group:"Returns",items:[
      {t:"Driver Returns Approval",h:"driver-returns.html",i:"undo",r:"admin accounts manager warehouse"},
      {t:"Sales Return",h:"sales-return.html",i:"undo",r:"admin sales warehouse"},
      {t:"Credit Note Preview",h:"credit-note.html",i:"note",r:"admin accounts"}]},
    {group:"Masters & Stock",items:[
      {t:"Customer / Party Master",h:"customer-master.html",i:"users",r:"admin manager"},
      {t:"SKU Master",h:"sku-master.html",i:"tag",r:"admin manager"},
      {t:"Supplier Master",h:"supplier-master.html",i:"factory",r:"admin manager"},
      {t:"Goods Inward",h:"goods-inward.html",i:"inbox",r:"admin manager"},
      {t:"Opening Stock",h:"opening-stock.html",i:"box",r:"admin"},
      {t:"Group Loading",h:"group-party-loading.html",i:"layers",r:"admin"}]},
    {group:"Admin",items:[
      {t:"User Permissions",h:"dashboard.html#roleManager",i:"lock",r:"admin"}]}
  ];

  function allowed(item,role){return item.r==="*"||item.r.split(" ").includes(role)}
  function menuFor(role){
    return MENU.map(g=>({group:g.group,items:g.items.filter(i=>allowed(i,role))})).filter(g=>g.items.length);
  }
  function esc(v){return String(v==null?"":v).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]))}

  function mount(opts){
    const role=String(opts.role||"").toLowerCase();
    const page=(location.pathname.split("/").pop()||"dashboard.html").replace(/^$/,"dashboard.html");
    const groups=menuFor(role);
    let current=null,currentGroup="";
    groups.forEach(g=>g.items.forEach(i=>{if(!current&&i.h.split("#")[0]===page){current=i;currentGroup=g.group}}));
    const title=opts.title||(current&&current.t)||document.title.split("|")[0].trim();
    const group=opts.group!=null?opts.group:currentGroup;

    document.body.classList.add("erp");
    const top=document.createElement("header");
    top.className="erp-top";
    top.innerHTML=
      '<button class="erp-burger" type="button" aria-label="Menu"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M4 6h16M4 12h16M4 18h16"/></svg></button>'+
      '<nav class="erp-crumb" aria-label="Breadcrumb">'+(group?'<a class="mid" href="dashboard.html" style="text-decoration:none">'+esc(group)+'</a><span>/</span>':'')+'<b>'+esc(title)+'</b></nav>'+
      '<div class="erp-search"><input type="search" placeholder="Module Search" aria-label="Module Search">'+
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg><div class="erp-results"></div></div>'+
      '<div class="erp-user"><div class="who"><b>'+esc(opts.name||"User")+'</b><small>'+esc(role.toUpperCase())+'</small></div>'+
      '<div class="erp-avatar">'+esc((opts.name||"U").trim().charAt(0).toUpperCase())+'</div>'+
      '<button class="erp-logout" type="button">Logout</button></div>';

    const side=document.createElement("aside");
    side.className="erp-side";
    let html='<div class="erp-brand"><b>LUXURY WRIST BRAND</b><small>BUSINESS ERP</small></div>';
    groups.forEach(g=>{
      if(g.group)html+='<div class="erp-group">'+esc(g.group)+'</div>';
      g.items.forEach(i=>{html+='<a class="erp-link'+(i===current?' active':'')+'" href="'+esc(i.h)+'">'+svg(i.i)+'<span>'+esc(i.t)+'</span></a>'});
    });
    side.innerHTML=html;
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
    const flat=groups.flatMap(g=>g.items.map(i=>({...i,g:g.group})));
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
      if(e.key==="Escape"){input.value="";show()}
      if((e.key==="ArrowDown"||e.key==="ArrowUp")&&hits.length){
        e.preventDefault();pos=(pos+(e.key==="ArrowDown"?1:hits.length-1))%hits.length;
        [...box.children].forEach((a,n)=>a.classList.toggle("active",n===pos));
      }
    });
    document.addEventListener("click",e=>{if(!e.target.closest(".erp-search"))box.classList.remove("open")});
    return {menu:groups};
  }

  window.ERPShell={mount,menuFor,icon:svg};
})();
