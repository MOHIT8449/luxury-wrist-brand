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
    put(PIN,{uid,at:Date.now()});del(PINNO);
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

  window.LWBUnlock={supported,isOn,anyOn,declined,enable,disable,notNow,verify,lock,locked,unlock,safeBack,
    device,mpinOn,canLock,mpinDeclined,mpinNotNow,mpinWeak,mpinSet,mpinVerify,mpinOff};
})();
