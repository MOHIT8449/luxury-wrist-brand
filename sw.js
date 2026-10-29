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
