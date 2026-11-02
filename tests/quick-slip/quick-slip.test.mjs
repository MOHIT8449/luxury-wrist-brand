import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_quick_slip_setup.sql on an empty PGlite database (no live data).
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  accounts:'00000000-0000-4000-8000-000000000003',sales:'00000000-0000-4000-8000-000000000004',
  coke:'00000000-0000-4000-8000-000000000005'};
const roles={admin:'admin',head:'manager',accounts:'accounts',sales:'sales',coke:'manager'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
CREATE TABLE public.lwb_companies(id uuid default gen_random_uuid() primary key,name text,pack_unit text);
CREATE TABLE public.lwb_user_companies(user_id uuid,company_id uuid);
CREATE TABLE public.sku_master(sku_name text,company_id uuid);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,order_date timestamptz default now(),
  customer_name text,sales_person text,status text,total_qty numeric,total_amount numeric,created_by uuid);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric default 0,rate numeric);
CREATE TABLE public.dispatch_assignments(order_id uuid);
CREATE TABLE public.lwb_customer_master(customer_name text,mobile text,billing_address text,city text,pincode text,is_active boolean);
INSERT INTO public.lwb_customer_master VALUES ('Shree Krishna','9898012345','12 Station Road','Ahmedabad','382415',true);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false);
-- brand-limited logins see only their companies (as in lwb_company_brand_setup.sql)
CREATE FUNCTION public.lwb_my_companies() RETURNS uuid[] LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN EXISTS (SELECT 1 FROM public.lwb_user_companies WHERE user_id=auth.uid())
    THEN (SELECT array_agg(company_id) FROM public.lwb_user_companies WHERE user_id=auth.uid()) END $$;
CREATE FUNCTION public.lwb_company_ok(p uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT p IS NULL OR public.lwb_my_companies() IS NULL OR p = ANY(public.lwb_my_companies()) $$;
-- vehicle loaded trigger stand-in: Accounts gets "make bill"
CREATE FUNCTION public.t_loaded() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
  IF NEW.status='loaded' AND OLD.status<>'loaded' THEN
    INSERT INTO public.erp_notifications(user_id,title,message,notification_type,order_id) VALUES (NULL,'Vehicle Loaded — Make Tally Bill','x','TALLY_BILL_PENDING',NEW.id);
  END IF; RETURN NEW; END $$;
CREATE TRIGGER t_loaded AFTER UPDATE OF status ON public.orders FOR EACH ROW EXECUTE FUNCTION public.t_loaded();
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true)',[id,roles[k]]);
const [rg,cc]=(await db.query(`insert into lwb_companies(name,pack_unit) values('RAJNIGANDHA','BOX'),('COCA-COLA','CASE') returning id`)).rows.map(r=>r.id);
await db.query(`insert into lwb_user_companies values($1,$2)`,[ids.coke,cc]);
await db.query(`insert into sku_master values('RG PAN MASALA 10',$1),('RG SILVER PEARLS 5',$1),('COKE 250ML',$2),('LOOSE ITEM',null)`,[rg,cc]);
async function order(no,status,lines){
  const id=(await db.query(`insert into orders(order_no,customer_name,sales_person,status,total_qty,total_amount,created_by) values($1,' SHREE KRISHNA ','Vinesh',$2,0,0,$3) returning id`,[no,status,ids.head])).rows[0].id;
  for(const [s,q,r] of lines)await db.query(`insert into order_items(order_id,sku_name,ordered_qty,approved_qty,rate) values($1,$2,$3,$3,$4)`,[id,s,q,r]);
  await db.query(`insert into erp_notifications(title,notification_type,order_id) values('PO Approved — Get Ready to Load','PO_APPROVED_LOADING',$1),('PO Approved — Make Bill','PO_APPROVED_BILL',$1)`,[id]);
  return id;
}
const o1=await order('LXY-1','approved',[['rg pan masala 10',20,2450],['RG SILVER PEARLS 5',10,1180]]);
const oMix=await order('LXY-2','approved',[['RG PAN MASALA 10',1,100],['COKE 250ML',1,100]]);
const oCoke=await order('LXY-3','approved',[['COKE 250ML',5,300]]);
const oPend=await order('LXY-4','pending_approval',[['RG PAN MASALA 10',1,100]]);
const oLoose=await order('LXY-5','approved',[['RG PAN MASALA 10',1,100],['LOOSE ITEM',1,1]]);
const oTr=await order('LXY-6','approved',[['RG PAN MASALA 10',2,100]]);
await db.query('insert into dispatch_assignments values($1)',[oTr]);
const o7=await order('LXY-7','approved',[['RG PAN MASALA 10',3,100]]);

const sql=await readFile(new URL('../../lwb_quick_slip_setup.sql',import.meta.url),'utf8');
await db.exec(sql);await db.exec(sql); // safe to run again

async function run(who,q,params){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);
  await db.exec('SET ROLE authenticated');
  try{return await db.query(q,params)}finally{await db.exec('RESET ROLE')}
}
const P={driver_name:'  Ramesh   Patel ',vehicle_no:'gj-01 ab 1234',driver_mobile:'+91 98765 43210'};

test('Rajnigandha is a quick-slip brand, Coca-Cola is not; run twice keeps an Admin change', async()=>{
  const r=(await db.query(`select name,quick_slip from lwb_companies order by name`)).rows;
  assert.deepEqual(r.map(x=>[x.name,x.quick_slip]),[['COCA-COLA',false],['RAJNIGANDHA',true]]);
  await db.query(`update lwb_companies set quick_slip=true where id=$1`,[cc]);await db.exec(sql);
  assert.equal((await db.query(`select quick_slip from lwb_companies where id=$1`,[cc])).rows[0].quick_slip,true);
  await db.query(`update lwb_companies set quick_slip=false where id=$1`,[cc]);
});

test('Sales Head makes the slip: driver + vehicle saved, PO loaded, popups re-worded', async()=>{
  const s=(await run('head','select public.lwb_quick_slip_dispatch($1,$2) v',[o1,P])).rows[0].v;
  assert.equal(s.order_no,'LXY-1');assert.equal(s.party,'SHREE KRISHNA');assert.equal(s.brand,'RAJNIGANDHA');assert.equal(s.unit,'BOX');
  assert.equal(s.party_mobile,'9898012345');assert.equal(s.party_address,'12 Station Road, Ahmedabad, 382415');
  assert.equal(s.driver_name,'Ramesh Patel');assert.equal(s.vehicle_no,'GJ01AB1234');assert.equal(s.driver_mobile,'9876543210');
  assert.equal(Number(s.total_qty),30);assert.equal(Number(s.total_amount),60800);assert.equal(s.lines.length,2);
  const o=(await db.query('select status from orders where id=$1',[o1])).rows[0];assert.equal(o.status,'loaded');
  const q=(await db.query('select sum(loaded_qty)::int n from order_items where order_id=$1',[o1])).rows[0];assert.equal(q.n,30);
  const n=(await db.query('select notification_type t,title,is_read from erp_notifications where order_id=$1 order by id',[o1])).rows;
  assert.deepEqual(n.map(x=>[x.t,x.is_read]),[['PO_APPROVED_LOADING',true],['PO_APPROVED_BILL',true],['TALLY_BILL_PENDING',false]]);
  assert.match(n[2].title,/Rajnigandha Slip/);
  // called again: only driver / vehicle change, still loaded
  const s2=(await run('head','select public.lwb_quick_slip_dispatch($1,$2) v',[o1,{driver_name:'Suresh',vehicle_no:'GJ01XY9999'}])).rows[0].v;
  assert.equal(s2.driver_name,'Suresh');assert.equal(s2.driver_mobile,null);
});

test('refused: mixed brand, Coca-Cola, SKU without brand, not approved, transport assigned, bad input, wrong role', async()=>{
  await assert.rejects(run('head','select public.lwb_quick_slip_dispatch($1,$2)',[oMix,P]),/not a quick-slip/);
  await assert.rejects(run('head','select public.lwb_quick_slip_dispatch($1,$2)',[oCoke,P]),/not a quick-slip/);
  await assert.rejects(run('head','select public.lwb_quick_slip_dispatch($1,$2)',[oLoose,P]),/not a quick-slip/);
  await assert.rejects(run('head','select public.lwb_quick_slip_dispatch($1,$2)',[oPend,P]),/pending_approval/);
  await assert.rejects(run('head','select public.lwb_quick_slip_dispatch($1,$2)',[oTr,P]),/Transport is already assigned/);
  await assert.rejects(run('head','select public.lwb_quick_slip_dispatch($1,$2)',[o7,{vehicle_no:'GJ01AB1234'}]),/driver name/);
  await assert.rejects(run('head','select public.lwb_quick_slip_dispatch($1,$2)',[o7,{driver_name:'A',vehicle_no:'GJ'}]),/vehicle number/);
  await assert.rejects(run('head','select public.lwb_quick_slip_dispatch($1,$2)',[o7,{driver_name:'A',vehicle_no:'GJ01AB1',driver_mobile:'12345'}]),/10-digit/);
  await assert.rejects(run('accounts','select public.lwb_quick_slip_dispatch($1,$2)',[o7,P]),/Only Admin or Sales Head/);
  await assert.rejects(run('sales','select public.lwb_quick_slip_dispatch($1,$2)',[o7,P]),/Only Admin or Sales Head/);
  // a Coca-Cola-only Sales Head can not touch a Rajnigandha PO
  await assert.rejects(run('coke','select public.lwb_quick_slip_dispatch($1,$2)',[o7,P]),/Order not found/);
  assert.equal((await db.query('select status from orders where id=$1',[o7])).rows[0].status,'approved');
  // no direct table access
  await assert.rejects(run('admin','select * from lwb_quick_slips'),/permission denied/);
});

test('slip read / print count / list: Accounts can read and reprint, salesman can not', async()=>{
  const s=(await run('accounts','select public.lwb_quick_slip_get($1) v',[o1])).rows[0].v;assert.equal(s.order_no,'LXY-1');
  assert.equal((await run('accounts','select public.lwb_quick_slip_printed($1) v',[o1])).rows[0].v,1);
  assert.equal((await run('head','select public.lwb_quick_slip_printed($1) v',[o1])).rows[0].v,2);
  await assert.rejects(run('sales','select public.lwb_quick_slip_get($1)',[o1]),/Only Admin/);
  await assert.rejects(run('accounts','select public.lwb_quick_slip_get($1)',[o7]),/has no slip/);
  await assert.rejects(run('coke','select public.lwb_quick_slip_get($1)',[o1]),/Order not found/);
  const l=(await run('head','select public.lwb_quick_slip_list(null,null) v')).rows[0].v;
  assert.deepEqual(l.slips.map(x=>x.order_no),['LXY-1']);assert.equal(Number(l.slips[0].total_amount),60800);
  // waiting = approved Rajnigandha-only POs without slip or transport
  assert.deepEqual(l.waiting.map(x=>x.order_no).sort(),['LXY-7']);
  const lc=(await run('coke','select public.lwb_quick_slip_list(null,null) v')).rows[0].v;
  assert.equal(lc.slips.length,0);assert.equal(lc.waiting.length,0);
});
