import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_order_bill_type_setup.sql: GST / Cash bill on every PO. Salesman only writes a note; Sales Head / Admin choose;
// party default fills new POs; bill made as the other kind and payment mode mismatches are kept + Admin / Sales Head bell.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  sales:'00000000-0000-4000-8000-000000000003',acc:'00000000-0000-4000-8000-000000000004',cash:'00000000-0000-4000-8000-000000000005'};
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE TABLE auth.users(id uuid primary key);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid);
CREATE TABLE public.lwb_customer_master(id uuid default gen_random_uuid() primary key,customer_name text,is_active boolean default true);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text,total_amount numeric,
  created_by uuid,created_at timestamptz default now());
CREATE TABLE public.lwb_tally_invoices(order_id uuid primary key,invoice_no text,amount numeric);
INSERT INTO public.user_profiles VALUES ('${ids.admin}','admin',true,'Admin'),('${ids.head}','manager',true,'Head'),
  ('${ids.sales}','salesman',true,'Ravi'),('${ids.acc}','accounts',true,'Yogesh'),('${ids.cash}','cashier',true,'Cashier');
INSERT INTO public.lwb_customer_master(customer_name) VALUES ('SHREE GANESH'),('PATEL KIRANA');
`);
// old PO made before the setup: never blocked
await db.exec(`INSERT INTO public.orders(order_no,customer_name,created_at) VALUES ('OLD','PATEL KIRANA',now()-interval '2 days')`);
const setup=await sql('lwb_order_bill_type_setup.sql');
await db.exec(setup); await db.exec(setup); // safe to run again
const as=u=>db.exec(`SELECT set_config('request.jwt.claim.sub','${u||''}',false)`);
const one=async(q,p=[])=>(await db.query(q,p)).rows[0];
const po=(no,party,type)=>one(`INSERT INTO public.orders(order_no,customer_name,created_by,total_amount,bill_type) VALUES ($1,$2,auth.uid(),1000,$3) RETURNING *`,[no,party,type||null]);
const bells=async t=>(await db.query(`SELECT user_id FROM public.erp_notifications WHERE notification_type=$1 ORDER BY id`,[t])).rows.map(r=>r.user_id);

test('salesman can not choose; party default fills; Sales Head / Admin choose and set the default', async()=>{
  await as(ids.sales);
  let o=await po('P1','Shree Ganesh','CASH');
  assert.equal(o.bill_type,null);                         // salesman's choice ignored, no default yet
  await assert.rejects(db.query(`UPDATE public.orders SET bill_type='GST' WHERE id=$1`,[o.id]),/Only Sales Head or Admin/);
  await assert.rejects(one(`SELECT public.lwb_set_order_bill_type($1,'GST')`,[o.id]),/Only Sales Head or Admin/);
  assert.equal((await one(`SELECT public.lwb_set_order_bill_note($1,'  party wants   cash bill ') n`,[o.id])).n,'party wants cash bill');
  await as(ids.head);
  const r=(await one(`SELECT public.lwb_set_order_bill_type($1,'cash',null,true) r`,[o.id])).r;
  assert.equal(r.bill_type,'CASH'); assert.equal(r.party_default,'CASH');
  // approve path: a direct update by Sales Head is allowed
  await db.query(`UPDATE public.orders SET bill_type='GST',status='approved' WHERE id=$1`,[o.id]);
  await as(ids.sales);
  const o2=await po('P2','SHREE GANESH');
  assert.equal(o2.bill_type,'CASH');                      // from the party default
  const t=await one(`SELECT * FROM public.lwb_order_bill_types($1)`,[[o2.id]]);
  assert.equal(t,undefined);                              // salesman can not read the list
  await as(ids.acc);
  const t2=await one(`SELECT * FROM public.lwb_order_bill_types($1)`,[[o2.id]]);
  assert.equal(t2.bill_type,'CASH'); assert.equal(t2.required,true); assert.equal(t2.set_by,null);
  const old=await one(`SELECT b.required FROM public.orders o, public.lwb_order_bill_types(ARRAY[o.id]) b WHERE o.order_no='OLD'`);
  assert.equal(old.required,false);
});

test('after the bill is made only Admin changes it, with a reason; Accounts get a bell', async()=>{
  await as(ids.head);
  const o=await po('P3','PATEL KIRANA','GST');
  assert.equal(o.bill_type,'GST');
  await db.query(`INSERT INTO public.lwb_tally_invoices VALUES ($1,'INV-1',1000)`,[o.id]);
  await assert.rejects(one(`SELECT public.lwb_set_order_bill_type($1,'CASH','x')`,[o.id]),/Only Admin/);
  await assert.rejects(db.query(`UPDATE public.orders SET bill_type='CASH' WHERE id=$1`,[o.id]),/already made/);
  await as(ids.admin);
  await assert.rejects(one(`SELECT public.lwb_set_order_bill_type($1,'CASH','')`,[o.id]),/reason/);
  await assert.rejects(db.query(`UPDATE public.orders SET bill_type='CASH' WHERE id=$1`,[o.id]),/already made/);
  await one(`SELECT public.lwb_set_order_bill_type($1,'CASH','party asked cash')`,[o.id]);
  assert.deepEqual(await bells('BILL_TYPE_CHANGED'),[ids.acc]);
  const log=await one(`SELECT old_type,new_type,reason FROM public.lwb_bill_type_log WHERE order_id=$1`,[o.id]);
  assert.deepEqual(log,{old_type:'GST',new_type:'CASH',reason:'party asked cash'});
});

test('bill made as the other kind needs a reason, is flagged, Admin + Sales Head get a bell; same kind clears it', async()=>{
  await as(ids.head);
  const o=await po('P4','PATEL KIRANA','CASH');
  await as(ids.acc);
  await assert.rejects(db.query(`UPDATE public.orders SET bill_made_as='GST' WHERE id=$1`,[o.id]),/only from Bills to make/);
  assert.equal((await one(`SELECT public.lwb_bill_made_as($1,'CASH') r`,[o.id])).r.mismatch,false);
  await assert.rejects(one(`SELECT public.lwb_bill_made_as($1,'GST','')`,[o.id]),/Write why/);
  assert.equal((await one(`SELECT public.lwb_bill_made_as($1,'GST','party asked GST bill') r`,[o.id])).r.mismatch,true);
  assert.equal((await one(`SELECT bill_made_as FROM public.orders WHERE id=$1`,[o.id])).bill_made_as,'GST');
  assert.deepEqual((await bells('BILL_TYPE_MISMATCH')).sort(),[ids.admin,ids.head].sort());
  await as(ids.sales);
  await assert.rejects(one(`SELECT public.lwb_bill_made_as($1,'GST','x y z')`,[o.id]),/Only Accounts/);
  await as(ids.head);
  const n=await one(`INSERT INTO public.orders(order_no,customer_name) VALUES ('P5','NEW PARTY') RETURNING id`);
  await as(ids.acc);
  await assert.rejects(one(`SELECT public.lwb_bill_made_as($1,'GST','x y z')`,[n.id]),/not chosen/);
  assert.equal((await one(`SELECT public.lwb_bill_type_ask($1) n`,[n.id])).n,2);
});

test('payment mode mismatch: only real ones kept; list + OK by Admin / Sales Head only', async()=>{
  await as(ids.head);
  const g=await po('P6','PATEL KIRANA','GST'), c=await po('P7','PATEL KIRANA','CASH');
  await as(ids.cash);
  await assert.rejects(one(`SELECT public.lwb_bill_pay_mismatch($1,'')`,[JSON.stringify([{order_id:g.id,mode:'CASH'}])]),/what happened/);
  const n=(await one(`SELECT public.lwb_bill_pay_mismatch($1,'Party ne cash hi diya') n`,[JSON.stringify([
    {order_id:g.id,mode:'CASH',amount:500},{order_id:g.id,mode:'UPI',amount:500},{order_id:c.id,mode:'BANK',amount:300},{order_id:c.id,mode:'CASH',amount:1}])])).n;
  assert.equal(n,2);
  const list=(await db.query(`SELECT * FROM public.lwb_bill_type_flag_list(30) WHERE kind='PAYMENT'`)).rows;
  assert.deepEqual(list.map(r=>[r.order_no,r.bill_type,r.got]).sort(),[['P6','GST','CASH'],['P7','CASH','BANK']]);
  await assert.rejects(one(`SELECT public.lwb_bill_type_flag_ok($1)`,[list.map(r=>r.id)]),/Only Sales Head or Admin/);
  await as(ids.head);
  assert.equal((await one(`SELECT public.lwb_bill_type_flag_ok($1,'checked') n`,[list.map(r=>r.id)])).n,2);
  await as(ids.sales);
  await assert.rejects(db.query(`SELECT * FROM public.lwb_bill_type_flag_list(30)`),/Not allowed/);
});
