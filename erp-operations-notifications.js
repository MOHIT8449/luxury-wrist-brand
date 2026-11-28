/* LUXURY WRIST BRAND | Staff ERP Notifications
 * Supabase RLS restricts access to the logged-in user's own notifications.
 */
(function(){
 "use strict";
 function el(tag,cls,value){
  const x=document.createElement(tag);
  if(cls)x.className=cls;
  if(value!==undefined)x.textContent=String(value);
  return x;
 }
 // One format for every notification, every role:
 //   line 1  icon · what happened · [action pill]                 time  ✓
 //   line 2  party name                                            ₹ value
 //   line 3  order no · cases · vehicle · cash / due · by whom
 // CC_<type> = Sales Head copy of another login's notification: same text and page, never a popup.
 const baseType=n=>String(n.notification_type||"").toUpperCase().replace(/^CC_/,"");
 const num=s=>Number(String(s||"").replace(/,/g,""));
 const inr=v=>"₹"+Number(v).toLocaleString("en-IN",{minimumFractionDigits:v%1?2:0,maximumFractionDigits:2});
 // tone: act = needs you · move = dispatch · money = cash · ok = done · bad = cancel/reject · info = update
 const KIND=[
  [/^ORDER_NEW$/,"🛒","act","New order","Approve"],
  [/^ORDER_DELAY_DELIVERY$/,"⚠","bad","Delivery late 36h+","Deliver"],
  [/^ORDER_DELAY_APPROVAL$/,"⚠","act","Approval late 12h+","Approve"],
  [/^ORDER_APPROVED$/,"✅","ok","PO approved",""],
  [/^ORDER_LOADED$/,"📦","info","Loaded",""],
  [/^ORDER_DISPATCHED$/,"🚚","move","Out for delivery",""],
  [/^TALLY_BILL_PENDING$/,"🧾","act","Vehicle loaded","Make bill"],
  [/^PO_APPROVED_BILL$/,"🧾","act","PO approved","Make bill"],
  [/^PO_APPROVED_LOADING$/,"📦","act","PO approved","Get ready"],
  [/^TALLY_BILL_DONE$/,"🧾","ok","Bill made",""],
  [/^VEHICLE_LOADED$/,"🚛","move","Vehicle loaded",""],
  [/^LOADING_ASSIGNMENT/,"🚚","move","Vehicle assigned",""],
  [/^ORDER_DELIVERED$/,"✅","ok","Delivered",""],
  [/^ORDER_PARTIAL$/,"🟠","info","Part delivered",""],
  [/^ORDER_NOT_DELIVERED$/,"⚠","bad","Not delivered",""],
  [/^ORDER_CANCELLED$/,"✖","bad","Order cancelled",""],
  [/^ORDER_EDITED$/,"✏","info","Order changed",""],
  [/^DELIVERY_COLLECTION$/,"💰","act","Cash collected","Verify"],
  [/^DELIVERY_COLLECTION_INFO$/,"💰","money","Cash collected",""],
  [/^DELIVERY_COLLECTION_RECEIVED$/,"✅","money","Payment received",""],
  [/^DELIVERY_COLLECTION_VERIFIED$/,"✅","money","Payment verified",""],
  [/^DELIVERY_COLLECTION_/,"❌","bad","Payment rejected",""],
  [/^RETURN_CHECKED$/,"📦","info","Return checked",""],
  [/^DELIVERY_RETURN_INFO$/,"↩","info","Return taken",""],
  [/^DELIVERY_RETURN_RECEIVE$/,"📦","act","Return goods","Receive"],
  [/^DELIVERY_RETURN_DEDUCTED$/,"↩","info","Return cut",""],
  [/^DELIVERY_RETURN_APPROVED$/,"✅","ok","Return approved",""],
  [/^DELIVERY_RETURN_REJECTED$/,"❌","bad","Return rejected",""],
  [/^DELIVERY_RETURN_OPERATIONS$/,"↩","act","Return","Check"],
  [/^DELIVERY_RETURN/,"↩","act","Return","Verify"],
  [/^SALES_RETURN_NEW$/,"↩","act","Sales return","Credit note"],
  [/^TALLY_NOTE_.*DEBIT$/,"📝","info","Debit note",""],
  [/^TALLY_NOTE_/,"📝","info","Credit note",""],
  [/^BILL_CHANGE_APPROVAL$/,"✏","act","PO change","Approve"],
  [/^BILL_CHANGE_APPROVED$/,"✅","ok","PO change approved",""],
  [/^BILL_CHANGE_SENT_BACK$/,"↩","bad","PO change sent back",""],
  [/^(PO_)?RATE_APPROVAL$/,"₹","act","Rate below min","Approve"],
  [/^(PO_)?RATE_APPROVED$/,"✅","ok","Rate approved",""],
  [/^ORDER_RATE_CHECK$/,"⚠","act","Please check order","Check"],
  [/^STOCK_MOVE_PENDING$/,"📦","act","Stock transfer","Approve"],
  [/^STOCK_MOVE_APPROVED$/,"✅","ok","Stock transfer approved",""],
  [/^STOCK_MOVE_REJECTED$/,"❌","bad","Stock transfer rejected",""],
  [/^STOCK_AUDIT_OK$/,"✅","ok","Stock check OK",""],
  [/^STOCK_AUDIT_/,"🌙","act","Stock check",""],
  [/^GODOWN_/,"🏭","info","",""],
  [/^PURCHASE_ARRIVED$/,"🚛","act","Purchase vehicle arrived","Check"],
  [/^PURCHASE_DAMAGE$/,"⚠","bad","Purchase damage","View"],
  [/^PURCHASE_CHECK_OK$/,"✅","ok","Purchase vehicle OK",""],
  [/^PURCHASE_MISSING$/,"🧾","bad","Purchase bills missing","Enter"],
  [/^HIRED_RATE_VERIFY$/,"🚚","act","Trip rent","Verify"],
  [/^HIRED_RATE_SENT_BACK$/,"↩","bad","Trip rent sent back","Set again"],
  [/^PARTY_CREATED$/,"👤","act","New party added","Check"],
  [/^ACC_BANK_VERIFY$/,"🏦","act","Bank entry","Verify"],
  [/^ACC_BANK_REJECTED$/,"❌","bad","Bank entry rejected",""],
  [/^ACC_CASH_HANDOVER$/,"💵","act","Cash handover","Check"],
  [/^ACC_CASH_RETURNED$/,"✅","money","Cash returned",""],
  [/^ACC_CASH_DIFF$/,"⚠","bad","Cash difference",""],
  [/^ACC_CHEQUE/,"🧾","act","Cheque","Deposit"],
  [/^DOC_SHARE_OPENED$/,"📁","ok","Documents opened",""],
  [/^DOC_GST_DUE$/,"📊","act","GST return due","File"],
  [/^DOC_/,"📁","act","Document renewal","Renew"],
  [/^ACC_/,"₹","info","",""],
  [/^MARKET_REPORT$/,"🚩","info","Outside stock",""],
  [/^MARKET_REVIEW$/,"✅","ok","",""],
  [/^COMPLAINT_(RESOLVED|CLOSED)$/,"✅","ok","",""],
  [/^COMPLAINT_NEW$/,"📮","act","",""],
  [/^COMPLAINT_/,"💬","info","",""],
  [/^TASK_DONE$/,"✅","ok","",""],
  [/^TASK_(OVERDUE|CANCELLED)$/,"⚠","bad","",""],
  [/^TASK_/,"📋","act","",""],
  [/^RECEIPT_EDIT_ASK$/,"✏️","act","Old cash payment change","Approve"],
  [/^RECEIPT_EDIT_DONE$/,"✏️","ok","Old cash payment changed",""],
  [/^RECEIPT_EDIT_REJECT$/,"✏️","bad","Payment change rejected",""],
  [/^LABOUR_EXTRA$/,"👷","act","Labour extra cash","Approve"],
  [/^LABOUR_EXTRA_DONE$/,"👷","ok","Labour extra",""],
  [/^LABOUR_/,"👷","info","Daily labour",""],
  [/^ANNOUNCEMENT$/,"📢","info","",""],
  [/^SALES_PLAN$/,"📋","info","Today's plan",""],
  [/^PAYMENT_FOLLOWUP$/,"₹","act","Payment follow-up","Collect"],
  [/^BILL_TYPE_ASK$/,"🧾","act","GST or Cash bill?","Choose"],
  [/^BILL_TYPE_CHANGED$/,"🧾","info","Bill type changed",""],
  [/^BILL_TYPE_MISMATCH$/,"⚠","bad","GST / Cash mismatch","Check"]
 ];
 // Type of every notification (Mohit, 18 Nov 2026: "which notification is this?" must be clear at a glance).
 // Each type has its own colour, icon tile and filter tab in the bell.
 const CATS={
  order:{tab:"Orders",tag:"Order"},
  delivery:{tab:"Delivery",tag:"Delivery"},
  money:{tab:"Money",tag:"Payment"},
  stock:{tab:"Stock",tag:"Stock"},
  task:{tab:"Tasks",tag:"Task"},
  other:{tab:"Other",tag:"Update"}
 };
 const CAT_OF=[
  [/^(TASK_|COMPLAINT_|SALES_PLAN$|ANNOUNCEMENT$)/,"task"],
  [/^(DELIVERY_COLLECTION|ACC_|HIRED_RATE_|TALLY_NOTE_|PAYMENT_FOLLOWUP|LABOUR_|RECEIPT_EDIT_|BILL_TYPE_MISMATCH)/,"money"],
  [/^BILL_TYPE_/,"order"],
  [/^(ORDER_LOADED|ORDER_DISPATCHED|ORDER_DELIVERED|ORDER_PARTIAL|ORDER_NOT_DELIVERED|VEHICLE_LOADED|LOADING_ASSIGNMENT|TALLY_BILL_PENDING|PO_APPROVED_LOADING|DELIVERY_RETURN|RETURN_CHECKED)/,"delivery"],
  [/^(STOCK_|GODOWN_|PURCHASE_|MARKET_)/,"stock"],
  [/^(ORDER_|PO_|RATE_|BILL_CHANGE_|TALLY_BILL_|SALES_RETURN)/,"order"]
 ];
 const catOf=t=>(CAT_OF.find(r=>r[0].test(t))||[0,"other"])[1];
 // Line icons (24 x 24, stroke) in place of emoji: the same look on every phone.
 const ICON={
  cart:'<circle cx="8" cy="21" r="1"/><circle cx="19" cy="21" r="1"/><path d="M2.05 2.05h2l2.66 12.42a2 2 0 0 0 2 1.58h9.78a2 2 0 0 0 1.95-1.57l1.65-7.43H5.12"/>',
  check:'<circle cx="12" cy="12" r="9"/><path d="m8 12 3 3 5-6"/>',
  truck:'<path d="M14 18V6a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v11a1 1 0 0 0 1 1h2"/><path d="M15 18H9"/><path d="M19 18h2a1 1 0 0 0 1-1v-3.65a1 1 0 0 0-.22-.62L18.3 9.38a1 1 0 0 0-.78-.38H14"/><circle cx="17" cy="18" r="2"/><circle cx="7" cy="18" r="2"/>',
  bill:'<path d="M4 2v20l2-1 2 1 2-1 2 1 2-1 2 1 2-1 2 1V2l-2 1-2-1-2 1-2-1-2 1-2-1-2 1Z"/><path d="M8 7h8M8 11h8M8 15h5"/>',
  box:'<path d="M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z"/><path d="m3.3 7 8.7 5 8.7-5"/><path d="M12 22V12"/>',
  alert:'<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
  x:'<circle cx="12" cy="12" r="9"/><path d="m15 9-6 6M9 9l6 6"/>',
  edit:'<path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"/>',
  cash:'<rect width="20" height="12" x="2" y="6" rx="2"/><circle cx="12" cy="12" r="2"/><path d="M6 12h.01M18 12h.01"/>',
  back:'<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/>',
  note:'<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M16 13H8M16 17H8"/>',
  rupee:'<path d="M6 3h12M6 8h12M6 13l8.5 8M6 13h3a5 5 0 0 0 0-10"/>',
  moon:'<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>',
  store:'<path d="M22 8.35V20a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V8.35A2 2 0 0 1 3.26 6.5l8-3.2a2 2 0 0 1 1.48 0l8 3.2A2 2 0 0 1 22 8.35Z"/><path d="M6 18h12M6 14h12"/>',
  user:'<path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/>',
  bank:'<path d="M3 22h18M6 18v-7M10 18v-7M14 18v-7M18 18v-7M12 2l8 5H4Z"/>',
  folder:'<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>',
  chart:'<path d="M3 3v18h18"/><path d="M18 17V9M13 17V5M8 17v-3"/>',
  flag:'<path d="M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z"/><path d="M4 22v-7"/>',
  inbox:'<path d="M22 12h-6l-2 3h-4l-2-3H2"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>',
  chat:'<path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/>',
  task:'<rect width="8" height="4" x="8" y="2" rx="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><path d="m9 14 2 2 4-4"/>',
  speaker:'<path d="m3 11 18-5v12L3 14v-3z"/><path d="M11.6 16.8a3 3 0 1 1-5.8-1.6"/>',
  dot:'<circle cx="12" cy="12" r="4"/>'
 };
 const EMOJI_ICON={"🛒":"cart","✅":"check","🚚":"truck","🚛":"truck","🧾":"bill","📦":"box","🟠":"alert","⚠":"alert","✖":"x","❌":"x","✏":"edit","💰":"cash","💵":"cash","↩":"back","📝":"note","₹":"rupee","🌙":"moon","🏭":"store","👤":"user","🏦":"bank","📁":"folder","📊":"chart","🚩":"flag","📮":"inbox","💬":"chat","📋":"task","📢":"speaker","👷":"user"};
 const svg=e=>'<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'+(ICON[EMOJI_ICON[e]]||ICON.dot)+'</svg>';
 function dayOf(v){
  const d=new Date(v),t=new Date();t.setHours(0,0,0,0);
  if(d>=t)return "Today";
  if(d>=new Date(t-864e5))return "Yesterday";
  return window.LWBDate?LWBDate.d(v):d.toLocaleDateString("en-IN");
 }
 // ord = this notification's order row (party, value), when this login can read it.
 function summary(n,ord){
  const t=baseType(n),m=String(n.message||"").replace(/\s+/g," ").trim(),title=String(n.title||"").trim();
  const k=KIND.find(r=>r[0].test(t))||[null,"•","info","",""];
  let [,icon,tone,head,action]=k;
  if(/URGENT/i.test(title)&&tone!=="ok")tone="bad";
  if(!head)head=title.replace(/^URGENT · /i,"").replace(/^Godown: /,"Godown · ")||"ERP update";
  if(/^LOADING_ASSIGNMENT/.test(t)&&/updated|changed|badla/i.test(title))head="Vehicle changed";
  if(t==="VEHICLE_LOADED"&&/differs/i.test(title)){head="Loaded ≠ bill";tone="act";action="Check"}
  const ref=(m.match(/\b[A-Z]{2,6}-\d{3,}\b/)||m.match(/\b(?:STM|AUD|GDN|MKT|CMP|TSK)-\d+\b/)||[])[0]||ord?.order_no||"";
  // Party: order row first; else "LXY-1 · PARTY · …" or "… on LXY-1 (PARTY): …".
  let party=String(ord?.customer_name||"").trim();
  const seg=m.split(" · ").map(s=>s.trim());
  const isOrder=!!n.order_id&&/^[A-Z]{2,6}-\d{3,}$/.test(ref);
  if(!party&&isOrder&&seg[0]===ref&&seg[1]&&!/^(Vehicle|Rs|₹|By |Driver|\d)/i.test(seg[1]))party=seg[1].replace(/\..*$/,"").replace(/ (?:delivered|loaded|cancelled|by|on|from)\b.*$/i,"").trim();
  if(!party&&isOrder)party=((m.match(/[A-Z]{2,6}-\d{3,} \(([^)]+)\)/)||[])[1]||"").trim();
  // Value: the main ₹ figure of the message (order / loaded / collected value), else the order total.
  let amount="";
  const delta=t.startsWith("BILL_CHANGE_")&&(m.match(/([+-])\s?Rs\.? ?([\d,]+(?:\.\d+)?)/)||null);
  if(delta)amount=delta[1]+inr(num(delta[2]));
  else{const a=(m.match(/(?:Rs\.?|₹)\s?([\d,]+(?:\.\d+)?)/i)||[])[1];
   if(a)amount=inr(num(a));else if(ord?.total_amount!=null&&/^(ORDER_|PO_|LOADING|VEHICLE|TALLY_BILL)/.test(t))amount=inr(Number(ord.total_amount))}
  const d=[];
  if(ref)d.push(ref);
  const qty=(m.match(/\b(\d[\d,]*)\s?(?:CS|cases)\b/i)||[])[1];if(qty)d.push(num(qty)+" CS");
  const veh=(m.match(/Vehicle ([A-Z0-9]{5,})/)||[])[1];if(veh)d.push("🚛 "+veh);
  const drv=((m.match(/Driver ([^(·.]+)/)||[])[1]||"").trim();if(drv&&/^LOADING/.test(t))d.push("Driver "+drv);
  const cash=(m.match(/Cash Rs\.? ?([\d,]+(?:\.\d+)?)/i)||[])[1];if(cash)d.push("Cash "+inr(num(cash)));
  const onl=m.match(/\+ ([A-Za-z]+) Rs\.? ?([\d,]+(?:\.\d+)?)/);if(onl)d.push(onl[1].toUpperCase()+" "+inr(num(onl[2])));
  if(/nothing paid/i.test(m))d.push("Nothing paid");
  const due=(m.match(/Outstanding Rs\.? ?([\d,]+(?:\.\d+)?)/i)||[])[1];if(num(due)>0)d.push("Due "+inr(num(due)));
  const why=((m.match(/Reason: ([^.]+)/i)||[])[1]||"").trim();if(why&&!/^not given$/i.test(why))d.push("Reason: "+why);
  if(t==="SALES_PLAN"){const p=(m.match(/from (\d+) part/)||[])[1];if(p)d.push(p+" parties due")}
  // Who did it: "By X", "Loaded by X", or "X on LXY-1 (…)" (driver collection).
  let by=((m.match(/\b(?:by|By) ([A-Za-z][^·.()\d:]{1,30})/)||[])[1]||"").trim();
  if(!by&&/^DELIVERY_COLLECTION$/.test(t))by=((m.match(/^([^·(:]{2,30}?) on [A-Z]{2,6}-\d/)||[])[1]||"").trim();
  if(!by&&ord?.sales_person&&t==="ORDER_NEW")by=ord.sales_person;
  if(by)d.push("By "+by);
  // Purchase vehicle (lwb_purchase_damage_report_setup.sql): "Vehicle X · SUPPLIER · Inv N · 15 CS. lines…"
  if(/^PURCHASE_/.test(t)){
   const p=m.split(". ")[0].split(" · "),inv=(p.find(s=>/^Inv /.test(s))||""),cs=(p.find(s=>/ CS$/.test(s))||""),v=(p[0]||"").replace(/^Vehicle /,"");
   const dd=[inv,cs,v?"🚛 "+v:"",p.find(s=>/^In \d/.test(s))||"",p.find(s=>/^Out \d/.test(s))||""].filter(Boolean),lines=t==="PURCHASE_DAMAGE"?(m.split(". ")[1]||""):"";
   if(lines)dd.push(lines);if(by)dd.push("By "+by);
   const dc=t==="PURCHASE_DAMAGE"?((title.match(/([\d.,]+) CS/)||[])[1]||""):"";
   return {icon,tone,head,action,line2:p[1]||"Purchase bill",isParty:true,amount:dc?dc+" CS":"",details:dd,cat:"stock"};
  }
  // No party (tasks, banners, accounts…): show the message itself on line 2.
  let line2=party;
  if(!line2){
   line2=seg.filter(s=>s!==ref).join(" · ").replace(/\b(?:STM|AUD|GDN|MKT|CMP|TSK)-\d+\b/g,"").replace(/^[\s·:,-]+/,"");
   line2=line2.split(/\. (?=[A-Z])/)[0].replace(/\.$/,"");
   if(line2.length>70)line2=line2.slice(0,67)+"…";
  }
  // Trip rent: "GJ16AW2503 → PARTY (CITY): ₹1700 per trip" → party on line 2, vehicle + rate on line 3.
  if(/^HIRED_RATE_/.test(t)){const h=m.match(/^([A-Z0-9]{5,}) → ([^:]+):\s*(.*)$/);
   if(h){const rate=(h[3].match(/₹\s?([\d.,]+) per trip/)||[])[1];
    return {icon,tone,head,action,line2:h[2].trim(),isParty:true,amount:rate?inr(num(rate)):amount,
     details:["🚛 "+h[1],rate?"per trip":h[3].replace(/\. Set it again.*$/,"").replace(/\. Vehicle Master.*$/,"")].filter(Boolean),cat:"money"}}}
  if(/^ACC_CHEQUE/.test(t)){const c=(m.match(/To deposit: (\d+)/)||[])[1];if(c)line2=c+(c==="1"?" cheque":" cheques")+" to deposit"}
  return {icon,tone,head,action,line2,isParty:!!party,amount,details:d,cat:catOf(t)};
 }
 function ago(v){
  if(!v)return "";
  const s=(Date.now()-new Date(v))/1000;
  if(s<60)return "now";if(s<3600)return Math.floor(s/60)+" min";if(s<86400)return Math.floor(s/3600)+" hr";
  if(s<7*86400)return Math.floor(s/86400)+" d";
  return LWBDate.d(v);
 }
 // Page each notification opens. {o} = the notification's order id. The first page this login can open wins.
 const ROUTES=[
  [/^(TALLY_BILL_PENDING|PO_APPROVED_BILL)$/,["party-billing.html?order={o}"]],
  [/^BILL_TYPE_ASK$/,["warehouse-orders.html?order={o}"]],
  [/^BILL_TYPE_CHANGED$/,["party-billing.html?order={o}","warehouse-orders.html?order={o}"]],
  [/^BILL_TYPE_MISMATCH$/,["party-billing.html?tab=bt","warehouse-orders.html?order={o}"]],
  // Sales Head "Tell Accounts" (lwb_sales_head_outstanding_setup.sql): Party & Collections > To collect; Cashier: Cashier view.
  [/^PAYMENT_FOLLOWUP$/,["party-billing.html#party","accounts-dashboard.html#cash","accounts-books.html?v=out"]],
  [/^PO_APPROVED_LOADING$/,["loading-dispatch.html?order={o}","warehouse-orders.html"]],
  [/^(VEHICLE_LOADED|TALLY_BILL_DONE)$/,["loading-dispatch.html","party-billing.html?order={o}","warehouse-orders.html","driver-delivery.html?order={o}","my-sales.html#orders"]],
  [/^ORDER_NEW$/,["warehouse-orders.html"]],
  [/^ORDER_DELAY_DELIVERY$/,["warehouse-orders.html?late=delivery"]],
  [/^ORDER_DELAY_APPROVAL$/,["warehouse-orders.html?late=approval"]],
  [/^RATE_APPROVAL$/,["quick-slip.html?review={o}"]],
  [/^BILL_CHANGE_/,["party-billing.html?tab=chg&change={o}"]],
  [/^RATE_APPROVED$/,["quick-slip.html?order={o}"]],
  [/^PO_RATE_APPROVAL$/,["warehouse-orders.html?rate={o}"]],
  [/^ORDER_RATE_CHECK$/,["approvals.html#market","warehouse-orders.html?order={o}"]],
  [/^PO_RATE_APPROVED$/,["warehouse-orders.html?order={o}","my-sales.html#orders"]],
  [/^DELIVERY_COLLECTION_(INFO|RECEIVED)$/,["driver-collections.html?order={o}","my-sales.html#orders","loading-dispatch.html"]],
  [/^RETURN_CHECKED$/,["driver-returns.html?order={o}","my-sales.html#orders"]],
  [/^DELIVERY_RETURN_INFO$/,["driver-returns.html?order={o}","my-sales.html#orders"]],
  [/^TALLY_NOTE_/,["accounts-invoice.html?order={o}"]],
  [/^SALES_RETURN_NEW$/,["sales-return.html","accounts-invoice.html?order={o}","credit-note.html"]],
  [/^DELIVERY_RETURN_(PENDING|OPERATIONS|RECEIVE|DEDUCTED)$/,["driver-returns.html?order={o}"]],
  [/^DELIVERY_COLLECTION$/,["driver-collections.html?order={o}"]],
  [/^DELIVERY_COLLECTION_/,["driver-delivery.html?order={o}&tab=deliver"]],
  [/^DELIVERY_RETURN_/,["driver-delivery.html?order={o}&tab=return"]],
  [/^LOADING_ASSIGNMENT_DRIVER$/,["driver-delivery.html?order={o}","loading-dispatch.html","transport-allocation.html"]],
  [/^LOADING_ASSIGNMENT/,["loading-dispatch.html?order={o}","transport-allocation.html"]],
  [/^HIRED_RATE_/,["fleet-master.html#rates"]],
  [/^PARTY_CREATED$/,["customer-master.html"]],
  [/^RECEIPT_EDIT_ASK$/,["approvals.html","accounts-books.html"]],
  [/^RECEIPT_EDIT_/,["accounts-dashboard.html","accounts-books.html"]],
  [/^LABOUR_EXTRA$/,["approvals.html","labour.html"]],
  [/^LABOUR_/,["labour.html"]],
  [/^GODOWN_/,["godown-report.html"]],
  [/^PURCHASE_MISSING$/,["purchase-register.html?missing=1"]],
  [/^PURCHASE_ARRIVED$/,["purchase-register.html?bill={r}"]],
  [/^PURCHASE_/,["purchase-register.html?report={r}"]],
  [/^STOCK_AUDIT_/,["stock-audit.html"]],
  [/^STOCK_MOVE_PENDING$/,["stock-transfer.html#approvals"]],
  [/^STOCK_MOVE_/,["stock-transfer.html#history"]],
  [/^ACC_BANK_VERIFY$/,["accounts-dashboard.html#verify"]],
  [/^ACC_CHEQUE/,["accounts-dashboard.html#cheques"]],
  [/^DOC_/,["documents.html"]],
  [/^ACC_/,["accounts-dashboard.html"]],
  [/^MARKET_/,["market-report.html"]],
  [/^COMPLAINT_/,["complaint-box.html?id={c}"]],
  [/^TASK_/,["tasks.html?id={t}"]],
  [/^SALES_PLAN$/,["my-sales.html","sales-team.html"]],
  [/^ORDER_/,["my-sales.html#orders","warehouse-orders.html","driver-delivery.html?order={o}","loading-dispatch.html"]]
 ];
 function route(n,pages){
  const t=baseType(n),hit=ROUTES.find(r=>r[0].test(t));
  if(!hit)return "";
  const base=h=>h.split(/[?#]/)[0];
  const href=(pages&&pages.length?hit[1].find(h=>pages.includes(base(h))):hit[1][0])||"";
  // {c} = complaint no. from "CMP-12" in the message.
  if(href.includes("{c}")){const c=(String(n.message||"").match(/CMP-(\d+)/)||[])[1];return c?href.replace("{c}",c):href.split("?")[0]}
  // {t} = task no. from "TSK-12" in the message.
  if(href.includes("{r}"))return n.ref_id?href.replace("{r}",encodeURIComponent(n.ref_id)):href.split("?")[0];
  if(href.includes("{t}")){const c=(String(n.message||"").match(/TSK-(\d+)/)||[])[1];return c?href.replace("{t}",c):href.split("?")[0]}
  return n.order_id?href.replace("{o}",encodeURIComponent(n.order_id)):href.split("?")[0];
 }
 // New rows: bell count + a small popup with its own sound (erp-notify-popup.js); no dialog blocks entry.
 function init({db,user,mount,pages,role}){
  if(!db||!user?.id||!mount)return;
  // One bell per page. If a page put it in its old (now hidden) header, move it to the ERP top bar.
  const old=document.getElementById("lwbOpsBell");
  if(old){if(mount.closest&&mount.closest(".erp-top")&&!old.closest(".erp-top"))mount.prepend(old.parentElement);return}
  const css=el("style");
  css.textContent=[
   ".lwb-op-wrap{position:relative;display:inline-flex;align-items:center}",
   ".lwb-op-bell{background:#ffdc67!important;color:#382900!important;border:1px solid #e6af22!important;border-radius:8px!important;min-width:45px;min-height:39px;font-size:18px!important;position:relative;cursor:pointer}",
   ".lwb-op-count{position:absolute;top:-9px;right:-7px;background:#c72a38;color:#fff;font-size:11px;padding:2px 5px;border-radius:12px;display:none;min-width:18px}",
   ".lwb-op-panel{position:absolute;top:calc(100% + 9px);right:0;z-index:99999;width:min(470px,94vw);max-height:calc(100vh - 90px);overflow-y:auto;overscroll-behavior:contain;background:#f4f6f9;color:#1f2a37;border:1px solid #dde3ea;border-radius:14px;box-shadow:0 16px 40px rgba(16,24,40,.22);padding:0;font:13px/1.4 'Segoe UI',Roboto,Arial,sans-serif;white-space:normal;text-align:left}",
   ".lwb-op-panel[hidden]{display:none}",
   ".lwb-op-head{position:sticky;top:0;z-index:2;background:#fff;padding:10px 12px 0;border-bottom:1px solid #e3e7ec}",
   ".lwb-op-top{display:flex;align-items:center;justify-content:space-between;gap:8px}.lwb-op-top strong{font-size:15.5px;font-weight:700}.lwb-op-top small{background:#c8102e;color:#fff;font-size:11px;font-weight:700;padding:1px 7px;border-radius:999px;margin-left:7px;vertical-align:2px}",
   ".lwb-op-top button{padding:5px 10px;border:1px solid #dfe5ec;background:#fff;color:#3b4652;border-radius:8px;cursor:pointer;font:600 12px 'Segoe UI',Roboto,Arial,sans-serif}.lwb-op-top button:hover{border-color:#c8102e;color:#c8102e}",
   ".lwb-op-tabs{display:flex;flex-wrap:wrap;gap:5px;padding:9px 0}",
   ".lwb-op-panel .lwb-op-tab{display:inline-flex;align-items:center;gap:5px;padding:4px 10px;border:1px solid #dfe5ec;background:#fff;color:#4a5a6b;border-radius:999px;cursor:pointer;font:600 12px 'Segoe UI',Roboto,Arial,sans-serif;min-height:0}",
   ".lwb-op-panel .lwb-op-tab:hover{border-color:#9fb0c3}",
   ".lwb-op-panel .lwb-op-tab.on{background:#1f2a37;border-color:#1f2a37;color:#fff}",
   ".lwb-op-tab i{font-style:normal;font-size:10.5px;font-weight:700;min-width:17px;text-align:center;padding:0 5px;border-radius:999px;background:#eef1f5;color:#4a5a6b}",
   ".lwb-op-tab.on i{background:rgba(255,255,255,.2);color:#fff}.lwb-op-tab.todo i{background:#c8102e;color:#fff}",
   ".lwb-op-tab .sw{width:8px;height:8px;border-radius:50%;flex:0 0 8px}",
   ".lwb-op-dates{display:inline-flex;gap:5px;margin-left:auto}",
   ".lwb-op-dates select,.lwb-op-dates input{height:27px;padding:0 8px;border:1px solid #dfe5ec;background:#fff;color:#4a5a6b;border-radius:999px;font:600 12px 'Segoe UI',Roboto,Arial,sans-serif;min-height:0;max-width:150px;cursor:pointer}",
   ".lwb-op-dates select.on{background:#e8f0fc;border-color:#9dbbe8;color:#1d5fbf}",
   ".lwb-op-dates [hidden]{display:none}",
   ".lwb-op-list{padding:2px 8px 6px}",
   ".lwb-op-day{font-size:10.5px;font-weight:700;letter-spacing:.7px;text-transform:uppercase;color:#8592a1;margin:9px 4px 5px}",
   ".lwb-op-empty{color:#6b7785;text-align:center;padding:22px 8px;margin:0}",
   ".lwb-op-msg{display:flex;gap:10px;align-items:flex-start;background:#fff;border:1px solid #e6eaf0;border-radius:12px;padding:9px 10px;margin-bottom:6px;cursor:default;transition:border-color .12s,box-shadow .12s}",
   ".lwb-op-msg.link{cursor:pointer}.lwb-op-msg.link:hover{border-color:#b9c6d4;box-shadow:0 2px 8px rgba(16,24,40,.08)}",
   ".lwb-op-msg.unread{border-color:#d3dce7;box-shadow:0 1px 3px rgba(16,24,40,.07)}",
   ".lwb-op-msg:not(.unread){background:#fbfcfd}",
   ".lwb-op-ic{flex:0 0 36px;height:36px;border-radius:10px;display:grid;place-items:center}",
   ".lwb-op-body{flex:1;min-width:0}",
   ".lwb-op-l{display:flex;align-items:center;gap:6px;min-width:0}.lwb-op-l+.lwb-op-l{margin-top:1px}",
   ".lwb-op-what{flex:1;min-width:0;font-weight:700;font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}",
   ".lwb-op-msg:not(.unread) .lwb-op-what{font-weight:600;color:#4a5a6b}",
   ".lwb-op-meta{flex:0 0 auto;display:flex;align-items:center;gap:5px;font-size:11.5px;color:#8592a1;white-space:nowrap}",
   ".lwb-op-tag{font-size:10px;font-weight:700;letter-spacing:.5px;text-transform:uppercase;padding:1px 6px;border-radius:5px}",
   ".lwb-op-dot{width:8px;height:8px;border-radius:50%;background:#c8102e}",
   ".lwb-op-party{flex:1;min-width:0;font-size:13.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:#4a5a6b}",
   ".lwb-op-party.p{font-weight:600;color:#1f2a37;text-transform:uppercase;letter-spacing:.2px}",
   ".lwb-op-amt{flex:0 0 auto;font-weight:700;font-size:14.5px;font-variant-numeric:tabular-nums;color:#0f2b45}",
   ".lwb-op-det{flex:1;min-width:0;color:#7a8796;font-size:12px;overflow-wrap:anywhere;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}",
   ".lwb-op-btns{flex:0 0 auto;display:flex;gap:5px;margin-left:auto}",
   ".lwb-op-panel .lwb-op-btns button{padding:4px 11px;border-radius:8px;cursor:pointer;font:700 12px 'Segoe UI',Roboto,Arial,sans-serif;min-height:0;border:1px solid #dfe5ec;background:#fff;color:#4a5a6b}",
   ".lwb-op-panel .lwb-op-btns button.do{background:#c8102e;border-color:#c8102e;color:#fff}.lwb-op-panel .lwb-op-btns button.do:hover{background:#a00d25}",
   ".lwb-op-msg:not(.unread) .lwb-op-btns button.do{background:#fff;color:#c8102e}",
   ".lwb-op-panel .lwb-op-btns button.tick:hover{border-color:#13824a;color:#13824a}",
   ".lwb-op-msg p{margin:5px 0 0;color:#51657a;font-size:12px;overflow-wrap:anywhere}",
   ".c-order .lwb-op-ic,.c-order .lwb-op-tag{background:#e8f0fc;color:#1d5fbf}.lwb-op-tab .sw.c-order{background:#1d5fbf}",
   ".c-delivery .lwb-op-ic,.c-delivery .lwb-op-tag{background:#def3f5;color:#0b7285}.lwb-op-tab .sw.c-delivery{background:#0b7285}",
   ".c-money .lwb-op-ic,.c-money .lwb-op-tag{background:#e3f5ea;color:#13824a}.lwb-op-tab .sw.c-money{background:#13824a}",
   ".c-stock .lwb-op-ic,.c-stock .lwb-op-tag{background:#f0eafb;color:#6f42c1}.lwb-op-tab .sw.c-stock{background:#6f42c1}",
   ".c-task .lwb-op-ic,.c-task .lwb-op-tag{background:#fdefe0;color:#b85a00}.lwb-op-tab .sw.c-task{background:#b85a00}",
   ".c-other .lwb-op-ic,.c-other .lwb-op-tag{background:#eef1f5;color:#56677a}.lwb-op-tab .sw.c-other{background:#56677a}",
   ".lwb-op-msg.t-bad .lwb-op-ic{background:#fdecef;color:#c8102e}",
   ".lwb-op-msg:not(.unread) .lwb-op-ic{opacity:.7}",
   ".lwb-op-foot{padding:8px 12px 10px;border-top:1px solid #e3e7ec;background:#fff;font-size:12px}",
   "@media(max-width:560px){.lwb-op-panel{position:fixed;left:8px;right:8px;width:auto;max-height:calc(100vh - 80px)}.lwb-op-list{padding:2px 6px 6px}.lwb-op-msg{gap:9px;padding:8px}.lwb-op-ic{flex-basis:32px;height:32px}.lwb-op-tag{font-size:9.5px;padding:1px 5px}}",
   ".lwb-op-error{color:#ac2828!important;padding:8px 12px}"
  ].join("");
  document.head.append(css);
  const wrap=el("div","lwb-op-wrap"),bell=el("button","lwb-op-bell"),count=el("span","lwb-op-count","0");
  bell.innerHTML='<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/></svg>';
  bell.id="lwbOpsBell";bell.type="button";
  bell.setAttribute("aria-label","ERP Notifications");bell.title="Notifications";bell.setAttribute("aria-expanded","false");
  bell.append(count);
  const panel=el("section","lwb-op-panel"),head=el("div","lwb-op-head"),reload=el("button",null,"Refresh"),allRead=el("button",null,"Mark all read");
  panel.hidden=true;panel.setAttribute("aria-label","ERP Notifications");
  reload.type="button";allRead.type="button";allRead.hidden=true;
  const btns=el("span");btns.style.cssText="display:flex;gap:6px";btns.append(allRead,reload);
  const ttl=el("strong",null,"Notifications"),newTxt=el("small");ttl.append(newTxt);
  const top=el("div","lwb-op-top"),tabs=el("div","lwb-op-tabs");tabs.setAttribute("role","tablist");
  top.append(ttl,btns);head.append(top,tabs);
  // Phone-alert switch sits at the bottom so the list starts right under the header.
  const list=el("div","lwb-op-list"),foot=el("div","lwb-op-foot");panel.append(head,list,foot);wrap.append(bell,panel);mount.prepend(wrap);
  const orders=new Map();
  // Filter tabs: All · To do (needs your action) · one tab per type that has notifications.
  let tab="all",allItems=[];
  // Date filter (Mohit, 18 Nov 2026): All dates · Today · Yesterday · Last 7 days · Pick a date.
  let when="all",pick="";
  const ymd=d=>d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")+"-"+String(d.getDate()).padStart(2,"0");
  function inDate(it){
   if(when==="all")return true;
   const d=new Date(it.n.created_at),t=new Date();t.setHours(0,0,0,0);
   if(when==="today")return d>=t;
   if(when==="yesterday")return d>=new Date(t-864e5)&&d<t;
   if(when==="week")return d>=new Date(t-6*864e5);
   if(when==="date")return !pick||ymd(d)===pick;
   return true;
  }
  const dates=el("span","lwb-op-dates"),dSel=el("select"),dPick=el("input");
  dSel.setAttribute("aria-label","Filter by date");dSel.title="Filter by date";
  for(const [v,t] of [["all","All dates"],["today","Today"],["yesterday","Yesterday"],["week","Last 7 days"],["date","Pick a date…"]]){const o=el("option",null,t);o.value=v;dSel.append(o)}
  dPick.type="date";dPick.hidden=true;dPick.max=ymd(new Date());dPick.setAttribute("aria-label","Date");
  dates.append(dSel,dPick);
  dSel.addEventListener("change",()=>{when=dSel.value;dPick.hidden=when!=="date";if(when==="date"){if(!pick){pick=ymd(new Date());dPick.value=pick}reloadData()}else render();panel.scrollTop=0});
  dPick.addEventListener("change",()=>{pick=dPick.value;reloadData();panel.scrollTop=0});
  dates.addEventListener("click",e=>e.stopPropagation());
  const todo=it=>!it.n.is_read&&!!it.sum.action&&it.sum.tone!=="ok";
  async function markRead(n){return db.from("erp_notifications").update({is_read:true}).eq("id",n.id).eq("user_id",user.id)}
  function render(){
   const items=allItems.filter(inDate);
   const unreadIn=f=>items.filter(it=>!it.n.is_read&&f(it)).length;
   const defs=[["all","All",()=>true],["todo","To do",todo]];
   for(const [k,c] of Object.entries(CATS))if(items.some(it=>it.sum.cat===k))defs.push([k,c.tab,it=>it.sum.cat===k]);
   if(!defs.some(d=>d[0]===tab))tab="all";
   tabs.replaceChildren();
   for(const [k,label,f] of defs){
    const b=el("button","lwb-op-tab"+(k===tab?" on":"")+(k==="todo"?" todo":""));b.type="button";b.setAttribute("role","tab");b.setAttribute("aria-selected",String(k===tab));
    if(CATS[k])b.append(el("span","sw c-"+k));
    b.append(document.createTextNode(label));
    const c=k==="todo"?items.filter(todo).length:unreadIn(f);
    if(c)b.append(el("i",null,c>99?"99+":c));
    if(k==="todo"&&!c)continue;
    b.addEventListener("click",e=>{e.stopPropagation();tab=k;render();panel.scrollTop=0});
    tabs.append(b);
   }
   tabs.append(dates);
   dSel.classList.toggle("on",when!=="all");
   list.replaceChildren();
   const f=(defs.find(d=>d[0]===tab)||defs[0])[2],show=items.filter(f);
   if(!show.length){list.append(el("p","lwb-op-empty",allItems.length?(when==="all"?"Nothing here right now.":"No notifications on this date."):"No notifications yet."));return}
   let day="";
   for(const {n,sum,href} of show){
    const d=dayOf(n.created_at);
    if(d!==day){day=d;list.append(el("div","lwb-op-day",d))}
    const cat=CATS[sum.cat]||CATS.other;
    const box=el("div","lwb-op-msg c-"+sum.cat+" t-"+sum.tone+(n.is_read?"":" unread")+(href?" link":""));
    box.title=href?"Open":"Click to view details";
    const ic=el("span","lwb-op-ic");ic.innerHTML=svg(sum.icon);
    const body=el("div","lwb-op-body");
    const l1=el("div","lwb-op-l"),meta=el("span","lwb-op-meta");
    meta.append(el("span","lwb-op-tag",cat.tag),el("span",null,ago(n.created_at)));
    if(!n.is_read)meta.append(el("span","lwb-op-dot"));
    l1.append(el("b","lwb-op-what",sum.head),meta);
    const l2=el("div","lwb-op-l");
    l2.append(el("span","lwb-op-party"+(sum.isParty?" p":""),sum.line2||"—"));
    if(sum.amount)l2.append(el("span","lwb-op-amt",sum.amount));
    const bt=el("span","lwb-op-btns");
    if(sum.action&&href){
     const go=el("button","do",sum.action);go.type="button";go.title=sum.action;
     go.addEventListener("click",async()=>{go.disabled=true;if(!n.is_read)await markRead(n);location.href=href});
     bt.append(go);
    }
    if(!n.is_read){
     const read=el("button","tick","✓");read.type="button";read.title="Mark as read";read.setAttribute("aria-label","Mark as read");
     read.addEventListener("click",async()=>{
      read.disabled=true;
      const {error:err}=await markRead(n);
      if(err){read.disabled=false;box.append(el("p","lwb-op-error",err.message))}
      else{n.is_read=true;await reloadData()}
     });
     bt.append(read);
    }
    const l3=(sum.details.length||bt.childNodes.length)?el("div","lwb-op-l"):null;
    if(l3){l3.append(el("span","lwb-op-det",sum.details.join(" · ")),bt);l3.style.marginTop="3px"}
    const full=el("p",null,(n.title?n.title+": ":"")+(n.message||""));full.hidden=true;
    // Click opens the page of this notification (and marks it read); others show the full text.
    box.addEventListener("click",async e=>{
     if(e.target.closest("button"))return;
     if(!href){full.hidden=!full.hidden;return}
     if(!n.is_read)await markRead(n);
     location.href=href;
    });
    body.append(l1,l2);if(l3)body.append(l3);body.append(full);
    box.append(ic,body);
    list.append(box);
   }
  }
  // Godown Manager: only his own work (loading given to him, purchase vehicle to unload, tasks, his returns).
  // The database already sends / shows only these (lwb_gm_notify_scope_setup.sql); this is the same rule by type.
  const GM_BELL=/^(LOADING_ASSIGNMENT_DISPATCH|PURCHASE_ARRIVED|TASK_|DELIVERY_RETURN_RECEIVE|ANNOUNCEMENT|LABOUR_)/;
  async function reloadData(){
   let qy=db.from("erp_notifications").select("*").eq("user_id",user.id);
   // A picked older date reads that day only, so it is not cut by the latest-70 limit.
   if(when==="date"&&pick){const a=new Date(pick+"T00:00:00");qy=qy.gte("created_at",a.toISOString()).lt("created_at",new Date(+a+864e5).toISOString())}
   const {data,error}=await qy.order("created_at",{ascending:false}).limit(70);
   if(error){list.replaceChildren(el("p","lwb-op-error","Notification error: "+error.message));return}
   // Salesman: his order updates show again (17 Nov 2026); live GPS / loading-assignment bells stay hidden.
   // Driver sees no history: only the last 12 hours.
   // Team chat bells (CHAT_MSG, lwb_team_chat_setup.sql) are only for the phone push: the chat button shows them.
   const rows=(data||[]).filter(n=>baseType(n)!=="CHAT_MSG").filter(n=>!["sales","salesman"].includes(String(role||"").trim().toLowerCase())||!/^(LIVE_|GPS_|TRACK|LOADING_ASSIGNMENT)/.test(baseType(n))).filter(n=>String(role||"").toLowerCase()!=="driver"||Date.now()-new Date(n.created_at)<12*36e5).filter(n=>String(role||"").trim().toLowerCase()!=="warehouse"||GM_BELL.test(baseType(n))),unread=rows.filter(n=>!n.is_read).length;
   bell.setAttribute("aria-label", "Notifications" + (unread ? ", " + unread + " unread" : ""));
   newTxt.textContent=unread?unread+" new":"";newTxt.hidden=!unread;
   count.textContent=unread>99?"99+":String(unread);count.style.display=unread?"inline-block":"none";
   // Party name + order value for every order notification, in one read (rows this login may see).
   const need=[...new Set(rows.map(n=>n.order_id).filter(id=>id&&!orders.has(id)))];
   if(need.length){
    try{const {data:od}=await db.from("orders").select("id,order_no,customer_name,total_amount,sales_person").in("id",need);
     for(const o of od||[])orders.set(o.id,o);}catch(e){}
   }
   arrived(rows);
   // Market order checks no longer pop up (Mohit, 7 Nov 2026): they wait in the bell and on Approvals.
   allRead.hidden=!unread;
   allItems=rows.map(n=>({n,sum:summary(n,orders.get(n.order_id)),href:route(n,pages)}));
   render();
   // 🔔 New notification: small popup + its own sound (erp-notify-popup.js). A picked old date is not "new".
   if(when!=="date"&&window.LWBNotifyPopup)window.LWBNotifyPopup.feed(allItems.map(it=>({...it,tag:(CATS[it.sum.cat]||CATS.other).tag,svg:svg(it.sum.icon),
    open:async()=>{if(!it.n.is_read)await markRead(it.n);if(it.href)location.href=it.href;else{panel.hidden=false;bell.setAttribute("aria-expanded","true");reloadData()}}})));
  }
  // "Market order — please check once" (lwb_rate_check_setup.sql) used to pop up here for every PO, again and
  // again. Now it is only a bell row + the "Market order check" card on Approvals (approvals.html), where
  // "✓ Checked OK" marks it read. The PO is never stopped, as before.
  // "Purchase vehicle arrived" (Godown Manager): popup until the vehicle is checked; Later = 15 min.
  let pdLoading=false;
  async function arrived(rows){
   const a=rows.filter(n=>!n.is_read&&n.ref_id&&baseType(n)==="PURCHASE_ARRIVED"&&Date.now()-new Date(n.created_at)<4*864e5);
   if(!a.length||pdLoading||document.querySelector(".pd-back"))return;
   pdLoading=true;
   try{
    if(!window.LWBPurchaseDamage)await new Promise((ok,bad)=>{const s=document.createElement("script");s.src="purchase-damage.js";s.onload=ok;s.onerror=bad;document.head.append(s)});
    await window.LWBPurchaseDamage.arrivals({client:db,rows:a,role:String(role||"").toLowerCase(),onDone:()=>reloadData()});
   }catch(e){}
   pdLoading=false;
  }
  allRead.addEventListener("click",async()=>{
   allRead.disabled=true;
   const {error:err}=await db.from("erp_notifications").update({is_read:true}).eq("user_id",user.id).eq("is_read",false);
   allRead.disabled=false;
   if(err)list.prepend(el("p","lwb-op-error",err.message));else await reloadData();
  });
  bell.addEventListener("click",()=>{
    panel.hidden=!panel.hidden;bell.setAttribute("aria-expanded",String(!panel.hidden));
    if(!panel.hidden){panel.style.top=innerWidth<=560?Math.round(bell.getBoundingClientRect().bottom+8)+"px":"";reloadData()}
  });
  reload.addEventListener("click",reloadData);
  document.addEventListener("click",e=>{
   if(!wrap.contains(e.target)){panel.hidden=true;bell.setAttribute("aria-expanded","false")}
  });
  // Permission / test controls are loaded only once inside the notification panel.
  (async()=>{
   try{
    if(!window.LWBPhonePush)await new Promise((ok,bad)=>{const script=document.createElement('script');script.src='erp-push.js';script.onload=ok;script.onerror=bad;document.head.append(script)});
    const actualRole=role||document.querySelector('.erp-user .who small')?.textContent?.toLowerCase();
    await window.LWBPhonePush.init({db,user,role:actualRole,mount:foot});
   }catch(e){}
  })();
  let lastLoad=Date.now(),liveOk=false,soon=0;
  const load=()=>{lastLoad=Date.now();return reloadData()};
  // Popup + sound for new notifications; loaded first so the first load is only the "already there" list.
  const popReady=window.LWBNotifyPopup?Promise.resolve():new Promise(ok=>{const s=document.createElement("script");s.src="erp-notify-popup.js";s.onload=ok;s.onerror=ok;document.head.append(s)});
  popReady.then(()=>{try{window.LWBNotifyPopup&&window.LWBNotifyPopup.controls(foot)}catch(e){}load()});
  // Phone app open on screen: the push comes here instead of a second banner (sw.js), so read at once.
  if(navigator.serviceWorker)navigator.serviceWorker.addEventListener("message",e=>{if(e.data&&e.data.type==="LWB_PUSH_IN"){clearTimeout(soon);soon=setTimeout(load,300)}});
  // Backup check: every 30 s while the instant (Realtime) link is down, every 2 min while it works
  // (speed fix, 17 Nov 2026: each open tab of every user used to read 70 bells every 30 s).
  setInterval(()=>{if(!document.hidden&&Date.now()-lastLoad>=(liveOk?120000:29000))load()},30000);
  // Instant: a new row updates the bell count without interrupting the current task.
  // Needs erp_notifications in Supabase Realtime (lwb_order_flow_popups_setup.sql).
  try{
   db.channel("lwb-bell-"+user.id).on("postgres_changes",{event:"INSERT",schema:"public",table:"erp_notifications",filter:"user_id=eq."+user.id},
    ()=>{clearTimeout(soon);soon=setTimeout(load,400)}).subscribe(st=>{liveOk=st==="SUBSCRIBED"});
  }catch(e){}
  document.addEventListener("visibilitychange",()=>{if(!document.hidden&&Date.now()-lastLoad>15000)load()});
 }
 window.LWBOperationsNotifications={init};
})();
