import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

const ids={admin:'00000000-0000-4000-8000-000000000001',manager:'00000000-0000-4000-8000-000000000002',sales:'00000000-0000-4000-8000-000000000003',warehouse:'00000000-0000-4000-8000-000000000004',inactive:'00000000-0000-4000-8000-000000000005'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid,role text,active boolean,full_name text);
CREATE TABLE public.sku_master(id uuid default gen_random_uuid(),sku_name text,is_active boolean,unit_weight_kg numeric,cases_per_pallet integer);
CREATE TABLE public.lwb_customer_master(customer_name text,is_active boolean);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text unique,order_date timestamptz,customer_name text,transportation text,sales_person text,status text,total_qty numeric,total_amount numeric,total_weight numeric,created_by uuid,approved_by uuid,approved_at timestamptz);
CREATE TABLE public.order_items(id uuid default gen_random_uuid(),order_id uuid references orders(id),sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric,rate numeric,unit_weight numeric,amount numeric,total_weight numeric,entry_uom text,ordered_pallet_qty integer,cases_per_pallet_snapshot integer);
CREATE TABLE public.qa_notifications(kind text);
CREATE FUNCTION public.lwb_next_order_no() RETURNS text LANGUAGE sql AS $$ SELECT 'LXY-'||lpad((count(*)+1)::text,5,'0') FROM public.orders $$;
CREATE FUNCTION public.lwb_order_pending(text) RETURNS boolean LANGUAGE sql AS $$ SELECT $1='pending_approval' $$;
CREATE FUNCTION public.lwb_flow_send(uuid,text[],text,text,text,boolean DEFAULT false) RETURNS void LANGUAGE sql AS $$ INSERT INTO public.qa_notifications VALUES($5) $$;
INSERT INTO sku_master(sku_name,is_active,unit_weight_kg,cases_per_pallet) VALUES('QA SKU',true,9,117),('QA SKU 2',true,12,50);
INSERT INTO lwb_customer_master VALUES('QA Party',true);
`);
for(const [role,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,$3,$4)',[id,role==='inactive'?'admin':role,role!=='inactive',role]);
const flow=await readFile(new URL('../../lwb_order_flow_popups_setup.sql',import.meta.url),'utf8');
await db.exec(flow.match(/CREATE OR REPLACE FUNCTION public\.lwb_flow_order_new\(\)[\s\S]*?\$fn\$;/)[0]);
await db.exec('CREATE TRIGGER qa_new_order AFTER INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION public.lwb_flow_order_new()');
await db.exec(await readFile(new URL('../../lwb_head_po_auto_approval_setup.sql',import.meta.url),'utf8'));
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated; GRANT SELECT ON public.user_profiles,public.sku_master,public.lwb_customer_master,public.orders TO authenticated; GRANT INSERT ON public.orders,public.order_items TO authenticated');
const items=[{sku_name:'QA SKU',ordered_qty:40,rate:640,unit_weight:999,amount:1,approved_by:ids.sales},{sku_name:'QA SKU 2',ordered_qty:50,rate:520}];
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||'']);}
async function create(lines=items,transport='DELIVERY'){
 await db.exec('SET ROLE authenticated');
 try{return (await db.query('select public.lwb_head_create_approved_po($1,$2,$3,now(),$4::jsonb) as po',['QA Party',transport,'QA person',JSON.stringify(lines)])).rows[0].po;}finally{await db.exec('RESET ROLE')}
}
const count=async()=>Number((await db.query('select count(*) as n from orders')).rows[0].n);

test('Admin and Sales Head create approved POs with server identities, approved quantities and calculated totals',async()=>{
 for(const role of ['admin','manager']){
  await as(role);const po=await create();assert.equal(po.status,'approved');assert.equal(po.total_qty,90);assert.equal(po.total_amount,51600);assert.equal(po.total_weight,960);
  const o=(await db.query('select * from orders where id=$1',[po.id])).rows[0];assert.equal(o.created_by,ids[role]);assert.equal(o.approved_by,ids[role]);assert.ok(o.approved_at);
  const rows=(await db.query('select * from order_items where order_id=$1',[po.id])).rows;assert.equal(rows.length,2);assert.ok(rows.every(i=>i.approved_qty===i.ordered_qty&&Number(i.loaded_qty)===0));
 }
 assert.equal((await db.query('select * from qa_notifications')).rows.length,0,'No request-to-approve notification');
});
test('Salesman, warehouse, inactive Admin and logged-out callers cannot auto-approve',async()=>{
 const n=await count();for(const role of ['sales','warehouse','inactive','none']){await as(role);await assert.rejects(create(),/Active Admin or Sales Head required/)}assert.equal(await count(),n);
});
test('invalid items fail before saving an order',async()=>{
 await as('admin');const n=await count();
 for(const lines of [[],[items[0],items[0]],[{...items[0],ordered_qty:1.5}],[{...items[0],rate:-1}],[{...items[0],rate:'NaN'}],[{...items[0],sku_name:'Unknown SKU'}]])await assert.rejects(create(lines));
 assert.equal(await count(),n);
});
test('pallet approval uses configured cases per pallet; stale snapshots are rejected',async()=>{
 await as('manager');const line={sku_name:'QA SKU',ordered_qty:234,rate:470,entry_uom:'PALLET',ordered_pallet_qty:2,cases_per_pallet_snapshot:117};
 const po=await create([line],'DIRECT VEHICLE | QTY: PALLET');assert.equal(po.total_qty,234);assert.equal(po.total_weight,2106);
 await assert.rejects(create([{...line,cases_per_pallet_snapshot:100}],'DIRECT VEHICLE | QTY: PALLET'),/Cases per pallet changed/);
 await assert.rejects(create([line],'DELIVERY'),/requires Direct vehicle/);
});
test('a failing SKU insert rolls back the approved header and all other items',async()=>{
 await as('admin');await db.exec(`CREATE FUNCTION qa_fail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.rate=13 THEN RAISE EXCEPTION 'QA item insert failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER qa_item_fail BEFORE INSERT ON order_items FOR EACH ROW EXECUTE FUNCTION qa_fail();`);
 const n=await count();await assert.rejects(create([items[0],{...items[1],rate:13}]),/QA item insert failure/);assert.equal(await count(),n);
});
test('ordinary salesman submission still remains pending and requests review',async()=>{
 await as('sales');await db.query("insert into orders(order_no,status,created_by) values('QA-SALES','pending_approval',$1)",[ids.sales]);
 assert.equal((await db.query("select status from orders where order_no='QA-SALES'")).rows[0].status,'pending_approval');assert.equal((await db.query('select * from qa_notifications')).rows.length,1);
 assert.equal((await db.query("select has_function_privilege('anon','public.lwb_head_create_approved_po(text,text,text,timestamptz,jsonb)','EXECUTE') as allowed")).rows[0].allowed,false);
});
