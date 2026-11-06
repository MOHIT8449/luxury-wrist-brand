import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_purchase_damage_report_setup.sql on an empty PGlite database, after the files it needs
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
await db.exec(mine);await db.exec(mine); // safe to run again

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

test('new purchase bill: every Godown Manager gets one "vehicle arrived" bell with vehicle, supplier, invoice, cases', async()=>{
  const b=await bill('INV-1');
  for(const g of ['godown','godown2']){
    const n=await bells(g,'PURCHASE_ARRIVED');
    assert.equal(n.length,1);assert.equal(n[0].ref_id,b);assert.equal(n[0].ref_type,'PURCHASE_BILL');
    assert.equal(n[0].title,'Purchase vehicle arrived: GJ05AB1234');
    assert.match(n[0].message,/^Vehicle GJ05AB1234 · DS GROUP · Inv INV-1 · 15 CS\. /);
  }
  assert.equal((await bells('admin','PURCHASE_ARRIVED')).length,0);
});

test('Godown Manager reports damage: Admin + Sales Head get the report, arrived bells close, damaged goods leave saleable', async()=>{
  const b=await bill('INV-2');
  const before=await live();
  const r=await report('godown',b,[{sku_id:sku.rg,sku_name:'RG 4G',pcs_per_case:24,issue:'DAMAGE',cases:2,pcs:0},
    {sku_id:sku.rg,sku_name:'RG 4G',pcs_per_case:24,issue:'LEAKAGE',cases:0,pcs:6},{sku_id:sku.pp,sku_name:'PASS PASS',pcs_per_case:12,issue:'SHORTAGE',cases:1,pcs:0}],'door side wet');
  assert.equal(r.damage,true);assert.equal(r.notified,2);
  for(const w of ['admin','head']){
    const n=await bells(w,'PURCHASE_DAMAGE');
    assert.equal(n.length,1);assert.equal(n[0].ref_id,b);
    assert.equal(n[0].title,'Purchase damage: 3.3 CS');
    assert.match(n[0].message,/Inv INV-2 · 15 CS\. PASS PASS Shortage 1 cs, RG 4G Damage 2 cs, RG 4G Leakage 6 pcs\. Photos 0\. Kept out of saleable stock\. Note: door side wet\. By Name godown\.$/);
  }
  assert.equal((await bells('acc','PURCHASE_DAMAGE')).length,0);
  for(const g of ['godown','godown2'])assert.ok((await bells(g,'PURCHASE_ARRIVED')).filter(n=>n.ref_id===b).every(n=>n.is_read));
  const m=await moves(b);
  assert.deepEqual(m.map(x=>[x.to_bucket,x.qty_pcs,x.status]).sort(),[['DAMAGE',48,'APPROVED'],['LEAKAGE',6,'APPROVED'],['LOSS',12,'APPROVED']]);
  const after=await live();
  assert.equal(before[sku.rg].s-after[sku.rg].s,54);assert.equal(after[sku.rg].d-before[sku.rg].d,54);
  assert.equal(before[sku.pp].s-after[sku.pp].s,12);assert.equal(after[sku.pp].d,before[sku.pp].d); // shortage: not held
  // claim still pending for Admin / Sales Head
  assert.equal((await db.query('select claim_status from lwb_purchase_checks where inward_id=$1',[b])).rows[0].claim_status,'PENDING');
});

test('changing the report moves stock again (no double count); All OK gives stock back', async()=>{
  const b=await bill('INV-3');
  const base=(await live())[sku.rg].s;
  await report('godown',b,[{sku_id:sku.rg,sku_name:'RG 4G',pcs_per_case:24,issue:'DAMAGE',cases:3,pcs:0}]);
  await report('godown',b,[{sku_id:sku.rg,sku_name:'RG 4G',pcs_per_case:24,issue:'DAMAGE',cases:3,pcs:0}]); // same again
  assert.equal((await moves(b)).filter(x=>x.status==='APPROVED').length,1);
  assert.equal(base-(await live())[sku.rg].s,72);
  await report('admin',b,[{sku_id:sku.rg,sku_name:'RG 4G',pcs_per_case:24,issue:'DAMAGE',cases:1,pcs:0}]);
  assert.equal(base-(await live())[sku.rg].s,24);
  const r=await report('godown',b,[]);
  assert.equal(r.damage,false);
  assert.equal((await live())[sku.rg].s,base);
  assert.ok((await moves(b)).every(x=>x.status==='CANCELLED'));
  assert.equal((await bells('head','PURCHASE_CHECK_OK')).filter(n=>n.ref_id===b).length,1);
});

test('check saved at Goods Inward (old RPC) also moves stock and closes the arrived popup', async()=>{
  const b=await bill('INV-4');
  await as('head');
  await call("select lwb_save_purchase_check($1,current_date,'',$2)",[b,JSON.stringify([{sku_id:sku.pp,sku_name:'PASS PASS',pcs_per_case:12,issue:'LEAKAGE',cases:1,pcs:0}])]);
  assert.deepEqual((await moves(b)).map(x=>[x.to_bucket,x.qty_pcs]),[['LEAKAGE',12]]);
  assert.ok((await bells('godown','PURCHASE_ARRIVED')).filter(n=>n.ref_id===b).every(n=>n.is_read));
  // Admin deletes the check: stock lines cancelled
  await as('admin');await call('delete from lwb_purchase_checks where inward_id=$1',[b]);
  assert.ok((await moves(b)).every(x=>x.status==='CANCELLED'));
});

test('rules: only Admin / Sales Head / Godown Manager; not more than billed; type and qty needed', async()=>{
  const b=await bill('INV-5');
  await assert.rejects(report('acc',b,[]),/Only Admin, Sales Head or Godown Manager/);
  await assert.rejects(report('sales',b,[]),/Only Admin, Sales Head or Godown Manager/);
  await assert.rejects(report('godown',b,[{sku_id:sku.pp,sku_name:'PASS PASS',pcs_per_case:12,issue:'DAMAGE',cases:4,pcs:0},{sku_id:sku.pp,sku_name:'PASS PASS',pcs_per_case:12,issue:'LEAKAGE',cases:1,pcs:1}]),/more than the bill/);
  await assert.rejects(report('godown',b,[{sku_id:sku.pp,sku_name:'PASS PASS',pcs_per_case:12,issue:'BROKEN',cases:1,pcs:0}]),/type/);
  await assert.rejects(report('godown',b,[{sku_id:sku.pp,sku_name:'PASS PASS',pcs_per_case:12,issue:'DAMAGE',cases:0,pcs:0}]),/cases or PCS/);
  assert.equal((await db.query('select count(*)::int n from lwb_purchase_checks where inward_id=$1',[b])).rows[0].n,0);
  // claim already with the company: Godown Manager can not change it
  await report('godown',b,[{sku_id:sku.pp,sku_name:'PASS PASS',pcs_per_case:12,issue:'DAMAGE',cases:1,pcs:0}]);
  await db.query("update lwb_purchase_checks set claim_status='SENT' where inward_id=$1",[b]);
  await assert.rejects(report('godown',b,[]),/already with the company/);
});
