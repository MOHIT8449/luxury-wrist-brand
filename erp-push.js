/* Phone push controls. Permission is requested only from the Enable button. */
(function(){
 'use strict';
 const el=(tag,text)=>{const n=document.createElement(tag);if(text)n.textContent=text;return n;};
 const keyBytes=value=>Uint8Array.from(atob(value.replace(/-/g,'+').replace(/_/g,'/')),c=>c.charCodeAt(0));
 async function workerMessage(reg,type,user_id){
  const worker=reg.active;if(!worker)return null;
  return new Promise(resolve=>{const ch=new MessageChannel(),timer=setTimeout(()=>resolve(null),1500);
   ch.port1.onmessage=e=>{clearTimeout(timer);resolve(e.data);ch.port1.close();};
   worker.postMessage({type,user_id},[ch.port2]);
  });
 }
 async function init({db,user,role,mount}){
  if(!mount||mount.querySelector('.lwb-push-controls'))return;
  const box=el('div'),status=el('small','Phone alerts: checking…'),actions=el('div'),enable=el('button','Enable phone alerts'),test=el('button','Test'),off=el('button','Turn off');
  box.className='lwb-push-controls';status.setAttribute('role','status');
  [enable,test,off].forEach(b=>{b.type='button';actions.append(b);b.hidden=true;});box.append(status,actions);mount.prepend(box);
  if(!window.isSecureContext||!('serviceWorker' in navigator)||!('PushManager' in window)||!('Notification' in window)){
   status.textContent=/iPhone|iPad/.test(navigator.userAgent)?'Phone alerts: open ERP from its Home Screen app.':'Phone alerts are not supported in this browser.';return;
  }
  let reg,config,subscription,busy=false,signedOut=false;
  const setBusy=b=>{busy=b;[enable,test,off].forEach(x=>x.disabled=b);};
  function draw(){
   [enable,test,off].forEach(b=>b.hidden=true);
   if(!config?.enabled||!config.public_key){
    status.textContent='Phone alerts: server setup pending.';
    if(role==='admin'){enable.textContent='Activate phone alerts';enable.hidden=false;}
    return;
   }
   enable.textContent='Enable phone alerts';
   if(Notification.permission==='denied'){status.textContent='Phone alerts are blocked. Allow notifications in this app / browser settings.';return;}
   if(subscription&&Notification.permission==='granted'){status.textContent='Phone alerts: on for this login.';test.hidden=false;off.hidden=false;}
   else{status.textContent='Receive order and delivery updates on this phone.';enable.hidden=false;}
  }
  async function save(sub){
   const r=await db.rpc('lwb_push_subscribe',{p_subscription:sub.toJSON(),p_device:navigator.userAgent.slice(0,240)});
   if(r.error)throw Error('Phone alerts could not be connected. Try again.');
   if(signedOut){await sub.unsubscribe();return;}
   subscription=sub;await workerMessage(reg,'LWB_PUSH_USER',user.id);
  }
  async function edge(body){const r=await db.functions.invoke('lwb-web-push',{body});if(r.error||r.data?.error)throw Error(r.data?.error||'Phone alert service is not ready yet.');return r.data;}
  enable.onclick=async()=>{
   if(busy)return;setBusy(true);
   try{
    if(!config?.enabled||!config.public_key){
     config=await edge({action:'setup'});draw();status.textContent='Server ready. Tap Enable phone alerts to allow this phone.';return;
    }
    // Registration/config were loaded before the click: subscribe retains the user gesture on iOS.
    const sub=await reg.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:keyBytes(config.public_key)});
    await save(sub);draw();status.textContent='Phone alerts enabled. You can send a test now.';
   }catch(e){status.textContent=Notification.permission==='denied'?'Notifications were blocked. Allow them in app / browser settings.':e.message;}
   finally{setBusy(false);}
  };
  off.onclick=async()=>{
   if(busy||!subscription)return;setBusy(true);
   try{
    const r=await db.rpc('lwb_push_unsubscribe',{p_endpoint:subscription.endpoint});if(r.error)throw Error('Could not disconnect phone alerts. Try again.');
    await subscription.unsubscribe();subscription=null;await workerMessage(reg,'LWB_PUSH_CLEAR');draw();
   }catch(e){status.textContent=e.message;}finally{setBusy(false);}
  };
  test.onclick=async()=>{
   if(busy||!subscription)return;setBusy(true);
   try{await edge({action:'test',endpoint:subscription.endpoint});status.textContent='Test accepted. Check your phone notification panel.';}
   catch(e){status.textContent=e.message;}finally{setBusy(false);}
  };
  try{
   await navigator.serviceWorker.register('/sw.js');reg=await navigator.serviceWorker.ready;
   navigator.serviceWorker.addEventListener('controllerchange',()=>{if(!signedOut)workerMessage(reg,'LWB_PUSH_USER',user.id).catch(()=>{});});
   // Restore the tapped destination after sign-in, but only for the intended recipient.
   const next=await workerMessage(reg,'LWB_PUSH_OPEN',user.id);
   if(next?.url){const u=new URL(next.url,location.origin);if(u.origin===location.origin&&u.href!==location.href){location.assign(u.href);return;}}
   db.auth.onAuthStateChange((event,session)=>{
    if(event==='SIGNED_OUT'||(session?.user?.id&&session.user.id!==user.id)){
     signedOut=true;
     // Clear device identity immediately; unsubscribe also invalidates the provider endpoint.
     workerMessage(reg,'LWB_PUSH_CLEAR').catch(()=>{});
     reg.pushManager.getSubscription().then(s=>s?.unsubscribe()).catch(()=>{});
    }
   });
   if(signedOut)return;
   await workerMessage(reg,'LWB_PUSH_USER',user.id);
   const r=await db.rpc('lwb_push_public_config');
   if(r.error||!r.data){status.textContent='Phone alerts: server setup pending.';return;}
   config=r.data;subscription=await reg.pushManager.getSubscription();
   // A new login rebinds this phone to that user. No permission prompts during page load.
   if(config.enabled&&config.public_key&&subscription&&Notification.permission==='granted')await save(subscription);
   draw();
  }catch(e){status.textContent='Phone alerts could not connect. Reopen the app and try again.';}
 }
 window.LWBPhonePush={init};
})();
