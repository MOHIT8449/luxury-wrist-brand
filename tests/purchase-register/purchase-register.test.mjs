import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_purchase_register_setup.sql on an empty PGlite database, after the files it needs
// (tasks, documents, purchase claims). Goods Inward tables and storage are small stand-ins.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  godown:'00000000-0000-4000-8000-000000000003',godown2:'00000000-0000-4000-8000-000000000009',
  acc:'00000000-0000-4000-8000-000000000004',sales:'00000000-0000-4000-8000-000000000005'};
const roles={admin:'admin',head:'manager',godown:'warehouse',godown2:'warehouse',acc:'accounts',sales:'sales'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE SCHEMA storage;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.lwb_user_page_access(user_id uuid,extra text[]);
CREATE FUNCTION public.lwb_has_page(p text) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT false $$;
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean not null default false,created_at timestamptz default now());
CREATE TABLE public.lwb_goods_inward(id uuid primary key default gen_random_uuid(),invoice_no text,supplier_id uuid,supplier_name text,
  invoice_date date,received_date date,vehicle_no text,created_at timestamptz default now());
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
GRANT SELECT ON public.lwb_goods_inward TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,roles[k].toUpperCase(),'Name '+k]);
const file=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
for(const f of ['lwb_task_management_setup.sql','lwb_documents_setup.sql','lwb_purchase_claim_setup.sql'])await db.exec(await file(f));
const mine=await file('lwb_purchase_register_setup.sql');
await db.exec(mine);await db.exec(mine); // safe to run again
await db.exec(await file('lwb_task_management_setup.sql')); // the task file again keeps the new columns

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const bill=async(inv,veh='GJ05AB1234')=>(await db.query("insert into lwb_goods_inward(invoice_no,supplier_name,invoice_date,received_date,vehicle_no) values($1,'DS GROUP',current_date,current_date,$2) returning id",[inv,veh])).rows[0].id;
const tasks=async(bid)=>(await db.query("select id,assigned_to,status,priority,title from lwb_tasks where ref_type='PURCHASE_BILL' and ref_id=$1 order by id",[bid])).rows;
const dmg=[{sku_name:'RG 4G',issue:'DAMAGE',cases:2,pcs:0}];
async function addPhoto(who,bid){await as(who);
  const path='PURCHASE_BILL/'+bid+'/DAMAGE/'+ids[who].replace(/-/g,'')+'-'+Math.random().toString(36).slice(2)+'.jpg';
  await call("insert into storage.objects(bucket_id,name) values('lwb-documents',$1)",[path]);
  await call("select lwb_doc_add('PURCHASE_BILL',$1,'DAMAGE',$2,'a.jpg','image/jpeg',100)",[bid,path]);}

test('Check later: every Godown Manager gets one task; a second call adds nothing', async()=>{
  const b=await bill('INV-1');
  await as('head');
  const r=(await call('select lwb_purchase_photo_task($1) ids',[b]))[0].ids;
  assert.equal(r.length,2);
  const t=await tasks(b);
  assert.deepEqual(t.map(x=>x.assigned_to).sort(),[ids.godown,ids.godown2].sort());
  assert.match(t[0].title,/^Check vehicle \+ photos: GJ05AB1234 · Inv INV-1$/);
  const bell=(await db.query("select * from erp_notifications where user_id=$1 and notification_type='TASK_NEW'",[ids.godown])).rows;
  assert.equal(bell.length,1);
  assert.equal((await call('select lwb_purchase_photo_task($1) ids',[b]))[0].ids.length,0);
  // Godown Manager checks: no damage -> tasks close by themselves, giver gets TASK_DONE
  await as('godown');
  await call("select lwb_save_purchase_check($1,current_date,'',$2)",[b,JSON.stringify([])]);
  assert.deepEqual((await tasks(b)).map(x=>x.status),['DONE','DONE']);
  assert.ok((await db.query("select 1 from erp_notifications where user_id=$1 and notification_type='TASK_DONE'",[ids.head])).rows.length>=1);
});

test('Damage without photo: urgent photo task; closes when the damage photo is added', async()=>{
  const b=await bill('INV-2','GJ01ZZ0001');
  await as('admin');
  await call("select lwb_save_purchase_check($1,current_date,'2 cases leaked',$2)",[b,JSON.stringify(dmg)]);
  await call('select lwb_purchase_photo_task($1,$2)',[b,[ids.godown]]);
  let t=await tasks(b);
  assert.equal(t.length,1);assert.equal(t[0].priority,'URGENT');assert.match(t[0].title,/^Damage photos: vehicle GJ01ZZ0001/);
  await addPhoto('godown',b);
  t=await tasks(b);assert.equal(t[0].status,'DONE');
  const upd=(await db.query('select body,by_user from lwb_task_updates where task_id=$1',[t[0].id])).rows;
  assert.equal(upd[0].by_user,ids.godown);
});

test('Nothing to do: no task. Godown Manager / Salesman cannot give it', async()=>{
  const b=await bill('INV-3');
  await as('admin');
  await call("select lwb_save_purchase_check($1,current_date,'',$2)",[b,JSON.stringify(dmg)]);
  await addPhoto('admin',b);
  assert.equal((await call('select lwb_purchase_photo_task($1) ids',[b]))[0].ids.length,0);
  await as('godown');
  await assert.rejects(call('select lwb_purchase_photo_task($1)',[b]),/Only Admin \/ Sales Head/);
});

test('Godown Manager may not change a check once the claim went to the company; Salesman never', async()=>{
  const b=await bill('INV-4');
  await as('admin');
  await call("select lwb_save_purchase_check($1,current_date,'',$2)",[b,JSON.stringify(dmg)]);
  await db.query("update lwb_purchase_checks set claim_status='SENT' where inward_id=$1",[b]);
  await as('godown');
  await assert.rejects(call("select lwb_save_purchase_check($1,current_date,'',$2)",[b,'[]']),/already with the company/);
  await as('sales');
  await assert.rejects(call("select lwb_save_purchase_check($1,current_date,'',$2)",[b,'[]']),/Only Admin, Sales Head or Godown Manager/);
  await as('acc');
  assert.ok((await call('select * from lwb_purchase_checks')).length>=1,'accounts can read check status');
  await as('sales');
  assert.equal((await call('select * from lwb_purchase_checks')).length,0);
});

test('Duplicate invoice: same number ignoring case, spaces, / and -', async()=>{
  await bill('DS/322-HA21087');
  await as('head');
  const r=await call("select * from lwb_purchase_invoice_find('ds 322ha21087')");
  assert.equal(r.length,1);assert.equal(r[0].invoice_no,'DS/322-HA21087');
  assert.equal((await call("select * from lwb_purchase_invoice_find('322HA2108')")).length,0);
  await as('sales');
  await assert.rejects(call("select * from lwb_purchase_invoice_find('x')"),/Not allowed/);
});

test('Sales bill PDF register: upload, search exact and partial, edit, remove, rights', async()=>{
  await as('acc');
  const path='2026-11-01/'+ids.acc.replace(/-/g,'')+'-bills.pdf';
  await call("insert into storage.objects(bucket_id,name) values('lwb-sales-bills',$1)",[path]);
  const nos=['LWB/101','LWB/102','LWB/145'];
  const id=(await call('select lwb_sbs_add($1) id',[{bill_date:'2026-11-01',path,file_name:'bills.pdf',size:1000,invoice_text:'LWB/101-102, 145',invoice_nos:nos}]))[0].id;
  assert.ok(id);
  let r=await call("select * from lwb_sbs_find('lwb 145')");
  assert.equal(r.length,1);assert.equal(r[0].invoice_no,'LWB/145');assert.equal(r[0].exact,true);
  r=await call("select * from lwb_sbs_find('10')");
  assert.deepEqual(r.map(x=>x.invoice_no),['LWB/101','LWB/102']);
  await as('head');
  assert.equal((await call("select * from lwb_sbs_find('145')")).length,1,'Sales Head can search');
  await assert.rejects(call('select lwb_sbs_add($1)',[{bill_date:'2026-11-01',path,invoice_nos:nos}]),/Only Admin \/ Accounts/);
  await as('godown');
  await assert.rejects(call("select * from lwb_sbs_find('145')"),/Not allowed/);
  await as('admin');
  await assert.rejects(call('select lwb_sbs_add($1)',[{bill_date:'2026-11-01',path,invoice_nos:nos}]),/Wrong file path/);
  const p2='2026-11-02/'+ids.admin.replace(/-/g,'')+'-x.pdf';
  await assert.rejects(call('select lwb_sbs_add($1)',[{bill_date:'2026-11-02',path:p2,invoice_nos:nos}]),/File not found/);
  await call("insert into storage.objects(bucket_id,name) values('lwb-sales-bills',$1)",[p2]);
  await assert.rejects(call('select lwb_sbs_add($1)',[{bill_date:'2026-11-02',path:p2,invoice_nos:[' ']}]),/Enter the invoice numbers/);
  await call('select lwb_sbs_update($1,$2,$3,$4)',[id,'200',['200'],'redo']);
  assert.equal((await call("select * from lwb_sbs_find('145')")).length,0);
  assert.equal((await call("select * from lwb_sbs_find('200')")).length,1);
  await call('select lwb_sbs_update($1,null,null,null,true)',[id]);
  assert.equal((await call("select * from lwb_sbs_find('200')")).length,0);
  assert.equal((await call('select * from lwb_sales_bill_scans')).length,0);
});
