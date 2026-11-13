import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_sku_photo_setup.sql on an empty PGlite database; storage.* is a small stand-in for Supabase Storage.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  godown:'00000000-0000-4000-8000-000000000003',sales:'00000000-0000-4000-8000-000000000005',off:'00000000-0000-4000-8000-000000000009'};
const sku='10000000-0000-4000-8000-000000000001';
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE SCHEMA storage;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
CREATE TABLE public.sku_master(id uuid primary key,sku_name text);
CREATE TABLE storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
CREATE TABLE storage.objects(id bigserial primary key,bucket_id text,name text);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
CREATE POLICY all_read ON storage.objects FOR SELECT TO authenticated USING (true);
GRANT USAGE ON SCHEMA public, auth, storage TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO authenticated;
GRANT USAGE ON SEQUENCE storage.objects_id_seq TO authenticated;
`);
await db.query("insert into user_profiles values ($1,'ADMIN',true),($2,'manager',true),($3,'warehouse',true),($4,'sales',true),($5,'admin',false)",Object.values(ids));
await db.query("insert into sku_master values ($1,'250ML THUMS UP MRP 20')",[sku]);
const sql=await readFile(new URL('../../lwb_sku_photo_setup.sql',import.meta.url),'utf8');
await db.exec(sql);await db.exec(sql); // safe to run again

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const put=(who,name)=>as(who).then(()=>call("insert into storage.objects(bucket_id,name) values('lwb-sku-photos',$1)",[name]));

test('bucket is public, 1 MB, photos only', async()=>{
  const b=(await db.query("select public,file_size_limit,allowed_mime_types from storage.buckets where id='lwb-sku-photos'")).rows[0];
  assert.equal(b.public,true);assert.equal(Number(b.file_size_limit),1048576);
  assert.deepEqual(b.allowed_mime_types,['image/jpeg','image/png','image/webp']);
});

test('Admin and Sales Head upload; Godown, Salesman, inactive login cannot', async()=>{
  await put('admin',sku+'/1731480000000.jpg');
  await put('head',sku+'/1731480000001.webp');
  for(const who of ['godown','sales','off'])await assert.rejects(put(who,sku+'/1731480000002.jpg'),/row-level security/,who);
});

test('upload only into the folder of a SKU that exists, photo files only', async()=>{
  await assert.rejects(put('admin','20000000-0000-4000-8000-000000000009/1.jpg'),/row-level security/);
  await assert.rejects(put('admin',sku+'/evil.html'),/row-level security/);
  await assert.rejects(put('admin',sku+'/a/b.jpg'),/row-level security/);
});

test('remove: Admin / Sales Head only', async()=>{
  await as('sales');await call("delete from storage.objects where bucket_id='lwb-sku-photos'");
  assert.equal((await db.query("select count(*)::int n from storage.objects where bucket_id='lwb-sku-photos'")).rows[0].n,2);
  await as('head');await call("delete from storage.objects where bucket_id='lwb-sku-photos' and name like '%.webp'");
  assert.equal((await db.query("select count(*)::int n from storage.objects where bucket_id='lwb-sku-photos'")).rows[0].n,1);
});

test('image_url: https link only, NULL clears it', async()=>{
  await db.query("update sku_master set image_url='https://x.supabase.co/storage/v1/object/public/lwb-sku-photos/'||id||'/1.jpg'");
  await assert.rejects(db.query("update sku_master set image_url='javascript:alert(1)'"),/sku_master_image_url_ok/);
  await assert.rejects(db.query(`update sku_master set image_url='https://a.b/x" onerror="y'`),/sku_master_image_url_ok/);
  await db.query("update sku_master set image_url=null");
});
