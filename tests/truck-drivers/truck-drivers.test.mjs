import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_vehicle_driver_history_setup.sql on PGlite, after the Dial Book, Services, Gmail sync and ECRS on-the-way files.
// Live tables (party master, Goods Inward, ECRS trucks ...) are small stand-ins.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  godown:'00000000-0000-4000-8000-000000000003',acc:'00000000-0000-4000-8000-000000000004',
  sales:'00000000-0000-4000-8000-000000000005',cashier:'00000000-0000-4000-8000-000000000006'};
const roles={admin:'admin',head:'manager',godown:'warehouse',acc:'accounts',sales:'sales',cashier:'cashier'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
CREATE SCHEMA auth; CREATE SCHEMA extensions;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE FUNCTION extensions.gen_random_bytes(int) RETURNS bytea LANGUAGE sql AS $$ SELECT decode(md5(random()::text),'hex') $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text,mobile text);
CREATE TABLE public.lwb_companies(id uuid primary key default gen_random_uuid(),name text);
CREATE TABLE public.lwb_customer_master(id uuid primary key default gen_random_uuid(),customer_name text,mobile text,city text,is_active boolean default true,brand_ids uuid[]);
CREATE TABLE public.lwb_party_salesman(customer_id uuid primary key,salesman_id uuid);
CREATE TABLE public.lwb_acc_staff(id bigserial primary key,name text,mobile text,designation text,active boolean default true);
CREATE TABLE public.lwb_ecrs_trucks(id bigserial primary key,day date,vehicle_no text,invoice_no text,sent_rows jsonb,dispatched_at timestamptz,updated_at timestamptz);
CREATE TABLE public.lwb_tracking_settings(id int primary key,godown_lat double precision,godown_lng double precision);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,is_read boolean default false);
CREATE TABLE public.lwb_transport_master(id uuid primary key default gen_random_uuid(),transport_name text,is_active boolean default true);
CREATE TABLE public.lwb_goods_inward(id bigserial primary key,invoice_no text,vehicle_no text,driver_name text,driver_mobile text,transport_name text,
  received_date date,created_at timestamptz default now(),time_out timestamptz);
CREATE FUNCTION public.lwb_pst_role() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true $$;
GRANT USAGE ON SCHEMA public, auth TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.lwb_pst_role() TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.lwb_goods_inward TO authenticated;
GRANT USAGE ON SEQUENCE public.lwb_goods_inward_id_seq TO authenticated;
INSERT INTO lwb_transport_master(transport_name) VALUES ('Vikas Road Lines'),('R K Trailer'),('Shree Ganesh Roadways');
-- Old purchase bills (before this file): same vehicle, driver changed once; one bill with a bad mobile
INSERT INTO lwb_goods_inward(invoice_no,vehicle_no,driver_name,driver_mobile,transport_name,received_date,created_at) VALUES
 ('A1','gj05bx4471','Suresh','9811100001','Vikas Road Lines','2026-10-01','2026-10-01 10:00+05:30'),
 ('A2','GJ05 BX 4471','Suresh','98111 00001','Vikas Road Lines','2026-10-10','2026-10-10 10:00+05:30'),
 ('A3','GJ-05-BX-4471','Ramesh','+91 9811100002','Vikas Road Lines','2026-11-20','2026-11-20 10:00+05:30'),
 ('A4','GJ16AU1234','','9811100003','R K Trailer','2026-11-21','2026-11-21 10:00+05:30'),
 ('A5','GJ16AU9999','X','12345','R K Trailer','2026-11-21','2026-11-21 10:00+05:30');
`);
let n=0;for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3,$4)',[id,roles[k].toUpperCase(),'Name '+k,'+91 98250 '+String(10000+(++n))]);
const file=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
for(const f of ['lwb_dial_book_setup.sql','lwb_dial_book_numbers_setup.sql','lwb_dial_services_setup.sql'])await db.exec(await file(f));
await db.exec((await file('lwb_gmail_sync_setup.sql')).replace(/CREATE EXTENSION[^;]*;/,''));
await db.exec(await file('lwb_ecrs_on_way_setup.sql'));
const mine=await file('lwb_vehicle_driver_history_setup.sql');
await db.exec(mine);await db.exec(mine); // safe to run again
await db.exec(await file('lwb_ecrs_on_way_setup.sql')); // run again after: still fine
await db.exec("INSERT INTO lwb_tracking_settings VALUES (1,21.2103,72.899) ON CONFLICT DO NOTHING");
const gm=await file('lwb_godown_map_link_setup.sql');await db.exec(gm);await db.exec(gm);
await db.exec(`ALTER TABLE lwb_transport_master ADD COLUMN IF NOT EXISTS created_by uuid;`);
const add=await file('lwb_transport_add_setup.sql');await db.exec(add);await db.exec(add);
const adm=await file('lwb_dial_calls_admin_only_setup.sql');await db.exec(adm);await db.exec(adm);
const co=await file('lwb_dial_company_setup.sql');await db.exec(co);await db.exec(co);

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const one=async(q,a)=>(await db.query(q,a)).rows[0];
const book=async who=>{await as(who);return (await call('select lwb_dial_book() j'))[0].j};
const veh=b=>b.contacts.filter(c=>c.kind==='VEHICLE').map(c=>[c.ref,c.save_as,c.tag].join(' | ')).sort();

test('Transport short name', async()=>{
  const s=async t=>(await one('select lwb_transport_short($1) s',[t])).s;
  assert.equal(await s('Vikas Road Lines'),'VIKAS');
  assert.equal(await s('R K Trailer'),'RK');
  assert.equal(await s('R.K. TRAILERS'),'RK');
  assert.equal(await s('RK Trailer'),'RK');
  assert.equal(await s('Shree Ganesh Roadways'),'GANESH');
  assert.equal(await s('M/s. Balaji Transport Co.'),'BALAJI');
  assert.equal(await s('Maa Ambe Roadlines'),'MAA AMBE');
  assert.equal(await s('S K Logistics Pvt Ltd'),'SK');
  assert.equal(await s('VRL Logistics'),'VRL');
  assert.equal(await s('Transport'),'TRANSPORT');
  assert.equal(await s(''),null);
  assert.equal((await one("select lwb_vehicle_save_as('gj05bx4471','Ramesh','Vikas Road Lines') s")).s,'GJ05 BX 4471 RAMESH VIKAS');
  assert.equal((await one("select lwb_vehicle_save_as('GJ05BX4471',null,'R K Trailer') s")).s,'GJ05 BX 4471 DRIVER RK');
  assert.equal((await one("select lwb_vehicle_save_as('GJ05BX4471','ramesh',null) s")).s,'GJ05 BX 4471 RAMESH');
});

test('Old Goods Inward bills taken in once: every driver kept, newest is current, trips counted', async()=>{
  const h=(await db.query('select vehicle_key,driver_mobile,driver_name,transport_name,trips from lwb_vehicle_driver_hist order by vehicle_key,driver_mobile')).rows;
  assert.deepEqual(h.map(x=>[x.vehicle_key,x.driver_mobile,x.driver_name,x.trips]),[
    ['GJ05BX4471','9811100001','Suresh',2],['GJ05BX4471','9811100002','Ramesh',1],['GJ16AU1234','9811100003',null,1]],'file ran twice: no extra trips');
  const c=(await db.query('select vehicle_key,driver_mobile,driver_name,transport_name from lwb_vehicle_driver order by 1')).rows;
  assert.deepEqual(c.map(x=>[x.vehicle_key,x.driver_mobile,x.transport_name]),[['GJ05BX4471','9811100002','Vikas Road Lines'],['GJ16AU1234','9811100003','R K Trailer']]);
});

test('Dial Book + Gmail: current + old drivers, vehicle no. first, every number once', async()=>{
  assert.deepEqual(veh(await book('admin')),[
    'GJ05BX4471 | GJ05 BX 4471 RAMESH VIKAS | Truck driver',
    'GJ05BX4471:9811100001 | GJ05 BX 4471 SURESH VIKAS | Old driver',
    'GJ16AU1234 | GJ16 AU 1234 DRIVER RK | Truck driver']);
  assert.equal(veh(await book('cashier')).length,3,'every Dial Book login sees truck drivers');
  // call an old driver: full number + log
  await as('head');
  const r=(await call("select lwb_dial_call('VEHICLE','GJ05BX4471:9811100001','Dial Book') j"))[0].j;
  assert.equal(r.mobile,'9811100001');
  // Gmail list (service_role, as the connected Admin)
  await db.query("update lwb_gsync_config set connected_by=$1, refresh_token='x' where id=1",[ids.admin]);
  await db.exec('SET ROLE service_role');
  const g=(await db.query('select lwb_gsync_contacts() j')).rows[0].j;await db.exec('RESET ROLE');
  const names=g.filter(x=>x.kind==='VEHICLE').map(x=>x.name).sort();
  assert.deepEqual(names,['GJ05 BX 4471 RAMESH VIKAS','GJ05 BX 4471 SURESH VIKAS','GJ16 AU 1234 DRIVER RK']);
});

test('Driver changes on the same vehicle: old one stays, Godown Manager may save, transport kept', async()=>{
  await as('cashier');
  await assert.rejects(call("select lwb_vehicle_driver_save('GJ05BX4471','9811100009','Mahesh',null,null)"),/Only Admin/);
  await as('godown');
  const r=(await call("select lwb_vehicle_driver_save('GJ05 BX 4471','98111 00009','MAHESH',null,null) j"))[0].j;
  assert.deepEqual([r.save_as,r.new_driver,r.changed,r.transport],['GJ05 BX 4471 MAHESH VIKAS',true,true,'Vikas Road Lines']);
  const b=veh(await book('admin'));
  assert.deepEqual(b,[
    'GJ05BX4471 | GJ05 BX 4471 MAHESH VIKAS | Truck driver',
    'GJ05BX4471:9811100001 | GJ05 BX 4471 SURESH VIKAS | Old driver',
    'GJ05BX4471:9811100002 | GJ05 BX 4471 RAMESH VIKAS | Old driver',
    'GJ16AU1234 | GJ16 AU 1234 DRIVER RK | Truck driver']);
  // old 4-arg save (older pages) still works and keeps the transport; Ramesh is back: name remembered
  await as('sales');
  const back=(await call("select lwb_vehicle_driver_save('GJ05BX4471','9811100002') j"))[0].j;
  assert.deepEqual([back.save_as,back.new_driver],['GJ05 BX 4471 RAMESH VIKAS',false]);
  // a driver who moved to another vehicle shows once, on his newest vehicle
  await as('acc');
  await call("select lwb_vehicle_driver_save('GJ16AU1234','9811100001','Suresh',null,'Shree Ganesh Roadways')");
  const b2=veh(await book('admin'));
  assert.ok(b2.includes('GJ16AU1234 | GJ16 AU 1234 SURESH GANESH | Truck driver'),b2.join('\n'));
  assert.ok(!b2.some(x=>x.startsWith('GJ05BX4471:9811100001')),'Suresh not twice');
  assert.equal(b2.filter(x=>/9811100003/.test(x)).length,1,'driver without name on GJ16 is now old driver');
  // drivers list for Purchase List / ECRS rows: masked + old drivers
  const d=(await call("select lwb_vehicle_drivers(array['GJ05 BX 4471']) j"))[0].j[0];
  assert.deepEqual([d.short,d.save_as,d.old_drivers.length],['VIKAS','GJ05 BX 4471 RAMESH VIKAS',2]);
  assert.ok(!JSON.stringify(d).includes('9811100009'),'masked');
});

test('New Goods Inward bill: driver goes in by itself; a bad row never stops the bill', async()=>{
  await as('godown');
  await call("insert into lwb_goods_inward(invoice_no,vehicle_no,driver_name,driver_mobile,transport_name,received_date) values('B1','GJ19 X 5555','Kalu','9811100077','R K Trailer',current_date)");
  await call("insert into lwb_goods_inward(invoice_no,vehicle_no,driver_name,driver_mobile) values('B2','bad','x','1')");
  const c=await one("select * from lwb_vehicle_driver where vehicle_key='GJ19X5555'");
  assert.deepEqual([c.driver_mobile,c.driver_name,c.transport_name],['9811100077','Kalu','R K Trailer']);
  // updating the bill later (time out) adds no trip
  await call("update lwb_goods_inward set time_out=now() where invoice_no='B1'");
  assert.equal((await one("select trips from lwb_vehicle_driver_hist where vehicle_key='GJ19X5555'")).trips,1);
});

test('ECRS on the way: blank mobile = same driver, transport saved, alert goes', async()=>{
  await db.exec(`insert into lwb_ecrs_trucks(day,vehicle_no,invoice_no,sent_rows,dispatched_at) values
    ('2026-11-28','GJ05 BX 4471','INV1','[{"cs":100}]',now()),('2026-11-28','GJ01 ZZ 1111','INV2','[{"cs":5}]',now())`);
  const t=(await db.query("select id from lwb_ecrs_trucks order by id")).rows.map(x=>x.id);
  await as('acc');
  const r=(await call('select lwb_ecrs_on_way($1,$2,$3,$4,$5) j',[t[0],'',null,100,'Vikas Road Lines']))[0].j;
  assert.equal(r.notified,2,'GM + Sales Head');
  const m=(await db.query("select message from erp_notifications order by id desc limit 1")).rows[0].message;
  assert.match(m,/Driver RAMESH 98•••••002/);
  const none=(await call('select lwb_ecrs_on_way($1,$2) j',[t[1],'']))[0].j;
  assert.equal(none.no_driver,true,'no saved driver: nothing sent, no error');
  const nw=(await call('select lwb_ecrs_on_way($1,$2,$3,$4,$5) j',[t[1],'9811100088','Bhola',5,'Maa Ambe Roadlines']))[0].j;
  assert.equal(nw.again,false);
  assert.equal((await one("select lwb_vehicle_save_as(vehicle_no,driver_name,transport_name) s from lwb_vehicle_driver where vehicle_key='GJ01ZZ1111'")).s,'GJ01 ZZ 1111 BHOLA MAA AMBE');
});

test('Gmail quick sync: marked due on a driver / Services change, checked every 10 minutes', async()=>{
  await db.query("update lwb_gsync_config set dirty_at=null, last_sync_at=now() where id=1");
  await as('godown');
  await call("select lwb_vehicle_driver_save('GJ05BX4471','9811100002','RAMESH BHAI',null,null)");
  const c=await one('select dirty_at > last_sync_at d from lwb_gsync_config');
  assert.equal(c.d,true);
  // pg_net is not in PGlite: tick says no, never an error
  assert.equal((await one("select lwb_gsync_tick('quick') t")).t,false);
  await assert.rejects(call("select lwb_gsync_tick('quick')"),/permission denied/);
});

test('New transport from the dropdown: once, any case', async()=>{
  await as('cashier');await assert.rejects(call("select lwb_transport_add('Om Logistics')"),/Only Admin/);
  await as('acc');
  const a=(await call("select lwb_transport_add('  om   logistics ') j"))[0].j;
  assert.deepEqual([a.name,a.short,a.added],['OM LOGISTICS','OM',true]);
  const b=(await call("select lwb_transport_add('OM LOGISTICS') j"))[0].j;assert.equal(b.added,false);
  const c=(await call("select lwb_transport_add('vikas road-lines') j"))[0].j;assert.deepEqual([c.name,c.added],['Vikas Road Lines',false]);
  await assert.rejects(call("select lwb_transport_add('x')"),/2 to 150/);
  const L=(await call('select lwb_transport_names() j'))[0].j.map(t=>t.name);
  assert.ok(L.includes('OM LOGISTICS'));
});

test('Send location: Google Maps place link + address', async()=>{
  await as('godown');
  const r=(await call("select lwb_vehicle_loc_sent('GJ05BX4471') j"))[0].j;
  assert.equal(r.map_url,'https://maps.app.goo.gl/ymaoBJxw1BLY1hnu8');
  assert.match(r.address,/Dev Campus/);
});

test('Call log + last call: only Admin', async()=>{
  await as('head');await call("select lwb_dial_call('VEHICLE','GJ05BX4471','Dial Book')");
  for(const w of ['head','acc','sales','godown']){
    const b=await book(w);
    assert.equal(b.recent.length,0,w+': no Recent');
    assert.ok(b.contacts.every(c=>c.last_at==null&&c.last_by==null&&c.last_result==null),w+': no last call');
    assert.equal(b.all_log,false);
    await as(w);await assert.rejects(call('select lwb_dial_log(null,null)'),/only Admin/);
  }
  const a=await book('admin');
  assert.equal(a.all_log,true);
  assert.ok(a.contacts.some(c=>c.last_by==='Name head'),'admin sees who called');
  await as('admin');assert.ok((await call('select lwb_dial_log(null,null) j'))[0].j.length>0);
});

test('Company people: own group, phone name NAME COMPANY POST AREA, call works', async()=>{
  const sv=(o)=>call('select lwb_dial_service_save($1,$2,$3,$4,$5,$6,$7,$8,$9) j',[o.id||null,'COMPANY',o.post,o.name||null,o.co||null,o.area||null,o.mob,null,'Dial Book']).then(r=>r[0].j);
  await as('sales');await assert.rejects(sv({post:'GSM',name:'Rajesh',co:'Coca-Cola',mob:'9700000001'}),/Only Admin/);
  await as('acc');
  await assert.rejects(sv({post:'GSM',name:'Rajesh',mob:'9700000001'}),/choose the company/);
  await assert.rejects(sv({post:'',name:'Rajesh',co:'Coca-Cola',mob:'9700000001'}),/post/);
  await assert.rejects(sv({post:'GSM',co:'Coca-Cola',mob:'9700000001'}),/person name/);
  const a=await sv({post:'gsm',name:'rajesh patel',co:'Coca-Cola',area:'Surat',mob:'97000 00001'});assert.equal(a.saved,true);
  await sv({post:'RTM',name:'Amit',co:'Rajnigandha',mob:'9700000002'});
  const dup=await sv({post:'ASM',name:'X',co:'Coca-Cola',mob:'9825010001'});assert.equal(dup.saved,false,'team number not saved again');
  const b=await book('sales');
  const c=b.contacts.filter(x=>x.kind==='COMPANY').map(x=>[x.save_as,x.tag,x.sub]).sort();
  assert.deepEqual(c,[['AMIT RG RTM','RTM','RAJNIGANDHA'],['RAJESH PATEL CC GSM SURAT','GSM','COCA-COLA · SURAT']]);
  assert.ok(!b.contacts.some(x=>x.kind==='SERVICE'&&/RAJESH/.test(x.name)),'not in Services');
  await as('sales');const r=(await call("select lwb_dial_call('COMPANY',$1,'Dial Book') j",[String(a.id)]))[0].j;
  assert.equal(r.mobile,'9700000001');
  // Gmail list has them
  await db.exec('SET ROLE service_role');const g=(await db.query('select lwb_gsync_contacts() j')).rows[0].j;await db.exec('RESET ROLE');
  assert.ok(g.some(x=>x.kind==='COMPANY'&&x.name==='RAJESH PATEL CC GSM SURAT'));
});
