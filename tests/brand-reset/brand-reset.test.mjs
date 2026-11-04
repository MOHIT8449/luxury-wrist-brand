import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_brand_reset_setup.sql on a tiny copy of the tables it touches (no live database).
const admin='00000000-0000-4000-8000-000000000001',manager='00000000-0000-4000-8000-000000000003';
const RAJ='c0000000-0000-4000-8000-000000000001',COKE='c0000000-0000-4000-8000-000000000002';
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid primary key);
INSERT INTO auth.users VALUES ('${admin}'),('${manager}');
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
INSERT INTO public.user_profiles VALUES ('${admin}','admin',true,'Mohit'),('${manager}','manager',true,'M');
CREATE TABLE public.lwb_companies(id uuid primary key,name text);
INSERT INTO lwb_companies VALUES ('${RAJ}','RAJNIGANDHA'),('${COKE}','COCA-COLA');
CREATE TABLE public.sku_master(id uuid primary key default gen_random_uuid(),sku_name text,company_id uuid references lwb_companies(id));
INSERT INTO sku_master(id,sku_name,company_id) VALUES
 ('50000000-0000-4000-8000-000000000001','RAJ 4G BOX','${RAJ}'),('50000000-0000-4000-8000-000000000002','RAJ 10G BOX','${RAJ}'),
 ('50000000-0000-4000-8000-000000000003','COKE 250ML','${COKE}');
CREATE TABLE public.orders(id uuid primary key default gen_random_uuid(),order_no text,customer_name text,order_date date default current_date,status text);
CREATE TABLE public.order_items(id uuid primary key default gen_random_uuid(),order_id uuid references orders(id),sku_name text,ordered_qty numeric,approved_qty numeric,rate numeric);
CREATE TABLE public.dispatch_assignments(id uuid primary key default gen_random_uuid(),order_id uuid references orders(id));
CREATE TABLE public.lwb_delivery_reports(id uuid primary key default gen_random_uuid(),order_id uuid references orders(id) ON DELETE RESTRICT,assignment_id uuid references dispatch_assignments(id));
CREATE TABLE public.erp_notifications(id bigserial primary key,order_id uuid,title text);
CREATE TABLE public.lwb_quick_slips(order_id uuid primary key references orders(id) ON DELETE CASCADE,company_id uuid);
CREATE TABLE public.lwb_tally_payments(id uuid primary key default gen_random_uuid(),receipt_id uuid not null,order_id uuid references orders(id) ON DELETE CASCADE,
  party text,amount numeric,mode text,cancelled_at timestamptz);
CREATE TABLE public.lwb_party_allocs(id uuid primary key default gen_random_uuid(),receipt_id uuid not null,order_id uuid not null references orders(id) ON DELETE CASCADE,amount numeric,cancelled_at timestamptz);
CREATE TABLE public.lwb_party_opening_balances(id uuid primary key default gen_random_uuid(),customer_name text,amount numeric);
CREATE TABLE public.lwb_tally_party_map(tally_key text primary key,customer_name text);
CREATE FUNCTION public.lwb_party_key(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT btrim(regexp_replace(upper(coalesce(p,'')), '[^A-Z0-9]+', ' ', 'g')) $$;
CREATE FUNCTION public.lwb_party_parent(p text) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT m.customer_name FROM public.lwb_tally_party_map m WHERE m.tally_key = public.lwb_party_key(p)), p) $$;
CREATE TABLE public.lwb_acc_cheques(src text,src_id uuid,cheque_no text,primary key(src,src_id));
CREATE TABLE public.lwb_acc_verify(src text,src_id uuid,status text,primary key(src,src_id));
CREATE TABLE public.lwb_goods_inward(id uuid primary key default gen_random_uuid(),invoice_no text,supplier_name text,received_date date default current_date);
CREATE TABLE public.lwb_goods_inward_items(id uuid primary key default gen_random_uuid(),inward_id uuid references lwb_goods_inward(id),sku_id uuid,total_amount numeric);
CREATE TABLE public.lwb_purchase_checks(id uuid primary key default gen_random_uuid(),inward_id uuid unique references lwb_goods_inward(id) ON DELETE CASCADE);
CREATE TABLE public.lwb_inventory_movements(id uuid primary key default gen_random_uuid(),sku_id uuid,sku_name text,movement_type text,stock_bucket text,qty_pcs integer,
  inward_id uuid references lwb_goods_inward(id),order_id uuid references orders(id));
CREATE VIEW public.lwb_live_stock AS SELECT s.id AS sku_id,s.sku_name,10 AS pcs_per_case,
  coalesce((SELECT sum(m.qty_pcs) FROM lwb_inventory_movements m WHERE m.sku_id=s.id),0) AS saleable_pcs,0 AS damaged_pcs FROM sku_master s;
CREATE TABLE public.lwb_stock_audit_lines(id bigserial primary key,sku_id uuid,sku_name text);
CREATE TABLE public.lwb_stock_moves(id bigserial primary key,sku_id uuid,sku_name text,audit_line_id bigint references lwb_stock_audit_lines(id));
CREATE TABLE public.lwb_stock_transit(id bigserial primary key,sku_name text,cases int);
CREATE TABLE public.lwb_company_payments(id uuid primary key default gen_random_uuid(),company_id uuid references lwb_companies(id),amount numeric,cancelled_at timestamptz);
CREATE TABLE public.lwb_order_audit(id bigserial primary key,order_id uuid not null);
`);
await db.exec(await sql('lwb_brand_reset_setup.sql'));
await db.exec(await sql('lwb_brand_reset_setup.sql')); // safe to run again
const as=async u=>db.exec(`SELECT set_config('request.jwt.claim.sub','${u}',false)`);
const one=async(q,p)=>(await db.query(q,p)).rows[0];
const n=async t=>Number((await one(`SELECT count(*)::int AS c FROM ${t}`)).c);

// Data: RAJ ONLY TRADERS buys only Rajnigandha; BOTH STORES buys both brands; COKE SHOP only Coca-Cola.
const o={r1:'a0000000-0000-4000-8000-000000000001',r2:'a0000000-0000-4000-8000-000000000002',r3:'a0000000-0000-4000-8000-000000000003',
  c1:'a0000000-0000-4000-8000-000000000004',c2:'a0000000-0000-4000-8000-000000000005'};
const rcpt1='b0000000-0000-4000-8000-000000000001',rcpt2='b0000000-0000-4000-8000-000000000002',pay1='b1000000-0000-4000-8000-000000000001';
const inR='d0000000-0000-4000-8000-000000000001',inC='d0000000-0000-4000-8000-000000000002';
await db.exec(`
INSERT INTO orders(id,order_no,customer_name) VALUES ('${o.r1}','PO1','RAJ ONLY TRADERS'),('${o.r2}','PO2','Raj Only Traders (branch)'),
 ('${o.r3}','PO3','BOTH STORES'),('${o.c1}','PO4','BOTH STORES'),('${o.c2}','PO5','COKE SHOP');
INSERT INTO lwb_tally_party_map VALUES ('RAJ ONLY TRADERS BRANCH','RAJ ONLY TRADERS');
INSERT INTO order_items(order_id,sku_name,ordered_qty,approved_qty,rate) VALUES
 ('${o.r1}','RAJ 4G BOX',10,10,100),('${o.r1}','raj 10g box',5,null,200),('${o.r2}','RAJ 4G BOX',1,1,100),
 ('${o.r3}','RAJ 10G BOX',2,2,200),('${o.c1}','COKE 250ML',3,3,300),('${o.c2}','COKE 250ML',4,4,300);
INSERT INTO dispatch_assignments(id,order_id) VALUES ('e0000000-0000-4000-8000-000000000001','${o.r1}'),('e0000000-0000-4000-8000-000000000002','${o.c1}');
INSERT INTO lwb_delivery_reports(order_id,assignment_id) VALUES ('${o.r1}','e0000000-0000-4000-8000-000000000001'),('${o.c1}','e0000000-0000-4000-8000-000000000002');
INSERT INTO erp_notifications(order_id,title) VALUES ('${o.r1}','raj'),('${o.c2}','coke');
INSERT INTO lwb_quick_slips VALUES ('${o.r1}','${RAJ}'),('${o.r2}','${RAJ}');
INSERT INTO lwb_tally_payments(id,receipt_id,order_id,party,amount,mode) VALUES
 ('${pay1}','${rcpt1}','${o.r1}',null,500,'CHEQUE'),
 (gen_random_uuid(),'${rcpt2}',null,'Raj Only Traders',900,'CASH'),
 (gen_random_uuid(),gen_random_uuid(),null,'BOTH STORES',700,'UPI'),
 (gen_random_uuid(),gen_random_uuid(),'${o.c2}',null,1200,'CASH');
INSERT INTO lwb_party_allocs(receipt_id,order_id,amount) VALUES ('${rcpt2}','${o.r1}',900),(gen_random_uuid(),'${o.r3}',300);
INSERT INTO lwb_party_opening_balances(customer_name,amount) VALUES ('RAJ ONLY TRADERS',5000),('BOTH STORES',8000);
INSERT INTO lwb_acc_cheques VALUES ('PAY','${pay1}','000123');
INSERT INTO lwb_goods_inward(id,invoice_no,supplier_name) VALUES ('${inR}','R-1','DHARAMPAL'),('${inC}','C-1','HCCB');
INSERT INTO lwb_goods_inward_items(inward_id,sku_id,total_amount) VALUES ('${inR}','50000000-0000-4000-8000-000000000001',10000),
 ('${inR}','50000000-0000-4000-8000-000000000002',5000),('${inC}','50000000-0000-4000-8000-000000000003',7000);
INSERT INTO lwb_purchase_checks(inward_id) VALUES ('${inR}'),('${inC}');
INSERT INTO lwb_inventory_movements(sku_id,sku_name,movement_type,stock_bucket,qty_pcs,inward_id,order_id) VALUES
 ('50000000-0000-4000-8000-000000000001','RAJ 4G BOX','OPENING','SALEABLE',50,null,null),
 ('50000000-0000-4000-8000-000000000001','RAJ 4G BOX','INWARD','SALEABLE',100,'${inR}',null),
 ('50000000-0000-4000-8000-000000000001','RAJ 4G BOX','DISPATCH','SALEABLE',-10,null,'${o.r1}'),
 ('50000000-0000-4000-8000-000000000003','COKE 250ML','OPENING','SALEABLE',70,null,null),
 ('50000000-0000-4000-8000-000000000003','COKE 250ML','INWARD','SALEABLE',30,'${inC}',null);
INSERT INTO lwb_stock_audit_lines(id,sku_id,sku_name) VALUES (1,'50000000-0000-4000-8000-000000000001','RAJ 4G BOX'),(2,'50000000-0000-4000-8000-000000000003','COKE 250ML');
INSERT INTO lwb_stock_moves(sku_id,sku_name,audit_line_id) VALUES ('50000000-0000-4000-8000-000000000001','RAJ 4G BOX',1),('50000000-0000-4000-8000-000000000003','COKE 250ML',2);
INSERT INTO lwb_stock_transit(sku_name,cases) VALUES ('RAJ 10G BOX',5),('COKE 250ML',9);
INSERT INTO lwb_company_payments(company_id,amount) VALUES ('${RAJ}',3000),('${COKE}',4000);
`);

test('only Admin can preview, start or step', async()=>{
  await as(manager);
  await assert.rejects(db.query(`SELECT lwb_brand_reset_preview($1)`,[RAJ]),/Only an active Admin/);
  await assert.rejects(db.query(`SELECT lwb_brand_reset_start($1,'RAJNIGANDHA')`,[RAJ]),/Only an active Admin/);
});

test('mixed PO stops the reset and is listed', async()=>{
  await as(admin);
  await db.exec(`INSERT INTO order_items(order_id,sku_name,ordered_qty,rate) VALUES ('${o.r3}','COKE 250ML',1,300)`);
  const p=(await one(`SELECT lwb_brand_reset_preview($1) AS p`,[RAJ])).p;
  assert.equal(p.mixed_orders.length,1);assert.equal(p.mixed_orders[0].order_no,'PO3');
  await assert.rejects(db.query(`SELECT lwb_brand_reset_start($1,'RAJNIGANDHA')`,[RAJ]),/another brand together/);
  await db.exec(`DELETE FROM order_items WHERE order_id='${o.r3}' AND sku_name='COKE 250ML'`);
});

test('preview counts without changing anything', async()=>{
  await as(admin);
  const before=await n('orders');
  const p=(await one(`SELECT lwb_brand_reset_preview($1) AS p`,[RAJ])).p;
  assert.equal(p.pos.n,3);                         // PO1, PO2, PO3
  assert.equal(Number(p.pos.amount),10*100+5*200+100+400);
  assert.equal(Number(p.po_payments.amount),500);
  assert.equal(Number(p.party_payments.amount),900);  // only the Rajnigandha-only party
  assert.equal(Number(p.opening.amount),5000);
  assert.equal(p.only_parties,1);
  assert.deepEqual(p.mixed_parties.map(x=>x.party),['BOTH STORES']);
  assert.equal(Number(p.mixed_advance[0].amount),300);
  assert.equal(p.purchases.n,1);assert.equal(Number(p.purchases.amount),15000);
  assert.equal(Number(p.company_payments.amount),3000);
  assert.equal(p.linked.orders,3);assert.equal(p.linked.erp_notifications,1);
  assert.equal(p.stock.length,1);assert.equal(p.stock[0].pcs,140);
  assert.equal(await n('orders'),before);
});

test('wrong typed name is refused', async()=>{
  await as(admin);
  await assert.rejects(db.query(`SELECT lwb_brand_reset_start($1,'RAJNI')`,[RAJ]),/Type the brand name/);
});

test('reset removes only Rajnigandha data, step by step, with backup', async()=>{
  await as(admin);
  const id=Number((await one(`SELECT lwb_brand_reset_start($1,' rajnigandha ') AS id`,[RAJ])).id);
  assert.equal(Number((await one(`SELECT lwb_brand_reset_start($1,'RAJNIGANDHA') AS id`,[RAJ])).id),id); // same run continues
  let r,steps=0;
  do{r=(await one(`SELECT lwb_brand_reset_step($1) AS r`,[id])).r;steps++}while(!r.done&&steps<20);
  assert.ok(r.done);
  // gone
  assert.deepEqual((await db.query(`SELECT order_no FROM orders ORDER BY order_no`)).rows.map(x=>x.order_no),['PO4','PO5']);
  assert.equal(await n(`order_items WHERE sku_name ILIKE 'raj%'`),0);
  assert.equal(await n('lwb_quick_slips'),0);
  assert.equal(await n(`erp_notifications`),1);
  assert.equal(await n(`lwb_delivery_reports`),1);
  assert.equal(await n(`lwb_tally_payments WHERE amount IN (500,900)`),0);
  assert.equal(await n(`lwb_party_allocs`),0);
  assert.equal(await n(`lwb_party_opening_balances`),1);
  assert.equal(await n(`lwb_acc_cheques`),0);
  assert.equal(await n(`lwb_goods_inward`),1);
  assert.equal(await n(`lwb_purchase_checks`),1);
  assert.equal(await n(`lwb_inventory_movements WHERE sku_name ILIKE 'raj%'`),0);
  assert.equal(await n(`lwb_stock_moves`),1);assert.equal(await n(`lwb_stock_audit_lines`),1);assert.equal(await n(`lwb_stock_transit`),1);
  assert.equal(await n(`lwb_company_payments`),1);
  // kept: Coca-Cola and the party who buys both
  assert.equal(await n(`lwb_tally_payments WHERE party='BOTH STORES'`),1);
  assert.equal(await n(`lwb_tally_payments WHERE amount=1200`),1);
  assert.equal(Number((await one(`SELECT saleable_pcs FROM lwb_live_stock WHERE sku_name='COKE 250ML'`)).saleable_pcs),100);
  assert.equal(Number((await one(`SELECT saleable_pcs FROM lwb_live_stock WHERE sku_name='RAJ 4G BOX'`)).saleable_pcs),0);
  assert.equal(await n('sku_master'),3);
  // backup has every removed row
  const b=(await one(`SELECT lwb_brand_reset_backup($1) AS b`,[id])).b;
  assert.equal(b.reset.status,'DONE');
  assert.equal(b.rows.filter(x=>x.table==='orders').length,3);
  assert.ok(b.rows.some(x=>x.table==='lwb_party_opening_balances'&&Number(x.row.amount)===5000));
  assert.equal(b.rows.length,Object.values(b.reset.counts).reduce((a,c)=>a+Number(c),0));
  // nothing left: a new preview is empty
  const p=(await one(`SELECT lwb_brand_reset_preview($1) AS p`,[RAJ])).p;
  assert.equal(p.pos.n,0);assert.equal(p.purchases.n,0);assert.equal(p.stock.length,0);assert.equal(p.last.id,id);
});
