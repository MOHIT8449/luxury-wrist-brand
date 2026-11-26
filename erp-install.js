/* LUXURY WRIST BRAND ERP — "Install App" button (Mohit, 26 Nov 2026).
   Installs the ERP on a Windows PC / laptop (or phone) like an app: own window,
   desktop + Start-menu icon, every update live (sw.js caches nothing).
   - Chrome / Edge give a beforeinstallprompt: one click opens the Install box.
   - Where that is not given (already dismissed, Firefox, Safari, iPhone) a short help popup shows the steps.
   - Hidden when the ERP is already open as the installed app, or after it is installed.
   Use: <button data-lwb-install hidden>…</button> anywhere; this file wires every such button.
   erp-shell.js loads this file and adds the button to the top bar. */
(function(){
  if(window.LWBInstall)return;
  let deferred=window.__lwbBIP||null,installed=false;
  const mm=q=>{try{return matchMedia(q).matches}catch(e){return false}};
  const standalone=()=>["standalone","fullscreen","minimal-ui","window-controls-overlay"].some(m=>mm("(display-mode: "+m+")"))||navigator.standalone===true;
  // The Android app (WebView) is already an app: no button there.
  const inAndroidApp=()=>/; wv\)/i.test(navigator.userAgent)||!!window.LWBNative||!!window.Android;
  const wanted=()=>!installed&&!standalone()&&!inAndroidApp();

  function refresh(){
    const show=wanted();
    document.querySelectorAll("[data-lwb-install]").forEach(b=>{b.hidden=!show});
  }
  addEventListener("beforeinstallprompt",e=>{e.preventDefault();deferred=e;installed=false;refresh()});
  addEventListener("appinstalled",()=>{deferred=null;installed=true;try{localStorage.setItem("lwbAppInstalled","1")}catch(x){}refresh();toast("App installed. Open it from the desktop icon.")});
  try{matchMedia("(display-mode: standalone)").addEventListener("change",refresh)}catch(e){}

  function browser(){
    const ua=navigator.userAgent;
    if(/iPhone|iPad|iPod/i.test(ua))return "ios";
    if(/Edg\//.test(ua))return "edge";
    if(/Firefox\//.test(ua))return "firefox";
    if(/Chrome\//.test(ua))return /Android/i.test(ua)?"android":"chrome";
    if(/Safari\//.test(ua))return "safari";
    return "other";
  }
  const STEPS={
    chrome:["Click the <b>Install</b> icon <span class='lwbi-ic'>⊕</span> at the right end of the address bar.","Or ⋮ menu → <b>Cast, save and share</b> → <b>Install page as app</b>.","Click <b>Install</b>. The <b>LWB ERP</b> icon comes on your desktop."],
    edge:["Click the <b>App available</b> icon <span class='lwbi-ic'>⊕</span> in the address bar.","Or ⋯ menu → <b>Apps</b> → <b>Install this site as an app</b>.","Click <b>Install</b>. The <b>LWB ERP</b> icon comes on your desktop."],
    android:["Tap the ⋮ menu in Chrome.","Tap <b>Install app</b> or <b>Add to Home screen</b>.","The <b>LWB ERP</b> icon comes on your home screen."],
    ios:["Tap <b>Share</b> at the bottom of Safari.","Tap <b>Add to Home Screen</b>, then <b>Add</b>.","The <b>LWB ERP</b> icon comes on your home screen."],
    firefox:["Firefox cannot install apps.","Open <b>luxurywristbrand.com/login.html</b> in <b>Google Chrome</b> or <b>Microsoft Edge</b>.","Click <b>Install App</b> there."],
    safari:["Mac Safari: <b>File</b> menu → <b>Add to Dock</b>.","Or open this page in <b>Google Chrome</b> and click <b>Install App</b>."],
    other:["Open <b>luxurywristbrand.com/login.html</b> in <b>Google Chrome</b> or <b>Microsoft Edge</b>.","Click <b>Install App</b> there."]
  };

  function css(){
    if(document.getElementById("lwbi-css"))return;
    const s=document.createElement("style");s.id="lwbi-css";
    s.textContent=
      ".lwbi-back{position:fixed;inset:0;z-index:2147483000;background:rgba(0,20,24,.55);display:flex;align-items:center;justify-content:center;padding:16px}"+
      ".lwbi-box{background:#fff;color:#1d2a30;border-radius:12px;max-width:380px;width:100%;padding:16px 16px 14px;box-shadow:0 18px 50px rgba(0,0,0,.3);font:14px/1.45 'Segoe UI',Roboto,Arial,sans-serif;text-align:left}"+
      ".lwbi-box h3{margin:0 0 4px;font-size:16px;color:#002f37;display:flex;align-items:center;gap:8px}"+
      ".lwbi-box h3 img{width:26px;height:26px;border-radius:6px}"+
      ".lwbi-box p.m{margin:0 0 10px;color:#66737a;font-size:12.5px}"+
      ".lwbi-box ol{margin:0 0 12px;padding-left:20px}.lwbi-box li{margin:0 0 6px}"+
      ".lwbi-ic{display:inline-block;padding:0 5px;border:1px solid #c9b26a;border-radius:4px;color:#8a7330;font-weight:700}"+
      ".lwbi-row{display:flex;gap:8px;justify-content:flex-end}"+
      ".lwbi-row button{width:auto;height:34px;margin:0;padding:0 14px;border-radius:7px;border:0;background:#002f37;color:#fff;font:600 13px inherit;cursor:pointer;box-shadow:none}"+
      ".lwbi-toast{position:fixed;left:50%;bottom:20px;transform:translateX(-50%);z-index:2147483001;background:#0f6b3a;color:#fff;padding:9px 14px;border-radius:8px;font:600 13px 'Segoe UI',Roboto,Arial,sans-serif;box-shadow:0 8px 24px rgba(0,0,0,.25)}";
    document.head.appendChild(s);
  }
  function toast(t){css();const d=document.createElement("div");d.className="lwbi-toast";d.textContent=t;document.body.appendChild(d);setTimeout(()=>d.remove(),4000)}
  function help(){
    css();
    const k=browser(),steps=STEPS[k]||STEPS.other;
    const back=document.createElement("div");back.className="lwbi-back";
    back.innerHTML='<div class="lwbi-box" role="dialog" aria-modal="true" aria-label="Install LWB ERP">'+
      '<h3><img src="/app-icon-192.png" alt="">Install LWB ERP</h3>'+
      '<p class="m">Opens in its own window with a desktop icon. Every update comes on its own.</p>'+
      '<ol>'+steps.map(s=>"<li>"+s+"</li>").join("")+'</ol>'+
      ((k==="chrome"||k==="edge")?'<p class="m">Already installed? Open the <b>LWB ERP</b> icon on your desktop, or click <b>Open in app</b> in the address bar.</p>':'')+
      '<div class="lwbi-row"><button type="button">OK</button></div></div>';
    const close=()=>{back.remove();removeEventListener("keydown",esc,true)};
    const esc=e=>{if(e.key==="Escape"){e.stopPropagation();close()}};
    back.addEventListener("click",e=>{if(e.target===back)close()});
    back.querySelector("button").onclick=close;
    addEventListener("keydown",esc,true);
    document.body.appendChild(back);
    back.querySelector("button").focus();
  }
  async function install(){
    if(deferred){
      const e=deferred;deferred=null;
      try{e.prompt();const r=await e.userChoice;if(r&&r.outcome==="accepted"){installed=true;refresh()}}catch(x){help()}
      return;
    }
    help();
  }
  document.addEventListener("click",e=>{
    const b=e.target.closest&&e.target.closest("[data-lwb-install]");
    if(!b)return;e.preventDefault();install();
  });
  // Installed already in this browser? Chrome/Edge can tell (needs related_applications; falls back quietly).
  try{navigator.getInstalledRelatedApps&&navigator.getInstalledRelatedApps().then(a=>{if(a&&a.length){installed=true;refresh()}}).catch(()=>{})}catch(e){}
  window.LWBInstall={install,help,refresh,available:()=>!!deferred};
  if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",refresh);else refresh();
})();
