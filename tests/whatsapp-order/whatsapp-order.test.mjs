import {test} from 'node:test';
import assert from 'node:assert/strict';
import {step, fresh, inputOf, apiBody, parseQty, doneText, MAX_ROWS} from '../../supabase/functions/lwb-wa-order/logic.js';

const sk=(name,brand,category)=>({name,brand,category,pcs:24});
const many=Array.from({length:14},(_,i)=>sk('COKE ITEM '+(i+1),'cc',i<11?'CSD':'JUICE'));
const catalog={brands:[{id:'cc',name:'Coca-Cola'},{id:'rj',name:'Rajnigandha'}],skus:[...many,sk('THUMS UP 250ML PET','cc','CSD'),sk('RAJNIGANDHA 4G','rj','PAN MASALA')]};
const known={catalog,party:{name:'SHREE GANESH STORES'},profileName:'Ganesh'};
const newc={catalog,party:null,profileName:'Rakesh'};
const run=(ctx,steps,st=fresh())=>{let r;for(const s of steps){r=step(st,s,ctx);st=r.state}return r};
const T=t=>({kind:'text',text:t}),P=id=>({kind:'pick',id});
const rowsOf=m=>m.sections.flatMap(s=>s.rows);

test('hi shows brands with party name; template Order button starts too',()=>{
 const r=step(fresh(),T('Hi'),known);
 assert.equal(r.replies[0].type,'list');assert.match(r.replies[0].body,/SHREE GANESH STORES/);
 assert.deepEqual(rowsOf(r.replies[0]).map(x=>x.id),['b:cc','b:rj']);
 assert.equal(step(fresh(),inputOf({type:'button',button:{text:'Order करें',payload:'Order करें'}}),known).replies[0].type,'list');
});

test('more than 10 products: categories, then pages with More',()=>{
 let r=run(known,[T('hi'),P('b:cc')]);
 assert.deepEqual(rowsOf(r.replies[0]).map(x=>x.title),['CSD','JUICE']);
 r=run(known,[T('hi'),P('b:cc'),P('c:0')]);
 const rows=rowsOf(r.replies[0]);
 assert.equal(rows.length,MAX_ROWS);assert.equal(rows.at(-1).id,'pg:1');
 r=step(r.state,P('pg:1'),known);
 assert.deepEqual(rowsOf(r.replies[0]).map(x=>x.title),['COKE ITEM 10','COKE ITEM 11','THUMS UP 250ML PET']);
});

test('pick product, cases, cart buttons; 0 removes; typed name works',()=>{
 let r=run(known,[T('hi'),P('b:cc'),P('c:0'),P('p:THUMS UP 250ML PET')]);
 assert.match(r.replies[0].body,/कितने केस/);
 r=step(r.state,T('abc'),known);assert.match(r.replies[0].body,/नंबर/);
 r=step(r.state,T('10 case'),known);
 assert.equal(r.replies[0].type,'buttons');assert.deepEqual(r.state.cart,[{sku:'THUMS UP 250ML PET',qty:10}]);
 assert.deepEqual(r.replies[0].buttons.map(b=>b.id),['a:more','a:send','a:cancel']);
 r=step(r.state,T('coke item 12'),known);assert.match(r.replies[0].body,/COKE ITEM 12: कितने केस/);
 r=step(r.state,T('५'),known);assert.equal(r.state.cart.length,2);assert.match(r.replies[0].body,/कुल: 15 केस/);
 r=step(r.state,P('a:more'),known);r=step(r.state,P('c:1'),known);r=step(r.state,P('p:COKE ITEM 12'),known);
 assert.match(r.replies[0].body,/अभी 5/);
 r=step(r.state,T('0'),known);assert.deepEqual(r.state.cart.map(c=>c.sku),['THUMS UP 250ML PET']);
});

test('known party: Send submits at once; new customer asked shop first',()=>{
 const base=[T('hi'),P('b:rj'),P('p:RAJNIGANDHA 4G'),T('3')];
 let r=run(known,[...base,P('a:send')]);assert.deepEqual(r.submit,{shop:'',city:''});
 r=run(newc,[...base,P('a:send')]);assert.ok(!r.submit);assert.match(r.replies[0].body,/दुकान का नाम/);
 r=step(r.state,T('Jay Ambe Store, Varachha Surat'),newc);
 assert.deepEqual(r.submit,{shop:'Jay Ambe Store',city:'Varachha Surat'});
 assert.match(doneText(newc,r.state,'W-25'),/W-25[\s\S]*Rajnigandha · 3 केस · 1 प्रोडक्ट/);
});

test('one brand per order; cancel clears; old cart offered back',()=>{
 let r=run(known,[T('hi'),P('b:rj'),P('p:RAJNIGANDHA 4G'),T('3'),P('b:cc')]);
 assert.match(r.replies[0].body,/एक ही ब्रांड/);assert.equal(r.state.brand,'rj');
 r=step(r.state,T('hi'),known);assert.match(r.replies[0].body,/पिछला ऑर्डर/);
 r=step(r.state,P('a:cancel'),known);assert.deepEqual(r.state.cart,[]);assert.match(r.replies[0].body,/रद्द/);
});

test('parseQty and webhook input',()=>{
 assert.equal(parseQty('12'),12);assert.equal(parseQty('12 cs'),12);assert.equal(parseQty('१२ केस'),12);assert.equal(parseQty('1.5'),null);
 assert.deepEqual(inputOf({type:'interactive',interactive:{list_reply:{id:'b:cc'}}}),{kind:'pick',id:'b:cc'});
 assert.deepEqual(inputOf({type:'interactive',interactive:{button_reply:{id:'a:send'}}}),{kind:'pick',id:'a:send'});
 assert.equal(inputOf({type:'reaction'}).kind,'text');
});

test('API bodies keep WhatsApp limits',()=>{
 const r=run(known,[T('hi'),P('b:cc'),P('c:0')]);
 const b=apiBody('919825011111',r.replies[0]);
 assert.equal(b.interactive.type,'list');assert.ok(b.interactive.action.button.length<=20);
 const rows=b.interactive.action.sections.flatMap(s=>s.rows);
 assert.ok(rows.length<=10&&rows.every(x=>x.title.length<=24&&(x.description||'').length<=72));
 const long=apiBody('1',{type:'buttons',body:'x',buttons:[{id:'a',title:'A very long button title here'}]});
 assert.ok(long.interactive.action.buttons[0].reply.title.length<=20);
});
