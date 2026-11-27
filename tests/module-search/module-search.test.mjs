// Module Search (Mohit, 27 Nov 2026): "ledger" / Hindi words open Ledger & Outstanding first,
// and the top-bar Ledger button goes to the page this role may open. Run: node --test (from this folder).
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
const require=createRequire(import.meta.url);
let chromium;try{({chromium}=require('playwright'))}catch(e){}
const url='file://'+fileURLToPath(new URL('./fixture.html',import.meta.url));

test('ledger search and button',{skip:!chromium&&'playwright not installed'},async()=>{
  const b=await chromium.launch();
  try{
    const cases=[["admin","ledger","Ledger & Outstanding","accounts-books.html"],["accounts","लेजर","Ledger & Outstanding","accounts-books.html"],
      ["accounts","khata","Ledger & Outstanding","accounts-books.html"],["manager","ledger","Outstanding & Ledger","sales-outstanding.html"],
      ["manager","बकाया","Outstanding & Ledger","sales-outstanding.html"]];
    for(const [role,q,first,href] of cases){
      const p=await b.newPage({viewport:{width:1300,height:700}});
      await p.route(/supabase\.co/,r=>r.abort());
      await p.goto(url+'?role='+role);await p.waitForTimeout(500);
      const top=await p.evaluate(q=>{const m=ERPShell.menuForMe(new URLSearchParams(location.search).get("role")).flatMap(g=>g.items.map(i=>({...i,g:g.group})));return (ERPShell.findModules(m,q)[0]||{}).t},q);
      assert.equal(top,first,role+' '+q);
      assert.equal(await p.getAttribute('.erp-ledger-btn','href'),href,role+' button');
      await p.close();
    }
    const p=await b.newPage();await p.route(/supabase\.co/,r=>r.abort());
    await p.goto(url+'?role=sales');await p.waitForTimeout(500);
    assert.equal(await p.$('.erp-ledger-btn'),null,'salesman: no Ledger button');
  }finally{await b.close()}
});
