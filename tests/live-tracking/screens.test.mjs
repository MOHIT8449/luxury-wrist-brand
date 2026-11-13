// DOM interaction checks with mocked RPCs. No production sessions or writes.
// Layout/real maps and physical Android background behavior require device validation.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {JSDOM} from 'jsdom';
const root=new URL('../../',import.meta.url);
const html=await readFile(new URL('live-tracking.html',root),'utf8');
const inline=[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].at(-1)[1];
function mapStub(){
 const chain=new Proxy({}, {get:(_,key)=>key==='getBounds'?()=>({isValid:()=>true}):()=>chain});
 return {map:()=>chain,tileLayer:()=>chain,layerGroup:()=>chain,marker:()=>chain,circleMarker:()=>chain,polyline:()=>chain,divIcon:()=>chain,circle:()=>chain,latLngBounds:()=>chain};
}
for(const role of ['admin','manager','warehouse','accounts','sales']){
 test(`tracking DOM ${role}: Admin-only access, settings, pins and stale GPS`,async()=>{
  const dom=new JSDOM(html,{url:'https://erp.test/live-tracking.html',runScripts:'outside-only'}),w=dom.window;
  const calls=[],now=new Date().toISOString(),old=new Date(Date.now()-3600e3).toISOString();
  w.L=mapStub();w.ERPShell={toast(){}};
  w.LWBSales={el:id=>w.document.getElementById(id),esc:s=>String(s??''),fmt:n=>String(n),
   start:async()=>({role,realRole:role}),client:{rpc:async name=>{
    calls.push(name);
    if(name==='lwb_location_trail')return {data:{points:[],events:[]}};
    return {data:{can_edit:['admin','manager'].includes(role),now,
     settings:{tracked_roles:['driver'],work_start:'08:00',work_end:'21:00',godown_lat:21.17,godown_lng:72.83,avg_speed_kmph:25,godown_radius_m:200},
     people:[{user_id:'d1',name:'Driver One',role:'driver',mobile:'9876500001',lat:21.18,lng:72.83,accuracy:10,speed:22,status:'ON',updated_at:now},
      {user_id:'d2',name:'Driver Offline',role:'driver',mobile:'9876500002',lat:21.2,lng:72.84,accuracy:10,speed:0,status:'ON',updated_at:old}],
     trips:[{order_id:'o1',order_no:'PO-TEST',party_name:'Test Party',vehicle_no:'GJ05TEST',driver_name:'Driver One',driver_user_id:'d1',party_lat:null,party_lng:null,events:{LEFT_GODOWN:now},report_status:null}],back_godown:{}}};
   }}};
  try{
   w.eval(inline);await new Promise(ok=>setTimeout(ok,30));
   if(role!=='admin'){
    assert.deepEqual(calls,[]);assert.equal(w.document.getElementById('page').hidden,true);
   }else{
    assert.equal(w.document.getElementById('page').hidden,false);
    assert.match(w.document.getElementById('side').textContent,/Driver One/);
    assert.equal(w.document.getElementById('setBtn').hidden,false);
    assert.equal(w.document.querySelectorAll('[data-pin]').length,1);
    w.document.querySelector('[data-tab="staff"]').click();
    assert.match(w.document.getElementById('side').textContent,/Driver Offline/);
    assert.match(w.document.getElementById('side').textContent,/ago|old|offline|stale/i);
    {
     w.document.getElementById('setBtn').click();assert.equal(w.document.getElementById('setCard').hidden,false);
     w.document.getElementById('setClose').click();assert.equal(w.document.getElementById('setCard').hidden,true);
    }
    w.document.getElementById('refresh').click();await new Promise(ok=>setTimeout(ok,10));
    assert.ok(calls.filter(x=>x==='lwb_live_map').length>=2);
   }
  }finally{w.close();}
 });
}
test('shell shows Live Tracking to Admin only, even with page overrides',async()=>{
 const source=await readFile(new URL('erp-shell.js',root),'utf8');
 const dom=new JSDOM('<html><body></body></html>',{url:'https://erp.test/live-tracking.html',runScripts:'outside-only'}),w=dom.window;
 try{
  w.eval(source);const shell=w.ERPShell;
  const flat=(role,extra=[])=>shell.menuFor(role,[],extra).flatMap(g=>g.items).map(i=>i.h);
  assert.ok(flat('admin').includes('live-tracking.html'));
  for(const r of ['manager','warehouse','accounts','driver'])assert.ok(!flat(r,['live-tracking.html']).includes('live-tracking.html'),r);
  assert.ok(!flat('sales',['live-tracking.html','my-sales.html#orders']).includes('live-tracking.html'));
  assert.ok(!flat('sales',['my-sales.html#orders']).includes('my-sales.html#orders'));
 }finally{w.close();}
});
