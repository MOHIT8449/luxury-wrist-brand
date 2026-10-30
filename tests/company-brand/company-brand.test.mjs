import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_company_brand_setup.sql on a tiny copy of the tables it reads (no live database).
const ids={admin:'00000000-0000-4000-8000-000000000001',accounts:'00000000-0000-4000-8000-000000000002',manager:'00000000-0000-4000-8000-000000000003',
  rajHead:'00000000-0000-4000-8000-000000000004',rajSales:'00000000-0000-4000-8000-000000000005',cokeSales:'00000000-0000-4000-8000-000000000006',warehouse:'00000000-0000-4000-8000-000000000007'};
const roleOf={admin:'admin',accounts:'accounts',manager:'manager',rajHead:'manager',rajSales:'sales',cokeSales:'sales',warehouse:'warehouse'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.sku_master(id uuid default gen_random_uuid() primary key,sku_name text,pcs_per_case int default 24,is_active boolean default true);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text default 'approved',order_date timestamptz default now(),total_amount numeric,total_qty numeric,created_by uuid);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid references orders(id),sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric default 0,rate numeric,amount numeric);
CREATE TABLE public.lwb_goods_inward(id uuid default gen_random_uuid() primary key,invoice_no text,invoice_date date,received_date date,supplier_name text);
CREATE TABLE public.lwb_goods_inward_items(id bigserial primary key,inward_id uuid,sku_id uuid,total_amount numeric);
CREATE TABLE public.bill_due(order_id uuid,party text,due numeric,invoice_date date);
CREATE FUNCTION public.lwb_tally_bill_rows(p_days integer) RETURNS TABLE (order_id uuid, order_no text, party text, status text, order_date date, dispatch_date date,
  invoice_no text, invoice_date date, bill_amount numeric, erp_amount numeric, approved_return numeric, pending_return numeric, credit_notes numeric, debit_notes numeric,
  collected numeric, verified numeric, due numeric, credit_pending numeric, delivery text, notes jsonb)
  LANGUAGE sql STABLE AS $$ SELECT b.order_id,null,b.party,'loaded',b.invoice_date,b.invoice_date,'T1',b.invoice_date,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,b.due,0::numeric,'',null::jsonb FROM public.bill_due b $$;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY; ALTER TABLE public.sku_master ENABLE ROW LEVEL SECURITY; ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY lwb_signed_in_all ON public.orders FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY lwb_signed_in_all ON public.sku_master FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY lwb_signed_in_all ON public.order_items FOR ALL TO authenticated USING (true) WITH CHECK (true);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
GRANT ALL ON public.orders, public.sku_master, public.order_items TO authenticated;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,roleOf[k],k]);
const setup=await readFile(new URL('../../lwb_company_brand_setup.sql',import.meta.url),'utf8');
await db.exec(setup);
await db.exec(setup); // safe to run again

const today=(await db.query("select (now() at time zone 'Asia/Kolkata')::date::text d")).rows[0].d;
const dayAdd=(d,n)=>{const x=new Date(d+'T12:00:00Z');x.setUTCDate(x.getUTCDate()+n);return x.toISOString().slice(0,10)};
async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const one=async(q,args)=>(await call(q,args))[0];

const co=Object.fromEntries((await db.query('select upper(name) n,id from lwb_companies')).rows.map(r=>[r.n,r.id]));
const RAJ=co['RAJNIGANDHA'],COKE=co['COCA-COLA'];
let sku={};
async function addSku(n,c){const r=(await db.query('insert into sku_master(sku_name,company_id) values($1,$2) returning id',[n,c])).rows[0];sku[n]=r.id;return r.id}
async function po(no,party,lines,by,day=today,status='approved'){
  const total=lines.reduce((a,[,q,r])=>a+q*r,0);
  const id=(await db.query("insert into orders(order_no,customer_name,status,order_date,total_amount,total_qty,created_by) values($1,$2,$3,($4||' 10:00+05:30')::timestamptz,$5,$6,$7) returning id",
    [no,party,status,day,total,lines.reduce((a,[,q])=>a+q,0),ids[by]])).rows[0].id;
  for(const [s,q,r] of lines)await db.query('insert into order_items(order_id,sku_name,ordered_qty,approved_qty,loaded_qty,rate,amount) values($1,$2,$3,$3,$3,$4,$5)',[id,s,q,r,q*r]);
  return id;
}

test('seeded companies: Rajnigandha 4 days credit from company',async()=>{
  const r=(await db.query("select * from lwb_companies where id=$1",[RAJ])).rows[0];
  assert.equal(r.supplier_credit_days,4);
  assert.equal((await db.query('select count(*)::int n from lwb_companies')).rows[0].n,2);
});

test('company master: Admin only, no duplicate names',async()=>{
  await as('manager');
  await assert.rejects(call("select public.lwb_company_save('{\"name\":\"PARLE\"}'::jsonb)"),/Admin only/);
  await as('admin');
  const id=(await one("select public.lwb_company_save('{\"name\":\" parle  agro \",\"supplier_credit_days\":7,\"color\":\"#147d4c\"}'::jsonb) id")).id;
  assert.equal((await db.query('select name from lwb_companies where id=$1',[id])).rows[0].name,'PARLE AGRO');
  await assert.rejects(call("select public.lwb_company_save('{\"name\":\"Parle Agro\"}'::jsonb)"),/already exists/);
  await call("select public.lwb_company_save($1::jsonb)",[JSON.stringify({id,name:'PARLE AGRO',active:false})]);
  assert.equal((await db.query('select active from lwb_companies where id=$1',[id])).rows[0].active,false);
});

test('brand-wise team: Admin sets Sales Head, Sales Head sets salesman only within his brands',async()=>{
  await addSku('RAJNIGANDHA 4G',RAJ);await addSku('300ML THUMS UP',COKE);await addSku('OLD SKU NO COMPANY',null);
  await as('rajHead');
  await assert.rejects(call('select public.lwb_set_user_companies($1,$2)',[ids.rajHead,[RAJ]]),/Only Admin/);
  await as('admin');
  await call('select public.lwb_set_user_companies($1,$2)',[ids.rajHead,[RAJ]]);
  await call('select public.lwb_set_user_companies($1,$2)',[ids.cokeSales,[COKE]]);
  await as('rajHead');
  await assert.rejects(call('select public.lwb_set_user_companies($1,$2)',[ids.rajSales,[COKE]]),/only your own/);
  await assert.rejects(call('select public.lwb_set_user_companies($1,$2)',[ids.cokeSales,[RAJ]]),/another company/);
  await call('select public.lwb_set_user_companies($1,$2)',[ids.rajSales,[RAJ]]);
  await assert.rejects(call('select public.lwb_set_user_companies($1,$2)',[ids.accounts,[RAJ]]),/Sales Head or Salesman/);
  await as('admin');
  const team=await call('select * from public.lwb_brand_team()');
  assert.deepEqual(team.find(x=>x.user_id===ids.rajSales).company_ids,[RAJ]);
  assert.deepEqual(team.find(x=>x.user_id===ids.manager).company_ids,[]);
});

test('brand-limited login sees only its SKUs and orders; Admin, Accounts, Godown, open Sales Head see all',async()=>{
  const o1=await po('R-1','ASHOK STORES',[['RAJNIGANDHA 4G',10,500]],'admin');
  const o2=await po('C-1','ASHOK STORES',[['300ML THUMS UP',20,300]],'admin');
  const o3=await po('M-1','RAM STORES',[['300ML THUMS UP',2,300],['RAJNIGANDHA 4G',1,500]],'admin');
  const o4=await po('C-2','RAM STORES',[['300ML THUMS UP',5,300]],'rajSales'); // his own order stays visible
  const seen=async who=>{await as(who);return (await call('select order_no from orders order by order_no')).map(r=>r.order_no)};
  const skus=async who=>{await as(who);return (await call('select sku_name from sku_master order by sku_name')).map(r=>r.sku_name)};
  assert.deepEqual(await seen('rajHead'),['M-1','R-1']);
  assert.deepEqual(await seen('rajSales'),['C-2','M-1','R-1']);
  assert.deepEqual(await seen('cokeSales'),['C-1','C-2','M-1']);
  for(const w of ['admin','accounts','warehouse','manager'])assert.equal((await seen(w)).length,4,w);
  assert.deepEqual(await skus('rajHead'),['OLD SKU NO COMPANY','RAJNIGANDHA 4G']);
  assert.deepEqual(await skus('cokeSales'),['300ML THUMS UP','OLD SKU NO COMPANY']);
  assert.equal((await skus('accounts')).length,3);
  // a new order (no lines yet) is visible to the brand salesman who makes it
  await as('cokeSales');
  const r=await call("insert into orders(order_no,customer_name,created_by) values('NEW','X',$1) returning order_no",[ids.cokeSales]);
  assert.equal(r[0].order_no,'NEW');
  await db.query("delete from orders where order_no='NEW'");
  await as('rajHead');
  assert.deepEqual((await call('select name from lwb_companies')).map(x=>x.name),['RAJNIGANDHA']);
  void o1;void o2;void o3;void o4;
});

test('SKU company bulk set: Sales Head limited to his brand',async()=>{
  const id=await addSku('RAJNIGANDHA 9G',null);
  await as('rajHead');
  await assert.rejects(call('select public.lwb_set_sku_company($1,$2)',[[id],COKE]),/not yours/);
  assert.equal((await one('select public.lwb_set_sku_company($1,$2) n',[[id],RAJ])).n,1);
  await as('accounts');
  await assert.rejects(call('select public.lwb_set_sku_company($1,$2)',[[id],RAJ]),/Admin or Sales Head/);
});

test('targets per company and salesman, month sales split by SKU value',async()=>{
  await as('rajHead');
  await assert.rejects(call('select public.lwb_save_company_targets($1,$2,$3::jsonb)',[today,COKE,'[]']),/your company/);
  await call('select public.lwb_save_company_targets($1,$2,$3::jsonb)',[today,RAJ,JSON.stringify([{salesman_id:null,target_amount:100000},{salesman_id:ids.rajSales,target_amount:40000,target_cases:50}])]);
  await assert.rejects(call('select public.lwb_save_company_targets($1,$2,$3::jsonb)',[today,RAJ,JSON.stringify([{salesman_id:ids.accounts,target_amount:1}])]),/salesman only/);
  const m=(await one('select public.lwb_company_month($1) j',[today])).j;
  assert.equal(m.targets.length,2);
  assert.ok(m.sales.every(s=>s.company_id===RAJ||s.company_id===null),'Rajnigandha head sees no Coca-Cola sales');
  const raj=m.sales.filter(s=>s.company_id===RAJ).reduce((a,s)=>a+Number(s.amount),0);
  assert.equal(raj,10*500+1*500);
  await as('rajSales');
  const mine=(await one('select public.lwb_company_month($1) j',[today])).j;
  assert.deepEqual(mine.targets.map(t=>t.salesman_id),[ids.rajSales]);
  assert.ok(mine.sales.every(s=>s.salesman_id===ids.rajSales));
  await as('admin');
  await call('select public.lwb_save_company_targets($1,$2,$3::jsonb)',[today,RAJ,JSON.stringify([{salesman_id:ids.rajSales,target_amount:0}])]);
  assert.equal((await db.query('select count(*)::int n from lwb_company_targets where salesman_id=$1',[ids.rajSales])).rows[0].n,0,'0 removes the target');
});

test('to pay the company: oldest bill first, due after company credit days',async()=>{
  const g1=(await db.query("insert into lwb_goods_inward(invoice_no,invoice_date,supplier_name) values('DS-1',$1,'DS GROUP') returning id",[dayAdd(today,-6)])).rows[0].id;
  const g2=(await db.query("insert into lwb_goods_inward(invoice_no,invoice_date,supplier_name) values('DS-2',$1,'DS GROUP') returning id",[dayAdd(today,-1)])).rows[0].id;
  await db.query('insert into lwb_goods_inward_items(inward_id,sku_id,total_amount) values($1,$2,50000),($3,$2,30000),($3,$4,9999)',[g1,sku['RAJNIGANDHA 4G'],g2,sku['300ML THUMS UP']]);
  await as('manager');
  await assert.rejects(call('select public.lwb_company_payables($1)',[RAJ]),/Admin or Accounts/);
  await as('accounts');
  await assert.rejects(call('select public.lwb_company_pay($1,$2,$3,$4,$5,$6)',[RAJ,dayAdd(today,1),100,'BANK','',null]),/valid date/);
  const pid=(await one('select public.lwb_company_pay($1,$2,$3,$4,$5,$6) id',[RAJ,today,60000,'BANK','UTR1','part'])).id;
  let p=(await one('select public.lwb_company_payables($1) j',[RAJ])).j;
  assert.deepEqual(p.bills.map(b=>[b.invoice_no,Number(b.amount),Number(b.balance),b.due_date]),[['DS-1',50000,0,dayAdd(today,-2)],['DS-2',30000,20000,dayAdd(today,3)]]);
  const ov=(await one('select public.lwb_company_overview($1,$2) j',[today.slice(0,8)+'01',today])).j;
  assert.equal(Number(ov.payable[RAJ].balance),20000);
  assert.equal(Number(ov.payable[RAJ].overdue),0);
  assert.equal(ov.payable[RAJ].next_due,dayAdd(today,3));
  assert.equal(Number(ov.payable[COKE].balance),9999);
  await assert.rejects(call('select public.lwb_company_pay_cancel($1)',[pid]),/Admin only/);
  await as('admin');
  await call('select public.lwb_company_pay_cancel($1)',[pid]);
  p=(await one('select public.lwb_company_payables($1) j',[RAJ])).j;
  assert.equal(Number(p.bills[0].balance),50000);
  assert.equal(p.payments[0].cancelled,true);
  const ov2=(await one('select public.lwb_company_overview($1,$2) j',[today,today])).j;
  assert.equal(Number(ov2.payable[RAJ].overdue),50000,'DS-1 was due 2 days ago');
});

test('overview: sales, target and outstanding per brand, overdue by party / company udhari days',async()=>{
  const [r1]=(await db.query("select id from orders where order_no='M-1'")).rows; // 600 coke + 500 raj
  const [r2]=(await db.query("select id from orders where order_no='R-1'")).rows; // 5000 raj
  await db.query('insert into bill_due values($1,$2,1100,$3),($4,$5,5000,$6)',[r1.id,'RAM STORES',dayAdd(today,-1),r2.id,'ASHOK STORES',dayAdd(today,-3)]);
  await as('admin');
  // Rajnigandha market udhari 1 day; Ashok gets 5 days for Rajnigandha.
  await call('select public.lwb_set_party_company_credit($1,$2,$3)',['ashok stores ',RAJ,5]);
  const ov=(await one('select public.lwb_company_overview($1,$2) j',[today.slice(0,8)+'01',today])).j;
  assert.equal(Number(ov.sales[RAJ].amount),5500);
  assert.equal(Number(ov.sales[COKE].amount),20*300+2*300+5*300);
  assert.equal(Number(ov.targets[RAJ].amount),100000);
  assert.equal(Number(ov.outstanding[RAJ].due),5500);
  assert.equal(Number(ov.outstanding[COKE].due),600);
  assert.equal(Number(ov.outstanding[RAJ].overdue),0,'M-1 billed yesterday + 1 day, R-1 3 days ago + 5 days');
  assert.equal(Number(ov.outstanding[COKE].overdue),600,'Coca-Cola market days 0');
  await call('select public.lwb_set_party_company_credit($1,$2,$3)',['ASHOK STORES',RAJ,null]);
  const ov2=(await one('select public.lwb_company_overview($1,$2) j',[today,today])).j;
  assert.equal(Number(ov2.outstanding[RAJ].overdue),5000);
  // brand-limited Sales Head: only his company, no payable
  await as('rajHead');
  const h=(await one('select public.lwb_company_overview($1,$2) j',[today,today])).j;
  assert.deepEqual(h.companies.map(c=>c.name),['RAJNIGANDHA']);
  assert.equal(h.sales[COKE],undefined);assert.equal(h.outstanding[COKE],undefined);assert.equal(h.payable,null);
  await as('rajSales');
  await assert.rejects(call('select public.lwb_company_overview($1,$2)',[today,today]),/required/);
});

test('direct writes to the new tables are refused',async()=>{
  await as('admin');
  await assert.rejects(call("insert into lwb_companies(name) values('X')"),/permission denied/);
  await assert.rejects(call("insert into lwb_company_payments(company_id,pay_date,amount) values($1,current_date,1)",[RAJ]),/permission denied/);
  await as('');
  await db.exec('SET ROLE anon');
  try{await assert.rejects(db.query('select public.lwb_company_overview(current_date,current_date)'),/permission denied/)}finally{await db.exec('RESET ROLE')}
});
