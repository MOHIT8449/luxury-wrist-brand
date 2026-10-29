import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
import webpush from 'npm:web-push@3.6.7';
import { validEndpoint, messageFor } from './logic.ts';

const ORIGIN='https://luxury-wrist-brand.pages.dev';
const cors={'Access-Control-Allow-Origin':ORIGIN,'Access-Control-Allow-Headers':'authorization,apikey,x-client-info,content-type',
 'Access-Control-Allow-Methods':'POST, OPTIONS','Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin'};
const reply=(status,value)=>new Response(JSON.stringify(value),{status,headers:cors});
const db=createClient(Deno.env.get('SUPABASE_URL'),Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});
async function config(){const {data,error}=await db.from('lwb_push_config').select('*').eq('id',1).single();if(error||!data)throw Error('Phone alert setup is incomplete');return data;}
function sameSecret(a,b){if(!a||a.length!==b.length)return false;let v=0;for(let i=0;i<a.length;i++)v|=a.charCodeAt(i)^b.charCodeAt(i);return v===0;}
async function send(s,payload,c){
 if(!validEndpoint(s.endpoint))throw Object.assign(Error('Invalid endpoint'),{statusCode:410});
 const request=webpush.generateRequestDetails({endpoint:s.endpoint,keys:{p256dh:s.p256dh,auth:s.auth}},JSON.stringify(payload),{
  vapidDetails:{subject:ORIGIN,publicKey:c.vapid_public,privateKey:c.vapid_private},TTL:300,urgency:'high'});
 const response=await fetch(request.endpoint,{method:request.method,headers:request.headers,body:request.body,redirect:'error',signal:AbortSignal.timeout(8000)});
 if(!response.ok)throw Object.assign(Error('Push provider rejected request'),{statusCode:response.status});
 return response;
}
async function dispatch(id,c){
 const claim=await db.rpc('lwb_push_claim',{p_id:id});if(claim.error)throw Error('Cannot claim alert');
 const job=claim.data;if(!job)return reply(200,{status:'already_handled_or_not_due'});
 const finish=async(state,error=null)=>{
  const r=await db.from('lwb_push_jobs').update({state,last_error:error,lease_token:null,leased_until:null,
   retry_at:new Date(Date.now()+Math.min(60,2**job.attempts)*1000).toISOString()}).eq('notification_id',id).eq('lease_token',job.lease_token);
  if(r.error)throw Error('Cannot finish alert job');
 };
 try{
  const {data:n,error}=await db.from('erp_notifications').select('id,user_id,title,message,notification_type,order_id,is_read,created_at').eq('id',id).maybeSingle();
  if(error)throw Error('Cannot read notification');
  if(!n||n.is_read||Date.now()-Date.parse(n.created_at)>15*60e3){await finish('sent');return reply(200,{status:'skipped'});}
  const {data:p,error:pe}=await db.from('user_profiles').select('active,role').eq('id',n.user_id).maybeSingle();
  if(pe)throw Error('Cannot read recipient');
  if(!p?.active){await finish('sent');return reply(200,{status:'inactive_recipient'});}
  const subs=await db.from('lwb_push_subscriptions').select('*').eq('user_id',n.user_id);
  if(subs.error)throw Error('Cannot read subscriptions');
  const prior=await db.from('lwb_push_deliveries').select('subscription_id').eq('notification_id',id);
  if(prior.error)throw Error('Cannot read delivery history');
  const done=new Set((prior.data||[]).map(x=>x.subscription_id));
  let retry=false,sent=0;
  // Batches keep one slow provider from consuming the function's entire runtime.
  const list=(subs.data||[]).filter(s=>!done.has(s.id));
  for(let i=0;i<list.length;i+=5)await Promise.all(list.slice(i,i+5).map(async s=>{
   // Recheck ownership immediately before sending, because a shared phone may switch logins.
   const owner=await db.from('lwb_push_subscriptions').select('user_id').eq('id',s.id).maybeSingle();
   if(owner.error){retry=true;return;}if(owner.data?.user_id!==n.user_id)return;
   try{
    await send(s,messageFor(n,String(p.role).toLowerCase()),c);
    const saved=await db.from('lwb_push_deliveries').upsert({notification_id:id,subscription_id:s.id,state:'sent'},{onConflict:'notification_id,subscription_id'});
    if(saved.error)retry=true;else sent++;
   }catch(e){
    const code=Number(e.statusCode||0);
    if([404,410].includes(code)){await db.from('lwb_push_subscriptions').delete().eq('id',s.id).eq('user_id',n.user_id);}
    else retry=true;
   }
  }));
  await finish(retry?'failed':'sent',retry?'Push provider retry required':null);
  return reply(200,{status:retry?'retry_scheduled':'accepted',accepted:sent});
 }catch(e){await finish('failed','Delivery processing failed');throw e;}
}
async function activate(c){
 if(!c.vapid_public){const keys=webpush.generateVAPIDKeys();
  const r=await db.from('lwb_push_config').update({vapid_public:keys.publicKey,vapid_private:keys.privateKey,enabled:true}).eq('id',1).is('vapid_public',null);
  if(r.error)throw Error('Cannot save phone alert keys');
 }else if(!c.enabled){const r=await db.from('lwb_push_config').update({enabled:true}).eq('id',1);if(r.error)throw Error('Cannot activate phone alerts');}
 const ready=await config();return reply(200,{enabled:ready.enabled,public_key:ready.vapid_public});
}
Deno.serve(async(req)=>{
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers:cors});
 if(req.method!=='POST')return reply(405,{error:'POST required'});
 try{
  if(Number(req.headers.get('content-length')||0)>8192)return reply(413,{error:'Request too large'});
  const body=await req.json(),c=await config();
  if(body.action==='bootstrap'){
   if(!sameSecret(req.headers.get('x-lwb-push-secret')||'',c.webhook_secret))return reply(401,{error:'Unauthorized'});
   return await activate(c);
  }
  if(body.action==='dispatch'){
   if(!sameSecret(req.headers.get('x-lwb-push-secret')||'',c.webhook_secret))return reply(401,{error:'Unauthorized'});
   if(!c.enabled||!c.vapid_private)return reply(503,{error:'Phone alerts are not active'});
   if(typeof body.notification_id!=='string'||body.notification_id.length>128)return reply(400,{error:'Invalid notification'});
   return await dispatch(body.notification_id,c);
  }
  const token=(req.headers.get('authorization')||'').replace(/^Bearer\s+/i,'');
  const auth=await db.auth.getUser(token);if(auth.error||!auth.data.user)return reply(401,{error:'Login required'});
  const uid=auth.data.user.id,pr=await db.from('user_profiles').select('active,role').eq('id',uid).maybeSingle();
  if(pr.error||!pr.data?.active)return reply(403,{error:'Active ERP login required'});
  if(body.action==='setup'){
   if(String(pr.data.role).trim().toLowerCase()=='admin')return reply(403,{error:'Admin only'});
   return await activate(c);
  }
  if(body.action==='test'){
   if(!c.enabled||!c.vapid_public)return reply(503,{error:'Phone alerts are not active'});
   const sub=await db.from('lwb_push_subscriptions').select('*').eq('user_id',uid).eq('endpoint',String(body.endpoint||'')).maybeSingle();
   if(sub.error||!sub.data)return reply(404,{error:'Enable alerts on this phone first'});
   // Per-device test throttle; no business notification / order / payment is created.
   const recent=await db.from('lwb_push_subscriptions').update({last_test_at:new Date().toISOString()}).eq('id',sub.data.id).or('last_test_at.is.null,last_test_at.lt.'+new Date(Date.now()-10000).toISOString()).select('id');
   if(!recent.data?.length)return reply(429,{error:'Please wait 10 seconds before testing'});
   await send(sub.data,{title:'Luxury Wrist Brand',body:'Phone notifications are connected. Tap to open ERP.',url:'/dashboard.html',tag:'lwb-test',user_id:uid},c);
   return reply(200,{accepted:true});
  }
  return reply(400,{error:'Unknown action'});
 }catch(e){
  // Never return provider endpoints, subscription keys or server secrets in errors / logs.
  return reply(500,{error:'Phone alert service is not ready. Please try again later.'});
 }
});
