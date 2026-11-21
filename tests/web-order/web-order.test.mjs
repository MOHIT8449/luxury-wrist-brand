import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

const ids={admin:'00000000-0000-4000-8000-000000000001',manager:'00000000-0000-4000-8000-000000000002',sales:'00000000-0000-4000-8000-000000000003',warehouse:'00000000-0000-4000-8000-000000000005'};
const CC='10000000-0000-4000-8000-000000000001',RJ='10000000-0000-4000-8000-000000000002',OLD='10000000-0000-4000-8000-000000000003';
const P1='20000000-0000-4000-8000-000000000001',P2='20000000-0000-4000-8000-000000000002',P3='20000000-0000-4000-8000-000000000003';
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role BYPASSRLS; -- as in Supabase
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.lwb_companies(id uuid primary key,name text,color text default '#2362a4',active boolean default true,sort_no int default 0,quick_slip boolean default false);
CREATE TABLE public.sku_master(id uuid primary key default gen_random_uuid(),sku_name text,is_active boolean default true,company_id uuid,category text,pcs_per_case numeric,pack_unit text,image_url text,unit_weight_kg numeric);
CREATE TABLE public.lwb_customer_master(id uuid primary key,customer_name text,mobile text,city text,is_active boolean default true);
CREATE TABLE public.lwb_party_salesman(customer_id uuid primary key,salesman_id uuid);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text unique,order_date timestamptz,customer_name text,transportation text,sales_person text,status text,total_qty numeric,total_amount numeric,total_weight numeric,created_by uuid,created_at timestamptz default now());
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric,rate numeric,unit_weight numeric,amount numeric,total_weight numeric);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false);
GRANT USAGE ON SCHEMA public,auth TO anon,authenticated,service_role;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,k,k.toUpperCase()]);
await db.exec(`
insert into lwb_companies(id,name,sort_no,quick_slip) values('${CC}','Coca-Cola',1,false),('${RJ}','Rajnigandha',2,true),('${OLD}','Old Brand',3,false);
update lwb_companies set active=false where id='${OLD}';
insert into sku_master(sku_name,company_id,category,pcs_per_case,unit_weight_kg) values
 ('COKE 250ML','${CC}','CSD',24,6),('THUMS UP 2.25L','${CC}','CSD',9,21),('MAAZA 600ML','${CC}','JUICE',24,15),
 ('RAJNIGANDHA 4G','${RJ}','PAN MASALA',null,1),('OLD SKU','${OLD}',null,1,1);
insert into sku_master(sku_name,company_id,is_active) values('STOPPED SKU','${CC}',false);
insert into lwb_customer_master values('${P1}','SHREE GANESH STORES','+91 98250 11111','SURAT',true),
 ('${P2}','TWO NAME A','9825022222','SURAT',true),('${P3}','TWO NAME B','098250 22222','VAPI',true);
insert into lwb_party_salesman values('${P1}','${ids.sales}');
insert into orders(id,order_no,order_date,customer_name,status) values('30000000-0000-4000-8000-000000000001','LXY-00041',now()-interval '5 days','SHREE GANESH STORES','delivered');
insert into order_items(order_id,sku_name,ordered_qty,rate) values('30000000-0000-4000-8000-000000000001','COKE 250ML',10,380);
`);
const sql=await readFile(new URL('../../lwb_web_order_setup.sql',import.meta.url),'utf8');
await db.exec(sql);await db.exec(sql); // safe to run again
const wa=await readFile(new URL('../../lwb_whatsapp_order_setup.sql',import.meta.url),'utf8');
await db.exec(wa);await db.exec(wa);

async function as(who,q,params=[]){
 await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||'']);
 await db.exec(who==='anon'?'SET ROLE anon':'SET ROLE authenticated');
 try{return (await db.query(q,params)).rows}finally{await db.exec('RESET ROLE')}
}
const submit=p=>as('anon','select lwb_web_order_submit($1::jsonb) r',[JSON.stringify(p)]).then(r=>r[0].r);
const base={name:'Ramesh',brand:CC,items:[{sku:'coke 250ml',qty:5}]};

test('catalog shows active brands and SKUs only, no rates',async()=>{
 const c=(await as('anon','select lwb_web_catalog() c'))[0].c;
 assert.deepEqual(c.brands.map(b=>b.name),['Coca-Cola','Rajnigandha']);
 assert.ok(!c.skus.some(s=>s.name==='OLD SKU'||s.name==='STOPPED SKU'));
 assert.equal(c.skus.length,4);
 assert.ok(!JSON.stringify(c).includes('rate'));
});

test('known mobile: pending PO made at once with last rate, salesman as creator',async()=>{
 const r=await submit({...base,mobile:'98250 11111',items:[{sku:'COKE 250ML',qty:5},{sku:'MAAZA 600ML',qty:2}]});
 assert.match(r.ref,/^W-\d+$/);
 assert.ok(!('order_no' in r)&&!JSON.stringify(r).includes('GANESH'),'customer never sees party data');
 const [o]=(await db.query("select * from orders where sales_person='WEBSITE ORDER'")).rows;
 assert.equal(o.order_no,'LXY-00042');assert.equal(o.status,'pending_approval');assert.equal(o.customer_name,'SHREE GANESH STORES');
 assert.equal(o.created_by,ids.sales);assert.equal(Number(o.total_qty),7);assert.equal(Number(o.total_amount),1900);assert.equal(Number(o.total_weight),60);
 const items=(await db.query('select sku_name,ordered_qty,rate from order_items where order_id=$1 order by id',[o.id])).rows;
 assert.deepEqual(items.map(i=>[i.sku_name,Number(i.ordered_qty),Number(i.rate)]),[['COKE 250ML',5,380],['MAAZA 600ML',2,0]]);
 const [w]=(await db.query("select * from lwb_web_orders where id=$1",[Number(r.ref.slice(2))])).rows;
 assert.equal(w.status,'PO_MADE');assert.equal(w.order_id,o.id);
});

test('double tap gives back the first order',async()=>{
 const n=(await db.query('select count(*)::int n from orders')).rows[0].n;
 const r=await submit({...base,mobile:'9825011111',items:[{sku:'COKE 250ML',qty:5},{sku:'MAAZA 600ML',qty:2}]});
 assert.equal(r.again,true);
 assert.equal((await db.query('select count(*)::int n from orders')).rows[0].n,n);
});

test('new customer / number on 2 parties / slip brand wait for staff with a bell',async()=>{
 const a=await submit({...base,mobile:'7000000001',shop:'New Shop',city:'Navsari'});
 const b=await submit({...base,mobile:'9825022222'});
 const c=await submit({name:'Ramesh',brand:RJ,items:[{sku:'RAJNIGANDHA 4G',qty:3}],mobile:'9825011111'});
 const rows=(await db.query("select id,status,wait_reason,jsonb_array_length(matched_parties) m from lwb_web_orders where id = any($1) order by id",[[a,b,c].map(x=>Number(x.ref.slice(2)))])).rows;
 assert.deepEqual(rows.map(r=>[r.status,r.wait_reason,r.m]),[['WAITING','NEW_CUSTOMER',0],['WAITING','MANY_PARTIES',2],['WAITING','SLIP_BRAND',1]]);
 const bells=(await db.query("select user_id from erp_notifications where notification_type='WEB_ORDER'")).rows;
 assert.equal(bells.length,6); // 3 orders x (admin + manager)
 assert.ok(bells.every(x=>[ids.admin,ids.manager].includes(x.user_id)));
});

test('bad input is refused',async()=>{
 const bad=async(p,re)=>assert.rejects(submit({...base,mobile:'7000000099',...p}),re);
 await bad({mobile:'12345'},/valid 10-digit/);
 await bad({name:'x'},/name/);
 await bad({website:'http://spam'},/not accepted/);
 await bad({note:'buy at https://x.y'},/Links/);
 await bad({brand:OLD},/Select a brand/);
 await bad({items:[]},/1 to 60/);
 await bad({items:[{sku:'RAJNIGANDHA 4G',qty:1}]},/not available/);
 await bad({items:[{sku:'STOPPED SKU',qty:1}]},/not available/);
 await bad({items:[{sku:'COKE 250ML',qty:0}]},/1 to 5000/);
 await bad({items:[{sku:'COKE 250ML',qty:'2.5'}]},/whole cases/);
 await bad({items:[{sku:'COKE 250ML',qty:9999}]},/1 to 5000/);
});

test('rate limit per mobile',async()=>{
 const m='7000000002';
 for(let i=1;i<=3;i++)await submit({...base,mobile:m,items:[{sku:'COKE 250ML',qty:i}]});
 await assert.rejects(submit({...base,mobile:m,items:[{sku:'COKE 250ML',qty:9}]}),/Too many orders from this number/);
});

test('browser cannot read or write the table or call the inside functions',async()=>{
 await assert.rejects(as('anon','select * from lwb_web_orders'),/permission/);
 await assert.rejects(as('anon',"select lwb_web_order_intake('{}'::jsonb,'WHATSAPP')"),/permission/);
 await assert.rejects(as('sales',"select lwb_web_order_po(1,$1)",[P1]),/permission/);
 await assert.rejects(as('manager',"insert into lwb_web_orders(mobile,contact_name,items) values('9999999999','ab','[]')"),/permission/);
 assert.equal((await as('sales','select * from lwb_web_orders')).length,0);
 assert.equal((await as('warehouse','select * from lwb_web_orders')).length,0);
 assert.ok((await as('manager','select * from lwb_web_orders')).length>=5);
});

test('staff: done links the PO, reject closes it, others refused',async()=>{
 const [w]=(await db.query("select id from lwb_web_orders where wait_reason='NEW_CUSTOMER' limit 1")).rows;
 const [w2]=(await db.query("select id from lwb_web_orders where wait_reason='MANY_PARTIES' limit 1")).rows;
 await db.query("insert into orders(id,order_no,customer_name,status) values('30000000-0000-4000-8000-000000000009','LXY-00050','NEW SHOP','approved')");
 await assert.rejects(as('sales','select lwb_web_order_done($1,$2)',[w.id,'30000000-0000-4000-8000-000000000009']),/Admin or Sales Head/);
 await as('manager','select lwb_web_order_done($1,$2)',[w.id,'30000000-0000-4000-8000-000000000009']);
 const [r]=(await db.query('select * from lwb_web_orders where id=$1',[w.id])).rows;
 assert.equal(r.status,'PO_MADE');assert.equal(r.order_no,'LXY-00050');assert.equal(r.handled_by_name,'MANAGER');
 assert.equal((await db.query("select count(*)::int n from erp_notifications where notification_type='WEB_ORDER' and message like $1",['W-'+w.id+' ·%'])).rows[0].n,0);
 await as('admin','select lwb_web_order_reject($1,$2)',[w2.id,'Fake order']);
 assert.equal((await db.query('select status from lwb_web_orders where id=$1',[w2.id])).rows[0].status,'REJECTED');
 await assert.rejects(as('admin','select lwb_web_order_reject($1,$2)',[w2.id,'again']),/not waiting/);
});

test('site-wide limit',async()=>{
 await db.exec("insert into lwb_web_orders(mobile,contact_name,items) select '9'||lpad(g::text,9,'0'),'Bot','[]' from generate_series(1,40) g");
 await assert.rejects(submit({...base,mobile:'7000000077'}),/Too many orders right now/);
});

test('WhatsApp: service role takes orders, finds the party; browser cannot',async()=>{
 const svc=async(q,p=[])=>{await db.exec('SET ROLE service_role');try{return (await db.query(q,p)).rows}finally{await db.exec('RESET ROLE')}};
 assert.deepEqual((await svc("select lwb_wa_party('919825011111') r"))[0].r,{count:1,name:'SHREE GANESH STORES'});
 assert.deepEqual((await svc("select lwb_wa_party('9825022222') r"))[0].r,{count:2,name:null});
 await svc("insert into lwb_wa_sessions(mobile,state) values('9825011111','{}')");
 await svc("insert into lwb_wa_seen(msg_id) values('wamid.1')");
 await assert.rejects(svc("insert into lwb_wa_seen(msg_id) values('wamid.1')"),/duplicate/);
 await db.exec("delete from lwb_web_orders where contact_name='Bot'");
 const r=(await svc("select lwb_web_order_intake($1::jsonb,'WHATSAPP') r",[JSON.stringify({mobile:'9825011111',name:'SHREE GANESH STORES',brand:CC,items:[{sku:'MAAZA 600ML',qty:1},{sku:'THUMS UP 2.25L',qty:4}]})]))[0].r;
 const [w]=(await db.query('select channel,status from lwb_web_orders where id=$1',[Number(r.ref.slice(2))])).rows;
 assert.deepEqual(w,{channel:'WHATSAPP',status:'PO_MADE'});
 await assert.rejects(as('anon',"select lwb_wa_party('9825011111')"),/permission/);
 await assert.rejects(as('anon','select * from lwb_wa_sessions'),/permission/);
 await assert.rejects(as('manager','select * from lwb_wa_sessions'),/permission/);
});
