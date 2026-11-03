import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_party_master_save_fix.sql on an empty PGlite database (no live data).
// The signed-in role has only SELECT on lwb_customer_master, like the live error
// "permission denied for table lwb_customer_master".
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  nadim:'00000000-0000-4000-8000-000000000003'};
const roles={admin:'admin',head:'manager',nadim:'sales'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text,mobile text);
CREATE SEQUENCE public.cus_seq;
CREATE TABLE public.lwb_customer_master(id uuid default gen_random_uuid() primary key,
  customer_code text default 'CUS-'||lpad(nextval('public.cus_seq')::text,6,'0'),
  customer_name text not null,gst_registration_status text,pan text,gstin text,billing_address text,city text,state text,
  mobile text,pincode text,contact_person text,credit_days int default 0,is_active boolean default true,
  kyc_free_orders int,min_order_kg numeric(10,2),order_every_days int);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,created_by uuid);
CREATE TABLE public.order_items(id uuid default gen_random_uuid() primary key,order_id uuid,sku_name text);
CREATE TABLE public.sku_master(id serial primary key,sku_name text);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3,null)',[id,roles[k],'Name '+k]);
const load=async f=>db.exec(await readFile(new URL('../../'+f,import.meta.url),'utf8'));
await load('lwb_sales_team_setup.sql');
await load('lwb_sales_head_in_team_setup.sql');
await load('lwb_party_master_save_fix.sql');
await load('lwb_party_master_save_fix.sql'); // safe to run again

async function run(who,q,params){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);
  await db.exec('SET ROLE authenticated');
  try{return await db.query(q,params)}finally{await db.exec('RESET ROLE')}
}
const P=(await db.query(`insert into lwb_customer_master(customer_name,city,credit_days) values('VARIETY DEPARTMENTAL STORES','SURAT',0),('OTHER SHOP','BARDOLI',0) returning id`)).rows.map(r=>r.id);

test('direct update is refused for every signed-in login (the live error)', async()=>{
  await assert.rejects(run('admin',`update lwb_customer_master set city='X' where id=$1`,[P[0]]),/permission denied for table lwb_customer_master/);
  await assert.rejects(run('nadim',`update lwb_customer_master set city='X' where id=$1`,[P[0]]),/permission denied/);
});

test('Admin edits a party through lwb_party_master_save', async()=>{
  const r=await run('admin',`select public.lwb_party_master_save($1,$2::jsonb) id`,[P[0],JSON.stringify({
    customer_name:'VARIETY DEPARTMENTAL STORES (KATARGAM)',gst_registration_status:'REGISTERED',gstin:'24BAMPK0957R1Z1',
    pan:'BAMPK0957R',credit_days:'7',is_active:true,kyc_free_orders:null,min_order_kg:null,customer_code:'HACK',id:P[1]})]);
  assert.equal(r.rows[0].id,P[0]);
  const m=(await db.query('select * from lwb_customer_master where id=$1',[P[0]])).rows[0];
  assert.equal(m.customer_name,'VARIETY DEPARTMENTAL STORES (KATARGAM)');assert.equal(m.credit_days,7);
  assert.equal(m.city,'SURAT');assert.notEqual(m.customer_code,'HACK');
});

test('Admin adds a party (gets its own Customer Code) and inactivates old parties', async()=>{
  const id=(await run('admin',`select public.lwb_party_master_save(null,$1::jsonb) id`,[JSON.stringify({customer_name:'NEW SHOP',state:'Gujarat',credit_days:0,is_active:true})])).rows[0].id;
  const m=(await db.query('select * from lwb_customer_master where id=$1',[id])).rows[0];
  assert.match(m.customer_code,/^CUS-/);assert.equal(m.state,'Gujarat');
  const n=(await run('admin',`select public.lwb_party_master_set_active($1::uuid[],false) n`,[[id,P[1]]])).rows[0].n;
  assert.equal(n,2);
  assert.equal((await db.query('select count(*)::int c from lwb_customer_master where is_active=false')).rows[0].c,2);
});

test('Sales Head and salesman cannot save the Party Master', async()=>{
  for(const who of ['head','nadim']){
    await assert.rejects(run(who,`select public.lwb_party_master_save($1,'{"city":"X"}'::jsonb)`,[P[0]]),/Only Admin/);
    await assert.rejects(run(who,`select public.lwb_party_master_set_active($1::uuid[],true)`,[[P[1]]]),/Only Admin/);
  }
});

test('salesman still sees only his assigned parties', async()=>{
  await db.query("insert into lwb_salesmen(user_id,kind) values($1,'FIELD') on conflict do nothing",[ids.nadim]);
  assert.equal((await run('nadim','select id from lwb_customer_master')).rows.length,0);
  await run('admin','select public.lwb_assign_parties($1::uuid[],$2)',[[P[0]],ids.nadim]);
  const seen=(await run('nadim','select id from lwb_customer_master')).rows.map(r=>r.id);
  assert.deepEqual(seen,[P[0]]);
  assert.equal((await run('admin','select id from lwb_customer_master')).rows.length,3);
});
