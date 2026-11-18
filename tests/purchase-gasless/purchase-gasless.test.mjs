import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_purchase_gasless_setup.sql (after lwb_purchase_damage_report_setup.sql) on an empty PGlite database, after the files it needs
// (tasks, documents, purchase claims + register, stock transfer). Goods Inward / live stock are stand-ins.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  godown:'00000000-0000-4000-8000-000000000003',godown2:'00000000-0000-4000-8000-000000000009',
  acc:'00000000-0000-4000-8000-000000000004',sales:'00000000-0000-4000-8000-000000000005'};
const roles={admin:'admin',head:'manager',godown:'warehouse',godown2:'warehouse',acc:'accounts',sales:'sales'};
const sku={rg:'10000000-0000-4000-8000-000000000001',pp:'10000000-0000-4000-8000-000000000002'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE SCHEMA storage;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.lwb_user_page_access(user_id uuid,extra text[]);
CREATE FUNCTION public.lwb_has_page(p text) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT false $$;
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean not null default false,created_at timestamptz default now());
CREATE TABLE public.sku_master(id uuid primary key,sku_name text,pcs_per_case int,is_active boolean default true);
CREATE TABLE public.lwb_goods_inward(id uuid primary key default gen_random_uuid(),invoice_no text,supplier_id uuid,supplier_name text,
  invoice_date date,received_date date,vehicle_no text,created_at timestamptz default now());
CREATE TABLE public.lwb_goods_inward_items(id bigserial primary key,inward_id uuid,sku_id uuid,cases int,pcs int,quantity_pcs int);
CREATE VIEW public.lwb_live_stock AS SELECT s.id AS sku_id,s.sku_name,s.pcs_per_case,
  coalesce((SELECT sum(i.quantity_pcs) FROM public.lwb_goods_inward_items i WHERE i.sku_id=s.id),0) AS saleable_pcs,0::bigint AS damaged_pcs
  FROM public.sku_master s;
CREATE TABLE public.orders(id uuid primary key,status text);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,loaded_qty numeric);
CREATE TABLE public.dispatch_assignments(id bigserial primary key,order_id uuid,loading_completed_at timestamptz);
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
GRANT SELECT ON public.lwb_goods_inward, public.lwb_goods_inward_items, public.sku_master TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,roles[k].toUpperCase(),'Name '+k]);
await db.query("insert into sku_master values($1,'RG 4G',24,true),($2,'PASS PASS',12,true)",[sku.rg,sku.pp]);
const file=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
for(const f of ['lwb_task_management_setup.sql','lwb_documents_setup.sql','lwb_purchase_claim_setup.sql','lwb_purchase_register_setup.sql','lwb_stock_transfer_setup.sql'])await db.exec(await file(f));
await db.exec('GRANT SELECT ON public.lwb_live_stock TO authenticated');
const mine=await file('lwb_purchase_damage_report_setup.sql');
await db.exec(mine);
const gas=await file('lwb_purchase_gasless_setup.sql');
await db.exec(gas);await db.exec(gas); // safe to run again
const all=await file('lwb_purchase_arrived_all_setup.sql');
await db.exec(all);await db.exec(all);

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
// A purchase entry: header + lines in one transaction (like lwb_post_goods_inward).
async function bill(inv,lines=[[sku.rg,10],[sku.pp,5]],veh='GJ05AB1234'){
  await as('head');let id;
  await db.transaction(async tx=>{
    id=(await tx.query("insert into lwb_goods_inward(invoice_no,supplier_name,invoice_date,received_date,vehicle_no) values($1,'DS GROUP',current_date,current_date,$2) returning id",[inv,veh])).rows[0].id;
    for(const [s,cs] of lines){const pk=s===sku.rg?24:12;await tx.query('insert into lwb_goods_inward_items(inward_id,sku_id,cases,pcs,quantity_pcs) values($1,$2,$3,0,$4)',[id,s,cs,cs*pk])}
  });
  return id;
}
const bells=async(who,type)=>(await db.query('select * from erp_notifications where user_id=$1 and notification_type=$2 order by id',[ids[who],type])).rows;
const live=async()=>{await as('sales');return Object.fromEntries((await call('select sku_id,saleable_pcs::int s,damaged_pcs::int d from lwb_live_stock')).map(r=>[r.sku_id,r]))};
const moves=async(b)=>(await db.query("select to_bucket,sku_id,qty_pcs,status from lwb_stock_moves where inward_id=$1 order by id",[b])).rows;
const report=async(who,b,items,note='')=>{await as(who);return (await call("select lwb_purchase_damage_report($1,current_date,$2,$3) r",[b,note,JSON.stringify(items)]))[0].r};


const L=(s,issue,cases,pcs=0)=>({sku_id:s,sku_name:s===sku.rg?'RG 4G':'PASS PASS',pcs_per_case:s===sku.rg?24:12,issue,cases,pcs});

test('Gasless is its own type: stock moves Saleable -> Gasless; Damage / Leakage / Breakage -> Damage', async()=>{
  const b=await bill('GAS-1');
  const before=await live();
  const r=await report('godown',b,[L(sku.rg,'DAMAGE',2),L(sku.rg,'GASLESS',1,4),L(sku.pp,'SHORTAGE',1)]);
  assert.equal(r.damage,true);
  assert.deepEqual((await moves(b)).map(x=>[x.to_bucket,x.qty_pcs]).sort(),[['DAMAGE',48],['GASLESS',28],['LOSS',12]]);
  const after=await live();
  assert.equal(before[sku.rg].s-after[sku.rg].s,76);
  const n=await bells('admin','PURCHASE_DAMAGE');
  assert.match(n.at(-1).message,/RG 4G Damage \/ Leakage \/ Breakage 2 cs, RG 4G Gasless 1 cs \+ 4 pcs/);
  // changing the check rebooks the stock
  await report('godown',b,[L(sku.rg,'GASLESS',3)]);
  assert.deepEqual((await moves(b)).filter(x=>x.status==='APPROVED').map(x=>[x.to_bucket,x.qty_pcs]),[['GASLESS',72]]);
});

test('old Leakage lines still save; unknown types and more than the bill are refused', async()=>{
  const b=await bill('GAS-2');
  await report('head',b,[L(sku.pp,'LEAKAGE',1)]);
  assert.deepEqual((await moves(b)).map(x=>[x.to_bucket,x.qty_pcs]),[['LEAKAGE',12]]);
  await assert.rejects(report('head',b,[L(sku.pp,'EXPIRY',1)]),/a type/);
  await assert.rejects(report('head',b,[L(sku.pp,'GASLESS',4),L(sku.pp,'DAMAGE',1,1)]),/more than the bill/);
  await assert.rejects(db.query("insert into lwb_purchase_check_items(check_id,sku_name,issue,cases) select id,'X','OTHER',1 from lwb_purchase_checks limit 1"),/issue_check/);
});

test('purchase entry: the arrived popup goes to every Godown Manager; the chosen one is still saved', async()=>{
  const arrived=async(b,who=null,as_='head')=>{await as(as_);return (await call('select lwb_purchase_arrived($1,$2) n',[b,who?ids[who]:null]))[0].n};
  const open=async b=>(await db.query("select user_id from erp_notifications where notification_type='PURCHASE_ARRIVED' and ref_id=$1 and not is_read order by user_id",[b])).rows.map(r=>r.user_id);
  const b=await bill('ARR-1');
  assert.equal(await arrived(b,'godown2'),2);
  assert.deepEqual(await open(b),[ids.godown,ids.godown2].sort());
  assert.equal((await db.query('select godown_user_id from lwb_goods_inward where id=$1',[b])).rows[0].godown_user_id,ids.godown2);
  assert.equal(await arrived(b,'godown'),0); // no second popup
  const b2=await bill('ARR-2');assert.equal(await arrived(b2,null),2);
  await assert.rejects(arrived(b,'acc'),/active Godown Manager/);
  await assert.rejects(arrived(b,'godown','godown'),/Only Admin \/ Sales Head/);
  await report('godown2',b,[]); // one manager checks: everybody's popup closes, no new one
  assert.deepEqual(await open(b),[]);
  assert.equal(await arrived(b,'godown'),0);
});
