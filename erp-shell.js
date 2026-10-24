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
    {group:"Settings",items:[
      {t:"Settings",h:"settings.html",i:"gear",r:"admin manager"},
      {t:"Manage Users",h:"users.html",i:"lock",r:"admin"}]}
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
    watchSuccess();
    return {menu:groups};
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
  window.ERPShell={mount,menuFor,icon:svg,alert:erpAlert,confirm:erpConfirm,prompt:erpPrompt,toast};
  const me=document.currentScript;
  if(me&&me.hasAttribute("data-auto")){
    if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",auto);else auto();
  }
})();
