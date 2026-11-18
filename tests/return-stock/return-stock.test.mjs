import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_stock_transfer_setup.sql + lwb_return_stock_setup.sql on an empty PGlite database.
const ids={admin:'00000000-0000-4000-8000-000000000001',godown:'00000000-0000-4000-8000-000000000003',
  acc:'00000000-0000-4000-8000-000000000004',sales:'00000000-0000-4000-8000-000000000005'};
const roles={admin:'admin',godown:'warehouse',acc:'accounts',sales:'sales'};
const sku={thums:'10000000-0000-4000-8000-000000000001',sprite:'10000000-0000-4000-8000-000000000002'};
const ord='20000000-0000-4000-8000-000000000001';
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean not null default false,created_at timestamptz default now());
CREATE TABLE public.lwb_user_page_access(user_id uuid,extra text[]);
CREATE FUNCTION public.lwb_has_page(p text) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT false $$;
CREATE TABLE public.sku_master(id uuid primary key,sku_name text,pcs_per_case int,is_active boolean default true);
CREATE TABLE public.stock_now(sku_id uuid,saleable_pcs bigint,damaged_pcs bigint);
CREATE VIEW public.lwb_live_stock AS SELECT s.id AS sku_id,s.sku_name,s.pcs_per_case,coalesce(n.saleable_pcs,0) AS saleable_pcs,coalesce(n.damaged_pcs,0) AS damaged_pcs
  FROM public.sku_master s LEFT JOIN public.stock_now n ON n.sku_id=s.id;
GRANT SELECT ON public.lwb_live_stock TO authenticated;
CREATE TABLE public.lwb_goods_inward(id uuid primary key,received_date date);
CREATE TABLE public.lwb_goods_inward_items(id bigserial primary key,inward_id uuid,sku_id uuid,cases int,pcs int);
CREATE TABLE public.orders(id uuid primary key,status text,order_no text);
CREATE TABLE public.order_items(id uuid primary key default gen_random_uuid(),order_id uuid,loaded_qty numeric);
CREATE TABLE public.dispatch_assignments(id bigserial primary key,order_id uuid,loading_completed_at timestamptz);
CREATE TABLE public.lwb_driver_delivery_returns(id uuid primary key default gen_random_uuid(),order_id uuid,status text,reviewed_at timestamptz,
  goods_received_at timestamptz,goods_received_by uuid,goods_received_note text);
CREATE TABLE public.lwb_driver_delivery_return_items(id uuid primary key default gen_random_uuid(),return_id uuid,order_item_id uuid,sku_name text,reason text,uom text,qty int,pcs_per_case int,qty_cases numeric);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,roles[k].toUpperCase(),'Name '+k]);
await db.query("insert into sku_master values($1,'250ML THUMSUP',24,true),($2,'600ML SPRITE',24,true)",[sku.thums,sku.sprite]);
await db.query('insert into stock_now values($1,2400,0),($2,480,10)',[sku.thums,sku.sprite]);
await db.query("insert into orders values($1,'loaded','LXY-00231')",[ord]);
const st=await readFile(new URL('../../lwb_stock_transfer_setup.sql',import.meta.url),'utf8');
const rs=await readFile(new URL('../../lwb_return_stock_setup.sql',import.meta.url),'utf8');
await db.exec(st);await db.exec(rs);await db.exec(st);await db.exec(rs); // safe to run again (and after stock transfer again)

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const live=async()=>{await as('sales');return Object.fromEntries((await call('select sku_id,saleable_pcs::int s,damaged_pcs::int d from lwb_live_stock')).map(r=>[r.sku_id,r]))};
async function newReturn(status='APPROVED'){
  const r=(await db.query("insert into lwb_driver_delivery_returns(order_id,status,reviewed_at) values($1,$2,now()) returning id",[ord,status])).rows[0].id;
  await db.query(`insert into lwb_driver_delivery_return_items(return_id,sku_name,reason,uom,qty,pcs_per_case,qty_cases) values
    ($1,'250ml thumsup ','LEAKAGE','CS',6,24,6),($1,'600ML SPRITE','LOW_FILL','PCS',4,24,0.1666667),($1,'OLD SKU X','DAMAGE','CS',1,12,1)`,[r]);
  return r;
}

test('lines show default place and SKU match; old checks still hold', async()=>{
  const r=await newReturn();
  await as('godown');
  const l=await call('select * from lwb_return_receive_lines($1)',[r]);
  const by=Object.fromEntries(l.map(x=>[x.sku_name,x]));
  assert.equal(by['250ml thumsup '].default_bucket,'DAMAGE'); // leakage = damage (OLN)assert.equal(by['250ml thumsup '].qty_pcs,144);
  assert.equal(by['600ML SPRITE'].default_bucket,'DAMAGE');assert.equal(by['600ML SPRITE'].qty_pcs,4);
  assert.equal(by['OLD SKU X'].sku_id,null);
  await as('sales');await assert.rejects(call('select lwb_return_receive_lines($1)',[r]),/office staff/);
  await as('acc');await assert.rejects(call('select lwb_receive_return_goods2($1,null,null)',[r]),/Only Godown/);
  const p=await newReturn('PENDING_OFFICE');
  await as('godown');await assert.rejects(call('select lwb_receive_return_goods2($1,null,null)',[p]),/Only approved/);
});

test('receive: saleable goes up, leakage held, missing SKU skipped, only once', async()=>{
  const r=await newReturn();
  const before=await live();
  await as('godown');
  const l=await call('select * from lwb_return_receive_lines($1)',[r]);
  const th=l.find(x=>x.sku_name.trim()==='250ml thumsup');
  const res=(await call('select lwb_receive_return_goods2($1,$2,$3) r',[r,JSON.stringify([{item_id:th.item_id,bucket:'saleable'}]),'checked']))[0].r;
  assert.equal(res.lines,2);assert.equal(res.saleable_pcs,144);assert.equal(res.held_pcs,4);assert.deepEqual(res.skipped,['OLD SKU X']);
  const after=await live();
  assert.equal(after[sku.thums].s-before[sku.thums].s,144);
  assert.equal(after[sku.sprite].d-before[sku.sprite].d,4);
  assert.equal(after[sku.sprite].s,before[sku.sprite].s);
  await as('godown');await assert.rejects(call('select lwb_receive_return_goods2($1,null,null)',[r]),/already received/);
  const note=(await db.query('select goods_received_note n from lwb_driver_delivery_returns where id=$1',[r])).rows[0].n;
  assert.match(note,/checked · Not in SKU Master/);
  await as('admin');
  const s=Object.fromEntries((await call('select * from lwb_stx_status()')).map(x=>[x.sku_id,x]));
  assert.equal(Number(s[sku.sprite].damage_pcs)>=4,true);
  const led=await call("select * from lwb_stx_ledger('SALEABLE',null,null,$1)",[sku.thums]);
  assert.ok(led.some(x=>x.kind==='RETURN_IN'&&x.other_bucket==='PARTY'&&Number(x.in_pcs)===144));
  const recv=await call('select * from lwb_return_receive_lines($1)',[r]);
  assert.equal(recv.find(x=>x.item_id===th.item_id).received_bucket,'SALEABLE');
});

test('bad place refused; old one-tap receive also moves stock', async()=>{
  const r=await newReturn();
  await as('godown');
  const l=await call('select * from lwb_return_receive_lines($1)',[r]);
  await assert.rejects(call('select lwb_receive_return_goods2($1,$2,null)',[r,JSON.stringify([{item_id:l[0].item_id,bucket:'DESTROYED'}])]),/Choose Saleable/);
  const before=await live();
  await as('godown');assert.equal((await call('select lwb_receive_return_goods($1,null) r',[r]))[0].r,'RECEIVED');
  const after=await live();
  assert.equal(after[sku.thums].d-before[sku.thums].d,144); // leakage -> damage, held
  assert.equal(after[sku.thums].s,before[sku.thums].s);
});

test('users still cannot ask a move from PARTY, and manual moves still work', async()=>{
  await as('godown');
  const today=(await db.query("select to_char(public.lwb_stx_today(),'YYYY-MM-DD') d")).rows[0].d;
  await assert.rejects(call('select lwb_stx_request($1)',[JSON.stringify({from_bucket:'PARTY',to_bucket:'SALEABLE',move_date:today,reason:'x',lines:[{sku_id:sku.thums,cases:1}]})]));
  const r=(await call('select lwb_stx_request($1) r',[JSON.stringify({from_bucket:'SALEABLE',to_bucket:'DAMAGE',move_date:today,reason:'Damaged in vehicle',lines:[{sku_id:sku.thums,cases:1}]})]))[0].r;
  assert.ok(r);
});

// lwb_gm_return_check_setup.sql: market return checked by the assigned Godown Manager (18 Nov 2026).
test('GM return check: own vehicle only, good / damage / short in cases + pcs, sales notified', async()=>{
  const gm2='00000000-0000-4000-8000-000000000009';
  await db.exec(`ALTER TABLE orders ADD COLUMN IF NOT EXISTS customer_name text; ALTER TABLE orders ADD COLUMN IF NOT EXISTS created_by uuid;
    ALTER TABLE dispatch_assignments ADD COLUMN IF NOT EXISTS loading_manager_id uuid;`);
  await db.query("insert into user_profiles values($1,'warehouse',true,'Other GM'),('00000000-0000-4000-8000-000000000006','manager',true,'Head') on conflict do nothing",[gm2]);
  await db.query("update orders set customer_name='N K TRADERS',created_by=$2 where id=$1",[ord,ids.sales]);
  const gc=await readFile(new URL('../../lwb_gm_return_check_setup.sql',import.meta.url),'utf8');
  await db.exec(gc);await db.exec(gc);
  await db.query('delete from dispatch_assignments');
  await db.query('insert into dispatch_assignments(order_id,loading_manager_id) values($1,$2)',[ord,ids.godown]);
  const r=await newReturn();
  await as('godown');
  const l=await call('select * from lwb_return_receive_lines($1)',[r]);
  const th=l.find(x=>x.sku_name.trim()==='250ml thumsup'),sp=l.find(x=>x.sku_name==='600ML SPRITE');
  // another Godown Manager cannot check this vehicle
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[gm2]);
  await assert.rejects(call('select lwb_receive_return_goods3($1,null,null)',[r]),/another Godown Manager/);
  await as('godown');
  // more than the driver returned is refused (6 case returned)
  await assert.rejects(call('select lwb_receive_return_goods3($1,$2,null)',[r,JSON.stringify([{item_id:th.item_id,good_cs:5,bad_cs:2}])]),/driver returned only/);
  await assert.rejects(call('select lwb_receive_return_goods3($1,$2,null)',[r,JSON.stringify([{item_id:th.item_id,good_cs:'x'}])]),/whole cases/);
  const before=await live();
  await db.query('delete from erp_notifications');
  await as('godown');
  const res=(await call('select lwb_receive_return_goods3($1,$2,$3) r',[r,JSON.stringify([
    {item_id:th.item_id,good_cs:4,good_pcs:0,bad_cs:1,bad_pcs:12,bad_bucket:'leakage'},   // 4 case good, 1.5 case leakage, 12 pcs short
    {item_id:sp.item_id,good_cs:0,good_pcs:0,bad_cs:0,bad_pcs:4,bad_bucket:'GASLESS'}]),'counted']))[0].r;
  assert.equal(res.saleable_pcs,96);assert.equal(res.held_pcs,36+4+12);assert.equal(res.short_pcs,12);
  const after=await live();
  assert.equal(after[sku.thums].s-before[sku.thums].s,96);
  assert.equal(after[sku.thums].d-before[sku.thums].d,36);
  const n=(await db.query("select user_id,title,message from erp_notifications where notification_type='RETURN_CHECKED'")).rows;
  const to=new Set(n.map(x=>x.user_id));
  assert.ok(to.has(ids.sales)&&to.has(ids.admin)&&to.has('00000000-0000-4000-8000-000000000006'));
  assert.ok(!to.has(ids.godown)&&!to.has(gm2));
  assert.match(n[0].title,/SHORT/);
  assert.match(n[0].message,/250ml thumsup: good 4 case, Leakage 1 case \+ 12 pcs, SHORT 12 pcs/);
  await as('godown');await assert.rejects(call('select lwb_receive_return_goods3($1,null,null)',[r]),/already received/);
  assert.equal(await (async()=>{await as('godown');return (await call('select public.lwb_return_gm($1) g',[ord]))[0].g})(),ids.godown);
});
