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
  [/^ANNOUNCEMENT$/,"📢","info","",""],
  [/^SALES_PLAN$/,"📋","info","Today's plan",""]
 ];
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
   return {icon,tone,head,action,line2:p[1]||"Purchase bill",isParty:true,amount:dc?dc+" CS":"",details:dd};
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
     details:["🚛 "+h[1],rate?"per trip":h[3].replace(/\. Set it again.*$/,"").replace(/\. Vehicle Master.*$/,"")].filter(Boolean)}}}
  if(/^ACC_CHEQUE/.test(t)){const c=(m.match(/To deposit: (\d+)/)||[])[1];if(c)line2=c+(c==="1"?" cheque":" cheques")+" to deposit"}
  return {icon,tone,head,action,line2,isParty:!!party,amount,details:d};
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
  [/^PO_APPROVED_LOADING$/,["loading-dispatch.html?order={o}","warehouse-orders.html"]],
  [/^(VEHICLE_LOADED|TALLY_BILL_DONE)$/,["loading-dispatch.html","party-billing.html?order={o}","warehouse-orders.html","driver-delivery.html?order={o}","my-sales.html#orders"]],
  [/^ORDER_NEW$/,["warehouse-orders.html"]],
  [/^RATE_APPROVAL$/,["quick-slip.html?review={o}"]],
  [/^BILL_CHANGE_/,["party-billing.html?tab=chg&change={o}"]],
  [/^RATE_APPROVED$/,["quick-slip.html?order={o}"]],
  [/^PO_RATE_APPROVAL$/,["warehouse-orders.html?rate={o}"]],
  [/^ORDER_RATE_CHECK$/,["approvals.html#market","warehouse-orders.html?order={o}"]],
  [/^PO_RATE_APPROVED$/,["warehouse-orders.html?order={o}","my-sales.html#orders"]],
  [/^DELIVERY_COLLECTION_(INFO|RECEIVED)$/,["driver-collections.html?order={o}","my-sales.html#orders","loading-dispatch.html"]],
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
  [/^GODOWN_/,["godown-report.html"]],
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
 // Quiet notifications: updates stay in the bell; no automatic dialogs interrupt entry.
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
   ".lwb-op-panel{position:absolute;top:calc(100% + 9px);right:0;z-index:99999;width:min(520px,94vw);max-height:calc(100vh - 90px);overflow-y:auto;overscroll-behavior:contain;background:#fff;color:#173450;border:1px solid #cbd5e2;border-radius:10px;box-shadow:0 12px 35px #0004;padding:0 10px 10px;font:13px/1.4 Arial,sans-serif;white-space:normal;text-align:left}",
   ".lwb-op-panel[hidden]{display:none}.lwb-op-head{position:sticky;top:0;z-index:2;background:#fff;display:flex;align-items:center;justify-content:space-between;gap:9px;padding:10px 0 8px;border-bottom:2px solid #173450}.lwb-op-head strong{font-size:15px}.lwb-op-head small{color:#c72a38;font-weight:700;margin-left:6px}.lwb-op-foot{margin-top:8px;padding-top:8px;border-top:1px solid #e0e8f1;font-size:12px}",
   ".lwb-op-panel button{padding:7px 9px;border:1px solid #bbd1e7;background:#eef5fc;color:#164679;border-radius:6px;cursor:pointer;font:12px Arial,sans-serif}",
   ".lwb-op-msg{border-top:1px solid #e0e8f1;border-left:4px solid #c6d3e1;color:#173450;padding:7px 8px 7px 6px;cursor:default}",
   ".lwb-op-msg.link{cursor:pointer}.lwb-op-msg.link:hover{background:#f3f8fd}",
   ".lwb-op-msg.unread{background:#fffaeb}.lwb-op-msg.unread.link:hover{background:#fff3d1}",
   ".lwb-op-msg.t-act{border-left-color:#e3a008}.lwb-op-msg.t-move{border-left-color:#1f7a8c}.lwb-op-msg.t-money{border-left-color:#16865a}",
   ".lwb-op-msg.t-ok{border-left-color:#3aa371}.lwb-op-msg.t-bad{border-left-color:#c72a38}.lwb-op-msg.t-info{border-left-color:#8aa0b8}",
   ".lwb-op-msg:not(.unread){border-left-color:#dfe6ee}",
   ".lwb-op-l{display:flex;align-items:center;gap:6px;min-width:0}",
   ".lwb-op-l+.lwb-op-l{margin-top:2px;padding-left:26px}",
   ".lwb-op-ic{flex:0 0 20px;text-align:center;font-size:15px}",
   ".lwb-op-what{flex:1;min-width:0;display:flex;align-items:center;gap:6px;font-weight:700;font-size:14.5px}",
   ".lwb-op-what b{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}",
   ".lwb-op-act{flex:0 0 auto;font-size:11px;font-weight:700;padding:1px 7px;border-radius:10px;background:#fde8b0;color:#6b4a00}",
   ".lwb-op-msg:not(.unread) .lwb-op-act{background:#edf1f5;color:#5b6d80}",
   ".lwb-op-time{flex:0 0 auto;color:#5d7086;font-size:12.5px}",
   ".lwb-op-go{flex:0 0 auto;color:#164679;font-size:20px;line-height:1;font-weight:700}",
   ".lwb-op-party{flex:1;min-width:0;font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}",
   ".lwb-op-party.p{font-weight:600;text-transform:uppercase;letter-spacing:.2px}.lwb-op-party:not(.p){color:#3d5168}",
   ".lwb-op-amt{flex:0 0 auto;font-weight:700;font-size:14.5px;font-variant-numeric:tabular-nums;color:#0f2b45}",
   ".lwb-op-det{color:#4a5d72;font-size:12.5px;overflow-wrap:anywhere;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}",
   ".lwb-op-msg:not(.unread) .lwb-op-what{font-weight:600;color:#3d5168}",
   ".lwb-op-msg p{margin:4px 4px 0 26px;color:#51657a;font-size:12px;overflow-wrap:anywhere}",
   ".lwb-op-panel button.lwb-op-tick{flex:0 0 auto;padding:2px 7px;font-size:12px}",
   "@media(max-width:560px){.lwb-op-panel{position:fixed;left:8px;right:8px;width:auto;max-height:calc(100vh - 80px);padding:0 8px 8px}}",
   ".lwb-op-error{color:#ac2828!important}"
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
  head.append(ttl,btns);
  // Phone-alert switch sits at the bottom so the list starts right under the header.
  const list=el("div"),foot=el("div","lwb-op-foot");panel.append(head,list,foot);wrap.append(bell,panel);mount.prepend(wrap);
  const orders=new Map();
  async function reloadData(){
   const {data,error}=await db.from("erp_notifications")
    .select("*")
    .eq("user_id",user.id).order("created_at",{ascending:false}).limit(70);
   if(error){list.replaceChildren(el("p","lwb-op-error","Notification error: "+error.message));return}
   // Driver sees no history: only the last 12 hours.
   // Team chat bells (CHAT_MSG, lwb_team_chat_setup.sql) are only for the phone push: the chat button shows them.
   const rows=(data||[]).filter(n=>baseType(n)!=="CHAT_MSG").filter(n=>!["sales","salesman"].includes(String(role||"").trim().toLowerCase())||!(n.order_id||/^(ORDER_|PO_|TALLY_|VEHICLE_|LOADING_|DELIVERY_|SALES_RETURN|LIVE_|GPS_|TRACK)/.test(baseType(n)))).filter(n=>String(role||"").toLowerCase()!=="driver"||Date.now()-new Date(n.created_at)<12*36e5),unread=rows.filter(n=>!n.is_read).length;
   bell.setAttribute("aria-label", "Notifications" + (unread ? ", " + unread + " unread" : ""));
   newTxt.textContent=unread?unread+" new":"";
   count.textContent=unread>99?"99+":String(unread);count.style.display=unread?"inline-block":"none";
   // Party name + order value for every order notification, in one read (rows this login may see).
   const need=[...new Set(rows.map(n=>n.order_id).filter(id=>id&&!orders.has(id)))];
   if(need.length){
    try{const {data:od}=await db.from("orders").select("id,order_no,customer_name,total_amount,sales_person").in("id",need);
     for(const o of od||[])orders.set(o.id,o);}catch(e){}
   }
   arrived(rows);
   // Market order checks no longer pop up (Mohit, 7 Nov 2026): they wait in the bell and on Approvals.
   list.replaceChildren();
   if(!rows.length){list.append(el("p",null,"No notifications yet."));return}
   allRead.hidden=!unread;
   for(const n of rows){
    const sum=summary(n,orders.get(n.order_id)),href=route(n,pages);
    const box=el("div","lwb-op-msg t-"+sum.tone+(n.is_read?"":" unread")+(href?" link":""));
    box.title=href?"Open":"Click to view details";
    const l1=el("div","lwb-op-l"),hd=el("span","lwb-op-what");
    hd.append(el("b",null,sum.head));
    if(sum.action)hd.append(el("span","lwb-op-act",sum.action));
    l1.append(el("span","lwb-op-ic",sum.icon),hd,el("span","lwb-op-time",ago(n.created_at)));
    if(href)l1.append(el("span","lwb-op-go","›"));
    const l2=el("div","lwb-op-l");
    l2.append(el("span","lwb-op-party"+(sum.isParty?" p":""),sum.line2||"—"));
    if(sum.amount)l2.append(el("span","lwb-op-amt",sum.amount));
    const l3=sum.details.length?el("div","lwb-op-l"):null;
    if(l3)l3.append(el("span","lwb-op-det",sum.details.join(" · ")));
    const full=el("p",null,(n.title?n.title+": ":"")+(n.message||""));full.hidden=true;
    // Click opens the page of this notification (and marks it read); others show the full text.
    box.addEventListener("click",async e=>{
     if(e.target.closest("button"))return;
     if(!href){full.hidden=!full.hidden;return}
     if(!n.is_read)await db.from("erp_notifications").update({is_read:true}).eq("id",n.id).eq("user_id",user.id);
     location.href=href;
    });
    if(!n.is_read){
     const read=el("button","lwb-op-tick","✓");read.type="button";read.title="Mark as read";
     read.addEventListener("click",async()=>{
      read.disabled=true;
      const {error:err}=await db.from("erp_notifications").update({is_read:true})
       .eq("id",n.id).eq("user_id",user.id);
      if(err){read.disabled=false;box.append(el("p","lwb-op-error",err.message))}
      else await reloadData();
     });
     l1.append(read);
    }
    box.append(l1,l2);if(l3)box.append(l3);box.append(full);
    list.append(box);
   }
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
  reloadData();
  setInterval(()=>{if(!document.hidden)reloadData()},30000);
  // Instant: a new row updates the bell count without interrupting the current task.
  // Needs erp_notifications in Supabase Realtime (lwb_order_flow_popups_setup.sql); the 30 s check stays as backup.
  let soon=0;
  try{
   db.channel("lwb-bell-"+user.id).on("postgres_changes",{event:"INSERT",schema:"public",table:"erp_notifications",filter:"user_id=eq."+user.id},
    ()=>{clearTimeout(soon);soon=setTimeout(reloadData,400)}).subscribe();
  }catch(e){}
  document.addEventListener("visibilitychange",()=>{if(!document.hidden)reloadData()});
 }
 window.LWBOperationsNotifications={init};
})();
