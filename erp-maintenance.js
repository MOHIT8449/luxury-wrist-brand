/* LUXURY WRIST BRAND ERP — Maintenance mode (Mohit, 18 Nov 2026).
   Admin: a wrench button in the top bar opens "System Maintenance". Turning it ON stops every other
   login: the database refuses them all data and all changes (lwb_maintenance_mode_setup.sql:
   pre-request hook + RLS), so this file only shows what is going on:
     - Admin: the wrench turns red ("MAINTENANCE ON") and a red strip under the top bar says the system
       is closed for others, with "Turn OFF".
     - Everyone else: a full-page "System under maintenance" screen. It checks every 15 s and the page
       opens again by itself when Admin turns Maintenance OFF.
     - Login page: a notice that only Admin can log in right now.
   Loaded by erp-shell.js on every ERP page (cashbook.html and login.html load it themselves). */
(function(){
  if(window.LWBMaintenance)return;
  const URL_="https://txkbhadzdbxpieunfvox.supabase.co",KEY_="sb_publishable_W4I3Q5ODf0g17sq5uDml2Q_sLolXYEk";
  const PAGE=(location.pathname.split("/").pop()||"index.html").replace(/\.html$/,"");
  if(/^(index|privacy|terms|404|offline|share)$/.test(PAGE))return;
  const LOGIN=PAGE==="login";
  let client=null,state=null,admin=false,timer=0,btn=null,strip=null,cover=null,dlg=null,busy=false;
  const esc=v=>String(v==null?"":v).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
  const when=t=>{if(!t)return "";const d=new Date(t);if(isNaN(d))return "";
    return d.toLocaleString("en-IN",{day:"numeric",month:"short",hour:"numeric",minute:"2-digit",hour12:true,timeZone:"Asia/Kolkata"})};
  const ICON='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18v3h3l6.3-6.3a4 4 0 0 0 5.4-5.4l-2.5 2.5-2.4-.6-.6-2.4z"/></svg>';

  function css(){
    if(document.getElementById("lwb-mt-css"))return;
    const s=document.createElement("style");s.id="lwb-mt-css";
    s.textContent=
      ".lwb-mt-btn{display:inline-flex;align-items:center;justify-content:center;gap:5px;height:38px;min-width:38px;padding:0 9px;margin:0;border-radius:var(--erp-r,8px);border:1px solid var(--lwb-teal-line,#0f4b55);background:rgba(255,255,255,.07);color:var(--lwb-gold-hi,#e4d08f);cursor:pointer;flex:none;box-shadow:none;font:700 11px 'Segoe UI',Roboto,Arial,sans-serif;letter-spacing:.4px;width:auto}"+
      ".lwb-mt-btn:hover{background:rgba(255,255,255,.14)}.lwb-mt-btn svg{width:19px;height:19px;flex:none}"+
      ".lwb-mt-btn.on{background:#c8102e;border-color:#ff8a8a;color:#fff;animation:lwbMtPulse 1.6s ease-in-out infinite}"+
      ".lwb-mt-btn span{display:none}.lwb-mt-btn.on span{display:inline}"+
      "@keyframes lwbMtPulse{50%{box-shadow:0 0 0 4px rgba(200,16,46,.35)}}"+
      "@media(max-width:760px){.lwb-mt-btn{height:34px;min-width:34px;padding:0 7px}.lwb-mt-btn{display:none}}"+
      /* Phone: the top bar has no room, so while OFF the switch is the first item of the side menu */
      ".lwb-mt-side{display:none;align-items:center;gap:10px;width:calc(100% - 20px);margin:4px 10px 6px;padding:9px 12px;border-radius:8px;border:1px solid rgba(201,178,106,.45);background:rgba(201,178,106,.12);color:var(--lwb-gold-hi,#e4d08f);font:600 14px 'Segoe UI',Roboto,Arial,sans-serif;cursor:pointer;text-align:left;box-shadow:none}"+
      ".lwb-mt-side svg{width:18px;height:18px;flex:none}.lwb-mt-side span{flex:1}.lwb-mt-side i{font-style:normal;font-size:10.5px;font-weight:800;padding:1px 7px;border-radius:9px;background:#dcfce7;color:#166534}"+
      ".lwb-mt-side.on{background:#c8102e;border-color:#c8102e;color:#fff}.lwb-mt-side.on i{background:#fff;color:#c8102e}"+
      "@media(max-width:760px){.lwb-mt-side{display:flex}}"+
      ".lwb-mt-strip{display:flex;align-items:center;gap:10px;height:34px;box-sizing:border-box;padding:0 14px;background:#c8102e;color:#fff;font:600 13px/1.2 'Segoe UI',Roboto,Arial,sans-serif;position:fixed;left:0;right:0;top:var(--erp-top,54px);z-index:41;white-space:nowrap;overflow:hidden}"+
      "body.lwb-mt-strip-on .erp-main{padding-top:calc(var(--erp-top,54px) + 34px + 14px)}body.lwb-mt-strip-on .erp-side{top:calc(var(--erp-top,54px) + 34px)}"+
".lwb-mt-strip b{font-weight:800;letter-spacing:.3px;white-space:nowrap}.lwb-mt-strip .t{min-width:0;overflow:hidden;text-overflow:ellipsis}.lwb-mt-strip small{opacity:.85;font-weight:500}"+
      ".lwb-mt-strip button{flex:none;border:1px solid #fff;background:#fff;color:#c8102e;border-radius:6px;padding:4px 10px;font-weight:700;font-size:12px;font-family:inherit;cursor:pointer;width:auto;margin:0;box-shadow:none}"+
      "@media(max-width:760px){.lwb-mt-strip{font-size:12px;padding:0 10px;gap:8px}.lwb-mt-strip .t small{display:none}.lwb-mt-strip .t .x{display:none}}"+
      /* Popup */
      ".lwb-mt-dlg{border:0;padding:0;border-radius:12px;width:min(440px,calc(100vw - 24px));box-shadow:0 20px 50px rgba(0,0,0,.35);font:13.5px/1.45 'Segoe UI',Roboto,Arial,sans-serif;color:#1f2a37}"+
      ".lwb-mt-dlg::backdrop{background:rgba(15,23,42,.5)}"+
      ".lwb-mt-dlg .h{display:flex;align-items:center;gap:8px;padding:11px 14px;border-bottom:2px solid #c9b26a}.lwb-mt-dlg .h b{flex:1;font-size:16px}"+
      ".lwb-mt-dlg .h button{border:0;background:none;font-size:18px;line-height:1;cursor:pointer;color:#5b6672;padding:2px 4px;width:auto;margin:0;box-shadow:none}"+
      ".lwb-mt-badge{display:inline-block;padding:2px 9px;border-radius:10px;font-size:11px;font-weight:800;letter-spacing:.4px}"+
      ".lwb-mt-badge.live{background:#dcfce7;color:#166534;border:1px solid #86efac}.lwb-mt-badge.on{background:#fde4e4;color:#b3261e;border:1px solid #f3a5a5}"+
      ".lwb-mt-dlg .b{padding:12px 14px;display:grid;gap:9px}.lwb-mt-dlg p{margin:0}.lwb-mt-dlg .mut{color:#6b7785;font-size:12.5px}"+
      ".lwb-mt-dlg ul{margin:0;padding-left:18px;color:#374151}.lwb-mt-dlg li b{color:#b3261e}"+
      ".lwb-mt-dlg label{font-weight:600;font-size:12.5px;display:grid;gap:4px}"+
      ".lwb-mt-dlg input[type=text]{border:1px solid #d6dbe1;border-radius:8px;padding:8px 10px;font:inherit;width:100%;box-sizing:border-box;text-transform:none}"+
      ".lwb-mt-dlg .ck{display:flex;gap:8px;align-items:flex-start;font-weight:600;background:#fff7ed;border:1px solid #fed7aa;border-radius:8px;padding:8px 10px;color:#9a3412}"+
      ".lwb-mt-dlg .ck input{margin:2px 0 0;width:16px;height:16px;flex:none}"+
      ".lwb-mt-dlg .info{background:#fde4e4;border:1px solid #f3a5a5;border-radius:8px;padding:8px 10px;color:#7f1d1d}.lwb-mt-dlg .info b{color:#b3261e}"+
      ".lwb-mt-dlg .f{display:flex;justify-content:flex-end;gap:8px;padding:10px 14px 12px;border-top:1px solid #edf0f3}"+
      ".lwb-mt-dlg .f button{border:1px solid #d6dbe1;background:#fff;border-radius:8px;padding:8px 14px;font-weight:600;font-size:13px;font-family:inherit;cursor:pointer;color:#1f2a37;width:auto;margin:0;box-shadow:none}"+
      ".lwb-mt-dlg .f .red{background:#c8102e;border-color:#c8102e;color:#fff}.lwb-mt-dlg .f .green{background:#15803d;border-color:#15803d;color:#fff}"+
      ".lwb-mt-dlg .f button:disabled{opacity:.45;cursor:not-allowed}.lwb-mt-dlg .err{color:#b3261e;font-weight:600}"+
      /* Full-page screen for everyone else */
      "html.lwb-mt-locked,html.lwb-mt-locked body{overflow:hidden!important}"+
      "html.lwb-mt-locked body>*:not(.lwb-mt-cover){visibility:hidden!important}"+
      ".lwb-mt-cover{position:fixed;inset:0;z-index:2147483646;display:grid;place-items:center;padding:16px;background:#002f37;font:14px/1.5 'Segoe UI',Roboto,Arial,sans-serif;color:#e6f0f0;visibility:visible!important}"+
      ".lwb-mt-cover .c{width:min(420px,100%);text-align:center;background:#05404a;border:1px solid #0f4b55;border-radius:14px;padding:22px 18px}"+
      ".lwb-mt-cover .ic{width:56px;height:56px;margin:0 auto 10px;border-radius:50%;display:grid;place-items:center;background:#c9b26a;color:#002f37}.lwb-mt-cover .ic svg{width:30px;height:30px}"+
      ".lwb-mt-cover h1{margin:0 0 4px;font-size:21px;color:#fff}.lwb-mt-cover p{margin:0 0 6px}.lwb-mt-cover .msg{margin:10px 0;padding:8px 10px;border-radius:8px;background:rgba(201,178,106,.15);color:#e4d08f;font-weight:600}"+
      ".lwb-mt-cover small{display:block;color:#9fb7ba;font-size:12px}"+
      ".lwb-mt-cover .r{display:flex;gap:8px;justify-content:center;margin-top:14px}"+
      ".lwb-mt-cover button{border:1px solid #c9b26a;background:#c9b26a;color:#002f37;border-radius:8px;padding:8px 16px;font-weight:700;font-size:13px;font-family:inherit;cursor:pointer;width:auto;margin:0;box-shadow:none}"+
      ".lwb-mt-cover button.o{background:transparent;color:#e4d08f}"+
      /* Login notice */
      ".lwb-mt-login{margin:0 0 12px;padding:9px 11px;border-radius:8px;background:#fde4e4;border:1px solid #f3a5a5;color:#7f1d1d;font:600 13px/1.4 'Segoe UI',Roboto,Arial,sans-serif}.lwb-mt-login b{color:#b3261e}";
    (document.head||document.documentElement).appendChild(s);
  }

  async function db(){
    if(client)return client;
    for(let i=0;i<40&&!window.supabase;i++)await new Promise(r=>setTimeout(r,250));
    if(!window.supabase)return null;
    client=window.__lwbBellClient||(window.__lwbBellClient=window.supabase.createClient(URL_,KEY_));
    return client;
  }
  async function fetchState(){
    const c=await db();if(!c)return null;
    const {data,error}=await c.rpc("lwb_maintenance_status");
    if(error||!data)return null;   // SQL not run yet, or offline: change nothing
    return data;
  }

  // ---------- everyone else: full-page screen ----------
  function showCover(s){
    css();
    if(!cover){
      cover=document.createElement("div");cover.className="lwb-mt-cover";cover.setAttribute("role","alertdialog");cover.setAttribute("aria-live","assertive");
      document.body.appendChild(cover);
      cover.addEventListener("click",async e=>{
        if(e.target.closest("[data-mt-check]")){e.target.textContent="Checking...";await tick();const b=cover&&cover.querySelector("[data-mt-check]");if(b)b.textContent="Check again"}
        if(e.target.closest("[data-mt-logout]")){try{localStorage.setItem("lwbPushLogout",String(Date.now()))}catch(x){}try{const c=await db();await c.auth.signOut()}catch(x){}location.replace("login.html")}
      });
    }
    cover.innerHTML='<div class="c"><div class="ic">'+ICON+'</div><h1>System under maintenance</h1>'+
      '<p>The ERP is closed for a short time while Admin makes changes. No data can be viewed or changed right now.</p>'+
      (s.message?'<div class="msg">'+esc(s.message)+'</div>':'')+
      (s.since?'<small>Since '+esc(when(s.since))+'</small>':'')+
      '<small>This page opens by itself when the system is back.</small>'+
      '<div class="r"><button type="button" data-mt-check>Check again</button><button type="button" class="o" data-mt-logout>Logout</button></div></div>';
    document.documentElement.classList.add("lwb-mt-locked");
    try{document.querySelectorAll("dialog[open]").forEach(d=>{if(!d.closest(".lwb-mt-cover"))d.close()})}catch(e){}
  }

  // ---------- Admin: top bar button, red strip, popup ----------
  function topUser(){return document.querySelector(".erp-top .erp-user")}
  function paintAdmin(s){
    css();
    const u=topUser();
    if(u&&!btn){
      btn=document.createElement("button");btn.type="button";btn.className="lwb-mt-btn";
      btn.onclick=()=>openDlg();
      const ref=u.querySelector(".erp-keys-btn")||u.querySelector(".who")||u.firstChild;
      u.insertBefore(btn,ref&&ref.nextSibling?ref.nextSibling:null);
    }
    sideItem(s);
    if(btn){
      btn.classList.toggle("on",!!s.on);
      btn.innerHTML=ICON+'<span>MAINTENANCE ON</span>';
      btn.title=s.on?"Maintenance ON: other users are stopped. Tap to turn OFF.":"System Maintenance: stop all other users while you make changes";
      btn.setAttribute("aria-label",s.on?"Maintenance is ON":"System Maintenance");
    }
    if(s.on){
      if(!strip){
        strip=document.createElement("div");strip.className="lwb-mt-strip";strip.setAttribute("role","status");
        const top=document.querySelector(".erp-top");
        if(top&&top.parentNode)top.parentNode.insertBefore(strip,top.nextSibling);else document.body.prepend(strip);
        strip.addEventListener("click",e=>{if(e.target.closest("button"))openDlg()});
      }
      strip.innerHTML='<b>MAINTENANCE ON</b><button type="button">Turn OFF</button><span class="t"><span class="x">Other users cannot see or change any data. </span><small>Since '+esc(when(s.changed_at||s.since))+(s.changed_by?' · by '+esc(s.changed_by):'')+'</small></span>';document.body.classList.add("lwb-mt-strip-on");
    }else if(strip){strip.remove();strip=null;document.body.classList.remove("lwb-mt-strip-on")}
  }
  function sideItem(s){
    const side=document.querySelector(".erp-side");if(!side)return;
    let a=side.querySelector(".lwb-mt-side");
    if(!a){a=document.createElement("button");a.type="button";a.className="lwb-mt-side";a.onclick=()=>{document.body.classList.remove("side-open");openDlg()};
      const f=side.querySelector(".erp-menu-empty")||side.querySelector(".erp-menu-find");
      if(f&&f.parentNode)f.parentNode.insertBefore(a,f.nextSibling);else side.prepend(a)}
    a.classList.toggle("on",!!s.on);
    a.innerHTML=ICON+'<span>System Maintenance</span><i>'+(s.on?"ON":"LIVE")+'</i>';
  }
  // the side menu is drawn again when page access changes
  document.addEventListener("erp:access",()=>{if(admin&&state)sideItem(state)});
  function openDlg(){
    css();
    if(!dlg){
      dlg=document.createElement("dialog");dlg.className="lwb-mt-dlg";document.body.appendChild(dlg);
      dlg.addEventListener("click",e=>{if(e.target===dlg||e.target.closest("[data-mt-close]"))dlg.close()});
      dlg.addEventListener("change",e=>{if(e.target.matches("[data-mt-ok]")){const b=dlg.querySelector("[data-mt-on]");if(b)b.disabled=!e.target.checked}});
      dlg.addEventListener("click",async e=>{
        const on=e.target.closest("[data-mt-on]"),off=e.target.closest("[data-mt-off]");
        if(!(on||off)||busy)return;
        const msg=on?(dlg.querySelector("[data-mt-msg]").value||""):"";
        busy=true;e.target.disabled=true;e.target.textContent=on?"Turning ON...":"Turning OFF...";
        try{
          const c=await db();const {data,error}=await c.rpc("lwb_set_maintenance",{p_on:!!on,p_message:msg});
          if(error)throw error;
          state=data;paintAdmin(state);dlg.close();
          if(window.ERPShell&&ERPShell.toast)ERPShell.toast(on?"Maintenance ON. Other users are stopped.":"Maintenance OFF. The system is open for everyone.",on?"error":"success");
        }catch(err){
          const p=dlg.querySelector(".err");if(p)p.textContent="Could not change: "+((err&&err.message)||err);
          e.target.disabled=false;e.target.textContent=on?"Turn ON Maintenance":"Turn OFF Maintenance";
        }finally{busy=false}
      });
    }
    const s=state||{on:false};
    dlg.innerHTML=s.on
      ?'<div class="h"><b>System Maintenance</b><span class="lwb-mt-badge on">ON</span><button type="button" data-mt-close aria-label="Close">✕</button></div>'+
        '<div class="b"><div class="info"><b>All other users are stopped.</b> They see "System under maintenance" and cannot view, add or change any data.</div>'+
        '<p class="mut">Since <b>'+esc(when(s.changed_at||s.since))+'</b>'+(s.changed_by?' · by <b>'+esc(s.changed_by)+'</b>':'')+'</p>'+
        (s.message?'<p class="mut">Message: <b>'+esc(s.message)+'</b></p>':'')+
        '<p>Turn it OFF when your changes are done. Everyone can use the ERP again at once.</p><p class="err"></p></div>'+
        '<div class="f"><button type="button" data-mt-close>Close</button><button type="button" class="green" data-mt-off>Turn OFF Maintenance</button></div>'
      :'<div class="h"><b>System Maintenance</b><span class="lwb-mt-badge live">LIVE</span><button type="button" data-mt-close aria-label="Close">✕</button></div>'+
        '<div class="b"><p>Turn ON while you make changes. Until you turn it OFF, every user except Admin:</p>'+
        '<ul><li>sees <b>no data</b> (parties, routes, orders, deliveries, stock, bills)</li><li><b>cannot add, edit or delete</b> anything</li><li>sees a "System under maintenance" screen</li></ul>'+
        '<label>Message for users (optional)<input type="text" data-mt-msg maxlength="300" placeholder="e.g. Rate update, back by 4 PM"></label>'+
        '<label class="ck"><input type="checkbox" data-mt-ok> I understand all other users will be stopped now.</label><p class="err"></p></div>'+
        '<div class="f"><button type="button" data-mt-close>Cancel</button><button type="button" class="red" data-mt-on disabled>Turn ON Maintenance</button></div>';
    if(!dlg.open)dlg.showModal();
  }

  // ---------- Login page notice ----------
  function paintLogin(s){
    css();
    let n=document.querySelector(".lwb-mt-login");
    if(!s.on){if(n)n.remove();return}
    if(!n){n=document.createElement("div");n.className="lwb-mt-login";n.setAttribute("role","status");
      const box=document.querySelector(".login-box form")||document.querySelector("form");
      if(box&&box.parentNode)box.parentNode.insertBefore(n,box);else document.body.prepend(n)}
    n.innerHTML='<b>System under maintenance.</b> Only Admin can log in right now.'+(s.message?' '+esc(s.message):'');
  }

  async function tick(){
    clearTimeout(timer);
    const s=await fetchState();
    if(s){
      const was=state;state=s;admin=s.admin===true;
      if(LOGIN)paintLogin(s);
      else if(admin){if(cover){location.reload();return}paintAdmin(s)}
      else if(s.on)showCover(s);
      else if(cover||(was&&was.on)){location.reload();return}
    }
    const every=LOGIN?60e3:(state&&state.on&&!admin)?15e3:admin?60e3:30e3;
    timer=setTimeout(()=>{if(document.visibilityState==="visible")tick();else timer=setTimeout(tick,every)},every);
  }
  async function start(){
    const c=await db();if(!c)return;
    if(!LOGIN){
      try{const {data}=await c.auth.getSession();if(!data||!data.session)return}catch(e){return}
    }
    // the Admin button needs the top bar; wait for erp-shell.js to draw it
    for(let i=0;i<20&&!LOGIN&&!topUser();i++)await new Promise(r=>setTimeout(r,250));
    await tick();
    document.addEventListener("visibilitychange",()=>{if(document.visibilityState==="visible")tick()});
  }
  window.LWBMaintenance={check:tick,state:()=>state,open:openDlg};
  if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",start);else start();
})();
