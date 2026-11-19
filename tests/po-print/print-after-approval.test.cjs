// Print PO opens once the PO is approved; no transport / loading needed (Mohit, 19 Nov 2026).
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync(require('node:path').join(__dirname,'../../warehouse-orders.html'),'utf8');
const fnSource=name=>{const start=source.indexOf('function '+name+'(');assert.ok(start>=0,name);return source.slice(start,source.indexOf('\n}\n',start)+3)};
const ctx={alerts:[],alert(t){ctx.alerts.push(t)},
  normalizedStatus:o=>String(o?.status||'').toLowerCase(),
  isCancelled:o=>['cancelled','rejected'].includes(o?.status),
  isDeliveredOrder:o=>o?.status==='delivered',
  isPending:o=>['pending','pending_approval',''].includes(o?.status),
  isApproved:o=>['approved','manager_approved','warehouse_approved'].includes(o?.status),
  isSelfPickup:o=>!!o?.self};
vm.createContext(ctx);
vm.runInContext(['orderStage','poPrintAllowed','poPrintBlocked','printAllowed'].map(fnSource).join('\n'),ctx);
test('Print PO opens right after approval, without transport or loading',()=>{
  for(const s of ['approved','manager_approved','transport_allocated','loading','loaded','delivered'])
    assert.equal(ctx.poPrintAllowed({status:s}),true,s);
});
test('Print PO stays closed before approval and for cancelled POs',()=>{
  for(const s of ['pending_approval','pending','cancelled','rejected'])
    assert.equal(ctx.poPrintAllowed({status:s}),false,s);
  assert.equal(ctx.poPrintBlocked({status:'pending_approval',order_no:'LXY-1'}),true);
  assert.match(ctx.alerts.at(-1),/LXY-1: Print PO opens once the PO is approved/);
});
test('Challan / Bill keep the transport rule',()=>{
  assert.equal(ctx.printAllowed({status:'approved'}),false);
  assert.equal(ctx.printAllowed({status:'transport_allocated'}),true);
});
