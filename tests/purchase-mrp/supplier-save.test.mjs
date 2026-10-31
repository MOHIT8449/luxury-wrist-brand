import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_supplier_save_setup.sql. The browser role may write only the old columns (like the
// live table), so a direct insert with company_id is refused and the RPC must work.
const ids={admin:'00000000-0000-4000-8000-000000000001',manager:'00000000-0000-4000-8000-000000000002'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.lwb_companies(id uuid default gen_random_uuid() primary key,name text);
CREATE SEQUENCE public.sup_seq;
CREATE TABLE public.lwb_supplier_master(id uuid default gen_random_uuid() primary key,supplier_code text default 'SUP-'||lpad(nextval('public.sup_seq')::text,3,'0'),
  supplier_name text not null,gstin text,pan text,contact_person text,mobile text,email text,address text,city text,state text,pincode text,payment_terms text,
  is_active boolean default true,company_id uuid references lwb_companies(id));
GRANT USAGE ON SCHEMA public, auth TO authenticated;
GRANT SELECT ON public.lwb_supplier_master TO authenticated;
GRANT INSERT (supplier_name,gstin,is_active), UPDATE (supplier_name,gstin,is_active) ON public.lwb_supplier_master TO authenticated;
GRANT USAGE ON SEQUENCE public.sup_seq TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,k,k]);
const setup=await readFile(new URL('../../lwb_supplier_save_setup.sql',import.meta.url),'utf8');
await db.exec(setup);await db.exec(setup);
const RAJ=(await db.query("insert into lwb_companies(name) values('RAJNIGANDHA') returning id")).rows[0].id;
async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]])}
async function call(q,a=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,a)).rows}finally{await db.exec('RESET ROLE')}}
const save=p=>call('select public.lwb_supplier_save($1::jsonb) id',[JSON.stringify(p)]).then(r=>r[0].id);

test('direct insert with company_id is refused (the reported error)',async()=>{
  await as('admin');
  await assert.rejects(call("insert into lwb_supplier_master(supplier_name,company_id) values('X',$1)",[RAJ]),/permission denied/);
});
test('admin adds and edits a supplier with brand through the RPC',async()=>{
  await as('admin');
  const id=await save({supplier_name:' DHARAMPAL  SATYAPAL LTD. ',gstin:'24aaacd0132h1ze',company_id:RAJ,is_active:true,state:'Gujarat'});
  let r=(await db.query('select * from lwb_supplier_master where id=$1',[id])).rows[0];
  assert.equal(r.supplier_name,'DHARAMPAL SATYAPAL LTD.');assert.equal(r.gstin,'24AAACD0132H1ZE');assert.equal(r.company_id,RAJ);assert.equal(r.supplier_code,'SUP-001');
  await save({id,supplier_name:'DHARAMPAL SATYAPAL LTD.',company_id:null,is_active:false});
  r=(await db.query('select * from lwb_supplier_master where id=$1',[id])).rows[0];
  assert.equal(r.company_id,null);assert.equal(r.is_active,false);assert.equal(r.state,null);
});
test('duplicate name and non-admin are refused',async()=>{
  await as('admin');
  await assert.rejects(save({supplier_name:'dharampal satyapal ltd.'}),/already exists/);
  await as('manager');
  await assert.rejects(save({supplier_name:'NEW ONE'}),/Admin/);
});
