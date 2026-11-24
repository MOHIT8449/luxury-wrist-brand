/**
 * Luxury Wrist Brand — Party GST / PAN verify (party-kyc.js, Party Master popup).
 *
 * POST {gstin} -> legal name, trade name, GST status, address (city, pincode)
 * POST {pan, name?} -> name on PAN, valid
 * Only a logged-in, active ERP user can call it (JWT checked by Supabase + user_profiles here).
 *
 * Provider (Edge Function secrets, Supabase > Edge Functions > Secrets). Both are paid per check:
 *   KYC_PROVIDER=cashfree   CASHFREE_CLIENT_ID, CASHFREE_CLIENT_SECRET   (Cashfree Secure ID / Verification Suite)
 *   KYC_PROVIDER=surepass   SUREPASS_TOKEN                                 (Surepass KYC API)
 * With no provider / keys the function answers in DEMO mode: a sample name, marked demo:true,
 * so the screen can be tried before an account is opened. Nothing in DEMO mode comes from GST.
 */
import { createClient } from 'npm:@supabase/supabase-js@2.118.0';

const OWN=['https://luxurywristbrand.com','https://www.luxurywristbrand.com'];
const ok=(o:string)=>OWN.includes(o)||o==='https://luxury-wrist-brand.pages.dev'||/^https:\/\/[a-z0-9-]+\.luxury-wrist-brand\.pages\.dev$/.test(o);
const headers=(origin:string)=>({'Access-Control-Allow-Origin':ok(origin)?origin:'https://luxurywristbrand.com',
  'Access-Control-Allow-Headers':'authorization,apikey,x-client-info,content-type','Access-Control-Allow-Methods':'POST, OPTIONS',
  'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin'});
const ROLES=['admin','manager','accounts','sales','salesman','sales_head','cashier'];
const env=(k:string)=>(Deno.env.get(k)||'').trim();
const T=(v:unknown)=>String(v??'').replace(/\s+/g,' ').trim();
const GST_RE=/^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/, PAN_RE=/^[A-Z]{5}[0-9]{4}[A-Z]$/;

type Gst={valid:boolean,legal_name?:string,trade_name?:string,status?:string,address?:string,city?:string,pincode?:string,constitution?:string,registered_on?:string};
type Pan={valid:boolean,name?:string};

// Pull city + pincode out of a one-line GST address ("..., Surat, Gujarat, 395003").
function place(addr:string){const pin=(addr.match(/\b[1-9][0-9]{5}\b/)||[''])[0];
  const parts=addr.split(',').map(T).filter(Boolean).filter(p=>!/^[0-9]{6}$/.test(p));
  return {pincode:pin,city:parts.length>=2?parts[parts.length-2]:''}}
function addrOf(a:any):string{if(!a)return '';if(typeof a==='string')return T(a);
  return T(['bno','bnm','flno','st','loc','dst','city','stcd','pncd'].map(k=>T(a[k])).filter(Boolean).join(', '))}

// ---------- Cashfree (https://api.cashfree.com/verification) ----------
async function cashfree(path:string,body:unknown){
  const r=await fetch('https://api.cashfree.com/verification/'+path,{method:'POST',headers:{'Content-Type':'application/json',
    'x-client-id':env('CASHFREE_CLIENT_ID'),'x-client-secret':env('CASHFREE_CLIENT_SECRET')},body:JSON.stringify(body)});
  const j=await r.json().catch(()=>({}));if(!r.ok&&r.status!==422)throw Error(T(j?.message)||'Provider error '+r.status);return j}
async function cfGst(g:string):Promise<Gst>{const j=await cashfree('gstin',{GSTIN:g});if(j?.valid===false)return {valid:false};
  const address=addrOf(j.principal_place_address||j.principal_place_split_address);
  return {valid:true,legal_name:T(j.legal_name_of_business),trade_name:T(j.trade_name_of_business),status:T(j.gst_in_status),
    address,...place(address),constitution:T(j.constitution_of_business),registered_on:T(j.date_of_registration)}}
async function cfPan(p:string,name:string):Promise<Pan>{const j=await cashfree('pan',{pan:p,name:name||undefined});
  return {valid:j?.valid!==false&&!!T(j.registered_name),name:T(j.registered_name)}}

// ---------- Surepass (https://kyc-api.surepass.io) ----------
async function surepass(path:string,body:unknown){
  const r=await fetch('https://kyc-api.surepass.io/api/v1/'+path,{method:'POST',headers:{'Content-Type':'application/json',
    Authorization:'Bearer '+env('SUREPASS_TOKEN')},body:JSON.stringify(body)});
  const j=await r.json().catch(()=>({}));if(r.status===422||r.status===404)return {data:null};if(!r.ok)throw Error(T(j?.message)||'Provider error '+r.status);return j}
async function spGst(g:string):Promise<Gst>{const d=(await surepass('corporate/gstin',{id_number:g})).data;if(!d)return {valid:false};
  const address=addrOf(d.address||d.contact_details?.principal?.address);
  return {valid:true,legal_name:T(d.legal_name),trade_name:T(d.business_name),status:T(d.gstin_status),address,...place(address),
    constitution:T(d.constitution_of_business),registered_on:T(d.date_of_registration)}}
async function spPan(p:string):Promise<Pan>{const d=(await surepass('pan/pan',{id_number:p})).data;return d?{valid:true,name:T(d.full_name)}:{valid:false}}

// ---------- DEMO (no account yet): same number always gives the same sample answer ----------
const DEMO_NAMES=['SHREE KRISHNA TRADERS','MAHADEV ENTERPRISE','JAY AMBE AGENCY','RADHE PROVISION STORE','OM SAI GENERAL STORES','GANESH DISTRIBUTORS'];
const DEMO_CITY=[['Surat','395003','Ring Road, Udhna'],['Ahmedabad','380001','Relief Road'],['Vadodara','390001','Mandvi'],['Rajkot','360001','Dhebar Road']];
const h=(s:string)=>[...s].reduce((a,c)=>(a*31+c.charCodeAt(0))>>>0,7);
function demoGst(g:string):Gst{const n=h(g),c=DEMO_CITY[n%DEMO_CITY.length];const address=`Shop 12, ${c[2]}, ${c[0]}, Gujarat, ${c[1]}`;
  return {valid:true,legal_name:DEMO_NAMES[n%DEMO_NAMES.length],trade_name:DEMO_NAMES[n%DEMO_NAMES.length],
    status:g.endsWith('X')?'Cancelled':'Active',address,city:c[0],pincode:c[1],constitution:'Proprietorship',registered_on:'01/07/2017'}}
function demoPan(p:string):Pan{const first=['RAMESH','SURESH','MAHESH','KIRAN','JIGNESH','HITESH'],last=['PATEL','SHAH','DESAI','MODI','JOSHI','VAGHELA'];
  const n=h(p);return {valid:true,name:p[3]==='P'?first[n%6]+' '+(p[4]==='P'?'PATEL':last[(n>>>3)%6]):DEMO_NAMES[n%DEMO_NAMES.length]}}

Deno.serve(async(req)=>{
  const hd=headers(req.headers.get('origin')||'');
  const reply=(status:number,v:unknown)=>new Response(JSON.stringify(v),{status,headers:hd});
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers:hd});
  if(req.method!=='POST')return reply(405,{error:'POST required'});
  try{
    if(Number(req.headers.get('content-length')||0)>1024)return reply(413,{error:'Request too large'});
    const url=env('SUPABASE_URL');let projectSecret='';try{projectSecret=JSON.parse(env('SUPABASE_SECRET_KEYS')||'{}').default||''}catch{/* legacy */}
    const secret=env('SUPABASE_SERVICE_ROLE_KEY')||projectSecret;
    const server=createClient(url,secret,{auth:{persistSession:false,autoRefreshToken:false}});
    const jwt=(req.headers.get('authorization')||'').replace(/^Bearer\s+/i,'');
    const {data:u}=await server.auth.getUser(jwt);
    if(!u?.user)return reply(401,{error:'Log in again.'});
    const {data:pr}=await server.from('user_profiles').select('role,active').eq('id',u.user.id).maybeSingle();
    if(!pr?.active||!ROLES.includes(T(pr.role).toLowerCase()))return reply(403,{error:'Your login cannot verify parties.'});

    const body=await req.json().catch(()=>({}));
    const gstin=T(body?.gstin).toUpperCase(),pan=T(body?.pan).toUpperCase(),name=T(body?.name).slice(0,120);
    if(gstin&&!GST_RE.test(gstin))return reply(400,{error:'GSTIN format is wrong.'});
    if(!gstin&&!PAN_RE.test(pan))return reply(400,{error:'Give a GSTIN or a PAN.'});

    const prov=env('KYC_PROVIDER').toLowerCase();
    const live=prov==='cashfree'?!!(env('CASHFREE_CLIENT_ID')&&env('CASHFREE_CLIENT_SECRET')):prov==='surepass'?!!env('SUREPASS_TOKEN'):false;
    if(gstin){const r=!live?demoGst(gstin):prov==='cashfree'?await cfGst(gstin):await spGst(gstin);
      return reply(200,{kind:'GST',gstin,...r,demo:!live,provider:live?prov:'demo'})}
    const r=!live?demoPan(pan):prov==='cashfree'?await cfPan(pan,name):await spPan(pan);
    return reply(200,{kind:'PAN',pan,...r,demo:!live,provider:live?prov:'demo'});
  }catch(e){
    console.error('lwb-party-kyc failed:',String((e as Error)?.message||'error').slice(0,160));
    return reply(502,{error:'GST / PAN site did not answer. Try again in a minute.'});
  }
});
