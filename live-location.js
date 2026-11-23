/* LUXURY WRIST BRAND ERP — phone location for Live Tracking.
   Loaded by erp-shell.js on every page. Sends this login's GPS to
   lwb_track_ping while the ERP is open, for every login except Admin, in the
   work hours set on the Live Tracking page.
   Phones only: on a desktop / laptop nothing runs (no location, no lock).
   Location gate (22 Nov 2026): in work hours, if location permission is
   blocked or the phone's location (GPS) is switched off, a full-screen
   "Turn on location" screen covers the ERP until location works again, and
   the server gets OFF / DENIED (Admin is alerted and sees it in red).
   Weak signal / timeouts never block the screen.
   Browsers and the Chrome-based Android app stop GPS when the app is in the
   background or the screen is off; the native Android app's service covers
   that (see android/README.md). */
(function(){
  if(window.LWBLocation)return;
  // Phones only (mobile browser + the Android app). Desktop / laptop ERP is office
  // work: no location asked, no lock, nothing sent (23 Nov 2026, owner's rule).
  const nav=typeof navigator!=="undefined"?navigator:{},ua=String(nav.userAgent||"");
  // A Windows / Mac / Linux / ChromeOS computer is never a phone, even with a touch screen or a narrow window.
  const isComputer=/Windows NT|Macintosh|CrOS|X11|Linux x86_64/i.test(ua)&&!/Android|iPhone|iPod|Mobi/i.test(ua);
  const isPhone=!isComputer&&(nav.userAgentData&&typeof nav.userAgentData.mobile==="boolean"?nav.userAgentData.mobile
    :/Android|iPhone|iPod|Mobi|Windows Phone/i.test(ua));
  if(!isPhone){window.LWBLocation={last:null,status:"desktop",start(){},now:async()=>null,retry:async()=>null};return}
  const SEND_MS=25e3,MOVE_M=50,BEAT_MS=60e3,RECHECK_MS=10*60e3;
  const st={db:null,watch:null,last:null,sentAt:0,sentPos:null,beat:null,on:false,denied:false,busy:false,
    unavail:0,offSent:false,hours:null,gate:null,perm:null};
  const api={last:null,status:"idle",start,now:fix,retry};
  window.LWBLocation=api;

  function dist(a,b){
    if(!a||!b)return 1e9;
    const R=6371e3,r=x=>x*Math.PI/180,dl=r(b.lat-a.lat),dg=r(b.lng-a.lng);
    const h=Math.sin(dl/2)**2+Math.cos(r(a.lat))*Math.cos(r(b.lat))*Math.sin(dg/2)**2;
    return 2*R*Math.asin(Math.min(1,Math.sqrt(h)));
  }

  async function send(p,status){
    if(st.busy&&!status)return;st.busy=true;
    try{
      const args=status?{p_lat:null,p_lng:null,p_status:status}:
        {p_lat:p.lat,p_lng:p.lng,p_accuracy:p.acc,p_speed_kmph:p.speed,p_heading:p.heading,p_status:"ON"};
      const {data,error}=await st.db.rpc("lwb_track_ping",args);
      if(error)return;
      if(!status){st.sentAt=Date.now();st.sentPos=p}
      if(data&&(data.tracked===false||data.in_hours===false)){hideGate();stop();setTimeout(start,RECHECK_MS);return}
    }catch(e){}finally{st.busy=false}
  }
  function onPos(pos){
    const c=pos.coords,p={lat:c.latitude,lng:c.longitude,acc:Math.round(c.accuracy||0),
      speed:c.speed!=null&&c.speed>=0?Math.round(c.speed*3.6*10)/10:null,heading:c.heading!=null&&!isNaN(c.heading)?Math.round(c.heading):null,at:Date.now()};
    st.last=api.last=p;api.status="on";st.denied=false;st.unavail=0;st.offSent=false;
    hideGate();
    if(!st.on&&st.db&&st.hours)watchOn();
    if(Date.now()-st.sentAt>=SEND_MS||dist(p,st.sentPos)>=MOVE_M)send(p);
  }
  function onErr(e){
    if(e&&e.code===1){
      api.status="denied";
      if(!st.denied){st.denied=true;send(null,"DENIED")}
      stop();showGate("denied");
    }else if(e&&e.code===2&&++st.unavail>=2){
      // Position unavailable twice in a row = phone location (GPS) switched off.
      api.status="off";
      if(!st.offSent){st.offSent=true;send(null,"OFF")}
      showGate("off");
    }else{
      api.status="weak";
    }
  }
  function fix(){
    return new Promise(ok=>{
      if(!navigator.geolocation)return ok(st.last);
      navigator.geolocation.getCurrentPosition(p=>{onPos(p);ok(st.last)},e=>{onErr(e);ok(null)},{enableHighAccuracy:true,maximumAge:20e3,timeout:15e3});
    });
  }
  function stop(){
    if(st.watch!=null&&navigator.geolocation)navigator.geolocation.clearWatch(st.watch);
    st.watch=null;clearInterval(st.beat);st.beat=null;st.on=false;
  }
  function watchOn(){
    if(st.on)return;
    st.on=true;
    st.watch=navigator.geolocation.watchPosition(onPos,onErr,{enableHighAccuracy:true,maximumAge:15e3,timeout:30e3});
    // Standing still: watchPosition goes quiet, so re-send every minute.
    st.beat=setInterval(()=>{if(!document.hidden)fix().then(p=>{if(p&&Date.now()-st.sentAt>=BEAT_MS)send(p)})},BEAT_MS);
  }
  async function start(db){
    if(db)st.db=db;
    if(!st.db||st.on)return;
    try{
      const {data,error}=await st.db.rpc("lwb_track_me");
      if(error||!data||!data.tracked)return; // Admin / not tracked (or SQL not run yet)
      if(!data.in_hours){st.hours=null;hideGate();setTimeout(start,RECHECK_MS);return}
      st.hours=data;
      if(!navigator.geolocation){send(null,"OFF");return}
      watchPerm();
      watchOn();
    }catch(e){}
  }
  // Re-check from the gate's button (or when the browser says permission changed).
  async function retry(){
    if(!st.db)return null;
    const b=st.gate&&st.gate.querySelector("button");
    if(b){b.disabled=true;b.textContent="Checking location…"}
    st.unavail=Math.max(st.unavail,1);
    const p=await fix();
    if(b){b.disabled=false;b.textContent="📍 Location ON — check again"}
    if(p){hideGate();stop();watchOn();send(p)}
    return p;
  }
  function watchPerm(){
    try{
      if(st.perm||!navigator.permissions||!navigator.permissions.query)return;
      navigator.permissions.query({name:"geolocation"}).then(s=>{
        st.perm=s;
        s.onchange=()=>{if(s.state==="denied")onErr({code:1});else if(s.state==="granted"&&st.gate)retry()};
      }).catch(()=>{});
    }catch(e){}
  }

  // ---------- Full-screen gate ----------
  function showGate(kind){
    if(typeof document==="undefined"||!document.body||!document.createElement||!st.hours)return;
    if(!st.gate){
      const css=document.createElement("style");
      css.textContent=".lwb-gate{position:fixed;inset:0;z-index:2147483000;background:rgba(0,30,36,.92);display:grid;place-items:center;padding:16px;font-family:var(--erp-font,Arial,sans-serif)}"+
        ".lwb-gate .box{background:#fff;border-radius:14px;max-width:380px;width:100%;padding:20px 18px;text-align:center;display:grid;gap:10px;box-shadow:0 10px 40px rgba(0,0,0,.35)}"+
        ".lwb-gate .ic{font-size:40px;line-height:1}.lwb-gate h2{margin:0;font-size:19px;color:#b42318}"+
        ".lwb-gate p{margin:0;font-size:14px;color:#334;line-height:1.45}.lwb-gate .hi{font-size:13px;color:#667}"+
        ".lwb-gate ol{margin:0;padding:10px 12px 10px 30px;text-align:left;font-size:13.5px;background:#fff6e5;border:1px solid #f0d9a8;border-radius:8px;color:#5d4d17;line-height:1.5}"+
        ".lwb-gate button{height:44px;border:0;border-radius:8px;background:#002f37;color:#fff;font:700 15px/1 inherit;cursor:pointer}"+
        ".lwb-gate button:disabled{opacity:.6}";
      document.head.appendChild(css);
      st.gate=document.createElement("div");st.gate.className="lwb-gate";st.gate.setAttribute("role","alertdialog");
      st.gate.addEventListener("click",e=>{if(e.target.closest("button"))retry()});
      document.addEventListener("keydown",e=>{if(st.gate&&st.gate.isConnected&&e.key!=="Tab"){e.stopPropagation()}},true);
    }
    const steps=kind==="denied"
      ?"<li>Browser में: ऊपर <b>🔒 / ⓘ</b> → <b>Location → Allow</b></li><li>App में: फ़ोन <b>Settings → Apps → LWB ERP → Permissions → Location → Allow</b></li><li>फिर नीचे वाला बटन दबाएँ</li>"
      :"<li>फ़ोन में ऊपर से नीचे swipe करें</li><li><b>Location</b> (📍) चालू करें</li><li>नीचे वाला बटन दबाएँ</li>";
    st.gate.innerHTML='<div class="box"><div class="ic">📍</div><h2>Location चालू करें</h2>'+
      "<p>काम के समय (<b>"+(st.hours.work_start||"")+" – "+(st.hours.work_end||"")+"</b>) में ERP चलाने के लिए location चालू रखना ज़रूरी है।</p>"+
      "<ol>"+steps+"</ol>"+
      '<p class="hi">Location '+(kind==="denied"?"block":"बंद")+" है — Admin को पता चल गया है।</p>"+
      '<button type="button">📍 Location ON — check again</button></div>';
    if(!st.gate.isConnected)document.body.appendChild(st.gate);
    try{document.activeElement&&document.activeElement.blur&&document.activeElement.blur()}catch(e){}
  }
  function hideGate(){if(st.gate&&st.gate.isConnected)st.gate.remove()}

  document.addEventListener("visibilitychange",()=>{if(!document.hidden&&(st.on||st.gate&&st.gate.isConnected))fix().then(p=>{if(p)send(p)})});
})();
