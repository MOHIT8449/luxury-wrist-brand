/* LUXURY WRIST BRAND ERP — phone location for Live Tracking.
   Loaded by erp-shell.js on every page. Sends this login's GPS position to
   lwb_track_ping while the ERP is open on the screen, only when Admin's
   tracking settings include this role and only in work hours.
   A small "Location ON" pill tells the staff member it is shared.
   Browsers (and the Chrome-based Android app) stop GPS when the app is in the
   background or the screen is off; it starts again when the app is opened. */
(function(){
  if(window.LWBLocation)return;
  const SEND_MS=25e3,MOVE_M=50,BEAT_MS=60e3,RECHECK_MS=10*60e3;
  const st={db:null,watch:null,last:null,sentAt:0,sentPos:null,beat:null,on:false,denied:false,pill:null,busy:false};
  const api={last:null,status:"idle",start,now:fix};
  window.LWBLocation=api;

  function dist(a,b){
    if(!a||!b)return 1e9;
    const R=6371e3,r=x=>x*Math.PI/180,dl=r(b.lat-a.lat),dg=r(b.lng-a.lng);
    const h=Math.sin(dl/2)**2+Math.cos(r(a.lat))*Math.cos(r(b.lat))*Math.sin(dg/2)**2;
    return 2*R*Math.asin(Math.min(1,Math.sqrt(h)));
  }
  function pill(text,kind,title){
    if(!st.pill){
      const s=document.createElement("style");
      s.textContent=".lwb-loc{position:fixed;left:10px;bottom:10px;z-index:60;font:600 11px/1 Arial,sans-serif;padding:6px 9px;border-radius:14px;"+
        "background:#e6f4ec;color:#11633a;border:1px solid #b9dfc8;box-shadow:0 2px 6px #0002;cursor:pointer;max-width:70vw}"+
        ".lwb-loc.off{background:#fff3df;color:#8a5600;border-color:#f0d29a}"+
        "@media(max-width:760px){.lwb-loc{bottom:calc(72px + env(safe-area-inset-bottom))}}";
      document.head.appendChild(s);
      st.pill=document.createElement("button");st.pill.type="button";st.pill.className="lwb-loc";
      st.pill.onclick=()=>{const t=st.pill.title;if(window.ERPShell)ERPShell.alert(t);else alert(t)};
      document.body.appendChild(st.pill);
    }
    st.pill.textContent=text;st.pill.classList.toggle("off",kind==="off");st.pill.title=title||"";st.pill.hidden=!text;
  }

  async function send(p,status){
    if(st.busy)return;st.busy=true;
    try{
      const args=status?{p_lat:null,p_lng:null,p_status:status}:
        {p_lat:p.lat,p_lng:p.lng,p_accuracy:p.acc,p_speed_kmph:p.speed,p_heading:p.heading,p_status:"ON"};
      const {data,error}=await st.db.rpc("lwb_track_ping",args);
      if(error)return;
      if(!status){st.sentAt=Date.now();st.sentPos=p}
      if(data&&(data.tracked===false||data.in_hours===false)){stop();pill("");setTimeout(start,RECHECK_MS);return}
      if(data&&data.events&&data.events.length)window.dispatchEvent(new CustomEvent("lwb-trip-events",{detail:data.events}));
    }catch(e){}finally{st.busy=false}
  }
  function onPos(pos){
    const c=pos.coords,p={lat:c.latitude,lng:c.longitude,acc:Math.round(c.accuracy||0),
      speed:c.speed!=null&&c.speed>=0?Math.round(c.speed*3.6*10)/10:null,heading:c.heading!=null&&!isNaN(c.heading)?Math.round(c.heading):null,at:Date.now()};
    st.last=api.last=p;api.status="on";st.denied=false;
    pill("📍 Location ON","on","Your live location is shared with Admin / Sales Head / Godown Manager during work hours while the ERP app is open.");
    if(Date.now()-st.sentAt>=SEND_MS||dist(p,st.sentPos)>=MOVE_M)send(p);
  }
  function onErr(e){
    if(e&&e.code===1){
      api.status="denied";
      pill("⚠ Location OFF","off","Location is blocked. Allow location for this app: phone Settings > Apps > Chrome (or LWB ERP) > Permissions > Location > Allow, then open the ERP again.");
      if(!st.denied){st.denied=true;send(null,"DENIED")}
      stop();
    }else{
      api.status="weak";
      pill("📍 Location: searching GPS…","off","Phone GPS is not giving a position. Turn on Location (GPS) in the phone quick settings.");
    }
  }
  function fix(){
    return new Promise(ok=>{
      if(!navigator.geolocation)return ok(st.last);
      navigator.geolocation.getCurrentPosition(p=>{onPos(p);ok(st.last)},e=>{onErr(e);ok(st.last)},{enableHighAccuracy:true,maximumAge:20e3,timeout:15e3});
    });
  }
  function stop(){
    if(st.watch!=null&&navigator.geolocation)navigator.geolocation.clearWatch(st.watch);
    st.watch=null;clearInterval(st.beat);st.beat=null;st.on=false;
  }
  async function start(db){
    if(db)st.db=db;
    if(!st.db||st.on)return;
    try{
      const {data,error}=await st.db.rpc("lwb_track_me");
      if(error||!data||!data.tracked)return; // not tracked (or SQL not run yet)
      if(!data.in_hours){setTimeout(start,RECHECK_MS);return}
      if(!navigator.geolocation){send(null,"OFF");return}
      st.on=true;
      st.watch=navigator.geolocation.watchPosition(onPos,onErr,{enableHighAccuracy:true,maximumAge:15e3,timeout:30e3});
      // Standing still: watchPosition goes quiet, so re-send every minute.
      st.beat=setInterval(()=>{if(!document.hidden)fix().then(p=>{if(p&&Date.now()-st.sentAt>=BEAT_MS)send(p)})},BEAT_MS);
    }catch(e){}
  }
  document.addEventListener("visibilitychange",()=>{if(!document.hidden&&st.on)fix().then(p=>{if(p)send(p)})});
})();
