import {test} from 'node:test';
import assert from 'node:assert/strict';
import {makePlan,actions,mob,mask} from '../../supabase/functions/lwb-google-contacts/plan.js';

// acc 0 = main Gmail (has the LWB ERP label), 1 / 2 = Mohit's other Gmail
const C=[
 {acc:0,rn:'people/e1',name:'RAJESH PATEL CC GSM SURAT',phones:['+919876500001'],erp:true},
 {acc:1,rn:'people/a1',name:'Rajesh coke',phones:['98765 00001'],erp:false},
 {acc:2,rn:'people/b1',name:'Rajesh',phones:['09876500001','0261 2345678'],erp:false},  // also a landline: keep contact
 {acc:1,rn:'people/a2',name:'Kalu bhai',phones:['9811100002'],erp:false},
 {acc:2,rn:'people/b2',name:'Kalu Tempo Wala',phones:['+91 98111 00002'],erp:false},
 {acc:2,rn:'people/b3',name:'Only once',phones:['9000000003'],erp:false},
 {acc:1,rn:'people/a4',name:'Two nums',phones:['9811100002','9000000004'],erp:false},   // dup number + own number
];
const erp=new Map([['9876500001','RAJESH PATEL CC GSM SURAT']]);

test('mobile: any spacing / +91 / 0; landline not', ()=>{
  assert.equal(mob('+91 98765 00001'),'9876500001');assert.equal(mob('09876500001'),'9876500001');
  assert.equal(mob('0261 2345678'),null);assert.equal(mob('12345'),null);assert.equal(mask('9876500001'),'98•••••001');
});

test('Plan: ERP number keeps the ERP name (fixed); others: longest name, Admin can pick', ()=>{
  const g=makePlan(C,erp);
  assert.deepEqual(g.map(x=>[x.m,x.fixed,x.keep,x.ids.join()]),[['9876500001',true,0,'0,1,2'],['9811100002',false,4,'3,4,6']]);
  assert.equal(g[0].erp_name,'RAJESH PATEL CC GSM SURAT');
});

test('Actions: delete copies; contact with another number only loses the duplicate; ERP never touched', ()=>{
  const g=makePlan(C,erp);
  let a=actions(C,g,{});
  assert.deepEqual(a.del.map(x=>x.rn).sort(),['people/a1','people/a2']);
  assert.deepEqual(a.upd.map(x=>[x.rn,x.drop.join()]).sort(),[['people/a4','9811100002'],['people/b1','9876500001']]);
  a=actions(C,g,{'9811100002':3,'9876500001':1}); // fixed group ignores the pick
  assert.deepEqual(a.del.map(x=>x.rn).sort(),['people/a1','people/b2']);
  assert.ok(!a.del.concat(a.upd).some(x=>x.rn==='people/e1'));
  assert.throws(()=>actions(C,g,{'9811100002':5}),/Wrong choice/);
});

test('ERP number whose ERP contact is not in Gmail yet: Admin picks (not fixed)', ()=>{
  const g=makePlan(C.filter(x=>!x.erp),erp);
  const r=g.find(x=>x.m==='9876500001');assert.equal(r.fixed,false);assert.equal(r.erp_name,'RAJESH PATEL CC GSM SURAT');
});
