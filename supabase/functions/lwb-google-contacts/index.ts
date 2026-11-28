// Dial Book -> Gmail (Google Contacts) auto sync (Mohit, 28 Nov 2026). lwb_gmail_sync_setup.sql.
// Actions (POST JSON):
//   start      Admin JWT          -> {url} Google consent page (redirect back to dial-book.html)
//   callback   Admin JWT + code   -> saves the Google login, then syncs
//   sync       Admin JWT or x-lwb-gsync-secret (nightly cron)
//   disconnect Admin JWT          -> forgets the Google login (contacts already in Gmail stay)
//   start {extra:true} / callback    another Gmail of Admin, only for the duplicate cleaner (lwb_gmail_dedupe_setup.sql)
//   remove_account {email}           forget an extra Gmail
//   dedupe_scan                      every number saved 2+ times in all connected Gmail -> plan (nothing changes)
//   dedupe_apply {run_id, picks}     delete the other copies (Admin pressed "Haan, saaf karo")
// Only contacts in the label "LWB ERP" are created / changed / deleted. Refresh token never leaves the server.
import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
import { makePlan, actions, mob, mask } from './plan.js';

const ORIGINS=['https://luxurywristbrand.com','https://www.luxurywristbrand.com'];
const REDIRECT='https://luxurywristbrand.com/dial-book.html';
const GROUP='LWB ERP';
const SCOPE='https://www.googleapis.com/auth/contacts https://www.googleapis.com/auth/userinfo.email';
const P='https://people.googleapis.com/v1/';
const db=createClient(Deno.env.get('SUPABASE_URL'),Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});

function headers(origin){return {'Access-Control-Allow-Origin':ORIGINS.includes(origin)?origin:ORIGINS[0],'Access-Control-Allow-Headers':'authorization,apikey,x-client-info,content-type',
  'Access-Control-Allow-Methods':'POST, OPTIONS','Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin'};}
function sameSecret(a,b){if(!a||!b||a.length!==b.length)return false;let v=0;for(let i=0;i<a.length;i++)v|=a.charCodeAt(i)^b.charCodeAt(i);return v===0;}
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function cfg(){const r=await db.from('lwb_gsync_config').select('*').eq('id',1).single();if(r.error||!r.data)throw Error('Gmail sync is not set up (lwb_gmail_sync_setup.sql)');return r.data;}
async function setCfg(v){const r=await db.from('lwb_gsync_config').update({...v,updated_at:new Date().toISOString()}).eq('id',1);if(r.error)throw Error('Cannot save Gmail sync settings');}

async function token(c,extra){
  const r=await fetch('https://oauth2.googleapis.com/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
    body:new URLSearchParams({client_id:c.client_id,client_secret:c.client_secret,refresh_token:extra?extra.refresh_token:c.refresh_token,grant_type:'refresh_token'})});
  const j=await r.json().catch(()=>({}));
  if(!r.ok){if(j.error==='invalid_grant'){
      if(extra){await db.from('lwb_gsync_accounts').delete().eq('email',extra.email);throw Error(extra.email+': Google login expired or was removed. Add this Gmail again.');}
      await setCfg({refresh_token:null});throw Error('Google login expired or was removed. Press Connect Gmail again.');}
    throw Error('Google token error: '+(j.error_description||j.error||r.status));}
  return j.access_token;
}
// People API call with retry on 429 / 5xx (Google asks for sequential writes for one account).
async function g(at,method,path,body){
  for(let i=0;i<5;i++){
    const r=await fetch(P+path,{method,headers:{Authorization:'Bearer '+at,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});
    if(r.status===429||r.status>=500){await sleep(1500*(i+1)*(i+1));continue;}
    const t=await r.text();const j=t?JSON.parse(t):{};
    if(!r.ok){const e=Error('Google '+r.status+': '+(j.error?.message||t).slice(0,200));e.status=r.status;throw e;}
    return j;
  }
  throw Error('Google is busy, try again later');
}
function person(x,grp){
  const nums=(x.numbers||[]).map((n,i)=>({value:'+91'+n.mobile,type:i===0?'mobile':'other'}));
  return {names:[{unstructuredName:x.name,givenName:x.name}],phoneNumbers:nums,
    biographies:x.sub?[{value:'LWB ERP · '+x.sub,contentType:'TEXT_PLAIN'}]:[{value:'LWB ERP',contentType:'TEXT_PLAIN'}],
    memberships:[{contactGroupMembership:{contactGroupResourceName:grp}}]};
}
async function groupOf(at,c){
  if(c.group_rn){try{await g(at,'GET',c.group_rn+'?maxMembers=0');return c.group_rn;}catch(e){if(e.status!==404)throw e;}}
  let page='';
  do{const j=await g(at,'GET','contactGroups?pageSize=200'+(page?'&pageToken='+page:''));
    const f=(j.contactGroups||[]).find(x=>x.groupType==='USER_CONTACT_GROUP'&&x.name===GROUP);
    if(f){await setCfg({group_rn:f.resourceName});return f.resourceName;}page=j.nextPageToken||'';}while(page);
  const n=await g(at,'POST','contactGroups',{contactGroup:{name:GROUP}});await setCfg({group_rn:n.resourceName});return n.resourceName;
}
async function delMany(at,rns){
  for(let i=0;i<rns.length;i+=200){const part=rns.slice(i,i+200);
    try{await g(at,'POST','people:batchDeleteContacts',{resourceNames:part});}
    catch(e){ // one contact deleted by hand in Gmail fails the batch: delete one by one, missing ones are fine
      for(const rn of part){try{await g(at,'DELETE',rn+':deleteContact');}catch(x){if(x.status!==404&&x.status!==400)throw x;}}}
  }
}
async function sync(c,by){
  const until=c.running_until?Date.parse(c.running_until):0;
  if(until>Date.now())return {status:'running'};
  await setCfg({running_until:new Date(Date.now()+4*60e3).toISOString()});
  const out={by,at:new Date().toISOString(),added:0,updated:0,removed:0,total:0};
  try{
    const at=await token(c),grp=await groupOf(at,c);
    const list=await db.rpc('lwb_gsync_contacts');if(list.error)throw Error(list.error.message);
    const want=new Map((list.data||[]).map(x=>[x.key,x]));out.total=want.size;
    const m=await db.from('lwb_gsync_map').select('*');if(m.error)throw Error('Cannot read sync list');
    const have=new Map((m.data||[]).map(x=>[x.key,x]));
    const gone=[...have.values()].filter(x=>!want.has(x.key));
    const changed=[...want.values()].filter(x=>have.has(x.key)&&have.get(x.key).hash!==x.hash);
    const fresh=[...want.values()].filter(x=>!have.has(x.key));
    // removed + changed: delete in Gmail (changed ones are created again below with the new name / numbers)
    const del=gone.concat(changed.map(x=>have.get(x.key)));
    if(del.length){await delMany(at,del.map(x=>x.resource_name));
      const d=await db.from('lwb_gsync_map').delete().in('key',del.map(x=>x.key));if(d.error)throw Error('Cannot update sync list');}
    out.removed=gone.length;out.updated=changed.length;out.added=fresh.length;
    const make=changed.concat(fresh);
    for(let i=0;i<make.length;i+=200){const part=make.slice(i,i+200);
      const j=await g(at,'POST','people:batchCreateContacts',{contacts:part.map(x=>({contactPerson:person(x,grp)})),readMask:'names'});
      const made=(j.createdPeople||[]).map((r,k)=>({key:part[k].key,resource_name:r.person?.resourceName,hash:part[k].hash,synced_at:new Date().toISOString()})).filter(r=>r.resource_name);
      if(made.length){const u=await db.from('lwb_gsync_map').upsert(made,{onConflict:'key'});if(u.error)throw Error('Cannot save sync list');}
      if(i+200<make.length)await sleep(1200);
    }
    out.ok=true;
  }catch(e){out.ok=false;out.error=String(e.message||e).slice(0,300);}
  await setCfg({last_sync_at:new Date().toISOString(),last_result:out,running_until:null});
  return out;
}

// ---- Duplicate number cleaner (Mohit, 28 Nov 2026; lwb_gmail_dedupe_setup.sql, plan.js) ----
async function accountsOf(c){
  const ex=await db.from('lwb_gsync_accounts').select('email,refresh_token').order('connected_at');
  if(ex.error)throw Error('Run lwb_gmail_dedupe_setup.sql first');
  return [{email:c.google_email||'Main Gmail',main:true},...(ex.data||[]).map(x=>({email:x.email,extra:x}))];
}
async function listAll(at){
  const out=[];let page='';
  do{const j=await g(at,'GET','people/me/connections?personFields=names,phoneNumbers,memberships&pageSize=1000'+(page?'&pageToken='+page:''));
    out.push(...(j.connections||[]));page=j.nextPageToken||'';}while(page&&out.length<30000);
  return out;
}
async function scan(c,uid){
  const accs=await accountsOf(c),contacts=[],ats=[];
  const m=await db.from('lwb_gsync_map').select('resource_name');const mine=new Set((m.data||[]).map(x=>x.resource_name));
  for(let a=0;a<accs.length;a++){
    const at=await token(c,accs[a].extra);ats.push(at);
    for(const p of await listAll(at)){
      const phones=(p.phoneNumbers||[]).map(x=>x.value||x.canonicalForm||'').filter(Boolean);
      if(!phones.some(mob))continue;
      const erp=accs[a].main&&(mine.has(p.resourceName)||(p.memberships||[]).some(x=>c.group_rn&&x.contactGroupMembership?.contactGroupResourceName===c.group_rn));
      contacts.push({acc:a,rn:p.resourceName,name:(p.names||[])[0]?.displayName||'',phones,erp});
    }
  }
  const erpNames=new Map();
  if(c.refresh_token){const l=await db.rpc('lwb_gsync_contacts');if(!l.error)for(const x of l.data||[])for(const n of x.numbers||[])if(!erpNames.has(n.mobile))erpNames.set(n.mobile,x.name);}
  const groups=makePlan(contacts,erpNames);
  const ins=await db.from('lwb_gdedupe_runs').insert({by_user:uid,plan:{accounts:accs.map(x=>x.email),contacts,groups}}).select('id').single();
  if(ins.error)throw Error('Cannot save the scan');
  return {run_id:ins.data.id,accounts:accs.map(x=>x.email),contacts:contacts.length,
    groups:groups.map(gr=>({m:gr.m,masked:mask(gr.m),erp_name:gr.erp_name,fixed:gr.fixed,keep:gr.keep,
      items:gr.ids.map(i=>({i,acc:contacts[i].acc,name:contacts[i].name||'(no name)',erp:contacts[i].erp,more:contacts[i].phones.length>1}))})),
    backup:contacts.map(x=>[accs[x.acc].email,x.name,x.phones.join(' / '),x.erp?'LWB ERP':''])};
}
async function apply(c,uid,runId,picks){
  const r=await db.from('lwb_gdedupe_runs').select('*').eq('id',runId).maybeSingle();
  if(r.error||!r.data)throw Error('Scan not found. Press Scan again.');
  if(r.data.applied_at)throw Error('This scan is already done. Press Scan again.');
  if(Date.now()-Date.parse(r.data.created_at)>60*60e3)throw Error('This scan is old. Press Scan again.');
  const {contacts,groups,accounts}=r.data.plan,act=actions(contacts,groups,picks||{});
  const accs=await accountsOf(c);
  if(accs.map(x=>x.email).join('|')!==accounts.join('|'))throw Error('Gmail list changed. Press Scan again.');
  const out={deleted:0,changed:0,left:0,errors:[]},t0=Date.now();
  await db.from('lwb_gdedupe_runs').update({applied_at:new Date().toISOString(),result:{running:true}}).eq('id',runId);
  for(let a=0;a<accs.length;a++){
    const d=act.del.filter(x=>x.acc===a),u=act.upd.filter(x=>x.acc===a);if(!d.length&&!u.length)continue;
    const at=await token(c,accs[a].extra);
    for(let i=0;i<d.length;i+=200){if(Date.now()-t0>110e3){out.left+=d.length-i;break;}await delMany(at,d.slice(i,i+200).map(x=>x.rn));out.deleted+=Math.min(200,d.length-i);}
    for(const x of u){
      if(Date.now()-t0>110e3){out.left++;continue;}
      try{const p=await g(at,'GET',x.rn+'?personFields=phoneNumbers');const drop=new Set(x.drop);
        const keep=(p.phoneNumbers||[]).filter(n=>!drop.has(mob(n.value||n.canonicalForm)));
        if(keep.length===(p.phoneNumbers||[]).length)continue;
        if(!keep.length){await g(at,'DELETE',x.rn+':deleteContact');out.deleted++;continue;}
        await g(at,'PATCH',x.rn+':updateContact?updatePersonFields=phoneNumbers',{etag:p.etag,phoneNumbers:keep.map(n=>({value:n.value,type:n.type}))});out.changed++;
      }catch(e){if(e.status!==404)out.errors.push(String(e.message||e).slice(0,120));}
    }
  }
  out.numbers=groups.length;out.ok=!out.errors.length;out.errors=out.errors.slice(0,5);
  await db.from('lwb_gdedupe_runs').update({result:out}).eq('id',runId);
  return out;
}

Deno.serve(async req=>{
  const h=headers(req.headers.get('origin')||'');const reply=(s,v)=>new Response(JSON.stringify(v),{status:s,headers:h});
  if(req.method==='OPTIONS')return new Response('ok',{headers:h});
  if(req.method!=='POST')return reply(405,{error:'POST only'});
  let body={};try{body=await req.json();}catch(_){return reply(400,{error:'Bad request'});}
  try{
    const c=await cfg();
    if(body.action==='sync'&&req.headers.get('x-lwb-gsync-secret')){
      if(!sameSecret(req.headers.get('x-lwb-gsync-secret')||'',c.webhook_secret))return reply(401,{error:'Unauthorized'});
      if(!c.refresh_token)return reply(200,{status:'not_connected'});
      return reply(200,await sync(c,'nightly'));
    }
    const jwt=(req.headers.get('authorization')||'').replace(/^Bearer\s+/i,'');
    const au=await db.auth.getUser(jwt);if(au.error||!au.data.user)return reply(401,{error:'Login required'});
    const uid=au.data.user.id,pr=await db.from('user_profiles').select('active,role,full_name').eq('id',uid).maybeSingle();
    if(pr.error||!pr.data?.active||String(pr.data.role).trim().toLowerCase()!=='admin')return reply(403,{error:'Only Admin can use Gmail sync'});
    if(body.action==='start'){
      if(!c.client_id||!c.client_secret)return reply(400,{error:'Save the Google Client ID and Secret first'});
      const state=crypto.randomUUID().replace(/-/g,'')+crypto.randomUUID().replace(/-/g,'');
      if(body.extra&&!c.refresh_token)return reply(400,{error:'Connect the main Gmail first'});
      await setCfg({oauth_state:state,oauth_state_by:uid,oauth_state_at:new Date().toISOString(),oauth_extra:!!body.extra});
      const u=new URL('https://accounts.google.com/o/oauth2/v2/auth');
      u.search=new URLSearchParams({client_id:c.client_id,redirect_uri:REDIRECT,response_type:'code',scope:SCOPE,access_type:'offline',prompt:'consent',include_granted_scopes:'true',state}).toString();
      return reply(200,{url:u.toString()});
    }
    if(body.action==='callback'){
      const code=String(body.code||''),state=String(body.state||'');
      if(!code||!c.oauth_state||!sameSecret(state,c.oauth_state)||c.oauth_state_by!==uid||Date.now()-Date.parse(c.oauth_state_at)>20*60e3)
        return reply(400,{error:'This Google login link is old. Press Connect Gmail again.'});
      await setCfg({oauth_state:null});
      const r=await fetch('https://oauth2.googleapis.com/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
        body:new URLSearchParams({code,client_id:c.client_id,client_secret:c.client_secret,redirect_uri:REDIRECT,grant_type:'authorization_code'})});
      const j=await r.json().catch(()=>({}));
      if(!r.ok||!j.refresh_token)return reply(400,{error:'Google did not give the login: '+(j.error_description||j.error||'no refresh token, try again')});
      if(!String(j.scope||'').includes('auth/contacts'))return reply(400,{error:'Please tick "See, edit, download and delete your contacts" on the Google page.'});
      let email=null;try{const ui=await fetch('https://openidconnect.googleapis.com/v1/userinfo',{headers:{Authorization:'Bearer '+j.access_token}});email=(await ui.json()).email||null;}catch(_){}
      if(c.oauth_extra){ // another Gmail, only for the duplicate cleaner: ERP contacts are not synced to it
        await setCfg({oauth_extra:false});
        if(!email)return reply(400,{error:'Google did not tell the Gmail address. Try again.'});
        if(email===c.google_email)return reply(400,{error:email+' is already the main Gmail. Choose your other Gmail.'});
        const u=await db.from('lwb_gsync_accounts').upsert({email,refresh_token:j.refresh_token,connected_by:uid,connected_at:new Date().toISOString()},{onConflict:'email'});
        if(u.error)throw Error('Run lwb_gmail_dedupe_setup.sql first');
        return reply(200,{connected:true,extra:true,email});
      }
      const changedAcc=c.google_email&&email&&c.google_email!==email;
      if(changedAcc){const d=await db.from('lwb_gsync_map').delete().neq('key','');if(d.error)throw Error('Cannot reset sync list');}
      await setCfg({refresh_token:j.refresh_token,google_email:email,connected_by:uid,connected_at:new Date().toISOString(),group_rn:changedAcc?null:c.group_rn});
      const res=await sync(await cfg(),'connect');
      return reply(200,{connected:true,email,result:res});
    }
    if(body.action==='sync'){if(!c.refresh_token)return reply(400,{error:'Connect Gmail first'});return reply(200,await sync(c,pr.data.full_name||'Admin'));}
    if(body.action==='remove_account'){
      const a=await db.from('lwb_gsync_accounts').select('refresh_token').eq('email',String(body.email||'')).maybeSingle();
      if(a.data?.refresh_token)try{await fetch('https://oauth2.googleapis.com/revoke?token='+encodeURIComponent(a.data.refresh_token),{method:'POST'});}catch(_){}
      await db.from('lwb_gsync_accounts').delete().eq('email',String(body.email||''));return reply(200,{removed:true});
    }
    if(body.action==='dedupe_scan'){if(!c.refresh_token)return reply(400,{error:'Connect Gmail first'});return reply(200,await scan(c,uid));}
    if(body.action==='dedupe_apply'){if(!c.refresh_token)return reply(400,{error:'Connect Gmail first'});
      return reply(200,await apply(c,uid,Number(body.run_id),body.picks&&typeof body.picks==='object'?body.picks:{}));}
    if(body.action==='disconnect'){
      if(c.refresh_token)try{await fetch('https://oauth2.googleapis.com/revoke?token='+encodeURIComponent(c.refresh_token),{method:'POST'});}catch(_){}
      await setCfg({refresh_token:null});return reply(200,{connected:false});
    }
    return reply(400,{error:'Unknown action'});
  }catch(e){return reply(500,{error:String(e.message||e).slice(0,300)});}
});
