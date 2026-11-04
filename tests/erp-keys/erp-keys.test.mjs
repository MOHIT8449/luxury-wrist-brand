// erp-keys.js in a real browser (Playwright's Chromium) on a small page: Enter = next field,
// arrows in a list, Enter opens a row, shortcuts, popup focus. Run: node --test (from this folder).
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
const require=createRequire(import.meta.url);
let chromium;try{({chromium}=require('playwright'))}catch(e){}
const url='file://'+fileURLToPath(new URL('./fixture.html',import.meta.url));

test('keyboard first',{skip:!chromium&&'playwright not installed'},async()=>{
  const b=await chromium.launch();const p=await b.newPage();
  try{
  await p.addInitScript(()=>{try{localStorage.setItem('lwbk-tip','1')}catch(e){}});
  await p.goto(url);await p.waitForTimeout(1100);
  p.setDefaultTimeout(5000);
  const id=()=>p.evaluate(()=>document.activeElement.id||document.activeElement.tagName);
  const g=k=>p.evaluate(k=>window[k],k);
  assert.equal(await id(),'q','page search has the cursor at start');
  // search -> Enter -> first row; arrows; Enter opens
  await p.keyboard.press('Enter');assert.equal(await p.evaluate(()=>document.activeElement.textContent.trim()),'A');
  await p.keyboard.press('ArrowDown');await p.keyboard.press('ArrowDown');
  assert.equal(await p.evaluate(()=>document.activeElement.textContent.trim()),'C');
  await p.keyboard.press('ArrowUp');await p.keyboard.press('Enter');assert.equal(await g('opened'),'B');
  // clickable card
  await p.focus('#card');await p.keyboard.press('Enter');assert.equal(await g('card'),1);
  // tab buttons: arrows and Alt+digit
  await p.focus('#t1');await p.keyboard.press('ArrowRight');assert.equal(await id(),'t2');
  await p.keyboard.press('Alt+3');assert.equal(await g('tab'),3);
  // Enter walks the fields, skips read-only, textarea keeps Enter, Ctrl+Enter goes on, last -> Save
  await p.focus('#f1');await p.keyboard.press('Enter');assert.equal(await id(),'f2');
  await p.keyboard.press('Enter');assert.equal(await id(),'f4');
  await p.keyboard.press('Shift+Enter');assert.equal(await id(),'f2');
  await p.focus('#f5');await p.keyboard.press('Enter');assert.equal(await id(),'f5');
  await p.keyboard.press('Control+Enter');assert.equal(await id(),'save');
  await p.keyboard.press('Enter');assert.equal(await g('saved'),1);
  await p.focus('#f1');await p.keyboard.press('Control+s');assert.equal(await g('saved'),2);
  // a real <form>: Enter moves, last field submits as before
  await p.focus('#g1');await p.keyboard.press('Enter');assert.equal(await id(),'g2');
  await p.keyboard.press('Enter');assert.equal(await g('submitted'),1);
  // Alt+N opens the popup, cursor in its first field, Tab stays inside, Esc closes and goes back
  await p.focus('#f4');await p.keyboard.press('Alt+n');await p.waitForTimeout(300);
  assert.equal(await id(),'p1');
  await p.keyboard.press('Tab');await p.keyboard.press('Tab');await p.keyboard.press('Tab');
  assert.equal(await id(),'px','Tab wraps inside the popup');
  await p.keyboard.press('Escape');await p.waitForTimeout(700);
  assert.equal(await p.evaluate(()=>document.getElementById('pop').hidden),true);
  assert.equal(await id(),'f4','cursor back where it was');
  // ? shows the list of keys
  await p.focus('#card');await p.keyboard.press('?');assert.ok(await p.evaluate(()=>!!document.getElementById('lwbk-help')));
  await p.keyboard.press('Escape');assert.ok(await p.evaluate(()=>!document.getElementById('lwbk-help')));
  }finally{await b.close()}
});
