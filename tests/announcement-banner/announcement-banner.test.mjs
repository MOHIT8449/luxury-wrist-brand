import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_announcement_banner_setup.sql on top of the old announcements setup (no live database).
const ids={admin:'00000000-0000-4000-8000-000000000001',manager:'00000000-0000-4000-8000-000000000002',sales:'00000000-0000-4000-8000-000000000003'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE SCHEMA storage;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
CREATE TABLE storage.objects(id bigserial primary key,bucket_id text,name text);
CREATE FUNCTION storage.foldername(name text) RETURNS text[] LANGUAGE sql AS $$ SELECT string_to_array(name,'/') $$;
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text);
CREATE FUNCTION public.lwb_sales_head() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('admin','manager')); $fn$;
GRANT USAGE ON SCHEMA public, auth, storage TO authenticated;
GRANT SELECT, INSERT ON storage.objects TO authenticated; GRANT USAGE ON ALL SEQUENCES IN SCHEMA storage TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,k,k]);
const old=await readFile(new URL('../../lwb_announcements_market_report_setup.sql',import.meta.url),'utf8');
await db.exec(old);
async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
// A text post made before the banner setup must survive it.
await as('admin');
await call("select lwb_post_announcement('Old text post','SKU A',null)");
const setup=await readFile(new URL('../../lwb_announcement_banner_setup.sql',import.meta.url),'utf8');
await db.exec(setup);
await db.exec(setup); // safe to run again
const img=who=>ids[who]+'/1730350000000.jpg';

test('old text post is still there and the 3-arg post still works', async()=>{
  await as('manager');
  await call("select lwb_post_announcement('Text only','',null)");
  const rows=await call('select message,image_path from lwb_announcements order by id');
  assert.deepEqual(rows.map(r=>[r.message,r.image_path]),[['Old text post',null],['Text only',null]]);
});

test('banner with photo and no message is posted; everyone else gets a bell', async()=>{
  await as('admin');
  await db.query('delete from erp_notifications');
  const [{id}]=await call("select lwb_post_announcement($1,'Thums Up 300ml',current_date+2,$2) id",['',img('admin')]);
  const r=(await call('select message,image_path,sku_name from lwb_announcements where id=$1',[id]))[0];
  assert.equal(r.image_path,img('admin'));assert.equal(r.message,'');
  const n=(await db.query('select user_id,title,message from erp_notifications order by user_id')).rows;
  assert.equal(n.length,2);
  assert.equal(n[0].title,'New banner: Thums Up 300ml');
  assert.equal(n[0].message,'See the new banner on the Dashboard.');
});

test('salesman sees live banners but cannot post', async()=>{
  await as('sales');
  const rows=await call('select image_path from lwb_announcements where image_path is not null');
  assert.equal(rows.length,1);
  await assert.rejects(call("select lwb_post_announcement('x','',null,$1)",[img('sales')]),/Admin or Sales Head only/);
});

test('needs message or photo; photo must be in own folder', async()=>{
  await as('admin');
  await assert.rejects(call("select lwb_post_announcement('  ','',null,null)"),/message or add a banner photo/);
  await assert.rejects(call("select lwb_post_announcement('x','',null,$1)",[img('manager')]),/Invalid banner photo/);
  await assert.rejects(call("select lwb_post_announcement('x','',null,$1)",[ids.admin+'/../a.jpg']),/Invalid banner photo/);
  await assert.rejects(db.query("insert into lwb_announcements(message,created_by) values('',$1)",[ids.admin]),/text_or_banner/);
});

test('bucket: only heads upload into own folder; every signed-in user reads', async()=>{
  const b=(await db.query("select public,allowed_mime_types from storage.buckets where id='lwb-banners'")).rows[0];
  assert.equal(b.public,false);
  await as('admin');
  await call("insert into storage.objects(bucket_id,name) values('lwb-banners',$1)",[img('admin')]);
  await assert.rejects(call("insert into storage.objects(bucket_id,name) values('lwb-banners',$1)",[img('manager')]),/row-level security/);
  await as('sales');
  await assert.rejects(call("insert into storage.objects(bucket_id,name) values('lwb-banners',$1)",[img('sales')]),/row-level security/);
  assert.equal((await call("select name from storage.objects where bucket_id='lwb-banners'")).length,1);
});
