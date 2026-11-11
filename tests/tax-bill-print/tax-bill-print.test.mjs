import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_tax_bill_print_setup.sql on a tiny copy of the tables it reads (no live database).
const ids={admin:'00000000-0000-4000-8000-000000000001',accounts:'00000000-0000-4000-8000-000000000002',manager:'00000000-0000-4000-8000-000000000003',warehouse:'00000000-0000-4000-8000-000000000004',sales:'00000000-0000-4000-8000-000000000005'};
const db=new PGlite();
const src=await readFile(new URL('../../lwb_tax_bill_print_setup.sql',import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text,order_date date default current_date);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric,rate numeric);
CREATE TABLE public.sku_master(id uuid default gen_random_uuid(),sku_name text,hsn_code text,gst_rate numeric,cess_rate numeric,is_active boolean default true);
CREATE TABLE public.lwb_customer_master(id uuid default gen_random_uuid() primary key,customer_name text,gstin text,billing_address text,city text,state text,pincode text,mobile text,is_active boolean default true);
`);
for(const [role,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,role,role+' user']);
await db.exec(src);
await db.exec(src); // safe to run again
const as=async(who,q,p=[])=>{await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[ids[who]||'']);return db.query(q,p)};
const fails=async(who,q,p,re)=>assert.match(await as(who,q,p).then(()=>'no error',e=>e.message),re);

const o=(await db.query(`insert into orders(order_no,customer_name,status) values('PO-1','JAY BAJARANG TOBACCO & GENERAL STORE','loaded') returning id`)).rows[0].id;
await db.query(`insert into orders(order_no,customer_name,status) values('PO-2','X','pending')`);
await db.query(`insert into order_items(order_id,sku_name,approved_qty,loaded_qty,rate) values($1,'250ML COKE 1*28 RS 20/-',5,4,455),($1,'2.25L SPRITE 1*9 RS.90/-',3,null,665),($1,'ZERO',2,0,10)`,[o]);
await db.query(`insert into sku_master(sku_name,hsn_code,gst_rate) values('250ML COKE 1*28 RS 20/-','22021010',40),('2.25L SPRITE 1*9 RS.90/-','22021010',40)`);
await db.query(`insert into lwb_customer_master(customer_name,state,mobile) values('Jay Bajarang Tobacco & General Store','Gujarat','9999999999')`);

test('off by default: only Admin can use it, seller hidden from others', async()=>{
  const a=(await as('accounts','select lwb_tax_bill_access() a')).rows[0].a;
  assert.equal(a.can,false);assert.equal(a.on,false);assert.equal(a.seller,null);
  assert.equal((await as('admin','select lwb_tax_bill_access() a')).rows[0].a.can,true);
  await fails('accounts','select * from lwb_tax_bill_orders(30)',[],/off/);
  await fails('accounts','select lwb_tax_bill_data($1)',[o],/off/);
});

test('only Admin turns it on; roles are checked', async()=>{
  await fails('accounts','select lwb_tax_bill_access_set(true,null,null,null)',[],/Only Admin/);
  await fails('admin',`select lwb_tax_bill_access_set(true,null,array['sales'],null)`,[],/Only Accounts/);
  await fails('admin',`select lwb_tax_bill_access_set(true,current_date-5,null,null)`,[],/before today/);
  await fails('admin',`select lwb_tax_bill_access_set(true,null,array[]::text[],null)`,[],/at least one/);
  const a=(await as('admin',`select lwb_tax_bill_access_set(true,(now() AT TIME ZONE 'Asia/Kolkata')::date,array['accounts'],'{"upi":"lwb@icici"}') a`)).rows[0].a;
  assert.equal(a.on,true);assert.deepEqual(a.roles,['accounts']);assert.equal(a.seller.upi,'lwb@icici');assert.equal(a.seller.gstin,'24BMBPV2782C1Z4');
  assert.equal((await as('accounts','select lwb_tax_bill_access() a')).rows[0].a.can,true);
  assert.equal((await as('manager','select lwb_tax_bill_access() a')).rows[0].a.can,false);
  await fails('sales','select * from lwb_tax_bill_orders(30)',[],/off/);
});

test('PO list and bill data: loaded qty, else approved; HSN / GST from SKU Master; party matched by name', async()=>{
  const l=(await as('accounts','select * from lwb_tax_bill_orders(30)')).rows;
  assert.equal(l.length,1);assert.equal(l[0].order_no,'PO-1');assert.equal(Number(l[0].qty),7);assert.equal(Number(l[0].amount),3815);
  const d=(await as('accounts','select lwb_tax_bill_data($1) d',[o])).rows[0].d;
  assert.equal(d.items.length,2);
  assert.deepEqual(d.items.map(i=>[i.qty,i.rate,i.hsn,i.gst]),[[4,455,'22021010',40],[3,665,'22021010',40]]);
  assert.equal(d.party.state,'Gujarat');assert.equal(d.party.mobile,'9999999999');assert.equal(d.saved,null);
});

test('save, change again, read back', async()=>{
  await fails('accounts','select lwb_tax_bill_save($1,current_date,$2,0)',[o,{lines:[{sku:'A'}]}],/total/);
  await fails('accounts','select lwb_tax_bill_save($1,current_date,$2,10)',[o,{lines:[]}],/at least one/);
  await as('accounts','select lwb_tax_bill_save($1,current_date,$2,3815)',[o,{lines:[{sku:'A',qty:4}]}]);
  await as('accounts','select lwb_tax_bill_save($1,current_date,$2,3820)',[o,{lines:[{sku:'A',qty:5}]}]);
  const d=(await as('accounts','select lwb_tax_bill_data($1) d',[o])).rows[0].d;
  assert.equal(Number(d.saved.total),3820);assert.equal(d.saved.saves,2);assert.equal(d.saved.by,'accounts user');
  assert.equal(Number((await as('accounts','select * from lwb_tax_bill_orders(30)')).rows[0].bill_total),3820);
});

test('turn off: Accounts stops at once, Admin still can; tables closed to direct reads', async()=>{
  await as('admin','select lwb_tax_bill_access_set(false)');
  await fails('accounts','select lwb_tax_bill_data($1)',[o],/off/);
  assert.equal((await as('admin','select lwb_tax_bill_data($1) d',[o])).rows[0].d.items.length,2);
  const r=(await db.query(`select has_table_privilege('authenticated','public.lwb_tax_bills','select') a, has_table_privilege('authenticated','public.lwb_tax_bill_settings','select') b`)).rows[0];
  assert.equal(r.a,false);assert.equal(r.b,false);
});
