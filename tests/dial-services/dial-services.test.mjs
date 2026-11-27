import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_dial_services_setup.sql on PGlite (after the Dial Book files). Party master, salesman links, Employee Master, ECRS trucks and
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
const svc=await readFile(new URL('../../lwb_dial_services_setup.sql',import.meta.url),'utf8');
await db.exec(svc);await db.exec(svc);
// Gmail sync SQL: pgcrypto / pg_cron / pg_net are not in PGlite (stand-ins; the cron block skips itself).
await db.exec(`CREATE ROLE service_role; CREATE SCHEMA extensions;
CREATE FUNCTION extensions.gen_random_bytes(int) RETURNS bytea LANGUAGE sql AS $$ SELECT decode(md5(random()::text),'hex') $$;
GRANT USAGE ON SCHEMA public, auth TO service_role;`);
const gs=(await readFile(new URL('../../lwb_gmail_sync_setup.sql',import.meta.url),'utf8')).replace(/CREATE EXTENSION[^;]*;/,'');
await db.exec(gs);await db.exec(gs);

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const book=async who=>{await as(who);return (await call('select lwb_dial_book() j'))[0].j};
const kinds=b=>[...new Set(b.contacts.map(c=>c.kind))].sort().join(',');


const save=(o)=>call('select lwb_dial_service_save($1,$2,$3,$4,$5,$6,$7,$8,$9) j',[o.id||null,o.grp,o.cat,o.name||null,o.firm||null,o.area||null,o.mob,o.note||null,o.src||'Dial Book']).then(r=>r[0].j);

test('Save: who may, checks, no duplicate number (no error)', async()=>{
  await as('sales');await assert.rejects(save({grp:'SERVICE',cat:'Tyre',firm:'Shree Tyres',mob:'9811111111'}),/Only Admin/);
  await as('godown');await assert.rejects(save({grp:'SERVICE',cat:'Tyre',firm:'Shree Tyres',mob:'9811111111'}),/Only Admin/);
  await as('acc');
  await assert.rejects(save({grp:'X',cat:'Tyre',firm:'A',mob:'9811111111'}),/Vendor, Service or Complaint/);
  await assert.rejects(save({grp:'SERVICE',cat:'Tyre',mob:'9811111111'}),/name or the firm/);
  await assert.rejects(save({grp:'SERVICE',cat:'Tyre',firm:'A',mob:'12'}),/10-digit/);
  const a=await save({grp:'SERVICE',cat:'tyre',name:'ramesh',firm:'shree tyres',area:'sachin',mob:'+91 98111 11111'});
  assert.equal(a.saved,true);
  const same=await save({grp:'VENDOR',cat:'Forklift',firm:'Other',mob:'9811111111'});
  assert.deepEqual([same.saved,same.same,same.owner],[false,true,'RAMESH']);
  const party=await save({grp:'VENDOR',cat:'Forklift',firm:'Other',mob:'9876543312'});
  assert.deepEqual([party.saved,party.owner_kind],[false,'PARTY'],'party number is not saved again');
  // edit keeps its own number
  const e=await save({id:a.id,grp:'SERVICE',cat:'Tyre',name:'Ramesh',firm:'Shree Tyres',area:'Sachin',mob:'9811111111',note:'truck tyres'});
  assert.equal(e.saved,true);
  const keep=await save({id:a.id,grp:'SERVICE',cat:'Tyre',name:'Ramesh',firm:'Shree Tyres',area:'Sachin',mob:''});
  assert.equal(keep.masked,'98•••••111','empty mobile on edit keeps the number');
  await as('admin');
  assert.equal((await save({grp:'COMPLAINT',cat:'Electrician',name:'Suresh',mob:'9822222222'})).saved,true);
  assert.equal((await save({grp:'VENDOR',cat:'Labour',name:'Mahesh',firm:'Jay Labour Contractor',mob:'9833333333',src:'Expense'})).saved,true);
});

test('List, Dial Book, call without reason, contacts file name', async()=>{
  await as('godown');
  const l=(await call('select lwb_dial_services_list() j'))[0].j;
  assert.equal(l.can_edit,false);assert.equal(l.rows.length,3);
  assert.ok(l.rows.every(x=>!('mobile' in x)));
  const t=l.rows.find(x=>x.category==='TYRE');assert.equal(t.masked,'98•••••111');
  const b=await book('godown');const s=b.contacts.filter(c=>c.kind==='SERVICE');
  assert.equal(s.length,3);
  assert.equal(s.find(c=>c.name==='RAMESH').tag,'Service · Tyre');
  assert.equal(s.find(c=>c.name==='RAMESH').sub,'SHREE TYRES · SACHIN');
  const c=(await call("select lwb_dial_call('SERVICE',$1,'Dial Book') j",[String(t.id)]))[0].j;
  assert.equal(c.mobile,'9811111111');
  await as('admin');
  const ex=(await call('select lwb_dial_export() j'))[0].j.filter(x=>x.kind==='SERVICE').map(x=>x.save_as).sort();
  assert.deepEqual(ex,['MAHESH JAY LABOUR CONTRACTOR LABOUR LWB VENDOR','RAMESH SHREE TYRES TYRE LWB SERVICE','SURESH ELECTRICIAN LWB COMPLAINT']);
  // the old Dial Book still works
  assert.ok(b.contacts.some(x=>x.kind==='TEAM'));
});

test('Remove: Admin / Sales Head / Accounts; number can be saved again after', async()=>{
  await as('godown');const l=(await call('select lwb_dial_services_list() j'))[0].j;const id=l.rows.find(x=>x.category==='ELECTRICIAN').id;
  await assert.rejects(call('select lwb_dial_service_remove($1)',[id]),/Only Admin/);
  await as('head');assert.equal((await call('select lwb_dial_service_remove($1) r',[id]))[0].r,true);
  await as('acc');assert.equal((await save({grp:'COMPLAINT',cat:'Electrician',name:'New Electrician',mob:'9822222222'})).saved,true);
});

test('Gmail sync: Admin only status / client; contacts list as the Admin who connected', async()=>{
  await as('head');await assert.rejects(call('select lwb_gsync_status()'),/Only Admin/);
  await assert.rejects(call("select lwb_gsync_set_client('1-a.apps.googleusercontent.com','abcdefghijkl')"),/Only Admin/);
  await as('admin');
  const st=(await call('select lwb_gsync_status() j'))[0].j;
  assert.deepEqual([st.client_set,st.connected,st.redirect_uri],[false,false,'https://luxurywristbrand.com/dial-book.html']);
  await assert.rejects(call("select lwb_gsync_set_client('hello','abcdefghijkl')"),/Client ID looks wrong/);
  const ok=(await call("select lwb_gsync_set_client('123456-abc9.apps.googleusercontent.com','GOCSPX-abcdefgh')  j"))[0].j;
  assert.equal(ok.client_set,true);assert.ok(!JSON.stringify(ok).includes('GOCSPX'),'secret never comes back');
  // browser logins cannot read the config table or the contacts list
  await assert.rejects(call('select * from lwb_gsync_config'),/permission denied/);
  await assert.rejects(call('select lwb_gsync_contacts()'),/permission denied/);
  // service_role (Edge Function), before Gmail is connected: refused
  await as('');
  const svc=async q=>{await db.exec('SET ROLE service_role');try{return (await db.query(q)).rows}finally{await db.exec('RESET ROLE')}};
  await assert.rejects(svc('select lwb_gsync_contacts()'),/not an active Admin/);
  await db.query('update lwb_gsync_config set connected_by=$1',[ids.admin]);
  const list=(await svc('select lwb_gsync_contacts() j'))[0].j;
  const names=list.map(x=>x.name);
  assert.ok(names.includes('RAMESH SHREE TYRES TYRE LWB SERVICE'));
  assert.ok(names.includes('SHREE JAGDISH TRADER AMROLI CC WS'));
  const mobs=list.flatMap(x=>x.numbers.map(n=>n.mobile));assert.equal(new Set(mobs).size,mobs.length,'every number once');
  assert.ok(list.every(x=>x.key&&x.hash&&x.numbers.length));
  const again=(await svc('select lwb_gsync_contacts() j'))[0].j;
  assert.deepEqual(again.map(x=>x.hash),list.map(x=>x.hash),'same data = same hash (no needless update)');
});
