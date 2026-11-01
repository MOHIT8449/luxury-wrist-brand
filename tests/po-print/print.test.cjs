const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync(require('node:path').join(__dirname,'../../warehouse-orders.html'),'utf8');
const printing=source.slice(source.indexOf('let savedPoItemsSignature='),source.indexOf('function warehouseSkuInputMarkup'));
const choice=source.slice(source.indexOf('function poChooseSaved('),source.indexOf('function showPoPicker('));
const fnSource=name=>{const start=source.indexOf('function '+name+'(');return source.slice(start,source.indexOf('\n}\n',start)+3)};
const helpers=fnSource('poNormalPhone')+fnSource('poTransportDirty');
function setup(status='approved'){
 const nodes=new Map();const node=id=>{if(!nodes.has(id))nodes.set(id,{value:'',hidden:false,disabled:false,innerHTML:''});return nodes.get(id)};
 node('postApprovalPanel').hidden=true;node('managerNote').value='';
 const initial={id:'po-1',order_no:'LXY-00009',customer_name:'QA Party',status,manager_note:'',sales_person:'QA User',order_date:'2026-10-30T10:00:00Z'};
 const items=[{id:'item1',sku_name:'QA SKU',ordered_qty:40,approved_qty:40,rate:640,unit_weight:9}];
 const saved=[{...items[0],approved_qty:45,rate:650}];
 const state={alerts:[],prints:0,confirms:0,assignment:null,order:{...initial},saved,queries:[],nodes};
 const db={from(table){let q; q={select(){return q},eq(k,v){state.queries.push([table,k,v]);return q},order(){return q},single(){return q},maybeSingle(){return q},then(ok,bad){return Promise.resolve({data:table==='orders'?state.order:table==='order_items'?state.saved:state.assignment,error:null}).then(ok,bad)}};return q}};
 const context={db,document:{getElementById:node,body:{appendChild(){}}},window:{print(){state.prints++}},alert(t){state.alerts.push(t)},async confirm(){state.confirms++;return false},reviewOrder:async()=>{},reviewReady:true,selectedOrder:initial,selectedItems:items,approvedTransport:null,managerNoteOriginal:'',managerNoteSaving:false,eligibleForPoPrint:o=>['approved','loading','loaded'].includes(o?.status),isCancelled:o=>['cancelled','rejected'].includes(o?.status),number:v=>Number(v)||0,escapeHtml:v=>String(v).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;'),formatDateTime:v=>v==='2026-10-30T10:00:00Z'?'30/10/2026, 03:30 PM':'01/11/2026, 04:10 PM',amountInWords:()=>'',poValue:id=>node(id).value.trim(),closePoPicker(){},poSavedDrivers:[],poSavedVehicles:[],poNormalPlate:v=>String(v||''),openTransportAllocation(){}};
 vm.createContext(context);vm.runInContext(helpers+printing+'\n'+choice+'\nsavedPoItemsSignature=poItemsSignature(selectedItems);',context);
 return {state,context,node};
}
test('PO prints latest saved SKU quantities/rates, with no transport assignment required',async()=>{
 const {state,context,node}=setup();await context.printApprovedPO('po');assert.equal(state.prints,1);assert.equal(state.confirms,0);const html=node('poPrintArea').innerHTML;assert.match(html,/PO INVOICE/);assert.doesNotMatch(html,/Luxury Wrist Brand|LUXURY WRIST BRAND/i);assert.match(html,/30\/10, 03:30 PM/);assert.doesNotMatch(html,/30\/10\/2026/);assert.equal(node('poPrintArea').className,'po-a5');assert.match(html,/<th>Loaded<\/th>/);assert.doesNotMatch(html,/Unit Wt|Total Wt|Prepared By|Driver Mobile|Printed/);assert.match(html,/Total Weight<\/label><b>405.00 KG/);assert.doesNotMatch(html,/approved\)/);assert.equal((html.match(/class='pa-tick'/g)||[]).length,1);assert.match(html,/29,250.00/);assert.match(html,/>45</);assert.doesNotMatch(html,/25,?600.00/);assert.ok(state.queries.every(q=>q[2]==='po-1'));assert.equal(node('printPoDocumentBtn').disabled,false);
});
test('pending PO prints as pending, while delivery challan still requires approval',async()=>{
 const {state,context,node}=setup('pending_approval');await context.printApprovedPO('po');assert.equal(state.prints,1);assert.match(node('poPrintArea').innerHTML,/pending_approval/);await context.printApprovedPO();assert.equal(state.prints,1);assert.match(state.alerts[0],/Approve the PO/);
});
test('unsaved SKU, manager note and transport updates block printing',async()=>{
 for(const kind of ['sku','note','transport']){const {state,context,node}=setup();if(kind==='sku')context.selectedItems[0].rate=999;if(kind==='note')node('managerNote').value='Unsaved';if(kind==='transport'){node('postApprovalPanel').hidden=false;node('poDriverName').value='New Driver'}await context.printApprovedPO('po');assert.equal(state.prints,0);assert.match(state.alerts[0],/unsaved changes|unsaved SKU/)}
});
test('latest cancellation blocks print and saved notes are escaped',async()=>{
 const {state,context,node}=setup();state.order.status='cancelled';await context.printApprovedPO('po');assert.equal(state.prints,0);state.order.status='approved';state.order.manager_note='<script>unsafe</script>';await context.printApprovedPO('po');assert.equal(state.prints,1);assert.match(node('poPrintArea').innerHTML,/&lt;script&gt;/);assert.doesNotMatch(node('poPrintArea').innerHTML,/<script>/);
});
test('selecting driver fills mobile and available default vehicle/transport',()=>{
 const {context,node}=setup();context.poChooseSaved('driver',{name:'QA Driver',mobile:'9999999999',vehicle:'GJ05AA1234',transporter:'QA Transport'});assert.equal(node('poDriverMobile').value,'9999999999');assert.equal(node('poVehicleNo').value,'GJ05AA1234');assert.equal(node('poTransportName').value,'QA Transport');
});
