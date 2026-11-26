import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_acc_dup_note_setup.sql on a tiny copy of the tables (no live database).
// The real party key / parent functions run; cashier rules are small copies of the live ones.
const ids={admin:'00000000-0000-4000-8000-000000000001',accounts:'00000000-0000-4000-8000-000000000002',
  cashier:'00000000-0000-4000-8000-000000000003',manager:'00000000-0000-4000-8000-000000000004',sales:'00000000-0000-4000-8000-000000000005'};
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false,created_at timestamptz default now());
CREATE TABLE public.lwb_tally_party_map(tally_key text primary key,tally_name text not null,customer_name text);
CREATE TABLE public.lwb_tally_payments(id bigserial primary key,receipt_id uuid,party text,amount numeric,mode text,cancelled_at timestamptz);
CREATE FUNCTION public.lwb_acc_today() RETURNS date LANGUAGE sql STABLE AS $$ SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date $$;
CREATE FUNCTION public.lwb_acc_admin() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.active AND p.role='admin') $$;
CREATE FUNCTION public.lwb_acc_cashier() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.active AND p.role='cashier') $$;
CREATE FUNCTION public.lwb_acc_user() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.active AND p.role IN ('admin','accounts','cashier')) $$;
`);
const g=await sql('lwb_party_group_billing_setup.sql');
await db.exec(g.slice(g.indexOf('CREATE OR REPLACE FUNCTION public.lwb_party_key'),g.indexOf('REVOKE ALL ON FUNCTION public.lwb_party_parent(text)')));
for(const [role,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,role,role+' user']);
await db.exec(await sql('lwb_acc_dup_note_setup.sql'));
await db.exec(`INSERT INTO lwb_tally_party_map VALUES ('RG MAA TRADERS','RG. MAA TRADERS','MAA TRADERS (BOMBY MARKET)')`);

const as=async(who,q,p=[])=>{await db.exec(`SET request.jwt.claim.sub='${ids[who]}'`);return db.query(q,p)};
const one=async(who,q,p)=>(await as(who,q,p)).rows[0];
const fails=async(who,q,p,re)=>{await db.exec('SAVEPOINT s');try{await as(who,q,p);assert.fail('should fail')}catch(e){assert.match(e.message,re)}finally{await db.exec('ROLLBACK TO SAVEPOINT s')}};

test('only the cashier enters; amount from the note count; bells to office staff', async()=>{
  await db.exec('BEGIN');
  await fails('manager',`select lwb_acc_dup_add($1)`,[{party:'MAA TRADERS (BOMBY MARKET)',notes:{'500':1}}],/today's cashier/);
  await fails('admin',`select lwb_acc_dup_add($1)`,[{party:'MAA TRADERS (BOMBY MARKET)',notes:{'500':1}}],/today's cashier/);
  await fails('cashier',`select lwb_acc_dup_add($1)`,[{party:'MAA TRADERS (BOMBY MARKET)',notes:{'300':1}}],/not a note/);
  await fails('cashier',`select lwb_acc_dup_add($1)`,[{party:'MAA TRADERS (BOMBY MARKET)',notes:{'500':0}}],/how many/);
  // a bill name (Tally name) goes to the main party
  const r=(await one('cashier',`select lwb_acc_dup_add($1) r`,[{party:'RG. MAA TRADERS',kind:'DUPLICATE',notes:{'500':1,'100':2},note:'counted at office'}])).r;
  assert.equal(r.party,'MAA TRADERS (BOMBY MARKET)');assert.equal(Number(r.amount),700);assert.equal(r.count,3);
  assert.equal(r.notes_text,'1 x Rs 500 + 2 x Rs 100');assert.equal(r.status,'PENDING');
  const bells=(await db.query(`select user_id,title from erp_notifications where notification_type='DUP_NOTE' order by user_id`)).rows;
  assert.deepEqual(bells.map(b=>b.user_id),[ids.admin,ids.accounts,ids.manager]);  // not the cashier who entered, not the salesman
  assert.match(bells[0].title,/Duplicate note Rs 700: MAA TRADERS/);
  await db.exec('ROLLBACK');
});

test('pending list: office staff yes, salesman only through his party, keys hold every bill name', async()=>{
  await db.exec('BEGIN');
  await one('cashier',`select lwb_acc_dup_add($1)`,[{party:'MAA TRADERS (BOMBY MARKET)',kind:'TORN',notes:{'200':1}}]);
  const p=(await one('manager',`select lwb_dup_pending() r`)).r;
  assert.equal(p.length,1);assert.ok(p[0].keys.includes('RG MAA TRADERS'));assert.ok(p[0].keys.includes('MAA TRADERS BOMBY MARKET'));
  assert.deepEqual((await one('sales',`select lwb_dup_pending() r`)).r,[]);
  assert.equal((await one('sales',`select lwb_dup_for_party('RG. MAA TRADERS') r`)).r.length,1);
  assert.equal((await one('sales',`select lwb_dup_for_party('OTHER SHOP') r`)).r.length,0);
  await fails('sales',`select lwb_acc_dup_list(30)`,[],/only/);
  const l=(await one('manager',`select lwb_acc_dup_list(30) r`)).r;
  assert.equal(l.rows.length,1);assert.equal(l.can_add,false);
  await db.exec('ROLLBACK');
});

test('collect needs the good note payment of the same party; cancel rules', async()=>{
  await db.exec('BEGIN');
  const r=(await one('cashier',`select lwb_acc_dup_add($1) r`,[{party:'MAA TRADERS (BOMBY MARKET)',notes:{'500':1}}])).r;
  await db.exec(`INSERT INTO lwb_tally_payments(receipt_id,party,amount,mode) VALUES
    ('11111111-1111-4111-8111-111111111111','RG. MAA TRADERS',500,'CASH'),('22222222-2222-4222-8222-222222222222','OTHER SHOP',500,'CASH')`);
  await fails('manager',`select lwb_acc_dup_collect($1,$2)`,[r.id,'11111111-1111-4111-8111-111111111111'],/cashier or Admin/);
  await fails('cashier',`select lwb_acc_dup_collect($1,null)`,[r.id],/party payment/);
  await fails('cashier',`select lwb_acc_dup_collect($1,$2)`,[r.id,'22222222-2222-4222-8222-222222222222'],/another party/);
  const c=(await one('cashier',`select lwb_acc_dup_collect($1,$2,'driver Ramesh brought it') r`,[r.id,'11111111-1111-4111-8111-111111111111'])).r;
  assert.equal(c.status,'COLLECTED');assert.equal(c.collect_receipt_id,'11111111-1111-4111-8111-111111111111');
  assert.equal((await db.query(`select count(*)::int n from erp_notifications where notification_type='DUP_NOTE' and title like '⚠%' and not is_read`)).rows[0].n,0);
  assert.deepEqual((await one('manager',`select lwb_dup_pending() r`)).r,[]);
  await fails('cashier',`select lwb_acc_dup_collect($1,$2)`,[r.id,'11111111-1111-4111-8111-111111111111'],/already collected/);
  // cancel: who entered it (same day) or Admin, with a reason
  const r2=(await one('cashier',`select lwb_acc_dup_add($1) r`,[{party:'OTHER SHOP',notes:{'100':1}}])).r;
  await fails('accounts',`select lwb_acc_dup_cancel($1,'x')`,[r2.id],/Only Admin/);
  await fails('cashier',`select lwb_acc_dup_cancel($1,'')`,[r2.id],/Write why/);
  assert.equal((await one('cashier',`select lwb_acc_dup_cancel($1,'wrong party') r`,[r2.id])).r.status,'CANCELLED');
  const r3=(await one('cashier',`select lwb_acc_dup_add($1) r`,[{party:'OTHER SHOP',notes:{'100':1}}])).r;
  assert.equal((await one('admin',`select lwb_acc_dup_cancel($1,'party will never replace') r`,[r3.id])).r.status,'CANCELLED');
  await db.exec('ROLLBACK');
});
