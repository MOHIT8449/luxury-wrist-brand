/* LUXURY WRIST BRAND ERP — service worker.
   Lets phones install the ERP as an app. Nothing is cached: every page and
   every Supabase call goes to the network, so each merge is live at once.
   Only when the phone has no internet does a page open show offline.html. */
const OFFLINE="offline.html";
self.addEventListener("install",e=>{
  e.waitUntil(caches.open("lwb-offline-v1").then(c=>c.add(OFFLINE)).then(()=>self.skipWaiting()));
});
self.addEventListener("activate",e=>{e.waitUntil(self.clients.claim())});
self.addEventListener("fetch",e=>{
  if(e.request.mode!=="navigate")return;
  e.respondWith(fetch(e.request).catch(()=>caches.match(OFFLINE)));
});


// Only the active login receives private banner text on a shared phone.
function pushStore(action,value){
 return new Promise((resolve,reject)=>{
  const open=indexedDB.open('lwb-phone-push',1);
  open.onupgradeneeded=()=>open.result.createObjectStore('state');
  open.onerror=()=>reject(open.error);
  open.onsuccess=()=>{const db=open.result,tx=db.transaction('state',action==='get'?'readonly':'readwrite'),store=tx.objectStore('state');
   const req=action==='get'?store.get('device'):action==='clear'?store.delete('device'):store.put(value,'device');
   let result;req.onsuccess=()=>{result=req.result};tx.oncomplete=()=>{db.close();resolve(result)};tx.onerror=()=>{db.close();reject(tx.error)};
  };
 });
}
const routeAllowed=value=>{
 try{const u=new URL(value,self.location.origin);return u.origin===self.location.origin&&/^\/[a-z0-9-]+\.html$/.test(u.pathname)?u.pathname+u.search:'/dashboard.html'}catch(e){return '/dashboard.html'}
};
self.addEventListener('message',event=>{
 event.waitUntil((async()=>{
  const m=event.data||{};let reply=null;
  if(m.type==='LWB_PUSH_CLEAR')await pushStore('clear');
  if(m.type==='LWB_PUSH_USER'&&typeof m.user_id==='string'){
   const old=await pushStore('get');await pushStore('set',{user_id:m.user_id,pending:old?.user_id===m.user_id?old.pending:null});
  }
  if(m.type==='LWB_PUSH_OPEN'){
   const old=await pushStore('get');if(old?.user_id===m.user_id&&old.pending){reply={url:routeAllowed(old.pending)};await pushStore('set',{user_id:old.user_id,pending:null})}
  }
  event.ports?.[0]?.postMessage(reply);
 })());
});
self.addEventListener('push',event=>{
 event.waitUntil((async()=>{
  let p;try{p=event.data?.json()}catch(e){return}
  const device=await pushStore('get');
  if(!p||!device?.user_id||p.user_id!==device.user_id)return;
  await self.registration.showNotification(String(p.title||'Luxury Wrist Brand').slice(0,120),{
   body:String(p.body||'Open the ERP app to view this update.').slice(0,260),
   icon:'/app-icon-192.png',badge:'/app-icon-192.png',tag:String(p.tag||'lwb-update'),
   vibrate:[200,100,200],data:{url:routeAllowed(p.url),user_id:p.user_id},renotify:false
  });
 })());
});
self.addEventListener('notificationclick',event=>{
 event.notification.close();
 event.waitUntil((async()=>{
  const data=event.notification.data||{},device=await pushStore('get');
  const route=device?.user_id===data.user_id?routeAllowed(data.url):'/dashboard.html';
  if(device?.user_id===data.user_id)await pushStore('set',{user_id:device.user_id,pending:route});
  const url=new URL(route,self.location.origin).href;
  const windows=await self.clients.matchAll({type:'window',includeUncontrolled:true});
  const current=windows.find(w=>new URL(w.url).origin===self.location.origin);
  if(current){await current.navigate(url);await current.focus();}else await self.clients.openWindow(url);
 })());
});
