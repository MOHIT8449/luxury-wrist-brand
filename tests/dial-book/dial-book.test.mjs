import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_dial_book_setup.sql on PGlite. Party master, salesman links, Employee Master, ECRS trucks and
// tracking settings are small stand-ins of the live tables.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  godown:'00000000-0000-4000-8000-000000000003',acc:'00000000-0000-4000-8000-000000000004',
  sales:'00000000-0000-4000-8000-000000000005',sales2:'00000000-0000-4000-8000-000000000006',
  driver:'00000000-0000-4000-8000-000000000007'};
const roles={admin:'admin',head:'manager',godown:'warehouse',acc:'accounts',sales:'sales',sales2:'sales',driver:'driver'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text,mobile text);
CREATE TABLE public.lwb_companies(id uuid primary key default gen_random_uuid(),name text);
INSERT INTO public.lwb_companies(id,name) VALUES('00000000-0000-4000-9000-000000000001','Coca-Cola'),('00000000-0000-4000-9000-000000000002','Rajnigandha');
CREATE TABLE public.lwb_customer_master(id uuid primary key default gen_random_uuid(),customer_name text,mobile text,city text,is_active boolean default true,brand_ids uuid[]);
CREATE TABLE public.lwb_party_salesman(customer_id uuid primary key,salesman_id uuid);
CREATE TABLE public.lwb_acc_staff(id bigserial primary key,name text,mobile text,designation text,active boolean default true);
CREATE TABLE public.lwb_ecrs_trucks(id bigserial primary key,day date,vehicle_no text,updated_at timestamptz);
CREATE TABLE public.lwb_tracking_settings(id int primary key,godown_lat double precision,godown_lng double precision);
INSERT INTO public.lwb_tracking_settings VALUES(1,21.2385,72.8743);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
let n=0;for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3,$4)',[id,roles[k].toUpperCase(),'Name '+k,'+91 98250 '+String(10000+(++n))]);
const party=async(name,mob,sm,brands)=>{const id=(await db.query('insert into lwb_customer_master(customer_name,mobile,city,brand_ids) values($1,$2,$3,$4) returning id',[name,mob,'Amroli',brands||null])).rows[0].id;
  if(sm)await db.query('insert into lwb_party_salesman values($1,$2)',[id,ids[sm]]);return id};
const CC='00000000-0000-4000-9000-000000000001',RG='00000000-0000-4000-9000-000000000002';
const pA=await party('SHREE JAGDISH TRADER','9876543312','sales',[CC]);
const pB=await party('NAVDURGA TRADERS','93-7777-0770','sales2',[CC,RG]);
await party('NO MOBILE PARTY','',null);
await db.query("insert into lwb_acc_staff(name,mobile,designation) values('Raju Loader','9000000221','Loader'),('Dup Of Login','9825010001','X')");
const mine=await readFile(new URL('../../lwb_dial_book_setup.sql',import.meta.url),'utf8');
await db.exec(mine);await db.exec(mine); // safe to run again
const nums=await readFile(new URL('../../lwb_dial_book_numbers_setup.sql',import.meta.url),'utf8');
await db.exec(nums);await db.exec(nums);

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const book=async who=>{await as(who);return (await call('select lwb_dial_book() j'))[0].j};
const kinds=b=>[...new Set(b.contacts.map(c=>c.kind))].sort().join(',');

test('Vehicle no. format: one way of writing, bad numbers refused', async()=>{
  const f=async v=>(await db.query('select lwb_vehicle_fmt($1) v',[v])).rows[0].v;
  assert.equal(await f('gj5bx4471'),'GJ05 BX 4471');
  assert.equal(await f('MH-04-KL-2210'),'MH04 KL 2210');
  assert.equal(await f('gj05bx44'),'GJ05 BX 0044');
  assert.equal(await f('DL1CAB1234'),'DL01 CAB 1234');
  assert.equal(await f('22bh1234aa'),'22 BH 1234 AA');
  assert.equal(await f('XY05AB1234'),null);
  assert.equal(await f('GJ05 4471'),null);
  assert.equal(await f('GJ05BX0000'),null);
  assert.equal(await f(''),null);
});

test('Who sees what: Sales Head / Accounts all parties, salesman own, GM none, driver no book; numbers masked', async()=>{
  const h=await book('head');
  assert.equal(h.contacts.filter(c=>c.kind==='PARTY').length,2);
  assert.equal(kinds(h),'DRIVER,PARTY,STAFF,TEAM');
  assert.ok(h.contacts.every(c=>!('mobile' in c)&&!/\d{10}/.test(c.masked+c.name+(c.sub||''))),'no full number in the list');
  assert.equal(h.contacts.find(c=>c.ref===pA).masked,'98•••••312');
  assert.ok(!h.contacts.some(c=>c.ref===ids.head),'not myself');
  assert.equal(h.contacts.filter(c=>c.kind==='STAFF').length,1,'staff with a login mobile is not twice');
  const a=await book('acc');assert.equal(a.contacts.filter(c=>c.kind==='PARTY').length,2);
  const s=await book('sales');
  assert.deepEqual(s.contacts.filter(c=>c.kind==='PARTY').map(c=>c.name),['SHREE JAGDISH TRADER']);
  assert.equal(s.contacts.filter(c=>c.kind==='STAFF').length,0);
  const g=await book('godown');
  assert.equal(g.contacts.filter(c=>c.kind==='PARTY').length,0);
  assert.ok(g.contacts.some(c=>c.kind==='TEAM'&&c.tag==='Sales Head'));
  await as('driver');await assert.rejects(call('select lwb_dial_book()'),/not allowed/);
});

test('Call: full number only for my own contact, logged; note on my own call; log scope', async()=>{
  await as('sales');
  await assert.rejects(call("select lwb_dial_call('PARTY',$1,'Dial Book')",[pB]),/not in your Dial Book/);
  const c=(await call("select lwb_dial_call('PARTY',$1,'Dial Book') j",[pA]))[0].j;
  assert.equal(c.mobile,'9876543312');
  await call("select lwb_dial_note($1,'ORDER','kal 20 case')",[c.id]);
  await as('sales2');
  await assert.rejects(call("select lwb_dial_note($1,'TALKED',null)",[c.id]),/own call/);
  await call("select lwb_dial_call('PARTY',$1,'Party Call List')",[pB]);
  const own=(await call("select lwb_dial_log(null,null) j"))[0].j;
  assert.equal(own.length,1);assert.equal(own[0].to_name,'NAVDURGA TRADERS');assert.equal(own[0].masked,'93•••••770');
  const all=(await book('head'),(await call("select lwb_dial_log(null,null) j"))[0].j);
  assert.equal(all.length,2);
  const x=all.find(r=>r.to_name==='SHREE JAGDISH TRADER');assert.equal(x.result,'ORDER');assert.equal(x.by_name,'Name sales');assert.equal(x.source,'Dial Book');
  const s=await book('sales');assert.equal(s.recent[0].ref,pA);assert.equal(s.contacts.find(c=>c.ref===pA).last_result,'ORDER');
  // the website cannot read the tables or the internal full list
  await as('admin');
  await assert.rejects(call('select * from lwb_dial_calls'),/permission denied/);
  await assert.rejects(call('select * from lwb_dial_all()'),/permission denied/);
});

test('Vehicle + driver: saved once in one format, ECRS gets the vehicle, location text, call from the vehicle', async()=>{
  const t=(await db.query("insert into lwb_ecrs_trucks(day) values('2026-11-27') returning id")).rows[0].id;
  await as('godown');
  await assert.rejects(call("select lwb_vehicle_driver_save('GJ05BX4471','9724531085','Ramesh',null)"),/Only Admin/);
  await as('sales');
  await assert.rejects(call("select lwb_vehicle_driver_save('GJ054471','9724531085',null,null)"),/not right/);
  await assert.rejects(call("select lwb_vehicle_driver_save('GJ05BX4471','12345',null,null)"),/10-digit/);
  const r=(await call("select lwb_vehicle_driver_save('gj 5 bx 4471','+91 97245 31085','Ramesh',$1) j",[t]))[0].j;
  assert.equal(r.vehicle_no,'GJ05 BX 4471');
  assert.equal((await db.query('select vehicle_no from lwb_ecrs_trucks where id=$1',[t])).rows[0].vehicle_no,'GJ05 BX 4471');
  const loc=(await call("select lwb_vehicle_loc_sent('GJ05-BX-4471') j"))[0].j;
  assert.equal(loc.mobile,'9724531085');assert.equal(loc.lat,21.2385);
  await as('godown');
  const d=(await call("select lwb_vehicle_drivers(array['GJ05 BX 4471','MH04KL2210']) j"))[0].j;
  assert.equal(d.length,1);assert.equal(d[0].masked,'97•••••085');assert.ok(d[0].loc_sent_at);
  const c=(await call("select lwb_dial_call('VEHICLE','GJ05BX4471','Purchase List') j"))[0].j;
  assert.equal(c.mobile,'9724531085');
  const g=await book('godown');assert.equal(g.contacts.find(x=>x.kind==='VEHICLE').name,'GJ05 BX 4471 · Ramesh');
  // same vehicle, new driver: name of the old driver is not kept, location to be sent again
  await as('head');
  await call("select lwb_vehicle_driver_save('GJ05BX4471','9898989898',null,null)");
  const v=(await db.query("select * from lwb_vehicle_driver where vehicle_key='GJ05BX4471'")).rows[0];
  assert.equal(v.driver_name,null);assert.equal(v.loc_sent_at,null);assert.equal(Number(v.ecrs_truck_id),Number(t));
});

test('Contacts file: Admin only', async()=>{
  await as('head');await assert.rejects(call('select lwb_dial_export()'),/Only Admin/);
  await as('admin');const x=(await call('select lwb_dial_export() j'))[0].j;
  assert.ok(x.some(c=>c.mobile==='9876543312'));
});

test('Saved contact name: party + area + brand short + WS / RT; Admin / Sales Head set Retail', async()=>{
  await as('sales');await assert.rejects(call("select lwb_set_party_type($1,'RT')",[[pB]]),/Admin or Sales Head/);
  await as('head');assert.equal((await call("select lwb_set_party_type($1,'RT') n",[[pB]]))[0].n,1);
  await as('admin');const x=(await call('select lwb_dial_export() j'))[0].j;
  const by=n=>x.find(c=>c.name===n).save_as;
  assert.equal(by('SHREE JAGDISH TRADER'),'SHREE JAGDISH TRADER AMROLI CC WS');
  assert.equal(by('NAVDURGA TRADERS'),'NAVDURGA TRADERS AMROLI CC RG RT');
  assert.equal(by('Name head'),'NAME HEAD LWB SALES HEAD');
  assert.equal(by('Raju Loader'),'RAJU LOADER LWB LOADER');
  assert.ok(x.some(c=>c.save_as==='GJ05 BX 4471 TRUCK DRIVER'));
});

test('Extra numbers: new number saved, an existing number is not saved (no error), call picks the extra, file has each number once', async()=>{
  await as('sales');
  // already a party main number / a login / own party
  let r=(await call("select lwb_dial_number_add('PARTY',$1,'93 7777 0770','Owner') j",[pA]))[0].j;
  assert.equal(r.saved,false);assert.equal(r.owner,'NAVDURGA TRADERS');
  r=(await call("select lwb_dial_number_add('PARTY',$1,'9825010001',null) j",[pA]))[0].j;
  assert.equal(r.saved,false);assert.equal(r.owner,'Name admin');
  r=(await call("select lwb_dial_number_add('PARTY',$1,'9876543312',null) j",[pA]))[0].j;
  assert.equal(r.saved,false);assert.equal(r.same,true);
  await assert.rejects(call("select lwb_dial_number_add('PARTY',$1,'9111111111',null)",[pB]),/not in your Dial Book/);
  r=(await call("select lwb_dial_number_add('PARTY',$1,'+91 91111 11111','Shop') j",[pA]))[0].j;
  assert.equal(r.saved,true);assert.equal(r.masked,'91•••••111');
  await as('head');
  r=(await call("select lwb_dial_number_add('PARTY',$1,'9111111111',null) j",[pB]))[0].j;
  assert.equal(r.saved,false);assert.equal(r.owner,'SHREE JAGDISH TRADER');
  const b=await book('head');const x=b.contacts.find(c=>c.ref===pA);
  assert.equal(x.extras.length,1);assert.equal(x.extras[0].label,'Shop');assert.ok(!JSON.stringify(x).includes('9111111111'));
  await as('sales');
  const c=(await call("select lwb_dial_call('PARTY',$1,'Dial Book',$2) j",[pA,x.extras[0].id]))[0].j;
  assert.equal(c.mobile,'9111111111');
  const c2=(await call("select lwb_dial_call('PARTY',$1,'Dial Book') j",[pA]))[0].j;
  assert.equal(c2.mobile,'9876543312');
  await assert.rejects(call("select lwb_dial_call('PARTY',$1,null,99999)",[pA]),/not of this contact/);
  // same main number on two contacts: dup_with shown, contacts file keeps it once
  await db.query("update lwb_customer_master set mobile='9000000221' where id=$1",[pB]); // same as staff Raju Loader
  const h=await book('head');assert.deepEqual(h.contacts.find(c=>c.ref===pB).dup_with,['Raju Loader']);
  await as('admin');const ex=(await call('select lwb_dial_export() j'))[0].j;
  const all=ex.flatMap(c=>(c.numbers||[]).map(n=>n.mobile));
  assert.equal(all.length,new Set(all).size,'each number once');
  assert.ok(!ex.some(c=>c.name==='Raju Loader'),'staff with the party number left out');
  assert.deepEqual(ex.find(c=>c.name==='SHREE JAGDISH TRADER').numbers.map(n=>n.label),['Primary','Shop']);
  await as('sales2');
  const xid=x.extras[0].id;
  await assert.rejects(call('select lwb_dial_number_remove($1)',[xid]),/Only Admin/);
  await as('sales');await call('select lwb_dial_number_remove($1)',[xid]);
});
