import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_daily_labour_setup.sql on a tiny copy of the tables (no live database).
// The money entry (lwb_acc_add_entry) and cashier rules are small copies of the live ones;
// the real lwb_gm_notify_scope_setup.sql runs first so the LABOUR bell patch is checked too.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  head2:'00000000-0000-4000-8000-000000000003',cashier:'00000000-0000-4000-8000-000000000004',
  gm:'00000000-0000-4000-8000-000000000005',gm2:'00000000-0000-4000-8000-000000000006',sales:'00000000-0000-4000-8000-000000000007'};
const roles={admin:'admin',head:'manager',head2:'manager',cashier:'cashier',gm:'warehouse',gm2:'warehouse',sales:'sales'};
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text,mobile text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,
  ref_type text,ref_id text,is_read boolean default false,created_at timestamptz default now());
CREATE TABLE public.dispatch_assignments(order_id uuid,loading_manager_id uuid);
CREATE TABLE public.lwb_acc_categories(id bigserial primary key,kind text,name text,sort int,active boolean default true);
CREATE TABLE public.lwb_acc_entries(id uuid primary key default gen_random_uuid(),entry_date date,kind text,category_id bigint,mode text,
  amount numeric,party text,remark text,created_by uuid,cancelled_at timestamptz);
CREATE FUNCTION public.lwb_acc_today() RETURNS date LANGUAGE sql STABLE AS $$ SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date $$;
CREATE FUNCTION public.lwb_acc_admin() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.active AND p.role='admin') $$;
CREATE FUNCTION public.lwb_acc_cashier() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.active AND p.role='cashier') $$;
CREATE FUNCTION public.lwb_acc_add_entry(p jsonb) RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO public.lwb_acc_entries(entry_date,kind,category_id,mode,amount,party,remark,created_by)
  VALUES ((p->>'date')::date,p->>'kind',(p->>'category_id')::bigint,p->>'mode',(p->>'amount')::numeric,p->>'party',p->>'remark',auth.uid()) RETURNING id $$;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3,$4)',[id,roles[k],k.toUpperCase(),null]);
await db.exec(await sql('lwb_gm_notify_scope_setup.sql'));
await db.exec(await sql('lwb_daily_labour_setup.sql'));
await db.exec(await sql('lwb_daily_labour_setup.sql'));   // safe to run again

const as=async(who,q,p=[])=>{await db.exec(`SET request.jwt.claim.sub='${ids[who]}'`);return db.query(q,p)};
const one=async(who,q,p)=>(await as(who,q,p)).rows[0].r;
const fails=async(who,q,p,re)=>{await db.exec('SAVEPOINT s');try{await as(who,q,p);assert.fail('should fail')}catch(e){assert.match(e.message,re)}finally{await db.exec('ROLLBACK TO SAVEPOINT s')}};
const today=(await db.query(`select lwb_acc_today()::text d`)).rows[0].d;
const add=(who,o)=>one(who,`select lwb_labour_add($1) r`,[o]);

test('Godown Manager enters own labour today: name + 10 digit mobile + wage required, one mobile once a day', async()=>{
  await db.exec('BEGIN');
  await fails('gm',`select lwb_labour_add($1)`,[{name:'',mobile:'9876543210',wage:500}],/labour name/);
  await fails('gm',`select lwb_labour_add($1)`,[{name:'Ramesh',mobile:'98765',wage:500}],/10 digit mobile/);
  await fails('gm',`select lwb_labour_add($1)`,[{name:'Ramesh',mobile:'9876543210'}],/wage/);
  await fails('gm',`select lwb_labour_add($1)`,[{name:'Ramesh',mobile:'9876543210',wage:500,gm_id:ids.gm2}],/only your own/);
  await fails('gm',`select lwb_labour_add($1)`,[{name:'Ramesh',mobile:'9876543210',wage:500,day:'2020-01-01'}],/today/);
  await fails('sales',`select lwb_labour_add($1)`,[{name:'Ramesh',mobile:'9876543210',wage:500}],/Godown Manager/);
  const r=await add('gm',{name:' ramesh  kumar ',mobile:'+91 98765 43210',wage:550,work:'unloading'});
  assert.equal(r.name,'RAMESH KUMAR');assert.equal(r.mobile,'9876543210');assert.equal(Number(r.wage),550);
  await fails('gm2',`select lwb_labour_add($1)`,[{name:'Ramesh',mobile:'9876543210',wage:500}],/already entered today \(by GM\)/);
  await add('gm',{name:'Suresh',mobile:'9123456789',wage:450});
  const d=await one('gm',`select lwb_labour_day(null) r`);
  assert.equal(d.gms.length,1);assert.equal(d.count,2);assert.equal(Number(d.total),1000);assert.equal(d.can_pay,false);
  const all=await one('head',`select lwb_labour_day(null) r`);
  assert.equal(all.gms.length,2);assert.equal(all.gms[0].name,'GM');assert.equal(Number(all.gms[0].due),1000);
  await fails('sales',`select lwb_labour_day(null)`,[],/only/);
  await db.exec('ROLLBACK');
});

test('morning plan by Sales Head: bell reaches the Godown Manager; over plan is flagged', async()=>{
  await db.exec('BEGIN');
  await fails('gm',`select lwb_labour_plan_set($1,$2,3,500,null)`,[today,ids.gm],/Admin or a Sales Head/);
  await one('head',`select lwb_labour_plan_set($1,$2,1,500,'truck unloading') r`,[today,ids.gm]);
  const b=(await db.query(`select title from erp_notifications where user_id=$1 and notification_type='LABOUR_PLAN'`,[ids.gm])).rows;
  assert.equal(b.length,1);assert.match(b[0].title,/1 labour/);   // not dropped by the Godown Manager bell filter
  await add('gm',{name:'Ramesh',mobile:'9876543210',wage:500});
  let g=(await one('head',`select lwb_labour_day(null) r`)).gms.find(x=>x.gm_id===ids.gm);
  assert.equal(g.plan.count,1);assert.equal(Number(g.plan.budget),500);assert.equal(g.over_plan,false);
  await add('gm',{name:'Suresh',mobile:'9123456789',wage:500});
  g=(await one('head',`select lwb_labour_day(null) r`)).gms.find(x=>x.gm_id===ids.gm);
  assert.equal(g.over_plan,true);
  // a GM with no plan can still add (gm2)
  await add('gm2',{name:'Mahesh',mobile:'9000000001',wage:400});
  await db.exec('ROLLBACK');
});

test('cashier gives at most the register; more needs Sales Head / Admin approval; GM locked after cash', async()=>{
  await db.exec('BEGIN');
  const r1=await add('gm',{name:'Ramesh',mobile:'9876543210',wage:500});
  await add('gm',{name:'Suresh',mobile:'9123456789',wage:500});
  await fails('gm',`select lwb_labour_pay($1,$2,1000)`,[today,ids.gm],/cashier/);
  await fails('head',`select lwb_labour_pay($1,$2,1000)`,[today,ids.gm],/cashier/);
  await fails('cashier',`select lwb_labour_pay($1,$2,1200)`,[today,ids.gm],/at most Rs 1,000/);
  const p=await one('cashier',`select lwb_labour_pay($1,$2,600,'part') r`,[today,ids.gm]);
  assert.equal(Number(p.due),400);
  const e=(await db.query(`select e.kind,e.mode,e.amount,e.party,c.name head from lwb_acc_entries e join lwb_acc_categories c on c.id=e.category_id`)).rows;
  assert.equal(e.length,1);assert.equal(e[0].head,'Labour charge');assert.equal(e[0].party,'GM');assert.equal(Number(e[0].amount),600);
  // after cash the Godown Manager cannot change the register any more; Sales Head can
  await fails('gm',`select lwb_labour_add($1)`,[{name:'Extra',mobile:'9000000002',wage:300}],/already given/);
  await fails('gm',`select lwb_labour_remove($1,'x')`,[r1.id],/already given/);
  await fails('cashier',`select lwb_labour_pay($1,$2,500)`,[today,ids.gm],/at most Rs 400/);
  // extra: asked by cashier, approved by a Sales Head (less than asked), then paid
  await fails('cashier',`select lwb_labour_extra_ask($1,$2,300,'')`,[today,ids.gm],/Write why/);
  const x=await one('cashier',`select lwb_labour_extra_ask($1,$2,300,'one more labour came late') r`,[today,ids.gm]);
  assert.equal((await db.query(`select count(*)::int n from erp_notifications where notification_type='LABOUR_EXTRA'`)).rows[0].n,3); // admin + 2 heads
  const list=await one('head',`select lwb_labour_extra_list() r`);
  assert.equal(list.length,1);assert.equal(Number(list[0].total),1000);
  await fails('cashier',`select lwb_labour_pay($1,$2,700)`,[today,ids.gm],/at most Rs 400/);  // still waiting
  await fails('gm',`select lwb_labour_extra_decide($1,true,null,null)`,[x.id],/Sales Head or Admin/);
  await fails('head',`select lwb_labour_extra_decide($1,true,400,null)`,[x.id],/asked/);
  await one('head',`select lwb_labour_extra_decide($1,true,200,'ok') r`,[x.id]);
  assert.equal((await db.query(`select count(*)::int n from erp_notifications where notification_type='LABOUR_EXTRA' and not is_read`)).rows[0].n,0);
  assert.equal((await db.query(`select count(*)::int n from erp_notifications where notification_type='LABOUR_EXTRA_DONE'`)).rows[0].n,2); // cashier + GM
  await fails('cashier',`select lwb_labour_pay($1,$2,700)`,[today,ids.gm],/at most Rs 600/);
  await one('cashier',`select lwb_labour_pay($1,$2,600) r`,[today,ids.gm]);
  const g=(await one('head',`select lwb_labour_day(null) r`)).gms.find(v=>v.gm_id===ids.gm);
  assert.equal(Number(g.paid),1200);assert.equal(Number(g.due),0);assert.equal(g.locked,true);assert.equal(g.pays.length,2);
  // a cancelled Cash Out entry is not counted as paid
  await db.exec(`update lwb_acc_entries set cancelled_at=now() where amount=600 and remark like '%part'`);
  assert.equal(Number((await one('head',`select lwb_labour_day(null) r`)).gms.find(v=>v.gm_id===ids.gm).due),600);
  await db.exec('ROLLBACK');
});

test('who asked cannot approve own extra (Sales Head); reject needs a reason', async()=>{
  await db.exec('BEGIN');
  await add('gm',{name:'Ramesh',mobile:'9876543210',wage:500});
  const x=await one('head',`select lwb_labour_extra_ask($1,$2,100,'tea') r`,[today,ids.gm]);
  await fails('head',`select lwb_labour_extra_decide($1,true,null,null)`,[x.id],/another Sales Head/);
  await fails('head2',`select lwb_labour_extra_decide($1,false,null,null)`,[x.id],/why/);
  assert.equal((await one('head2',`select lwb_labour_extra_decide($1,false,null,'not needed') r`,[x.id])).status,'REJECTED');
  await fails('cashier',`select lwb_labour_pay($1,$2,600)`,[today,ids.gm],/at most Rs 500/);
  await db.exec('ROLLBACK');
});

test('repeat labourer: find by mobile, per labourer history and per day list', async()=>{
  await db.exec('BEGIN');
  await db.exec(`insert into lwb_labour(day,gm_id,name,mobile,wage,created_by) values
    (current_date-3,'${ids.gm}','RAMESH','9876543210',450,'${ids.gm}'),(current_date-1,'${ids.gm2}','RAMESH K','9876543210',500,'${ids.gm2}')`);
  const f=await one('gm',`select lwb_labour_find('98765 43210') r`);
  assert.equal(f.name,'RAMESH K');assert.equal(Number(f.wage),500);assert.equal(f.days,2);assert.equal(f.last_gm,'GM2');
  assert.equal(await one('gm',`select lwb_labour_find('9999999999') r`),null);
  const r=await add('gm',{name:'Ramesh K',mobile:'9876543210',wage:500});
  assert.equal(r.days_before,2);
  const ppl=await one('head',`select lwb_labour_people(current_date-30,current_date) r`);
  assert.equal(ppl.length,1);assert.equal(ppl[0].days,3);assert.equal(Number(ppl[0].total),1450);assert.equal(ppl[0].gms.length,2);
  const mine=await one('gm',`select lwb_labour_people(current_date-30,current_date) r`);
  assert.equal(mine[0].days,2);   // Godown Manager: only his own rows
  const days=await one('head',`select lwb_labour_days(current_date-30,current_date) r`);
  assert.equal(days.length,3);
  await db.exec('ROLLBACK');
});
