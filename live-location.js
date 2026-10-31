/* LUXURY WRIST BRAND ERP — phone location for Live Tracking.
   Loaded by erp-shell.js on every page. Silently sends this login's GPS to
   lwb_track_ping while the ERP is open, only when the tracking settings
   include this role and only in work hours. No on-screen sign: the staff
   member sees nothing from this file. (The phone's own one-time location
   permission prompt and the browser / OS location icon are shown by the
   phone itself and cannot be removed by a website.)
   Browsers and the Chrome-based Android app stop GPS when the app is in the
   background or the screen is off; it starts again when the app is opened. */
(function(){
  if(window.LWBLocation)return;
  const SEND_MS=25e3,MOVE_M=50,BEAT_MS=60e3,RECHECK_MS=10*60e3;
  const st={db:null,watch:null,last:null,sentAt:0,sentPos:null,beat:null,on:false,denied:false,busy:false};
  const api={last:null,status:"idle",start,now:fix};
  window.LWBLocation=api;

  function dist(a,b){
    if(!a||!b)return 1e9;
    const R=6371e3,r=x=>x*Math.PI/180,dl=r(b.lat-a.lat),dg=r(b.lng-a.lng);
    const h=Math.sin(dl/2)**2+Math.cos(r(a.lat))*Math.cos(r(b.lat))*Math.sin(dg/2)**2;
    return 2*R*Math.asin(Math.min(1,Math.sqrt(h)));
  }

  async function send(p,status){
    if(st.busy)return;st.busy=true;
    try{
      const args=status?{p_lat:null,p_lng:null,p_status:status}:
        {p_lat:p.lat,p_lng:p.lng,p_accuracy:p.acc,p_speed_kmph:p.speed,p_heading:p.heading,p_status:"ON"};
      const {data,error}=await st.db.rpc("lwb_track_ping",args);
      if(error)return;
      if(!status){st.sentAt=Date.now();st.sentPos=p}
      if(data&&(data.tracked===false||data.in_hours===false)){stop();setTimeout(start,RECHECK_MS);return}
    }catch(e){}finally{st.busy=false}
  }
  function onPos(pos){
    const c=pos.coords,p={lat:c.latitude,lng:c.longitude,acc:Math.round(c.accuracy||0),
      speed:c.speed!=null&&c.speed>=0?Math.round(c.speed*3.6*10)/10:null,heading:c.heading!=null&&!isNaN(c.heading)?Math.round(c.heading):null,at:Date.now()};
    st.last=api.last=p;api.status="on";st.denied=false;
    if(Date.now()-st.sentAt>=SEND_MS||dist(p,st.sentPos)>=MOVE_M)send(p);
  }
  function onErr(e){
    if(e&&e.code===1){
      api.status="denied";
      if(!st.denied){st.denied=true;send(null,"DENIED")}
      stop();
    }else{
      api.status="weak";
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
