import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_purchase_stages_setup.sql on PGlite, after lwb_ecrs_order_setup.sql. Goods Inward, SKU Master and the
// purchase bill log are small stand-ins.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  godown:'00000000-0000-4000-8000-000000000003',acc:'00000000-0000-4000-8000-000000000004',sales:'00000000-0000-4000-8000-000000000005'};
const roles={admin:'admin',head:'manager',godown:'warehouse',acc:'accounts',sales:'sales'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE FUNCTION public.lwb_rate_editor() RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS(SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND lower(p.role) IN ('admin','manager')) $$;
CREATE TABLE public.sku_master(id uuid primary key default gen_random_uuid(),sku_name text,cases_per_pallet numeric);
CREATE TABLE public.lwb_goods_inward(id uuid primary key default gen_random_uuid(),invoice_no text,supplier_name text,
  invoice_date date,received_date date,vehicle_no text,created_at timestamptz default now());
CREATE TABLE public.lwb_purchase_bill_log(id bigserial primary key,action text,inward_id uuid,new_inward_id uuid);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,roles[k].toUpperCase(),'Name '+k]);
const file=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(await file('lwb_ecrs_order_setup.sql'));
const mine=await file('lwb_purchase_stages_setup.sql');
await db.exec(mine);await db.exec(mine); // safe to run again

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const sku=(await db.query("insert into sku_master(sku_name,cases_per_pallet) values('THUMS UP 250ML',60) returning id")).rows[0].id;
const truck=async(day,pal=24)=>(await db.query("insert into lwb_ecrs_trucks(day,cap,rows) values($1,24,$2) returning id",[day,JSON.stringify([{sku_id:sku,name:'TU',pal}])])).rows[0].id;
const bill=async(inv,veh,day='2026-11-27')=>(await db.query("insert into lwb_goods_inward(invoice_no,supplier_name,invoice_date,received_date,vehicle_no) values($1,'HCCB',$2,$2,$3) returning id",[inv,day,veh])).rows[0].id;
const stage=async id=>(await db.query('select * from lwb_purchase_stage where inward_id=$1',[id])).rows[0];
const list=async()=>{await as('godown');return (await call("select lwb_purchase_stage_list('2026-11-20','2026-11-30') j"))[0].j};

test('Dispatch: only Admin / Sales Head / Accounts; ordered cases come from pallets x cases per pallet', async()=>{
  const t=await truck('2026-11-26');
  await as('godown');
  await assert.rejects(call("select lwb_ecrs_dispatch($1,'GJ01AA1111','INV-1','2026-11-26',$2)",[t,'[]']),/Only Admin/);
  await as('acc');
  await call("select lwb_ecrs_dispatch($1,'gj01 aa 1111','INV-1','2026-11-26',$2)",[t,JSON.stringify([{sku_id:sku,name:'TU',cs:1410}])]);
  const x=(await list()).trucks.find(r=>r.id==t);
  assert.equal(x.vehicle_no,'GJ01 AA 1111');assert.equal(x.rows[0].cs,1440);assert.equal(x.sent_rows[0].cs,1410);
  assert.equal(x.dispatched_by,'Name acc');assert.equal(x.inward_id,null);
  await as('sales');
  await assert.rejects(call("select lwb_purchase_stage_list(null,null)"),/Not allowed/);
});

test('New bill links itself by invoice no., else by vehicle; a linked truck is not taken twice', async()=>{
  const a=await truck('2026-11-26'),b=await truck('2026-11-26');
  await as('head');
  await call("select lwb_ecrs_dispatch($1,'GJ05CW3928','7012789424','2026-11-26','[]')",[a]);
  await call("select lwb_ecrs_dispatch($1,'GJ12BV1447','','2026-11-26','[]')",[b]);
  const b1=await bill('7012-789424','GJ00XX0000');
  assert.equal(Number((await stage(b1)).ecrs_truck_id),Number(a));
  const b2=await bill('NEW-9','gj12bv1447');
  assert.equal(Number((await stage(b2)).ecrs_truck_id),Number(b));
  const b3=await bill('NEW-10','GJ12BV1447');
  assert.equal(await stage(b3),undefined);
  await as('godown');
  await assert.rejects(call('select lwb_purchase_link_ecrs($1,$2)',[b3,b]),/another purchase bill/);
  await assert.rejects(call("select lwb_ecrs_close($1,true,'x')",[b]),/Only Admin/);
  await as('admin');
  await assert.rejects(call("select lwb_ecrs_close($1,true,'x')",[b]),/already received/);
});

test('Tally done: Admin / Accounts only; it stays with a changed bill; a deleted bill frees the truck', async()=>{
  const t=await truck('2026-11-25');
  const b=await bill('INV-T','GJ09ZZ0009','2026-11-25');
  await as('head');
  await call('select lwb_purchase_link_ecrs($1,$2)',[b,t]);
  await assert.rejects(call("select lwb_purchase_tally_done($1,true,'V1')",[b]),/Only Admin or Accounts/);
  await as('acc');
  await call("select lwb_purchase_tally_done($1,true,'Vch 1842')",[b]);
  let s=await stage(b);assert.ok(s.tally_at);assert.equal(s.tally_voucher,'Vch 1842');assert.equal(Number(s.ecrs_truck_id),Number(t));
  // Edit = new bill id + log row EDIT
  const nb=await bill('INV-T','GJ09ZZ0009','2026-11-25');
  await db.query("insert into lwb_purchase_bill_log(action,inward_id,new_inward_id) values('EDIT',$1,$2)",[b,nb]);
  assert.equal(await stage(b),undefined);
  s=await stage(nb);assert.equal(s.tally_voucher,'Vch 1842');assert.equal(Number(s.ecrs_truck_id),Number(t));
  const j=await list();
  assert.equal(j.stage.find(x=>x.inward_id===nb).tally_by,'Name acc');
  assert.equal(j.trucks.find(x=>x.id==t).inward_id,nb);
  // Delete frees the truck
  await db.query("insert into lwb_purchase_bill_log(action,inward_id) values('DELETE',$1)",[nb]);
  assert.equal(await stage(nb),undefined);
  assert.equal((await list()).trucks.find(x=>x.id==t).inward_id,null);
  // Not coming, then open again
  await as('admin');
  await call("select lwb_ecrs_close($1,true,'company cancelled')",[t]);
  assert.ok((await list()).trucks.find(x=>x.id==t).closed_at);
  await as('admin');
  await call("select lwb_ecrs_close($1,false)",[t]);
  assert.equal((await list()).trucks.find(x=>x.id==t).closed_at,null);
  // Tally taken back
  const c=await bill('INV-U','GJ00',"2026-11-25");
  await as('acc');await call("select lwb_purchase_tally_done($1,true)",[c]);await call("select lwb_purchase_tally_done($1,false)",[c]);
  assert.equal((await stage(c)).tally_at,null);
});
