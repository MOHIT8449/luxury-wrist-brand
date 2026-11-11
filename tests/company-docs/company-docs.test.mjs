import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_documents_setup.sql + lwb_company_docs_setup.sql on an empty PGlite database (no live data).
const ids={admin:'00000000-0000-4000-8000-000000000001',acc:'00000000-0000-4000-8000-000000000002',
  head:'00000000-0000-4000-8000-000000000003',sales:'00000000-0000-4000-8000-000000000004',
  driver:'00000000-0000-4000-8000-000000000005',ticked:'00000000-0000-4000-8000-000000000006'};
const roles={admin:'admin',acc:'accounts',head:'manager',sales:'sales',driver:'driver',ticked:'warehouse'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
CREATE SCHEMA auth; CREATE SCHEMA storage;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,is_read boolean default false,created_at timestamptz default now());
CREATE TABLE public.lwb_user_page_access(user_id uuid,extra text[]);
CREATE FUNCTION public.lwb_has_page(p text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS(SELECT 1 FROM public.lwb_user_page_access a WHERE a.user_id=auth.uid() AND p=ANY(a.extra)) $$;
CREATE TABLE storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
CREATE TABLE storage.objects(id bigserial primary key,bucket_id text,name text);
CREATE FUNCTION storage.foldername(name text) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT (string_to_array(name,'/'))[1:array_length(string_to_array(name,'/'),1)-1] $$;
CREATE FUNCTION storage.filename(name text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT (string_to_array(name,'/'))[array_length(string_to_array(name,'/'),1)] $$;
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA public, auth, storage TO authenticated, service_role;
GRANT SELECT, INSERT ON storage.objects TO authenticated;
GRANT USAGE ON SEQUENCE storage.objects_id_seq TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,roles[k].toUpperCase(),'Name '+k]);
await db.query("insert into lwb_user_page_access values($1,ARRAY['documents.html'])",[ids.ticked]);

const docs=await readFile(new URL('../../lwb_documents_setup.sql',import.meta.url),'utf8');
const cd=await readFile(new URL('../../lwb_company_docs_setup.sql',import.meta.url),'utf8');
await db.exec(docs);await db.exec(cd);await db.exec(docs);await db.exec(cd); // safe to run again, either order

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[],role='authenticated'){await db.exec('SET ROLE '+role);try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const one=async(q,a,r)=>(await call(q,a,r))[0];
const nodash=who=>ids[who].replace(/-/g,'');
let n=0;
const pathFor=(who,id,type,ext='jpg')=>`COMPANY/${id}/${type}/${nodash(who)}-${Date.now()}-${++n}.${ext}`;
async function upload(who,id,type,ext='jpg'){await as(who);const p=pathFor(who,id,type,ext);await call("insert into storage.objects(bucket_id,name) values('lwb-documents',$1)",[p]);return p}
async function putFile(who,id,ext='jpg'){
  const p=await upload(who,id,'FILE',ext);
  await call('select lwb_doc_add($1,$2,$3,$4,$5,$6,$7,null)',['COMPANY',String(id),'FILE',p,'f.'+ext,ext==='pdf'?'application/pdf':'image/jpeg',100]);
  return p;
}
const save=async(who,p)=>{await as(who);return Number((await one('select lwb_cdoc_save($1) id',[p])).id)};
const list=async who=>{await as(who);return (await one('select lwb_cdoc_list() v')).v};

let gst,pan,aadhaar,fssai;
test('Admin and Accounts add documents; sales / Sales Head / driver can not; ticked page can', async()=>{
  gst=await save('acc',{grp:'COMPANY',name:'GST  Registration Certificate',doc_no:'24ABCDE1234F1Z5'});
  pan=await save('acc',{grp:'COMPANY',name:'Company PAN Card',doc_no:'ABCDE1234F'});
  aadhaar=await save('admin',{grp:'OWNER',name:'Aadhaar - Owner',admin_only:true});
  const l=await list('acc');
  assert.deepEqual(l.docs.map(d=>d.name).sort(),['Company PAN Card','GST Registration Certificate']);
  assert.equal((await list('admin')).docs.length,3);
  for(const w of ['sales','head','driver']){await as(w);await assert.rejects(call('select lwb_cdoc_list()'),/Admin and Accounts only/)}
  assert.equal((await list('ticked')).docs.length,2);
  await as('acc');await assert.rejects(call('select lwb_cdoc_save($1)',[{grp:'OWNER',name:'X',admin_only:true}]),/document name|Only Admin/);
  await assert.rejects(call('select lwb_cdoc_save($1)',[{grp:'OWNER',name:'Owner PAN',admin_only:true}]),/Only Admin/);
  await assert.rejects(call('select lwb_cdoc_save($1)',[{grp:'LICENSE',name:'Shop licence',issue_date:'2026-05-01',expiry_date:'2026-01-01'}]),/before the issue/);
});

test('files: COMPANY folder only for a live document; "Only Admin" files hidden from Accounts', async()=>{
  const p=await putFile('acc',gst,'pdf');
  await as('acc');
  assert.equal((await call('select * from lwb_doc_list($1,$2)',['COMPANY',[String(gst)]])).length,1);
  // no such document / not allowed
  await as('acc');
  await assert.rejects(call("insert into storage.objects(bucket_id,name) values('lwb-documents',$1)",[pathFor('acc',99999,'FILE')]),/row-level security/);
  await assert.rejects(call("insert into storage.objects(bucket_id,name) values('lwb-documents',$1)",[pathFor('acc',aadhaar,'FILE')]),/row-level security/);
  await as('sales');
  await assert.rejects(call("insert into storage.objects(bucket_id,name) values('lwb-documents',$1)",[pathFor('sales',gst,'FILE')]),/row-level security/);
  const ap=await putFile('admin',aadhaar);
  await as('acc');
  const seen=(await call("select name from storage.objects where bucket_id='lwb-documents'")).map(r=>r.name);
  assert.ok(seen.includes(p));assert.ok(!seen.includes(ap));
  assert.equal((await call('select * from lwb_doc_list($1,$2)',['COMPANY',[String(aadhaar)]])).length,0);
  assert.equal((await list('acc')).docs.find(d=>d.id==gst).files,1);
});

test('share link: watermarked copies, checks, open once counts and tells the sender, expiry and stop', async()=>{
  await putFile('acc',pan);
  const c1=await upload('acc',gst,'SHARE'),c2=await upload('acc',pan,'SHARE');
  await as('acc');
  const r=(await one('select lwb_cdoc_share_create($1) v',[{doc_ids:[gst,pan],files:[{path:c1,name:'GST certificate'},{path:c2,name:'PAN'}],party_name:'SHREE GANESH TRADERS',mobile:'+91 98250 12345',watermark:'For SHREE GANESH TRADERS only',days:7,channel:'whatsapp'}])).v;
  assert.match(r.token,/^[0-9a-f]{32}$/);assert.equal(r.files,2);
  // wrong things
  await assert.rejects(call('select lwb_cdoc_share_create($1)',[{doc_ids:[aadhaar],files:[]}]),/can not be shared/);
  await assert.rejects(call('select lwb_cdoc_share_create($1)',[{doc_ids:[gst],files:[{path:c2}]}]),/Wrong file/);
  await assert.rejects(call('select lwb_cdoc_share_create($1)',[{doc_ids:[gst],files:[{path:c1}],days:3}]),/1, 7 or 30/);
  await assert.rejects(call('select lwb_cdoc_share_create($1)',[{doc_ids:[gst],files:[]}]),/no file yet/);
  const other=await upload('admin',gst,'SHARE');await as('acc');
  await assert.rejects(call('select lwb_cdoc_share_create($1)',[{doc_ids:[gst],files:[{path:other}]}]),/Wrong file/);
  // logged-in users can not call the open function; the Edge Function (service role) can
  await assert.rejects(call('select lwb_cdoc_share_open($1)',[r.token]),/permission denied/);
  await assert.rejects(call('select lwb_cdoc_share_open($1)',[r.token],'anon'),/permission denied/);
  const o=(await one('select lwb_cdoc_share_open($1) v',[r.token],'service_role')).v;
  assert.equal(o.party_name,'SHREE GANESH TRADERS');assert.equal(o.files.length,2);assert.equal(o.by_name,'Name acc');
  await one('select lwb_cdoc_share_open($1) v',[r.token],'service_role');
  const s=(await db.query('select open_count,mobile,channel from lwb_company_doc_shares where token=$1',[r.token])).rows[0];
  assert.deepEqual(s,{open_count:2,mobile:'9825012345',channel:'WHATSAPP'});
  const bells=(await db.query("select user_id from erp_notifications where notification_type='DOC_SHARE_OPENED'")).rows;
  assert.deepEqual(bells.map(b=>b.user_id),[ids.acc]);
  assert.equal((await one('select lwb_cdoc_share_open($1) v',['0'.repeat(32)],'service_role')).v,null);
  // a removed document drops out of an old link
  const tmp=await save('acc',{grp:'OTHER',name:'Old letter'});const tf=await putFile('acc',tmp);await as('acc');
  const r2=(await one('select lwb_cdoc_share_create($1) v',[{doc_ids:[tmp,gst],files:[{path:tf},{path:c1}],days:1}])).v;
  await call('select lwb_cdoc_remove($1)',[tmp]);
  assert.equal((await one('select lwb_cdoc_share_open($1) v',[r2.token],'service_role')).v.files.length,1);
  // stop
  const sid=(await db.query('select id from lwb_company_doc_shares where token=$1',[r2.token])).rows[0].id;
  await as('acc');await call('select lwb_cdoc_share_revoke($1)',[sid]);
  assert.equal((await one('select lwb_cdoc_share_open($1) v',[r2.token],'service_role')).v.revoked,true);
  await db.query("update lwb_company_doc_shares set expires_at=now()-interval '1 minute' where token=$1",[r.token]);
  assert.equal((await one('select lwb_cdoc_share_open($1) v',[r.token],'service_role')).v.stopped,true);
  const l=await list('acc');assert.equal(l.shares.length,2);assert.equal(l.shares.every(x=>!x.live),true);
});

test('renewal reminders: once per step, every 7 days after expiry, again after renewal', async()=>{
  const today=(await db.query("select (now() at time zone 'Asia/Kolkata')::date::text d")).rows[0].d;
  const plus=k=>{const d=new Date(today+'T00:00:00Z');d.setUTCDate(d.getUTCDate()+k);return d.toISOString().slice(0,10)};
  fssai=await save('acc',{grp:'LICENSE',name:'FSSAI License',doc_no:'10726',expiry_date:plus(30),remind_days:[60,30,7,1],fees:2000,remind_roles:['accounts']});
  await save('admin',{grp:'LICENSE',name:'Trade License',expiry_date:plus(-14)});
  await save('admin',{grp:'OWNER',name:'Owner DL',expiry_date:plus(7),admin_only:true});
  await save('acc',{grp:'LICENSE',name:'Shop Act',expiry_date:plus(20)}); // 20 not a reminder day
  await db.query("delete from erp_notifications");
  await as('acc');const sent=Number((await one('select lwb_cdoc_remind_now() n')).n);
  const rows=(await db.query("select user_id,title,message from erp_notifications where notification_type='DOC_RENEWAL' order by title")).rows;
  const t=rows.map(r=>r.title+' > '+Object.keys(ids).find(k=>ids[k]===r.user_id));
  assert.ok(t.includes('Renew FSSAI License in 30 days > acc'));
  assert.ok(t.includes('Renew FSSAI License in 30 days > admin')); // admin is always added
  assert.ok(t.includes('Trade License expired 14 days ago > acc'));
  assert.ok(t.includes('Renew Owner DL in 7 days > admin'));
  assert.ok(!t.some(x=>/Owner DL > acc|Shop Act/.test(x)));
  assert.match(rows.find(r=>/FSSAI/.test(r.title)).message,/Fees Rs 2000/);
  assert.ok(sent>=rows.length);
  // same day again: nothing new for documents
  await db.query("delete from erp_notifications");await call('select lwb_cdoc_remind_now()');
  assert.equal((await db.query("select count(*)::int c from erp_notifications where notification_type='DOC_RENEWAL'")).rows[0].c,0);
  // renewed: new expiry, the 30-day step can come again later
  await save('acc',{id:fssai,grp:'LICENSE',name:'FSSAI License',expiry_date:plus(60),remind_days:[60,30]});
  await db.query("delete from erp_notifications");await as('acc');await call('select lwb_cdoc_remind_now()');
  assert.ok((await db.query("select title from erp_notifications where notification_type='DOC_RENEWAL'")).rows.some(r=>r.title==='Renew FSSAI License in 60 days'));
});

test('GST returns: one row per month; filed month gives no reminder', async()=>{
  const p=(await db.query("select to_char(date_trunc('month',(now() at time zone 'Asia/Kolkata')::date)-interval '1 month','YYYY-MM-DD') d")).rows[0].d;
  const g1=await save('acc',{grp:'GST',name:'GSTR-1',gst_type:'GSTR1',gst_period:p.slice(0,8)+'15',filed_on:p});
  await as('acc');
  await assert.rejects(call('select lwb_cdoc_save($1)',[{grp:'GST',name:'GSTR-1 again',gst_type:'GSTR1',gst_period:p}]),/already in the list/);
  await assert.rejects(call('select lwb_cdoc_save($1)',[{grp:'GST',name:'GSTR-3B',gst_type:'GSTR3B'}]),/return month/);
  const d=(await list('acc')).docs.find(x=>x.id==g1);assert.equal(d.gst_period,p);
  // force "today" to the 20th of this month = GSTR-3B due day, GSTR-1 9 days late (odd: no bell)
  await db.exec(`CREATE OR REPLACE FUNCTION public.lwb_cdoc_today() RETURNS date LANGUAGE sql STABLE SET search_path='' AS $$ SELECT (date_trunc('month',(now() AT TIME ZONE 'Asia/Kolkata')::date)+interval '19 days')::date $$`);
  await db.query("delete from erp_notifications");await call('select lwb_cdoc_remind_now()');
  const t=(await db.query("select distinct title from erp_notifications where notification_type='DOC_GST_DUE'")).rows.map(r=>r.title);
  assert.equal(t.length,1);assert.match(t[0],/^GSTR-3B .* due today$/);
  await save('acc',{grp:'GST',name:'GSTR-3B',gst_type:'GSTR3B',gst_period:p,filed_on:p});
  await db.exec("delete from erp_notifications;delete from lwb_company_doc_reminders where doc_id<0");await as('acc');await call('select lwb_cdoc_remind_now()');
  assert.equal((await db.query("select count(*)::int c from erp_notifications where notification_type='DOC_GST_DUE'")).rows[0].c,0);
});

test('packs: save, list, remove', async()=>{
  await as('acc');
  const l0=await list('acc');assert.equal(l0.packs[0].name,'KYC Pack');
  const id=Number((await one('select lwb_cdoc_pack_save($1,$2,$3) id',[l0.packs[0].id,'KYC Pack',[gst,pan]])).id);
  assert.deepEqual((await list('acc')).packs[0].doc_ids.map(Number),[gst,pan]);
  await call('select lwb_cdoc_pack_save($1,$2,$3)',[id,'',[]]);
  assert.equal((await list('acc')).packs.length,0);
});
