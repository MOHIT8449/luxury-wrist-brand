// erp-caps.js in a real browser: typed text turns CAPITAL, case-sensitive boxes stay as typed.
// Run: node --test (from this folder).
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
const require=createRequire(import.meta.url);
let chromium;try{({chromium}=require('playwright'))}catch(e){}
const url='file://'+fileURLToPath(new URL('./fixture.html',import.meta.url));

test('typed text in capitals',{skip:!chromium&&'playwright not installed'},async()=>{
  const b=await chromium.launch();const p=await b.newPage();
  try{
    await p.goto(url);
    const type=async(id,t)=>{await p.locator('#'+id).pressSequentially(t);return p.inputValue('#'+id)};
    assert.equal(await type('name','krishna store'),'KRISHNA STORE');
    assert.equal(await p.evaluate(()=>window.seen),'KRISHNA STORE','page handlers see capitals');
    assert.equal(await type('note','shop 4\nring road'),'SHOP 4\nRING ROAD');
    // cursor stays in the middle when editing
    await p.locator('#name').press('Home');await p.keyboard.type('m ');
    assert.equal(await p.inputValue('#name'),'M KRISHNA STORE');
    for(const id of ['pw','em','mail','key','raw','find','q'])assert.equal(await type(id,'abc'),'abc',id+' keeps case');
    assert.equal(await p.locator('#find').evaluate(e=>getComputedStyle(e).textTransform),'uppercase','search shows capitals');
    assert.equal(await p.locator('#q').evaluate(e=>getComputedStyle(e).textTransform),'uppercase');
    await p.fill('#dl','Shree Traders');assert.equal(await p.inputValue('#dl'),'Shree Traders','picked list option kept');
    assert.equal(await type('dl','x'),'SHREE TRADERSX');
    await p.locator('#name').fill('');await p.locator('#name').evaluate(e=>{e.value='';});
    // paste
    await p.locator('#name').evaluate(e=>{e.focus()});await p.keyboard.insertText('paste me');
    assert.equal(await p.inputValue('#name'),'PASTE ME');
  }finally{await b.close()}
});
