import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_ecrs_on_way_setup.sql on PGlite, after lwb_dial_book_setup.sql. Live tables are small stand-ins.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  godown:'00000000-0000-4000-8000-000000000003',acc:'00000000-0000-4000-8000-000000000004',
  sales:'00000000-0000-4000-8000-000000000005',godown2:'00000000-0000-4000-8000-000000000006'};
const roles={admin:'admin',head:'manager',godown:'warehouse',acc:'accounts',sales:'sales',godown2:'warehouse'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text,mobile text);
CREATE TABLE public.lwb_companies(id uuid primary key default gen_random_uuid(),name text);
CREATE TABLE public.lwb_customer_master(id uuid primary key default gen_random_uuid(),customer_name text,mobile text,city text,is_active boolean default true,brand_ids uuid[]);
CREATE TABLE public.lwb_party_salesman(customer_id uuid primary key,salesman_id uuid);
CREATE TABLE public.lwb_acc_staff(id bigserial primary key,name text,mobile text,designation text,active boolean default true);
CREATE TABLE public.lwb_ecrs_trucks(id bigserial primary key,day date,vehicle_no text,invoice_no text,sent_rows jsonb,dispatched_at timestamptz,updated_at timestamptz);
CREATE TABLE public.lwb_tracking_settings(id int primary key,godown_lat double precision,godown_lng double precision);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,is_read boolean default false);
CREATE FUNCTION public.lwb_pst_role() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true $$;
GRANT USAGE ON SCHEMA public, auth TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_pst_role() TO authenticated;
`);
let n=0;for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,$3,$4,$5)',[id,roles[k].toUpperCase(),k!=='godown2','Name '+k,'+91 98250 '+String(10000+(++n))]);
await db.exec(await readFile(new URL('../../lwb_dial_book_setup.sql',import.meta.url),'utf8'));
const mine=await readFile(new URL('../../lwb_ecrs_on_way_setup.sql',import.meta.url),'utf8');
await db.exec(mine);await db.exec(mine); // safe to run again
await db.exec(`insert into lwb_ecrs_trucks(day,vehicle_no,invoice_no,sent_rows,dispatched_at) values
 ('2026-11-27',null,null,null,null),
 ('2026-11-27','GJ05 BX 4471','INV9','[{"sku_id":"a","cs":1000},{"sku_id":"b","cs":200}]',now()),
 ('2026-11-27',null,null,null,null)`);

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const onway=(t,m,nm,o)=>call('select lwb_ecrs_on_way($1,$2,$3,$4) j',[t,m,nm,o]).then(r=>r[0].j);
const notes=async()=>(await db.query("select * from erp_notifications where notification_type='PURCHASE_ON_WAY' order by id")).rows;

test('Only Admin / Sales Head / Accounts; dispatch with vehicle first; 10-digit mobile', async()=>{
  await as('sales');await assert.rejects(onway(2,'9876543210',null,1200),/Only Admin/);
  await as('godown');await assert.rejects(onway(2,'9876543210',null,1200),/Only Admin/);
  await as('acc');await assert.rejects(onway(1,'9876543210',null,10),/company dispatch/);
  await assert.rejects(onway(2,'12345',null,1200),/10-digit/);
  assert.equal((await notes()).length,0);
});

test('Driver saved on the vehicle, GM + Sales Head alerted once (same qty)', async()=>{
  await as('acc');
  const r=await onway(2,'+91 98765 43210','ramesh',1200);
  assert.equal(r.notified,2,'active GM + Sales Head (not the inactive GM, not admin)');
  const ns=await notes();
  assert.deepEqual(ns.map(x=>x.user_id).sort(),[ids.head,ids.godown].sort());
  assert.equal(ns[0].title,'🚚 Vehicle on the way: GJ05 BX 4471');
  assert.match(ns[0].message,/^ECRS Order 2 \(27\/11\) · Inv INV9 · Bill 1200 cs, same as ECRS order ✓ · Driver RAMESH 98•••••210\./);
  assert.ok(!/9876543210/.test(ns[0].message),'number masked');
  const d=(await db.query("select * from lwb_vehicle_driver where vehicle_key='GJ05BX4471'")).rows[0];
  assert.equal(d.driver_mobile,'9876543210');assert.equal(Number(d.ecrs_truck_id),2);
  // saving the dispatch again with the same driver: no second alert
  const again=await onway(2,'9876543210',null,1200);
  assert.equal(again.again,true);assert.equal((await notes()).length,2);
});

test('Different qty + new driver: alert again, says less / more', async()=>{
  await as('head');
  const r=await onway(2,'9123456780','Suresh',1240);
  assert.equal(r.notified,1,'not to myself (Sales Head entered it)');
  const ns=await notes();const last=ns[ns.length-1];
  assert.equal(last.user_id,ids.godown);
  assert.match(last.message,/Bill 1200 cs, 40 cs LESS than ECRS order \(1240\)/);
  await as('admin');
  await onway(2,'9000000001',null,1100);
  assert.match((await notes()).at(-1).message,/100 cs MORE than ECRS order \(1100\)/);
});
