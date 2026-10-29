const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const crypto=require('node:crypto');
const path=require('node:path');
const webpush=require('web-push');
const ece=require('http_ece');
const root=path.resolve(__dirname,'../..');
const logic=()=>import('data:text/javascript;base64,'+Buffer.from(fs.readFileSync(path.join(root,'supabase/functions/lwb-web-push/logic.ts'))).toString('base64'));

test('push endpoints cannot target private servers, lookalike domains or non-HTTPS URLs',async()=>{
 const {validEndpoint}=await logic();
 for(const bad of ['http://fcm.googleapis.com/a','https://fcm.googleapis.com.evil.test/a','https://127.0.0.1/a','https://fcm.googleapis.com:8443/a','https://user:pass@fcm.googleapis.com/a','https://web.push.apple.com/a#x','file:///etc/passwd'])assert.equal(validEndpoint(bad),false,bad);
 for(const good of ['https://fcm.googleapis.com/wp/a','https://updates.push.services.mozilla.com/wpush/v2/a','https://web.push.apple.com/Qabc'])assert.equal(validEndpoint(good),true,good);
});
test('business updates link to their own order and preserve recipient identity',async()=>{
 const {messageFor,safeRoute}=await logic();
 const p=messageFor({id:'notice',user_id:'owner',notification_type:'ORDER_NEW',order_id:'order-1',title:'New order',message:'Demo party · By Salesman'},'admin');
 assert.equal(p.url,'/warehouse-orders.html?order=order-1');assert.equal(p.user_id,'owner');
 assert.equal(safeRoute('LOADING_ASSIGNMENT_DRIVER','order-2','driver'),'/driver-delivery.html?order=order-2');
 assert.equal(safeRoute('DELIVERY_RETURN_PENDING','order-3','accounts'),'/driver-returns.html?order=order-3');
 assert.equal(safeRoute('UNKNOWN',null,'admin'),'/dashboard.html');
});
test('actual Web Push encryption is decryptable by the subscribed browser key',()=>{
 const receiver=crypto.createECDH('prime256v1');receiver.generateKeys();const auth=crypto.randomBytes(16);
 const sub={endpoint:'https://fcm.googleapis.com/wp/test-only',keys:{p256dh:receiver.getPublicKey().toString('base64url'),auth:auth.toString('base64url')}};
 const keys=webpush.generateVAPIDKeys(),payload=JSON.stringify({title:'Demo',body:'New order',user_id:'owner'});
 const req=webpush.generateRequestDetails(sub,payload,{vapidDetails:{subject:'https://luxury-wrist-brand.pages.dev',publicKey:keys.publicKey,privateKey:keys.privateKey},TTL:300,urgency:'high'});
 assert.equal(req.headers['Content-Encoding'],'aes128gcm');assert.equal(req.headers.Urgency,'high');assert.ok(req.headers.Authorization.startsWith('vapid '));
 const clear=ece.decrypt(req.body,{version:'aes128gcm',privateKey:receiver,authSecret:auth});assert.equal(clear.toString(),payload);
});
function worker(){
 const handlers={},shown=[],navigated=[];let stored={user_id:'owner'};
 const scope={location:{origin:'https://luxury-wrist-brand.pages.dev'},addEventListener:(n,f)=>handlers[n]=f,
  registration:{showNotification:async(t,o)=>shown.push({t,o})},clients:{claim:async()=>{},matchAll:async()=>[],openWindow:async u=>navigated.push(u)}};
 const ctx=vm.createContext({self:scope,URL,Promise,caches:{},indexedDB:{}});vm.runInContext(fs.readFileSync(path.join(root,'sw.js'),'utf8'),ctx);
 // IndexedDB is replaced by an in-memory adapter; handlers and authorization code are the real SW.
 ctx.__store=async(action,value)=>{if(action==='get')return stored;if(action==='clear'){stored=undefined;return;}stored=value;};
 vm.runInContext('pushStore=__store',ctx);
 const event=async(type,data)=>{let work;handlers[type]({...data,waitUntil:p=>work=p});await work;};
 return {shown,navigated,event,setUser:u=>stored=u?{user_id:u}:undefined};
}
test('a shared phone suppresses another login and signed-out notifications',async()=>{
 const w=worker();const push=payload=>w.event('push',{data:{json:()=>payload}});
 await push({user_id:'someone-else',body:'private'});assert.equal(w.shown.length,0);
 w.setUser(null);await push({user_id:'owner',body:'private'});assert.equal(w.shown.length,0);
 w.setUser('owner');await push({user_id:'owner',title:'ERP',body:'owned',url:'https://evil.test/phish',tag:'n1'});
 assert.equal(w.shown.length,1);assert.equal(w.shown[0].o.data.url,'/dashboard.html');
 assert.equal(w.shown[0].o.tag,'n1');
});
test('tapping an owned banner opens the same order; foreign links stay on the ERP origin',async()=>{
 const w=worker();await w.event('notificationclick',{notification:{close(){},data:{user_id:'owner',url:'/warehouse-orders.html?order=one'}}});
 assert.equal(w.navigated[0],'https://luxury-wrist-brand.pages.dev/warehouse-orders.html?order=one');
 await w.event('notificationclick',{notification:{close(){},data:{user_id:'other',url:'/warehouse-orders.html?order=private'}}});
 assert.equal(w.navigated[1],'https://luxury-wrist-brand.pages.dev/dashboard.html');
});
class Element{
 constructor(tag){this.tag=tag;this.children=[];this.textContent='';this.hidden=false;this.disabled=false;this.className='';}
 append(...nodes){this.children.push(...nodes);}prepend(n){this.children.unshift(n);}setAttribute(){}
 querySelector(sel){return this.children.find(c=>'.'+c.className===sel)||null;}
}
function phone({existing=false,permission='default'}={}){
 const mount=new Element('section'),calls=[],windows={Notification:{permission},PushManager:function(){},isSecureContext:true};let subscription=existing?sub():null,onAuth;
 function sub(){return {endpoint:'https://fcm.googleapis.com/wp/local-only',toJSON:()=>({endpoint:'https://fcm.googleapis.com/wp/local-only',keys:{p256dh:'B'+'a'.repeat(86),auth:'b'.repeat(22)}}),unsubscribe:async()=>{calls.push('unsubscribe');subscription=null;return true}};}
 const reg={active:{postMessage(m,ports){calls.push(m.type);queueMicrotask(()=>ports[0].postMessage(null));}},pushManager:{getSubscription:async()=>subscription,subscribe:async opts=>{calls.push('permission-request');assert.equal(opts.applicationServerKey.length,65);windows.Notification.permission='granted';subscription=sub();return subscription;}}};
 function Channel(){const port={};this.port1={onmessage:null,close(){}};this.port2={postMessage:v=>this.port1.onmessage?.({data:v})};}
 const db={rpc:async(name,args)=>{calls.push(name);return {data:name==='lwb_push_public_config'?{enabled:true,public_key:Buffer.alloc(65).toString('base64url')}:true,error:null}},functions:{invoke:async()=>({data:{accepted:true},error:null})},auth:{onAuthStateChange:f=>{onAuth=f;}}};
 const ctx=vm.createContext({window:windows,Notification:windows.Notification,document:{createElement:t=>new Element(t)},navigator:{userAgent:'QA phone',serviceWorker:{addEventListener(){},register:async()=>reg,ready:Promise.resolve(reg)}},location:{origin:'https://luxury-wrist-brand.pages.dev',href:'https://luxury-wrist-brand.pages.dev/dashboard.html',assign(){}},URL,Uint8Array,atob,MessageChannel:Channel,setTimeout,clearTimeout,queueMicrotask});
 vm.runInContext(fs.readFileSync(path.join(root,'erp-push.js'),'utf8'),ctx);
 return {calls,mount,init:()=>windows.LWBPhonePush.init({db,user:{id:'owner'},role:'admin',mount}),signOut:()=>onAuth('SIGNED_OUT',null)};
}
test('phone permission is never requested on page load; Enable binds and Turn off unsubscribes',async()=>{
 const p=phone();await p.init();assert.equal(p.calls.includes('permission-request'),false);
 const controls=p.mount.children[0],buttons=controls.children[1].children;
 await buttons[0].onclick();assert.ok(p.calls.includes('permission-request'));assert.ok(p.calls.includes('lwb_push_subscribe'));
 assert.equal(buttons[1].hidden,false);await buttons[2].onclick();assert.ok(p.calls.includes('lwb_push_unsubscribe'));assert.ok(p.calls.includes('unsubscribe'));
});
test('an existing granted subscription rebinds to login; logout clears device and unsubscribes',async()=>{
 const p=phone({existing:true,permission:'granted'});await p.init();assert.ok(p.calls.includes('lwb_push_subscribe'));assert.equal(p.calls.includes('permission-request'),false);
 p.signOut();await new Promise(r=>setImmediate(r));assert.ok(p.calls.includes('LWB_PUSH_CLEAR'));assert.ok(p.calls.includes('unsubscribe'));
});
