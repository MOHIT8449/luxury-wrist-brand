import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_purchase_mrp_billing_setup.sql on a tiny copy of the tables it touches (no live database).
// lwb_post_goods_inward is a stand-in that is strict on purpose: it rejects a line whose
// total is not taxable + GST, like a careful live version would.
const ids={admin:'00000000-0000-4000-8000-000000000001',sales:'00000000-0000-4000-8000-000000000002'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE FUNCTION public.lwb_has_page(p_page text) RETURNS boolean LANGUAGE sql AS $$ SELECT false $$;
CREATE TABLE public.lwb_companies(id uuid default gen_random_uuid() primary key,name text,purchase_billing text default 'TAXABLE');
CREATE TABLE public.sku_master(id uuid default gen_random_uuid() primary key,sku_name text,pcs_per_case int,gst_rate numeric,cess_rate numeric default 0,company_id uuid,is_active boolean default true);
CREATE TABLE public.lwb_supplier_master(id uuid default gen_random_uuid() primary key,supplier_code text,supplier_name text,gstin text,is_active boolean default true);
CREATE TABLE public.lwb_goods_inward(id uuid default gen_random_uuid() primary key,supplier_id uuid,supplier_name text,invoice_no text,invoice_date date,received_date date,created_at timestamptz default clock_timestamp(),unique(supplier_name,invoice_no));
CREATE TABLE public.lwb_goods_inward_items(id bigserial primary key,inward_id uuid references lwb_goods_inward(id),sku_id uuid,cases int,pcs int,taxable_amount numeric(14,2),total_amount numeric(14,2));
CREATE TABLE public.stock_log(sku_id uuid,pcs int);
CREATE FUNCTION public.lwb_post_goods_inward(p_supplier_name text,p_invoice_no text,p_invoice_date date,p_received_date date,p_transport_name text,
  p_vehicle_no text,p_lr_no text,p_remarks text,p_items jsonb,p_driver_name text,p_driver_mobile text,p_supplier_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id uuid; i jsonb; v_rate numeric; v_pack int; v_tax numeric; v_pcs int := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = auth.uid() AND role IN ('admin','manager')) THEN RAISE EXCEPTION 'not allowed'; END IF;
  INSERT INTO public.lwb_goods_inward(supplier_id,supplier_name,invoice_no,invoice_date,received_date) VALUES (p_supplier_id,p_supplier_name,p_invoice_no,p_invoice_date,p_received_date) RETURNING id INTO v_id;
  FOR i IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT gst_rate,pcs_per_case INTO v_rate,v_pack FROM public.sku_master WHERE id = (i->>'sku_id')::uuid;
    v_tax := (i->>'taxable_amount')::numeric;
    IF abs((i->>'total_amount')::numeric - (v_tax + 2*round(v_tax*v_rate/200,2))) > 0.001 THEN RAISE EXCEPTION 'total mismatch'; END IF;
    INSERT INTO public.lwb_goods_inward_items(inward_id,sku_id,cases,pcs,taxable_amount,total_amount)
      VALUES (v_id,(i->>'sku_id')::uuid,(i->>'cases')::int,(i->>'pcs')::int,v_tax,(i->>'total_amount')::numeric);
    INSERT INTO public.stock_log VALUES ((i->>'sku_id')::uuid,(i->>'cases')::int*v_pack+(i->>'pcs')::int);
    v_pcs := v_pcs + (i->>'cases')::int*v_pack+(i->>'pcs')::int;
  END LOOP;
  RETURN jsonb_build_object('invoice_no',p_invoice_no,'sku_count',jsonb_array_length(p_items),'total_pcs',v_pcs);
END $$;
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,k,k]);
const setup=await readFile(new URL('../../lwb_purchase_mrp_billing_setup.sql',import.meta.url),'utf8');
await db.exec(setup);
await db.exec(setup); // safe to run again

const RAJ=(await db.query("insert into lwb_companies(name,purchase_billing) values('RAJNIGANDHA','MRP') returning id")).rows[0].id;
const COKE=(await db.query("insert into lwb_companies(name) values('COCA-COLA') returning id")).rows[0].id;
const sku={};
for(const [n,pack,co,gst] of [['RG 2.2G',96,RAJ,40],['RG 4G',60,RAJ,40],['RG 17G',72,RAJ,40],['THUMSUP 250ML',24,COKE,40]])
  sku[n]=(await db.query('insert into sku_master(sku_name,pcs_per_case,company_id,gst_rate) values($1,$2,$3,$4) returning id',[n,pack,co,gst])).rows[0].id;
const DS=(await db.query("insert into lwb_supplier_master(supplier_code,supplier_name,gstin,company_id) values('S1','DHARAMPAL SATYAPAL LTD','24AAACD0132H1ZE',$1) returning id",[RAJ])).rows[0].id;
const ANY=(await db.query("insert into lwb_supplier_master(supplier_code,supplier_name,gstin) values('S2','ANY TRADER','27AAAAA0000A1Z5') returning id")).rows[0].id;

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function post(header,items){
  await db.exec('SET ROLE authenticated');
  try{return (await db.query('select public.lwb_post_goods_inward_mrp($1::jsonb,$2::jsonb) r',[JSON.stringify(header),JSON.stringify(items)])).rows[0].r}
  finally{await db.exec('RESET ROLE')}
}
const head=(no,sup=DS)=>({p_supplier_id:sup,p_invoice_no:no,p_invoice_date:'2026-10-30',p_received_date:'2026-10-31',p_driver_name:'D',p_driver_mobile:'9999999999'});
const lines=async no=>(await db.query(`select s.sku_name,i.* from lwb_goods_inward_items i join lwb_goods_inward g on g.id=i.inward_id join sku_master s on s.id=i.sku_id where g.invoice_no=$1 order by s.sku_name`,[no])).rows;

test('DS Group bill 322HA21087 posts with the bill total',async()=>{
  await as('admin');
  const r=await post(head('322HA21087'),[
    {sku_id:sku['RG 2.2G'],cases:10,pcs:0,billing_mode:'MRP',net_amount:'278217.86',mrp_per_case:'51840.00',mrp_amount:'518400.00',deemed_value:'370286.00'},
    {sku_id:sku['RG 4G'],cases:10,pcs:0,billing_mode:'MRP',net_amount:'357355.88',mrp_per_case:'62400.00',mrp_amount:'624000.00',deemed_value:'445714.00'},
    {sku_id:sku['RG 17G'],cases:3,pcs:0,billing_mode:'MRP',net_amount:'97200.26',mrp_per_case:'60480.00',mrp_amount:'181440.00',deemed_value:'129600.00'}]);
  assert.equal(Number(r.invoice_total),1111014.00);   // bill: 11,11,014.00 before ₹0.02 round off
  assert.equal(r.total_pcs,10*96+10*60+3*72);
  const l=await lines('322HA21087');
  assert.deepEqual(l.map(x=>[x.sku_name,Number(x.total_amount),Number(x.taxable_amount),Number(x.net_amount),x.billing_mode]),[
    ['RG 17G',149040.26,129600,97200.26,'MRP'],['RG 2.2G',426332.26,370286,278217.86,'MRP'],['RG 4G',535641.48,445714,357355.88,'MRP']]);
  const mrp=(await db.query('select mrp_per_case from sku_master where id=$1',[sku['RG 2.2G']])).rows[0];
  assert.equal(Number(mrp.mrp_per_case),51840);       // remembered for the next bill
});

test('GST and totals come from the database, not the browser',async()=>{
  await as('admin');
  await post(head('T-2'),[{sku_id:sku['RG 17G'],cases:1,pcs:0,billing_mode:'MRP',net_amount:'32400.09',deemed_value:'43200',gst_amount:'1',total_amount:'5'}]);
  const [l]=await lines('T-2');
  assert.equal(Number(l.total_amount),32400.09+8640*2);
});

test('supplier tied to Rajnigandha refuses a Coca-Cola SKU, and nothing is saved',async()=>{
  await as('admin');
  await assert.rejects(post(head('T-3'),[
    {sku_id:sku['RG 4G'],cases:1,pcs:0,billing_mode:'MRP',net_amount:'100',deemed_value:'100'},
    {sku_id:sku['THUMSUP 250ML'],cases:1,pcs:0,billing_mode:'TAXABLE',taxable_amount:'100'}]),/not an SKU of this supplier/);
  assert.equal((await lines('T-3')).length,0);
});

test('mixed bill from an untied supplier: other-state GSTIN = IGST, normal lines stay normal',async()=>{
  await as('admin');
  await post(head('T-4',ANY),[
    {sku_id:sku['RG 4G'],cases:1,pcs:30,billing_mode:'MRP',net_amount:'53603.38',deemed_value:'66857'},
    {sku_id:sku['THUMSUP 250ML'],cases:5,pcs:0,billing_mode:'TAXABLE',taxable_amount:'1000.01'}]);
  const l=await lines('T-4');
  assert.equal(Number(l[0].total_amount),53603.38+26742.80);
  assert.equal(l[1].billing_mode,'TAXABLE');assert.equal(Number(l[1].total_amount),1400.01);
});

test('duplicate invoice and missing amounts are refused; salesman cannot post',async()=>{
  await as('admin');
  await assert.rejects(post(head('322HA21087'),[{sku_id:sku['RG 4G'],cases:1,pcs:0,billing_mode:'MRP',net_amount:'1',deemed_value:'1'}]));
  await assert.rejects(post(head('T-5'),[{sku_id:sku['RG 4G'],cases:1,pcs:0,billing_mode:'MRP',net_amount:'100',deemed_value:''}]),/Deemed/);
  await assert.rejects(post(head('T-5'),[{sku_id:sku['RG 4G'],cases:1,pcs:0,billing_mode:'MRP',net_amount:'0',deemed_value:'5'}]),/Net Sale/);
  await as('sales');
  await assert.rejects(post(head('T-6'),[{sku_id:sku['RG 4G'],cases:1,pcs:0,billing_mode:'MRP',net_amount:'1',deemed_value:'1'}]),/Admin or Manager/);
});
