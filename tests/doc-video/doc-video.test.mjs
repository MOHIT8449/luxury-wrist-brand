import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_doc_video_setup.sql (after lwb_documents_setup.sql) on an empty PGlite database (no live data).
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
await db.exec(fa);
const vid=await readFile(new URL('../../lwb_doc_video_setup.sql',import.meta.url),'utf8');
await db.exec(vid);await db.exec(vid); // safe to run again

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

const B='11111111-2222-4333-8444-555555555555';
async function addAs(who,entity,type,ext,mime){
  await as(who);const p=pathFor(who,entity,B,type,ext);
  await call("insert into storage.objects(bucket_id,name) values('lwb-documents',$1)",[p]);
  return call('select lwb_doc_add($1,$2,$3,$4,$5,$6,$7,null) id',[entity,B,type,p,'v.'+ext,mime,5000000]);
}

test('bucket takes videos up to 50 MB', async()=>{
  const b=(await db.query("select public,file_size_limit,allowed_mime_types from storage.buckets where id='lwb-documents'")).rows[0];
  assert.equal(b.public,false);assert.equal(Number(b.file_size_limit),52428800);
  for(const m of ['video/mp4','video/quicktime','image/jpeg','application/pdf'])assert.ok(b.allowed_mime_types.includes(m),m);
});

test('Godown Manager adds a damage video to a purchase bill; it is listed', async()=>{
  const r=await addAs('godown','PURCHASE_BILL','DAMAGE','mp4','video/mp4');
  assert.ok(Number(r[0].id)>0);
  await addAs('godown','PURCHASE_BILL','DAMAGE','mov','video/quicktime');
  await as('admin');
  const l=await call('select doc_type,mime from lwb_doc_list($1,$2)',['PURCHASE_BILL',[B]]);
  assert.deepEqual(l.map(x=>x.mime).sort(),['video/mp4','video/quicktime']);
});

test('videos are refused outside purchase damage, other files still refused', async()=>{
  await assert.rejects(addAs('godown','PURCHASE_BILL','BILL','mp4','video/mp4'),/only be added as purchase damage/);
  await assert.rejects(addAs('godown','PURCHASE_BILL','DAMAGE','html','text/html'),/Only photos/);
  const ok=await addAs('godown','PURCHASE_BILL','DAMAGE','jpg','image/jpeg');assert.ok(Number(ok[0].id)>0);
});
