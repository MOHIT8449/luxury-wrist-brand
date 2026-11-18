/* LWB ERP quick unlock: fingerprint / face / phone PIN instead of the password
   after 15 minutes without activity.

   It uses the phone's own screen lock through WebAuthn (the browser's built-in
   "platform authenticator"). It works in the Android app (Chrome TWA), in Chrome
   on a phone and on a laptop with Windows Hello / Touch ID. No APK change.

   - After a full login (password + OTP) login.html offers to turn it on. This
     makes a key on this phone that only opens after the phone's fingerprint,
     face or PIN / pattern. The key never leaves the phone.
   - After 15 minutes idle erp-shell.js LOCKS the ERP (login.html?lock=1)
     instead of logging out, but only when quick unlock is on for this user on
     this phone. The login session stays; every ERP page sends a locked phone
     back to the lock screen.
   - Unlock asks the phone for the fingerprint / face / PIN. "Login with
     password" or the Logout button always ends the session as before.

   localStorage:
     lwbUnlock  {uid, cred, at}   quick unlock is on for this user on this phone
     lwbUnlockNo {uid, at}        user said "Not now" (asked again after 30 days)
     lwbLocked  {uid, back, at}   ERP is locked; back = page to reopen after unlock
     lwbDevice  "random id"       this phone's id for the MPIN (lwb_mpin_setup.sql)
     lwbMpin    {uid, at}         a 4-digit MPIN is set for this user on this phone
     lwbMpinNo  {uid, at}         user said "Skip" to the MPIN (asked again after 30 days)

   MPIN (like a bank app): the MPIN itself is checked by the database (bcrypt hash, 5 wrong
   tries remove it), never kept on the phone. Either MPIN or fingerprint keeps the ERP locked
   instead of logged out.
*/
(function(){
  "use strict";
  const ON="lwbUnlock",NO="lwbUnlockNo",LOCK="lwbLocked",DEV="lwbDevice",PIN="lwbMpin",PINNO="lwbMpinNo";
  const get=k=>{try{return JSON.parse(localStorage.getItem(k)||"null")}catch(e){return null}};
  const put=(k,v)=>{try{localStorage.setItem(k,JSON.stringify(v))}catch(e){}};
  const del=k=>{try{localStorage.removeItem(k)}catch(e){}};
  const b64=buf=>btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");
  const unb64=s=>Uint8Array.from(atob(String(s).replace(/-/g,"+").replace(/_/g,"/")),c=>c.charCodeAt(0));
  const rand=n=>crypto.getRandomValues(new Uint8Array(n));

  // Only a page on this site may be reopened after unlock (no other site, no login page).
  function safeBack(u){
    try{
      const x=new URL(u,location.href);
      if(x.origin!==location.origin||/\/login(\.html)?$/.test(x.pathname))return "dashboard.html";
      return x.pathname.replace(/^\//,"")+x.search+x.hash||"dashboard.html";
    }catch(e){return "dashboard.html"}
  }

  async function supported(){
    try{
      return !!(window.isSecureContext&&window.PublicKeyCredential&&navigator.credentials&&
        await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable());
    }catch(e){return false}
  }
  const isOn=uid=>{const s=get(ON);return !!(uid&&s&&s.uid===uid&&s.cred)};
  const anyOn=()=>{const s=get(ON),p=get(PIN);return !!(s&&s.uid&&s.cred)||!!(p&&p.uid)};
  function declined(uid){const s=get(NO);return !!(s&&s.uid===uid&&Date.now()-s.at<30*864e5)}

  // Make the key on this phone. The phone asks for fingerprint / face / PIN once.
  async function enable(user){
    if(!user||!user.id)throw Error("Login first.");
    const label=user.email&&!/@staff\.lwb-erp\.in$/i.test(user.email)?user.email:("LWB ERP "+(user.phone||user.id.slice(0,8)));
    const cred=await navigator.credentials.create({publicKey:{
      challenge:rand(32),
      rp:{name:"LWB ERP",id:location.hostname},
      user:{id:new TextEncoder().encode(user.id),name:label,displayName:label},
      pubKeyCredParams:[{type:"public-key",alg:-7},{type:"public-key",alg:-257}],
      authenticatorSelection:{authenticatorAttachment:"platform",userVerification:"required",residentKey:"discouraged"},
      timeout:60000,attestation:"none"
    }});
    if(!cred)throw Error("Fingerprint unlock was not turned on.");
    put(ON,{uid:user.id,cred:b64(cred.rawId),at:Date.now()});
    del(NO);
    return true;
  }
  function disable(){del(ON)}
  function notNow(uid){put(NO,{uid,at:Date.now()})}

  // Ask the phone for fingerprint / face / PIN. True only when the phone checked the person
  // (the "user verified" flag in the answer), not just that the phone is present.
  async function verify(uid){
    const s=get(ON);
    if(!s||s.uid!==uid)throw Error("Fingerprint unlock is not on for this login.");
    const a=await navigator.credentials.get({publicKey:{
      challenge:rand(32),rpId:location.hostname,timeout:60000,userVerification:"required",
      allowCredentials:[{type:"public-key",id:unb64(s.cred),transports:["internal"]}]
    }});
    if(!a||b64(a.rawId)!==s.cred)throw Error("This is not the key saved on this phone.");
    const data=new Uint8Array(a.response.authenticatorData);
    if(data.length<33||!(data[32]&0x04))throw Error("The phone did not check your fingerprint / PIN.");
    return true;
  }

  function lock(uid,back){put(LOCK,{uid,back:safeBack(back||location.href),at:Date.now()})}
  const locked=()=>get(LOCK);
  function unlock(){del(LOCK)}

  // ---- MPIN (lwb_mpin_setup.sql) ----
  function device(){
    let d="";try{d=localStorage.getItem(DEV)||""}catch(e){}
    if(!/^[A-Za-z0-9_-]{16,64}$/.test(d)){d=b64(rand(18));try{localStorage.setItem(DEV,d)}catch(e){}}
    return d;
  }
  const mpinOn=uid=>{const s=get(PIN);return !!(uid&&s&&s.uid===uid)};
  const canLock=uid=>isOn(uid)||mpinOn(uid);
  function mpinDeclined(uid){const s=get(PINNO);return !!(s&&s.uid===uid&&Date.now()-s.at<30*864e5)}
  function mpinNotNow(uid){put(PINNO,{uid,at:Date.now()})}
  // Same easy-MPIN rule as the database (all digits same, or 4 in a row up / down).
  const mpinWeak=p=>/^(\d)\1{3}$/.test(p)||"0123456789".includes(p)||"9876543210".includes(p);
  async function mpinSet(client,uid,pin){
    const {error}=await client.rpc("lwb_mpin_set",{p_device:device(),p_pin:pin});
    if(error)throw Error(/Could not find the function|does not exist/i.test(error.message)?"MPIN is not set up yet. Ask Admin to run lwb_mpin_setup.sql.":error.message);
    const old=get(PIN);put(PIN,{uid,at:Date.now(),who:old&&old.uid===uid&&old.who||""});del(PINNO);
    return true;
  }
  // {ok:true} | {ok:false,left:n} | {ok:false,blocked:true}. Blocked removes the MPIN flag here too.
  async function mpinVerify(client,uid,pin){
    const {data,error}=await client.rpc("lwb_mpin_verify",{p_device:device(),p_pin:pin});
    if(error)throw Error("MPIN could not be checked: "+error.message);
    const r=data||{ok:false,blocked:true};
    if(r.blocked)del(PIN);
    return r;
  }
  async function mpinOff(client){
    try{await client.rpc("lwb_mpin_remove",{p_device:device()})}catch(e){}
    del(PIN);
  }

  // ---- MPIN entry: 4 square boxes + 3 x 4 number pad (login page and ERP "Login & Security") ----
  // The typed digit shows in its box for a moment, then turns into a dot. Phone / laptop keys 0-9
  // and Backspace work too. opts: {onDone(pin), busy()}. Returns {clear(bad), fingerprint(fn|null)}.
  const FP='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true"><path d="M12 11v3a8 8 0 0 1-1.5 4.7"/><path d="M8.5 10.5a3.5 3.5 0 0 1 7 0V13a12 12 0 0 1-.6 3.8"/><path d="M5.6 15.5A11 11 0 0 0 6 13v-2.5a6 6 0 0 1 9.6-4.8"/><path d="M18 9a6 6 0 0 1 .1 1.5V13c0 2.2-.4 4.2-1.2 6"/><path d="M8.8 20a14 14 0 0 0 .7-2.4"/><path d="M4 12.5v-2a8 8 0 0 1 1.3-4.4"/></svg>';
  let padCss=false;
  function addPadCss(){
    if(padCss)return;padCss=true;
    const st=document.createElement("style");
    st.textContent=
      ".lwb-pin{--pin:#002e36;--pin-hi:#c9a24a;--pin-key:#f6f3ea;--pin-key-hi:#ecdcb0}"+
      ".lwb-pin-boxes{display:flex;justify-content:center;gap:10px;margin:2px 0 14px}"+
      ".lwb-pin-boxes span{width:50px;height:54px;border:2px solid #d5d9dc;border-radius:10px;background:#fff;display:grid;place-items:center;font:700 24px/1 Montserrat,'Segoe UI',Arial,sans-serif;color:var(--pin);transition:border-color .12s,background .12s}"+
      ".lwb-pin-boxes span.on{border-color:var(--pin);background:#f4f7f7}"+
      ".lwb-pin-boxes span.next{border-color:var(--pin-hi);box-shadow:0 0 0 3px rgba(201,162,74,.18)}"+
      ".lwb-pin-boxes.bad span{border-color:#c62828;color:#c62828;background:#fdecec}"+
      ".lwb-pin-boxes.bad{animation:lwbPinShake .35s}"+
      "@keyframes lwbPinShake{25%{transform:translateX(-8px)}75%{transform:translateX(8px)}}"+
      ".lwb-pin-keys{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;max-width:260px;margin:0 auto}"+
      ".lwb-pin-keys button{width:100%;height:48px;margin:0;padding:0;border:0;border-radius:10px;background:var(--pin-key);color:var(--pin);font:600 21px Montserrat,'Segoe UI',Arial,sans-serif;letter-spacing:0;box-shadow:none;cursor:pointer}"+
      ".lwb-pin-keys button:hover{background:var(--pin-key-hi);color:var(--pin)}"+
      ".lwb-pin-keys button.ic{display:flex;align-items:center;justify-content:center;background:none}"+
      ".lwb-pin-keys button.ic svg{width:28px;height:28px;color:#a8842f}"+
      ".lwb-pin-keys button.ic:hover{background:#f7efda}";
    document.head.appendChild(st);
  }
  function pad(host,opts){
    addPadCss();
    const busy=()=>!!(opts.busy&&opts.busy());
    host.classList.add("lwb-pin");
    host.innerHTML='<div class="lwb-pin-boxes" aria-live="polite"><span></span><span></span><span></span><span></span></div><div class="lwb-pin-keys"></div>';
    const wrap=host.firstChild,boxes=[...wrap.children],keys=host.lastChild;
    let pin="",peek=false,t=0,fpFn=null;
    const draw=()=>boxes.forEach((b,k)=>{
      b.textContent=k<pin.length?(peek&&k===pin.length-1?pin[k]:"●"):"";
      b.classList.toggle("on",k<pin.length);b.classList.toggle("next",k===pin.length);
    });
    const key=(label,fn,cls,aria)=>{const b=document.createElement("button");b.type="button";if(cls)b.className=cls;b.innerHTML=label;if(aria)b.setAttribute("aria-label",aria);b.onclick=fn;keys.appendChild(b);return b};
    const press=d=>{
      if(busy()||pin.length>=4)return;
      wrap.classList.remove("bad");pin+=d;peek=true;draw();
      clearTimeout(t);t=setTimeout(()=>{peek=false;draw()},700);
      if(pin.length===4){const p=pin;setTimeout(()=>{peek=false;draw();opts.onDone(p)},250)}
    };
    const back=()=>{if(busy())return;pin=pin.slice(0,-1);peek=false;draw()};
    for(const d of "123456789")key(d,()=>press(d));
    const fp=key(FP,()=>fpFn&&fpFn(),"ic","Fingerprint");
    key("0",()=>press("0"));
    key("&#9003;",back,"ic","Delete");
    document.addEventListener("keydown",e=>{
      if(!host.isConnected||!host.offsetParent||/^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName))return;
      if(/^[0-9]$/.test(e.key)){e.preventDefault();press(e.key)}
      else if(e.key==="Backspace"){e.preventDefault();back()}
    });
    draw();
    return {
      clear(bad){pin="";peek=false;draw();if(bad){wrap.classList.remove("bad");void wrap.offsetWidth;wrap.classList.add("bad")}},
      fingerprint(fn){fpFn=fn;fp.style.visibility=fn?"visible":"hidden"}
    };
  }

  window.LWBUnlock={pad,supported,isOn,anyOn,declined,enable,disable,notNow,verify,lock,locked,unlock,safeBack,
    device,mpinOn,canLock,mpinDeclined,mpinNotNow,mpinWeak,mpinSet,mpinVerify,mpinOff};
})();
