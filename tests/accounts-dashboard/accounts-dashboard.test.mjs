import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_accounts_dashboard_setup.sql on a tiny copy of the tables it reads (no live database).
const ids={admin:'00000000-0000-4000-8000-000000000001',accounts:'00000000-0000-4000-8000-000000000002',manager:'00000000-0000-4000-8000-000000000003',sales:'00000000-0000-4000-8000-000000000004',driver:'00000000-0000-4000-8000-000000000005'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false,created_at timestamptz default now());
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text);
CREATE TABLE public.lwb_tally_invoices(order_id uuid,invoice_no text);
CREATE TABLE public.lwb_tally_payments(id uuid default gen_random_uuid() primary key,receipt_id uuid,order_id uuid,pay_date date,mode text,amount numeric(14,2),ref_no text,cash_notes jsonb,remark text,created_by uuid,created_at timestamptz default now(),cancelled_at timestamptz);
CREATE TABLE public.lwb_delivery_reports(id uuid default gen_random_uuid() primary key,order_id uuid,driver_user_id uuid,cash_reported numeric(14,2) default 0,payment_mode text,payment_reference text,cash_amount numeric(14,2),online_amount numeric(14,2),online_mode text,online_reference text,bank_ref text,payment_status text,payment_reviewed_by uuid,payment_reviewed_at timestamptz);
CREATE TABLE public.tax_invoices(id uuid primary key,order_id uuid);
CREATE SCHEMA storage;
CREATE TABLE storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
CREATE TABLE storage.objects(bucket_id text,name text);
CREATE FUNCTION storage.foldername(text) RETURNS text[] LANGUAGE sql AS $$ SELECT (string_to_array($1,'/'))[1:array_length(string_to_array($1,'/'),1)-1] $$;
CREATE TABLE public.lwb_payment_collections(id uuid default gen_random_uuid() primary key,invoice_id uuid,collection_date date,amount numeric(14,2),payment_mode text,reference_no text,remarks text,status text,submitted_by uuid,submitted_at timestamptz default now(),reviewed_at timestamptz);
`);
for(const [role,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,role,role+' user']);
await db.exec(await readFile(new URL('../../lwb_accounts_dashboard_setup.sql',import.meta.url),'utf8'));
await db.exec(await readFile(new URL('../../lwb_accounts_staff_setup.sql',import.meta.url),'utf8'));
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');

const today=(await db.query("select public.lwb_acc_today()::text d")).rows[0].d;
const dayAdd=(d,n)=>{const x=new Date(d+'T12:00:00Z');x.setUTCDate(x.getUTCDate()+n);return x.toISOString().slice(0,10)};
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(sql,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(sql,args)).rows}finally{await db.exec('RESET ROLE')}}
const dash=async(from=today,to=today)=>(await call('select public.lwb_acc_dashboard($1,$2) j',[from,to]))[0].j;
const cat=async(kind,name)=>(await db.query('select id from lwb_acc_categories where kind=$1 and name=$2',[kind,name])).rows[0].id;
const add=p=>call('select public.lwb_acc_add_entry($1::jsonb) id',[JSON.stringify(p)]).then(r=>r[0].id);
const notes=async(type)=>(await db.query('select * from erp_notifications where notification_type=$1 order by id',[type])).rows;

test('only Accounts and Admin open the dashboard; heads are seeded',async()=>{
 for(const r of ['manager','sales','driver','none']){await as(r);await assert.rejects(dash(),/Accounts or Admin only/)}
 await as('accounts');const d=await dash();
 assert.equal(d.opening_set,false);
 assert.ok(d.categories.some(c=>c.kind==='OUT'&&c.name==='Canteen'));
 assert.ok(d.holders.length===2&&d.holders.every(h=>['admin','manager'].includes(h.role)));
 assert.equal((await db.query("select has_function_privilege('anon','public.lwb_acc_dashboard(date,date)','EXECUTE') a")).rows[0].a,false);
 assert.equal((await db.query("select has_table_privilege('authenticated','public.lwb_acc_entries','SELECT') a")).rows[0].a,false);
});

let bank,order;
test('cash in, expenses, bank deposit and ERP money make the cash balance (10 lakh in, 9 lakh deposit = 1 lakh)',async()=>{
 await as('accounts');
 await call('select public.lwb_acc_set_opening($1,0,$2)',[today,'start']);
 await assert.rejects(call('select public.lwb_acc_set_opening($1,5,null)',[today]),/Only Admin/);
 bank=(await call("select public.lwb_acc_save_bank(null,'HDFC Current','1234',0,null,true) id"))[0].id;
 order=(await db.query("insert into orders(order_no,customer_name) values('LXY-1','Shree Traders') returning id")).rows[0].id;
 await db.query("insert into lwb_tally_invoices values($1,'T-9')",[order]);
 // Payment collection: cash 1,50,000 + UPI 50,000 ; driver: cash 3,00,000 + UPI 20,000 (old style cash row 5,50,000 = cash)
 await db.query("insert into lwb_tally_payments(order_id,pay_date,mode,amount,created_by) values($1,$2,'CASH',150000,$3),($1,$2,'UPI',50000,$3)",[order,today,ids.accounts]);
 await db.query("insert into lwb_delivery_reports(order_id,driver_user_id,cash_reported,payment_mode,cash_amount,online_amount,online_mode,bank_ref,payment_status,payment_reviewed_by,payment_reviewed_at) values($1,$2,320000,'CASH+UPI',300000,20000,'UPI','UTR77','VERIFIED',$3,now())",[order,ids.driver,ids.accounts]);
 await db.query("insert into lwb_delivery_reports(order_id,driver_user_id,cash_reported,payment_mode,payment_status,payment_reviewed_by,payment_reviewed_at) values($1,$2,550000,'CASH','VERIFIED',$3,now())",[order,ids.driver,ids.accounts]);
 await add({date:today,kind:'OUT',category_id:await cat('OUT','Canteen'),mode:'CASH',amount:1200,remark:'lunch'});
 await add({date:today,kind:'OUT',category_id:await cat('OUT','Salary'),mode:'BANK',bank_id:bank,amount:25000,party:'Ramesh'});
 await add({date:today,kind:'DEPOSIT',bank_id:bank,amount:900000});
 const d=await dash();
 const cashIn=d.lines.filter(l=>l.kind==='IN').reduce((a,l)=>a+Number(l.cash),0);
 assert.equal(cashIn,1000000);
 assert.equal(Number(d.opening),0);
 assert.equal(Number(d.closing),1000000-1200-900000);
 // UPI 50k (payment) + UPI 20k (driver) + deposit 9 lakh wait for Admin
 assert.equal(d.pending.length,3);
 assert.equal((await notes('ACC_BANK_VERIFY')).length,1,'one bell for the one Admin');
 assert.match((await notes('ACC_BANK_VERIFY'))[0].message,/Waiting for your bank check: 3/);
 // bank balance: salary paid by bank only; nothing verified yet
 assert.equal(Number(d.banks[0].balance),-25000);
});

test('Admin verifies (counts in bank) or rejects (Accounts gets a bell); Accounts cannot verify',async()=>{
 await as('accounts');let d=await dash();
 await assert.rejects(call('select public.lwb_acc_verify_line($1,$2,true,$3,null)',[d.pending[0].src,d.pending[0].id,bank]),/Only Admin/);
 await as('admin');
 const dep=d.pending.find(p=>p.kind==='DEPOSIT'),upi=d.pending.find(p=>p.src==='PAYMENT'),drv=d.pending.find(p=>p.src==='DRIVER_ONLINE');
 await call('select public.lwb_acc_verify_line($1,$2,true,null,null)',[dep.src,dep.id]);
 await assert.rejects(call('select public.lwb_acc_verify_line($1,$2,true,null,null)',[upi.src,upi.id]),/Choose the bank/);
 await call('select public.lwb_acc_verify_line($1,$2,true,$3,null)',[upi.src,upi.id,bank]);
 await assert.rejects(call('select public.lwb_acc_verify_line($1,$2,false,null,null)',[drv.src,drv.id]),/Write why/);
 await call("select public.lwb_acc_verify_line($1,$2,false,null,'not in bank')",[drv.src,drv.id]);
 d=await dash();
 assert.equal(d.pending.length,0);
 assert.equal(Number(d.banks[0].balance),900000+50000-25000);
 assert.equal((await notes('ACC_BANK_REJECTED')).length,1);
 assert.equal((await notes('ACC_BANK_VERIFY')).filter(n=>!n.is_read).length,0,'bell cleared when nothing waits');
});

test('night close hands cash to Sales Head; next day opens with it; morning return; entries locked on closed day',async()=>{
 await as('accounts');
 await assert.rejects(call("select public.lwb_acc_close_day($1,'{\"500\":200}'::jsonb,$2,null)",[today,ids.sales]),/Admin or Sales Head/);
 const r=(await call("select public.lwb_acc_close_day($1,'{\"500\":197,\"100\":8,\"coins\":0}'::jsonb,$2,null) j",[today,ids.manager]))[0].j;
 assert.equal(Number(r.expected),98800);assert.equal(Number(r.counted),99300);assert.equal(Number(r.difference),500);
 assert.equal((await notes('ACC_CASH_HANDOVER'))[0].user_id,ids.manager);
 assert.equal((await notes('ACC_CASH_DIFF')).length,1);
 await assert.rejects(add({date:today,kind:'OUT',category_id:await cat('OUT','Food'),mode:'CASH',amount:10}),/already closed/);
 // a payment entered after the close counts on the next day
 await db.query("insert into lwb_tally_payments(order_id,pay_date,mode,amount,created_by) values($1,$2,'CASH',700,$3)",[order,today,ids.accounts]);
 const tomorrow=dayAdd(today,1);
 let d=await dash(tomorrow,tomorrow);
 assert.equal(Number(d.opening),99300);
 assert.equal(Number(d.closing),100000);
 const close=d.closes.find(c=>c.date===today);assert.ok(close&&close.handed_to_name==='manager user');
 await assert.rejects(call('select public.lwb_acc_cash_returned($1,99000,null)',[close.id]),/Write why/);
 await call('select public.lwb_acc_cash_returned($1,99300,null)',[close.id]);
 assert.equal((await notes('ACC_CASH_RETURNED'))[0].user_id,ids.manager);
 // reopen: admin only, entries allowed again
 await assert.rejects(call("select public.lwb_acc_reopen_day($1,'x')",[close.id]),/Only Admin/);
 await as('admin');await call("select public.lwb_acc_reopen_day($1,'missed bill')",[close.id]);
 await as('accounts');await add({date:today,kind:'OUT',category_id:await cat('OUT','Food'),mode:'CASH',amount:10});
 d=await dash();assert.equal(Number(d.closing),1000000-1200-900000+700-10);
});

test('entry rules: head needed, cheque no., duplicate ref, 2 lakh cash, cancel own only',async()=>{
 await as('accounts');
 await assert.rejects(add({date:today,kind:'OUT',mode:'CASH',amount:5}),/expense head/);
 await assert.rejects(add({date:today,kind:'IN',category_id:await cat('IN','Other income'),mode:'CHEQUE',amount:5}),/cheque number/);
 await assert.rejects(add({date:today,kind:'IN',category_id:await cat('IN','Other income'),mode:'CASH',amount:250000}),/269ST/);
 await assert.rejects(add({date:dayAdd(today,1),kind:'OUT',category_id:await cat('OUT','Food'),mode:'CASH',amount:5}),/future/);
 await add({date:today,kind:'IN',category_id:await cat('IN','Other income'),mode:'RTGS',amount:5000,ref:'R1'});
 await assert.rejects(add({date:today,kind:'IN',category_id:await cat('IN','Other income'),mode:'RTGS',amount:5000,ref:'r1'}),/already entered/);
 await as('admin');const mine=await add({date:today,kind:'OUT',category_id:await cat('OUT','Repair'),mode:'CASH',amount:300});
 await as('accounts');await assert.rejects(call("select public.lwb_acc_cancel_entry($1,'x')",[mine]),/another person/);
 const cid=(await call("select public.lwb_acc_save_category(null,'OUT','Gate pass fee',true) id"))[0].id;
 await assert.rejects(call("select public.lwb_acc_save_category($1,'OUT','Gate pass fee',false)",[cid]),/Only Admin/);
 const own=await add({date:today,kind:'OUT',category_id:cid,mode:'CASH',amount:50});
 await call("select public.lwb_acc_cancel_entry($1,'typo')",[own]);
 const d=await dash();assert.ok(!d.lines.some(l=>l.id===own));
});

test('staff ledger: salary of the month, upad, salary paid, upad returned; staff heads need the staff',async()=>{
 await as('accounts');
 const ram=(await call(`select public.lwb_acc_save_staff('{"name":"Ramesh","mobile":"9876543210","designation":"Loader","monthly_salary":15000,"opening_balance":-2000}'::jsonb) id`))[0].id;
 await assert.rejects(call(`select public.lwb_acc_save_staff('{"name":" ramesh ","monthly_salary":1}'::jsonb)`),/already exists/);
 const add2=p=>call('select public.lwb_acc_add_entry2($1::jsonb) id',[JSON.stringify(p)]).then(r=>r[0].id);
 await assert.rejects(add2({date:today,kind:'OUT',category_id:await cat('OUT','Staff advance'),mode:'CASH',amount:3000}),/Choose the staff/);
 await add2({date:today,kind:'OUT',category_id:await cat('OUT','Staff advance'),mode:'CASH',amount:3000,staff_id:ram});
 await call(`select public.lwb_acc_save_salaries($1,$2::jsonb)`,[today.slice(0,8)+'01',JSON.stringify([{staff_id:ram,amount:14500,note:'1 day leave'}])]);
 await add2({date:today,kind:'OUT',category_id:await cat('OUT','Salary'),mode:'UPI',bank_id:null,amount:9000,staff_id:ram,ref:'SAL1'});
 await add2({date:today,kind:'IN',category_id:await cat('IN','Staff advance return'),mode:'CASH',amount:500,staff_id:ram});
 const list=(await call('select public.lwb_acc_staff_list(null) j'))[0].j;
 const r=list.find(x=>x.id===ram);
 // -2000 + 14500 - 3000 - 9000 + 500 = 1000 still to pay
 assert.equal(Number(r.balance),1000);assert.equal(Number(r.month_upad),3000);assert.equal(Number(r.month_paid),9000);assert.equal(Number(r.month_salary),14500);
 const led=(await call('select public.lwb_acc_staff_ledger($1) j',[ram]))[0].j;
 assert.deepEqual(led.lines.map(l=>l.kind).sort(),['PAID','RETURN','SALARY','UPAD']);
 const ex=(await call('select public.lwb_acc_extras($1,$1) j',[today]))[0].j;
 assert.equal(Object.values(ex.entries).filter(e=>e.staff==='Ramesh').length,3);
});

test('bill photo and GST bill on a Cash Out',async()=>{
 await as('accounts');
 const add2=p=>call('select public.lwb_acc_add_entry2($1::jsonb) id',[JSON.stringify(p)]).then(r=>r[0].id);
 const base={date:today,kind:'OUT',category_id:await cat('OUT','Repair'),mode:'CASH',amount:1180,party:'Shiv Motors'};
 await assert.rejects(add2({...base,photos:['someone-else/x.jpg']}),/Bad photo/);
 await assert.rejects(add2({...base,gst_bill:true,gstin:'BAD'}),/GSTIN/);
 await assert.rejects(add2({...base,gst_bill:true,gst_amount:5000}),/more than the bill/);
 const id=await add2({...base,photos:[ids.accounts+'/bill-1.jpg'],gst_bill:true,gst_amount:180,gstin:'24abcde1234f1z5'});
 const e=(await db.query('select photo_paths,gst_bill,gst_amount,gstin from lwb_acc_entries where id=$1',[id])).rows[0];
 assert.deepEqual(e.photo_paths,[ids.accounts+'/bill-1.jpg']);assert.equal(e.gstin,'24ABCDE1234F1Z5');assert.equal(Number(e.gst_amount),180);
 assert.equal((await db.query("select count(*) n from storage.buckets where id='lwb-acc-bills'")).rows[0].n,1);
});
