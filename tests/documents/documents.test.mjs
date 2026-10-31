import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_documents_setup.sql + lwb_fixed_assets_setup.sql on an empty PGlite database (no live data).
// storage.* is a small stand-in for Supabase Storage (buckets, objects, foldername, filename, RLS).
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  godown:'00000000-0000-4000-8000-000000000003',acc:'00000000-0000-4000-8000-000000000004',
  sales:'00000000-0000-4000-8000-000000000005',transport:'00000000-0000-4000-8000-000000000006',
  driver:'00000000-0000-4000-8000-000000000007',ticked:'00000000-0000-4000-8000-000000000008'};
const roles={admin:'admin',head:'manager',godown:'warehouse',acc:'accounts',sales:'sales',transport:'transport',driver:'driver',ticked:'sales'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE SCHEMA storage;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
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
GRANT USAGE ON SCHEMA public, auth, storage TO authenticated;
GRANT SELECT, INSERT ON storage.objects TO authenticated;
GRANT USAGE ON SEQUENCE storage.objects_id_seq TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,roles[k].toUpperCase(),'Name '+k]);
await db.query("insert into lwb_user_page_access values($1,ARRAY['fixed-assets.html','goods-inward.html'])",[ids.ticked]);

const docs=await readFile(new URL('../../lwb_documents_setup.sql',import.meta.url),'utf8');
const fa=await readFile(new URL('../../lwb_fixed_assets_setup.sql',import.meta.url),'utf8');
await db.exec(docs);await db.exec(docs); // safe to run again
await db.exec(fa);await db.exec(fa);

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const nodash=who=>ids[who].replace(/-/g,'');
let n=0;
const pathFor=(who,entity,id,type,ext='jpg')=>`${entity}/${id}/${type}/${nodash(who)}-${Date.now()}-${++n}.${ext}`;
// Upload through the storage policy, then register.
async function put(who,entity,id,type,ext='jpg'){
  await as(who);const p=pathFor(who,entity,id,type,ext);
  await call("insert into storage.objects(bucket_id,name) values('lwb-documents',$1)",[p]);
  const r=await call('select lwb_doc_add($1,$2,$3,$4,$5,$6,$7,null) id',[entity,id,type,p,'f.'+ext,ext==='pdf'?'application/pdf':'image/jpeg',1000]);
  return {id:Number(r[0].id),path:p};
}

test('bucket is private and allows photos + PDF', async()=>{
  const b=(await db.query("select public,allowed_mime_types from storage.buckets where id='lwb-documents'")).rows[0];
  assert.equal(b.public,false);
  assert.ok(b.allowed_mime_types.includes('application/pdf'));
});

test('Godown uploads an employee photo + Aadhaar; list and summary show them', async()=>{
  const ph=await put('godown','STAFF','12','PHOTO');
  await put('godown','STAFF','12','AADHAAR');
  await as('acc');
  const rows=await call('select doc_type,path,uploaded_by_name from lwb_doc_list($1,$2)',['STAFF',['12']]);
  assert.deepEqual(rows.map(r=>r.doc_type).sort(),['AADHAAR','PHOTO']);
  assert.equal(rows.find(r=>r.doc_type==='PHOTO').path,ph.path);
  assert.equal(rows[0].uploaded_by_name,'Name godown');
  const s=await call('select entity_id,doc_types from lwb_doc_summary($1)',['STAFF']);
  assert.deepEqual(s,[{entity_id:'12',doc_types:['AADHAAR','PHOTO']}]);
  // salesman and driver can not see staff documents
  await as('sales');await assert.rejects(call('select * from lwb_doc_list($1,$2)',['STAFF',['12']]),/can not view/);
  await as('driver');await assert.rejects(call('select * from lwb_doc_summary($1)',['STAFF']),/can not view/);
});

test('storage policy: only allowed folders, only own user id, read by viewers only', async()=>{
  await as('sales');
  await assert.rejects(call("insert into storage.objects(bucket_id,name) values('lwb-documents',$1)",[pathFor('sales','STAFF','12','PHOTO')]),/row-level security/);
  // a salesman may upload a party shop photo, but not under another user's id
  await call("insert into storage.objects(bucket_id,name) values('lwb-documents',$1)",[pathFor('sales','PARTY','abc-1','SHOP')]);
  await assert.rejects(call("insert into storage.objects(bucket_id,name) values('lwb-documents',$1)",[pathFor('admin','PARTY','abc-1','SHOP')]),/row-level security/);
  // unknown doc type for the record type
  await assert.rejects(call("insert into storage.objects(bucket_id,name) values('lwb-documents',$1)",[pathFor('sales','PARTY','abc-1','AADHAAR')]),/row-level security/);
  // read: transport sees vehicle files, not staff files
  await put('godown','VEHICLE','v1','PHOTO');
  await as('transport');
  const seen=(await call("select name from storage.objects where bucket_id='lwb-documents'")).map(r=>r.name);
  assert.ok(seen.some(x=>x.startsWith('VEHICLE/')));
  assert.ok(!seen.some(x=>x.startsWith('STAFF/')));
});

test('driver Aadhaar / bank are private to Admin, Sales Head, Accounts', async()=>{
  await put('head','DRIVER','d1','PHOTO');
  await put('head','DRIVER','d1','DL');
  await put('admin','DRIVER','d1','AADHAAR');
  await as('transport');
  let t=(await call('select doc_type from lwb_doc_list($1,$2)',['DRIVER',['d1']])).map(r=>r.doc_type).sort();
  assert.deepEqual(t,['DL','PHOTO']);
  await as('acc');
  t=(await call('select doc_type from lwb_doc_list($1,$2)',['DRIVER',['d1']])).map(r=>r.doc_type).sort();
  assert.deepEqual(t,['AADHAAR','DL','PHOTO']);
  // Godown can view driver photo / licence but not upload for drivers
  await as('godown');
  await assert.rejects(call("insert into storage.objects(bucket_id,name) values('lwb-documents',$1)",[pathFor('godown','DRIVER','d1','PHOTO')]),/row-level security/);
});

test('register checks: path must match, file must exist, type and count limits', async()=>{
  await as('acc');
  const p=pathFor('acc','PURCHASE_BILL','11111111-2222-4333-8444-555555555555','BILL','pdf');
  await assert.rejects(call('select lwb_doc_add($1,$2,$3,$4,null,$5,0,null)',['PURCHASE_BILL','11111111-2222-4333-8444-555555555555','BILL',p,'application/pdf']),/File not found/);
  await call("insert into storage.objects(bucket_id,name) values('lwb-documents',$1)",[p]);
  await assert.rejects(call('select lwb_doc_add($1,$2,$3,$4,null,$5,0,null)',['PURCHASE_BILL','other-id','BILL',p,'application/pdf']),/Wrong file path/);
  await assert.rejects(call('select lwb_doc_add($1,$2,$3,$4,null,$5,0,null)',['PURCHASE_BILL','11111111-2222-4333-8444-555555555555','BILL',p,'text/html']),/Only photos/);
  const r=await call('select lwb_doc_add($1,$2,$3,$4,null,$5,0,null) id',['PURCHASE_BILL','11111111-2222-4333-8444-555555555555','BILL',p,'application/pdf']);
  assert.ok(Number(r[0].id)>0);
  for(let i=0;i<9;i++)await put('godown','STOCK_MOVE','77','DAMAGE');
  await put('head','STOCK_MOVE','77','DAMAGE');
  // Accounts can view godown damage photos but not add them
  await as('acc');
  await assert.rejects(call("insert into storage.objects(bucket_id,name) values('lwb-documents',$1)",[pathFor('acc','STOCK_MOVE','77','DAMAGE')]),/row-level security/);
  assert.equal((await call('select * from lwb_doc_list($1,$2)',['STOCK_MOVE',['77']])).length,10);
  await as('godown');
  const p2=pathFor('godown','STOCK_MOVE','77','DAMAGE');
  await call("insert into storage.objects(bucket_id,name) values('lwb-documents',$1)",[p2]);
  await assert.rejects(call('select lwb_doc_add($1,$2,$3,$4,null,$5,0,null)',['STOCK_MOVE','77','DAMAGE',p2,'image/jpeg']),/Maximum 10/);
});

test('remove hides the file but keeps the row', async()=>{
  const f=await put('admin','PARTY','p9','PAN');
  await as('sales');
  assert.equal((await call('select lwb_doc_remove($1) ok',[f.id]))[0].ok,true);
  assert.equal((await call('select * from lwb_doc_list($1,$2)',['PARTY',['p9']])).length,0);
  const row=(await db.query('select removed_at,removed_by from lwb_documents where id=$1',[f.id])).rows[0];
  assert.ok(row.removed_at);assert.equal(row.removed_by,ids.sales);
  await as('driver');await assert.rejects(call('select lwb_doc_remove($1)',[f.id]),/not found|can not/);
});

test('KYC details: checked, cleaned, private', async()=>{
  await as('godown');
  await assert.rejects(call('select lwb_doc_info_save($1,$2,$3)',['STAFF','12',{aadhaar_no:'1234'}]),/12 digits/);
  await assert.rejects(call('select lwb_doc_info_save($1,$2,$3)',['STAFF','12',{bank_ifsc:'SBIN1234'}]),/IFSC/);
  const v=(await call('select lwb_doc_info_save($1,$2,$3) v',['STAFF','12',{aadhaar_no:'2345 6789 0123',pan_no:'abcde1234f',bank_account:'0012 3456 789',bank_ifsc:'sbin0001234',bank_name:'SBI',junk:'x'}]))[0].v;
  assert.deepEqual(v,{aadhaar_no:'234567890123',pan_no:'ABCDE1234F',bank_account:'00123456789',bank_ifsc:'SBIN0001234',bank_name:'SBI'});
  await as('acc');
  assert.equal((await call('select info from lwb_doc_info_get($1,$2)',['STAFF',['12']]))[0].info.bank_ifsc,'SBIN0001234');
  await as('transport');await assert.rejects(call('select * from lwb_doc_info_get($1,$2)',['DRIVER',['d1']]),/can not view/);
  await as('sales');await assert.rejects(call('select lwb_doc_info_save($1,$2,$3)',['PARTY','p1',{}]),/can not change/);
});

test('page ticked by Admin gives upload rights; driver never', async()=>{
  const f=await put('ticked','ASSET','a1','PHOTO');
  assert.ok(f.id>0);
  await put('ticked','PURCHASE_BILL','b1','BILL','pdf');
  await as('driver');
  await assert.rejects(call("insert into storage.objects(bucket_id,name) values('lwb-documents',$1)",[pathFor('driver','ORDER','o1','DAMAGE')]),/row-level security/);
});

test('fixed assets: ID fills itself, edit roles, godown read only, no delete', async()=>{
  await as('acc');
  await call("insert into lwb_fixed_assets(asset_name,category,amount) values('HP LaserJet printer','Computer / Printer',18500)");
  await call("insert into lwb_fixed_assets(asset_name,asset_code) values('Weighing scale','FA010')");
  await call("insert into lwb_fixed_assets(asset_name) values('Pallet truck')");
  const rows=await call('select asset_code,asset_name,created_by from lwb_fixed_assets order by asset_code');
  assert.deepEqual(rows.map(r=>r.asset_code),['FA001','FA010','FA011']);
  assert.equal(rows[0].created_by,ids.acc);
  await as('godown');
  assert.equal((await call('select count(*)::int c from lwb_fixed_assets'))[0].c,3);
  await assert.rejects(call("insert into lwb_fixed_assets(asset_name) values('AC')"),/row-level security/);
  assert.equal((await call("update lwb_fixed_assets set status='SOLD' returning id")).length,0);
  await as('sales');assert.equal((await call('select count(*)::int c from lwb_fixed_assets'))[0].c,0);
  await as('head');
  const u=await call("update lwb_fixed_assets set status='SCRAPPED' where asset_code='FA011' returning updated_by,created_by");
  assert.equal(u[0].updated_by,ids.head);assert.equal(u[0].created_by,ids.acc);
  await assert.rejects(call('delete from lwb_fixed_assets'),/permission denied/);
});
