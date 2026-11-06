import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_purchase_bill_edit_delete_setup.sql on a small copy of the tables it touches (no live database).
// lwb_post_goods_inward is a stand-in that writes one stock row per line, linked by `link`
// ('reference_id' = bill id, 'reference_no' = invoice no., 'none' = no link at all).
const ids={admin:'00000000-0000-4000-8000-000000000001',manager:'00000000-0000-4000-8000-000000000002'};
const files=async()=>Promise.all(['lwb_purchase_mrp_billing_setup.sql','lwb_purchase_bill_edit_delete_setup.sql']
  .map(f=>readFile(new URL('../../'+f,import.meta.url),'utf8')));

async function makeDb(link){
  const db=new PGlite();
  const col=link==='reference_id'?'reference_id uuid,':link==='reference_no'?'reference_no text,':'';
  const cn=link==='none'?'':link+',';
  const val=link==='reference_id'?'v_id,':link==='reference_no'?'p_invoice_no,':'';
  await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE FUNCTION public.lwb_has_page(p_page text) RETURNS boolean LANGUAGE sql AS $$ SELECT false $$;
CREATE FUNCTION public.lwb_inv_key(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT upper(regexp_replace(coalesce(p,''), '[^A-Za-z0-9]', '', 'g')) $$;
CREATE TABLE public.lwb_companies(id uuid default gen_random_uuid() primary key,name text,purchase_billing text default 'TAXABLE');
CREATE TABLE public.sku_master(id uuid default gen_random_uuid() primary key,sku_name text,pcs_per_case int,gst_rate numeric,cess_rate numeric default 0,company_id uuid,is_active boolean default true);
CREATE TABLE public.lwb_supplier_master(id uuid default gen_random_uuid() primary key,supplier_code text,supplier_name text,gstin text,is_active boolean default true);
CREATE TABLE public.lwb_goods_inward(id uuid default gen_random_uuid() primary key,supplier_id uuid,supplier_name text,invoice_no text,invoice_date date,received_date date,
  vehicle_no text,time_in timestamptz,time_out timestamptz,godown_user_id uuid,created_at timestamptz default clock_timestamp(),unique(supplier_name,invoice_no));
CREATE TABLE public.lwb_goods_inward_items(id bigserial primary key,inward_id uuid references lwb_goods_inward(id),sku_id uuid,cases int,pcs int,quantity_pcs int,taxable_amount numeric(14,2),total_amount numeric(14,2));
CREATE TABLE public.lwb_inventory_movements(id bigserial primary key,sku_id uuid,movement_type text,stock_bucket text default 'SALEABLE',qty_pcs int,${col}notes text,created_at timestamptz default now());
CREATE VIEW public.lwb_live_stock AS SELECT sku_id, sum(qty_pcs)::int AS saleable_pcs FROM public.lwb_inventory_movements WHERE stock_bucket='SALEABLE' GROUP BY sku_id;
CREATE FUNCTION public.lwb_post_goods_inward(p_supplier_name text,p_invoice_no text,p_invoice_date date,p_received_date date,p_transport_name text,
  p_vehicle_no text,p_lr_no text,p_remarks text,p_items jsonb,p_driver_name text,p_driver_mobile text,p_supplier_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id uuid; i jsonb; v_pack int; v_pcs int; v_all int := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = auth.uid() AND role IN ('admin','manager')) THEN RAISE EXCEPTION 'not allowed'; END IF;
  INSERT INTO public.lwb_goods_inward(supplier_id,supplier_name,invoice_no,invoice_date,received_date,vehicle_no) VALUES (p_supplier_id,p_supplier_name,p_invoice_no,p_invoice_date,p_received_date,p_vehicle_no) RETURNING id INTO v_id;
  FOR i IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT pcs_per_case INTO v_pack FROM public.sku_master WHERE id = (i->>'sku_id')::uuid;
    v_pcs := (i->>'cases')::int*v_pack+(i->>'pcs')::int; v_all := v_all + v_pcs;
    INSERT INTO public.lwb_goods_inward_items(inward_id,sku_id,cases,pcs,quantity_pcs,taxable_amount,total_amount)
      VALUES (v_id,(i->>'sku_id')::uuid,(i->>'cases')::int,(i->>'pcs')::int,v_pcs,(i->>'taxable_amount')::numeric,(i->>'total_amount')::numeric);
    INSERT INTO public.lwb_inventory_movements(sku_id,movement_type,qty_pcs,${cn}notes) VALUES ((i->>'sku_id')::uuid,'PURCHASE_IN',v_pcs,${val}'inward');
  END LOOP;
  RETURN jsonb_build_object('invoice_no',p_invoice_no,'sku_count',jsonb_array_length(p_items),'total_pcs',v_all);
END $$;
CREATE TABLE public.lwb_purchase_checks(id uuid primary key default gen_random_uuid(),inward_id uuid not null unique references lwb_goods_inward(id) on delete cascade,
  verified_on date not null default current_date,has_damage boolean default false,claim_status text default 'NONE',updated_at timestamptz default now());
CREATE TABLE public.lwb_purchase_check_items(id uuid primary key default gen_random_uuid(),check_id uuid references lwb_purchase_checks(id) on delete cascade,sku_id uuid,sku_name text,issue text,cases int,pcs int);
CREATE TABLE public.lwb_stock_moves(id bigserial primary key,sku_id uuid,qty_pcs int,status text,decided_at timestamptz,decided_by uuid,decision_note text,inward_id uuid);
CREATE TABLE public.lwb_documents(id bigserial primary key,entity_type text,entity_id text,doc_type text,removed_at timestamptz,removed_by uuid);
CREATE TABLE public.lwb_tasks(id bigserial primary key,status text,ref_type text,ref_id text,last_activity_at timestamptz);
CREATE TABLE public.erp_notifications(id bigserial primary key,ref_type text,ref_id text);
CREATE TABLE public.lwb_sp_entries(id bigserial primary key,entry_type text,ref_no text,note text,pallets int);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
  for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,k,k]);
  for(const f of await files()){await db.exec(f);await db.exec(f);} // safe to run again
  const RAJ=(await db.query("insert into lwb_companies(name,purchase_billing) values('RAJNIGANDHA','MRP') returning id")).rows[0].id;
  const COKE=(await db.query("insert into lwb_companies(name) values('COCA-COLA') returning id")).rows[0].id;
  const sku={};
  for(const [n,pack,co] of [['RG 2.2G',96,RAJ],['RG 4G',60,RAJ],['THUMSUP',24,COKE],['SPRITE',24,COKE]])
    sku[n]=(await db.query('insert into sku_master(sku_name,pcs_per_case,company_id,gst_rate) values($1,$2,$3,40) returning id',[n,pack,co])).rows[0].id;
  const DS=(await db.query("insert into lwb_supplier_master(supplier_code,supplier_name,gstin,company_id) values('S1','DHARAMPAL SATYAPAL LTD','24AAACD0132H1ZE',$1) returning id",[RAJ])).rows[0].id;
  const HC=(await db.query("insert into lwb_supplier_master(supplier_code,supplier_name,gstin,company_id) values('S2','HCCB','24AAACH0000A1Z5',$1) returning id",[COKE])).rows[0].id;
  // opening stock
  for(const s of Object.values(sku))await db.query("insert into lwb_inventory_movements(sku_id,movement_type,qty_pcs) values($1,'OPENING',10000)",[s]);
  const as=async who=>db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||'']);
  const call=async(who,sql,args)=>{await as(who);await db.exec('SET ROLE authenticated');
    try{return (await db.query(sql,args)).rows[0]}finally{await db.exec('RESET ROLE')}};
  const stock=async s=>(await db.query('select saleable_pcs from lwb_live_stock where sku_id=$1',[s])).rows[0]?.saleable_pcs??0;
  const header=(sup,inv)=>({p_supplier_id:sup,p_invoice_no:inv,p_invoice_date:'2026-11-05',p_received_date:'2026-11-06',p_vehicle_no:'GJ01AB1234',p_driver_name:'DIKEN'});
  const tax=(s,cases,amt)=>({sku_id:s,cases,pcs:0,taxable_amount:amt.toFixed(2),total_amount:(amt*1.4).toFixed(2)});
  const postCoke=async(inv,lines)=>{await call('admin','select public.lwb_post_goods_inward_mrp($1::jsonb,$2::jsonb) r',[JSON.stringify(header(HC,inv)),JSON.stringify(lines.map(l=>({...l,billing_mode:'TAXABLE'})))]);
    return (await db.query('select id from lwb_goods_inward where invoice_no=$1',[inv])).rows[0].id};
  return {db,sku,DS,HC,call,stock,header,tax,postCoke};
}

test('delete: stock goes back, check / claim, photos, tasks, pallets removed, copy kept', async()=>{
  const {db,sku,call,stock,postCoke,tax}=await makeDb('reference_id');
  const id=await postCoke('HC-101',[tax(sku.THUMSUP,10,1000),tax(sku.SPRITE,5,500)]);
  assert.equal(await stock(sku.THUMSUP),10000+240);
  const ck=(await db.query("insert into lwb_purchase_checks(inward_id,has_damage,claim_status) values($1,true,'PENDING') returning id",[id])).rows[0].id;
  await db.query("insert into lwb_purchase_check_items(check_id,sku_id,sku_name,issue,cases,pcs) values($1,$2,'THUMSUP','DAMAGE',1,0)",[ck,sku.THUMSUP]);
  await db.query("insert into lwb_stock_moves(sku_id,qty_pcs,status,inward_id) values($1,24,'APPROVED',$2)",[sku.THUMSUP,id]);
  await db.query("insert into lwb_documents(entity_type,entity_id,doc_type) values('PURCHASE_BILL',$1,'BILL')",[id]);
  await db.query("insert into lwb_tasks(status,ref_type,ref_id) values('OPEN','PURCHASE_BILL',$1)",[id]);
  await db.query("insert into lwb_sp_entries(entry_type,ref_no,note,pallets) values('COMPANY_IN','HC-101','Purchase bill · HCCB',2),('COMPANY_IN','HC-999','Purchase bill · HCCB',1)");

  await assert.rejects(call('manager','select public.lwb_purchase_bill_delete($1,$2) r',[id,'wrong bill']),/Only Admin/);
  await assert.rejects(call('admin','select public.lwb_purchase_bill_delete($1,$2) r',[id,'']),/reason/);
  const pre=(await call('admin','select public.lwb_purchase_bill_preview($1) r',[id])).r;
  assert.equal(pre.can,true);assert.equal(pre.stock_rows,2);
  const th=pre.lines.find(l=>l.sku_id===sku.THUMSUP);
  assert.equal(Number(th.bill_pcs),240);assert.equal(Number(th.stock_now),10240);assert.equal(Number(th.stock_after),10000);

  const r=(await call('admin','select public.lwb_purchase_bill_delete($1,$2) r',[id,'Entered twice'])).r;
  assert.equal(r.stock_rows,2);
  assert.equal(await stock(sku.THUMSUP),10000);assert.equal(await stock(sku.SPRITE),10000);
  const n=async q=>Number((await db.query(q)).rows[0].n);
  assert.equal(await n('select count(*) n from lwb_goods_inward'),0);
  assert.equal(await n('select count(*) n from lwb_goods_inward_items'),0);
  assert.equal(await n('select count(*) n from lwb_purchase_checks'),0);
  assert.equal(await n("select count(*) n from lwb_stock_moves where status='CANCELLED'"),1);
  assert.equal(await n('select count(*) n from lwb_documents where removed_at is not null'),1);
  assert.equal(await n("select count(*) n from lwb_tasks where status='CANCELLED'"),1);
  assert.equal(await n("select count(*) n from lwb_sp_entries"),1); // only the other bill's pallets are left
  const log=(await db.query('select * from lwb_purchase_bill_log')).rows;
  assert.equal(log.length,1);assert.equal(log[0].action,'DELETE');assert.equal(log[0].reason,'Entered twice');
  assert.equal(log[0].items.length,2);assert.equal(log[0].stock_rows.length,2);assert.equal(log[0].other.checks.length,1);
  await assert.rejects(call('admin','select public.lwb_purchase_bill_delete($1,$2) r',[id,'again']),/not found/);
});

test('edit: corrected qty / SKU posted, old stock taken back, check / photos / vehicle time move', async()=>{
  const {db,sku,call,stock,postCoke,tax,header,HC}=await makeDb('reference_id');
  const id=await postCoke('HC-200',[tax(sku.THUMSUP,10,1000),tax(sku.SPRITE,5,500)]);
  await db.query("update lwb_goods_inward set time_in='2026-11-06 10:00+05:30', godown_user_id=$2 where id=$1",[id,ids.manager]);
  const ck=(await db.query("insert into lwb_purchase_checks(inward_id,has_damage,claim_status) values($1,true,'PENDING') returning id",[id])).rows[0].id;
  await db.query("insert into lwb_purchase_check_items(check_id,sku_id,sku_name,issue,cases,pcs) values($1,$2,'THUMSUP','DAMAGE',1,0),($1,$3,'SPRITE','LEAKAGE',1,0)",[ck,sku.THUMSUP,sku.SPRITE]);
  await db.query("insert into lwb_stock_moves(sku_id,qty_pcs,status,inward_id) values($1,24,'APPROVED',$2)",[sku.THUMSUP,id]);
  await db.query("insert into lwb_documents(entity_type,entity_id,doc_type) values('PURCHASE_BILL',$1,'BILL')",[id]);

  await assert.rejects(call('manager','select public.lwb_purchase_bill_edit($1,$2,$3::jsonb,$4::jsonb) r',[id,'qty',JSON.stringify(header(HC,'HC-200')),'[]']),/Only Admin/);
  // THUMSUP 10 -> 12 cases, SPRITE removed (wrong SKU), invoice no. corrected
  const items=[{...tax(sku.THUMSUP,12,1200),billing_mode:'TAXABLE'}];
  const r=(await call('admin','select public.lwb_purchase_bill_edit($1,$2,$3::jsonb,$4::jsonb) r',[id,'Qty was wrong',JSON.stringify(header(HC,'HC-200A')),JSON.stringify(items)])).r;
  assert.notEqual(r.id,id);assert.equal(r.old_stock_rows,2);
  assert.equal(await stock(sku.THUMSUP),10000+288);assert.equal(await stock(sku.SPRITE),10000);
  const bills=(await db.query('select * from lwb_goods_inward')).rows;
  assert.equal(bills.length,1);assert.equal(bills[0].invoice_no,'HC-200A');assert.equal(bills[0].id,r.id);
  assert.ok(bills[0].time_in);assert.equal(bills[0].godown_user_id,ids.manager);
  const c=(await db.query('select * from lwb_purchase_checks')).rows;
  assert.equal(c.length,1);assert.equal(c[0].inward_id,r.id);
  const ci=(await db.query('select sku_name from lwb_purchase_check_items')).rows.map(x=>x.sku_name);
  assert.deepEqual(ci,['THUMSUP']); // the removed SKU's damage line goes
  assert.equal((await db.query("select inward_id from lwb_stock_moves")).rows[0].inward_id,r.id);
  assert.equal((await db.query("select entity_id from lwb_documents")).rows[0].entity_id,r.id);
  const log=(await db.query('select * from lwb_purchase_bill_log')).rows;
  assert.equal(log[0].action,'EDIT');assert.equal(log[0].new_inward_id,r.id);assert.equal(log[0].invoice_no,'HC-200');
});

test('edit with same invoice no. and an MRP (Rajnigandha) bill', async()=>{
  const {db,sku,call,stock,header,DS}=await makeDb('reference_id');
  const mrp=(s,cases,net,deemed)=>({sku_id:s,cases,pcs:0,billing_mode:'MRP',net_amount:net,deemed_value:deemed});
  await call('admin','select public.lwb_post_goods_inward_mrp($1::jsonb,$2::jsonb) r',[JSON.stringify(header(DS,'322HA21553')),JSON.stringify([mrp(sku['RG 2.2G'],14,'100000.00','120000.00')])]);
  const id=(await db.query('select id from lwb_goods_inward')).rows[0].id;
  assert.equal(await stock(sku['RG 2.2G']),10000+14*96);
  const r=(await call('admin','select public.lwb_purchase_bill_edit($1,$2,$3::jsonb,$4::jsonb) r',[id,'IC count wrong',JSON.stringify(header(DS,'322HA21553')),
    JSON.stringify([mrp(sku['RG 2.2G'],140,'100000.00','120000.00'),mrp(sku['RG 4G'],2,'5000.00','6000.00')])])).r;
  assert.equal(await stock(sku['RG 2.2G']),10000+140*96);assert.equal(await stock(sku['RG 4G']),10000+120);
  const b=(await db.query('select * from lwb_goods_inward')).rows;
  assert.equal(b.length,1);assert.equal(b[0].invoice_no,'322HA21553');
  const t=(await db.query("select sum(total_amount)::numeric n from lwb_goods_inward_items")).rows[0].n;
  assert.ok(Number(t)>105000); // net + GST, written by the MRP function
  // a failing post changes nothing (bad SKU)
  await assert.rejects(call('admin','select public.lwb_purchase_bill_edit($1,$2,$3::jsonb,$4::jsonb) r',[r.id,'x again',JSON.stringify(header(DS,'322HA21553')),
    JSON.stringify([mrp(sku.THUMSUP,1,'10.00','12.00')])]),/not an SKU/);
  assert.equal((await db.query('select count(*)::int n from lwb_goods_inward')).rows[0].n,1);
  assert.equal(await stock(sku['RG 2.2G']),10000+140*96);
});

test('no link column: stock rows found by invoice no.; none found = refused', async()=>{
  const a=await makeDb('reference_no');
  const id=await a.postCoke('HC-300',[a.tax(a.sku.THUMSUP,10,1000)]);
  await a.call('admin','select public.lwb_purchase_bill_delete($1,$2) r',[id,'test delete']);
  assert.equal(await a.stock(a.sku.THUMSUP),10000);
  assert.equal(await a.stock(a.sku.SPRITE),10000); // opening rows untouched

  const b=await makeDb('none');
  const id2=await b.postCoke('HC-400',[b.tax(b.sku.THUMSUP,10,1000)]);
  const pre=(await b.call('admin','select public.lwb_purchase_bill_preview($1) r',[id2])).r;
  assert.equal(pre.can,false);assert.match(pre.why,/not found/);
  await assert.rejects(b.call('admin','select public.lwb_purchase_bill_delete($1,$2) r',[id2,'test delete']),/not found/);
  assert.equal(await b.stock(b.sku.THUMSUP),10240);
  assert.equal((await b.db.query('select count(*)::int n from lwb_goods_inward')).rows[0].n,1);
});
