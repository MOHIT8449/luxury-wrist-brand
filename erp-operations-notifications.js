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
 // One short line per notification: icon + order no + the key number. Full text opens on click.
 // CC_<type> = Sales Head copy of another login's notification: same text and page, never a popup.
 const baseType=n=>String(n.notification_type||"").toUpperCase().replace(/^CC_/,"");
 function summary(n){
  const t=baseType(n),m=String(n.message||""),title=String(n.title||"");
  const order=(m.match(/\b[A-Z]{2,6}-\d{3,}\b/)||[])[0]||"";
  const amt=(m.match(/(?:Rs\.?|₹)\s?([\d,]+(?:\.\d+)?)/i)||[])[1];
  const val=amt?Number(amt.replace(/,/g,"")):0;
  const money=amt?"₹"+val.toLocaleString("en-IN",{minimumFractionDigits:val%1?2:0,maximumFractionDigits:2}):"";
  const join=a=>a.filter(Boolean).join(" · ");
  if(t==="TALLY_BILL_PENDING")return {icon:"🧾",text:join(["Make Tally bill",order])};
  if(t==="VEHICLE_LOADED")return {icon:"🚛",text:join(["Vehicle loaded",order,(m.match(/Vehicle ([A-Z0-9]+)/)||[])[1]])};
  if(t==="TALLY_BILL_DONE")return {icon:"🧾",text:join(["Bill made",order])};
  if(t==="ORDER_NEW")return {icon:"🛒",text:join(["New order",order,money,"Approve"])};
  if(t==="DELIVERY_COLLECTION_INFO")return {icon:"💰",text:join(["Driver collected",order,money])};
  if(t==="DELIVERY_COLLECTION_RECEIVED")return {icon:"✅",text:join(["Payment received",order,money])};
  if(t==="DELIVERY_RETURN_INFO")return {icon:"↩",text:join(["Driver took a return",order,money])};
  if(t.startsWith("TALLY_NOTE_"))return {icon:"📝",text:join([t.endsWith("DEBIT")?"Debit note":"Credit note",order,money])};
  if(t==="SALES_RETURN_NEW")return {icon:"↩",text:join(["Sales return",order,money,"Credit note"])};
  if(t==="DELIVERY_RETURN_RECEIVE")return {icon:"📦",text:join(["Receive return goods",order,money])};
  if(t==="DELIVERY_RETURN_DEDUCTED")return {icon:"↩",text:join(["Return cut",order,money])};
  if(t==="DELIVERY_RETURN_APPROVED"||t==="DELIVERY_RETURN_REJECTED")return {icon:t.endsWith("APPROVED")?"✅":"❌",text:join([t.endsWith("APPROVED")?"Return approved":"Return rejected",order,money])};
  if(t.startsWith("DELIVERY_RETURN"))return {icon:"↩",text:join(["Return",order,money,t.endsWith("OPERATIONS")?"Warehouse check":"Verify"])};
  if(t==="DELIVERY_COLLECTION"){const out=(m.match(/Outstanding Rs ([\d.]+)/)||[])[1];
   return {icon:"💰",text:join(["Collection",order,money,Number(out)>0?"Due ₹"+Number(out).toLocaleString("en-IN"):"","Verify"])}}
  if(t.startsWith("DELIVERY_COLLECTION_"))return {icon:t.endsWith("VERIFIED")?"✅":"❌",text:join([t.endsWith("VERIFIED")?"Payment verified":"Payment rejected",order,money])};
  if(t.startsWith("LOADING_ASSIGNMENT")){
   const veh=(m.match(/Vehicle ([A-Z0-9]+)/)||[])[1],drv=((m.match(/Driver ([^(·]+)/)||[])[1]||"").trim();
   return {icon:"🚚",text:join([/updated|changed|badla/i.test(title)?"Loading updated":"Loading",order,veh,drv])};
  }
  if(t.startsWith("GODOWN_")){const id=(m.match(/GDN-\d+/)||[])[0]||"";return {icon:"🏭",text:join([title.replace(/^Godown: /,"Godown · "),id])}}
  if(t.startsWith("ORDER_")){const ic={ORDER_DELIVERED:"✅",ORDER_PARTIAL:"🟠",ORDER_NOT_DELIVERED:"⚠",ORDER_CANCELLED:"✖",ORDER_EDITED:"✏"}[t]||"•";
   return {icon:ic,text:join([title,order])}}
  if(t==="ANNOUNCEMENT")return {icon:"📢",text:join([title,m.length>50?m.slice(0,47)+"…":m])};
  if(t==="MARKET_REPORT"||t==="MARKET_REVIEW"){const id=(m.match(/MKT-\d+/)||[])[0]||"";return {icon:t==="MARKET_REPORT"?"🚩":"✅",text:join([t==="MARKET_REPORT"?"Outside stock":title,id])}}
  if(t==="SALES_PLAN"){const n=(m.match(/from (\d+) part/)||[])[1];return {icon:"📋",text:join(["Today's plan",n?n+" parties due":"Sales Head note"])}}
  const short=m.length>60?m.slice(0,57)+"…":m;
  return {icon:"•",text:join([title||"ERP",order||short])};
 }
 function ago(v){
  if(!v)return "";
  const s=(Date.now()-new Date(v))/1000;
  if(s<60)return "now";if(s<3600)return Math.floor(s/60)+" min";if(s<86400)return Math.floor(s/3600)+" hr";
  if(s<7*86400)return Math.floor(s/86400)+" d";
  return new Date(v).toLocaleDateString("en-IN",{day:"2-digit",month:"short"});
 }
 // Page each notification opens. {o} = the notification's order id. The first page this login can open wins.
 const ROUTES=[
  [/^TALLY_BILL_PENDING$/,["accounts-invoice.html?order={o}"]],
  [/^(VEHICLE_LOADED|TALLY_BILL_DONE)$/,["loading-dispatch.html","accounts-invoice.html?order={o}","warehouse-orders.html","driver-delivery.html?order={o}","my-sales.html#orders"]],
  [/^ORDER_NEW$/,["warehouse-orders.html"]],
  [/^DELIVERY_COLLECTION_(INFO|RECEIVED)$/,["driver-collections.html?order={o}","my-sales.html#orders","loading-dispatch.html"]],
  [/^DELIVERY_RETURN_INFO$/,["driver-returns.html?order={o}","my-sales.html#orders"]],
  [/^TALLY_NOTE_/,["accounts-invoice.html?order={o}"]],
  [/^SALES_RETURN_NEW$/,["sales-return.html","accounts-invoice.html?order={o}","credit-note.html"]],
  [/^DELIVERY_RETURN_(PENDING|OPERATIONS|RECEIVE|DEDUCTED)$/,["driver-returns.html?order={o}"]],
  [/^DELIVERY_COLLECTION$/,["driver-collections.html?order={o}"]],
  [/^DELIVERY_COLLECTION_/,["driver-delivery.html?order={o}&tab=deliver"]],
  [/^DELIVERY_RETURN_/,["driver-delivery.html?order={o}&tab=return"]],
  [/^LOADING_ASSIGNMENT_DRIVER$/,["driver-delivery.html?order={o}","loading-dispatch.html","transport-allocation.html"]],
  [/^LOADING_ASSIGNMENT_/,["loading-dispatch.html?order={o}","transport-allocation.html"]],
  [/^GODOWN_/,["godown-report.html"]],
  [/^MARKET_/,["market-report.html"]],
  [/^SALES_PLAN$/,["my-sales.html","sales-team.html"]],
  [/^ORDER_/,["my-sales.html#orders","warehouse-orders.html","driver-delivery.html?order={o}","loading-dispatch.html"]]
 ];
 function route(n,pages){
  const t=baseType(n),hit=ROUTES.find(r=>r[0].test(t));
  if(!hit)return "";
  const base=h=>h.split(/[?#]/)[0];
  const href=(pages&&pages.length?hit[1].find(h=>pages.includes(base(h))):hit[1][0])||"";
  return n.order_id?href.replace("{o}",encodeURIComponent(n.order_id)):href.split("?")[0];
 }
 // Every new notification pops up once per device (Sales Head copies CC_* stay in the bell only).
 // These have their own title / button; href null = the notification's own page.
 const POPUP={LOADING_ASSIGNMENT_DRIVER:["🚚 New Transport Assignment","Open order",null],ANNOUNCEMENT:["📢 Focus message","OK",""],MARKET_REPORT:["🚩 Outside market stock","Open report","market-report.html"],
  DELIVERY_RETURN_APPROVED:["✅ Return approved","Open order",null],DELIVERY_RETURN_REJECTED:["❌ Return rejected","Open order",null],
  DELIVERY_COLLECTION_VERIFIED:["✅ Payment verified","Open order",null],DELIVERY_COLLECTION_REJECTED:["❌ Payment rejected","Correct it",null],
  DELIVERY_RETURN_DEDUCTED:["↩ Return amount cut","Open",null]};
 // Urgent, until done: returns waiting for approval (office) and approved returns to receive (godown).
 // They pop up on every page, again 15 min after "Later", until handled or opened from the bell.
 const URGENT=[
  {re:/^DELIVERY_RETURN_(PENDING|OPERATIONS)$/,key:"lwbReturnSnooze",title:"↩ Driver return waiting",ok:"Verify now",
   one:"A driver return is",many:" driver returns are",ask:" waiting for your check:",
   foot:"Only approved returns are cut from the bill. Until then the driver collects the full amount."},
  // Accounts: driver collected money, until it is received from the driver and verified on Driver Collections.
  {re:/^DELIVERY_COLLECTION$/,key:"lwbCollectSnooze",title:"💰 Money on the way — receive from driver",ok:"Receive & verify",
   skip:"driver-collections.html",one:"A driver payment is",many:" driver payments are",ask:" on the way to the office:",
   foot:"When the driver comes back, count the cash / check the UPI photo, then tap Verify on Driver Collections. This reminder stops once it is verified."},
  {re:/^TALLY_BILL_PENDING$/,key:"lwbTallySnooze",title:"🧾 Vehicle loaded — make Tally bill",skip:"accounts-invoice.html",ok:"Enter invoice no.",
   one:"A loaded vehicle is",many:" loaded vehicles are",ask:" waiting for the Tally bill:",
   foot:"Make the bill in Tally, then enter its invoice number. This reminder stops once the number is saved."},
  // Godown Manager: vehicle assigned to him for loading, until he starts / confirms the loading.
  {re:/^LOADING_ASSIGNMENT_DISPATCH$/,only:n=>/^Load This Vehicle/i.test(n.title||""),key:"lwbLoadSnooze",title:"🚛 Vehicle Loading Assignment",ok:"Open loading",
   skip:"loading-dispatch.html",one:"A vehicle is",many:" vehicles are",ask:" assigned to you for loading:",
   foot:"Please load the approved quantities, then tap ✅ Confirm Vehicle Loaded. Accounts and the Sales Head are informed automatically.",full:true},
  {re:/^DELIVERY_RETURN_RECEIVE$/,key:"lwbReceiveSnooze",title:"📦 Receive returned goods",ok:"Open",
   one:"An approved return is",many:" approved returns are",ask:" coming back to the godown:",
   foot:"When the vehicle comes back, check the goods and tap Goods received on Driver Returns.",full:true}
 ],SNOOZE=15*60e3;
 let popping=false;
 async function urgentPopup(rows,pages){
  for(const g of URGENT){
   if(location.pathname.endsWith(g.skip||"driver-returns.html"))continue;
   const due=rows.filter(n=>!n.is_read&&g.re.test(String(n.notification_type||"").toUpperCase())&&(!g.only||g.only(n))&&Date.now()-new Date(n.created_at)<3*864e5);
   const href=due.length?route(due[0],pages):"";
   if(!href)continue;
   let snoozed=0;try{snoozed=Number(localStorage.getItem(g.key))||0}catch(e){}
   if(Date.now()-snoozed<SNOOZE)continue;
   const lines=g.full&&due.length===1?[due[0].message||""]:due.slice(0,5).map(n=>"• "+summary(n).text.replace(/ · (Verify|Warehouse check)$/,"").replace(/^(Return|Receive return goods) · /,""));
   if(due.length>5)lines.push("… and "+(due.length-5)+" more");
   const orders=new Set(due.map(n=>n.order_id));
   const text=(due.length===1?g.one:due.length+g.many)+g.ask+"\n\n"+lines.join("\n")+"\n\n"+g.foot;
   try{localStorage.setItem(g.key,String(Date.now()))}catch(e){}
   const go=await window.confirm(text,{title:g.title,ok:g.ok,cancel:"Later"});
   if(go){location.href=orders.size===1?href:href.split("?")[0];return true}
  }
  return false;
 }
 async function popup(rows,pages,markRead){
  if(popping||typeof window.confirm!=="function")return;
  popping=true;
  try{
   if(await urgentPopup(rows,pages))return;
   let seen=[];try{seen=JSON.parse(localStorage.getItem("lwbPopped")||"[]")}catch(e){}
   const type=n=>String(n.notification_type||"").toUpperCase();
   const fresh=rows.filter(n=>!n.is_read&&!seen.includes(n.id)&&!/^CC_/.test(type(n))&&!URGENT.some(g=>g.re.test(type(n)))
    &&Date.now()-new Date(n.created_at)<(POPUP[type(n)]?2*864e5:12*36e5));
   if(!fresh.length)return;
   seen=seen.concat(fresh.map(n=>n.id)).slice(-300);
   try{localStorage.setItem("lwbPopped",JSON.stringify(seen))}catch(e){}
   // Many at once (e.g. after a break): one list instead of a row of popups.
   if(fresh.length>3){
    const lines=fresh.slice(0,8).map(n=>{const s=summary(n);return s.icon+" "+s.text});
    if(fresh.length>8)lines.push("… and "+(fresh.length-8)+" more");
    await window.alert(lines.join("\n")+"\n\nOpen the 🔔 bell to see each one.",{title:"🔔 "+fresh.length+" new updates",kind:"info"});
    return;
   }
   for(const n of fresh.reverse()){
    const s=summary(n),[title,ok,page]=POPUP[type(n)]||[s.icon+" "+(n.title||s.text),"Open",null],href=page===null?route(n,pages):page;
    const text=(n.title&&n.notification_type==="ANNOUNCEMENT"?n.title+"\n\n":"")+(n.message||"");
    const go=href?await window.confirm(text,{title,ok,cancel:"Later"}):(await window.alert(text,{title,kind:"info"}),false);
    if(go&&page===null){await markRead(n.id);location.href=href;break}
    if(go&&!location.pathname.endsWith(href)){location.href=href;break}
   }
  }finally{popping=false}
 }
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
   ".lwb-op-panel{position:absolute;top:calc(100% + 9px);right:0;z-index:99999;width:min(460px,92vw);max-height:440px;overflow-y:auto;background:#fff;color:#173450;border:1px solid #cbd5e2;border-radius:10px;box-shadow:0 12px 35px #0003;padding:12px;font:13px/1.4 Arial,sans-serif;white-space:normal;text-align:left}",
   ".lwb-op-panel[hidden]{display:none}.lwb-op-head{display:flex;align-items:center;justify-content:space-between;gap:9px;margin-bottom:8px}",
   ".lwb-op-panel button{padding:7px 9px;border:1px solid #bbd1e7;background:#eef5fc;color:#164679;border-radius:6px;cursor:pointer;font:12px Arial,sans-serif}",
   ".lwb-op-msg{border-top:1px solid #e0e8f1;color:#173450}",
   ".lwb-op-msg.unread{background:#fff8e0}.lwb-op-msg p{margin:2px 10px 8px 28px;color:#51657a;overflow-wrap:anywhere}",
   ".lwb-op-row{display:flex;align-items:center;gap:8px;padding:8px 6px;cursor:pointer}",
   ".lwb-op-ic{flex:0 0 20px;text-align:center;font-size:15px}",
   ".lwb-op-sum{flex:1;min-width:0;font-weight:700;font-size:13.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}",
   ".lwb-op-msg:not(.unread) .lwb-op-sum{font-weight:400;color:#51657a}",
   ".lwb-op-time{flex:0 0 auto;color:#71849a;font-size:12px}",
   ".lwb-op-go{flex:0 0 auto;color:#164679;font-size:18px;line-height:1}",
   ".lwb-op-row.link:hover{background:#eef5fc}",
   ".lwb-op-panel button.lwb-op-tick{padding:3px 7px;font-size:12px}",
   ".lwb-op-error{color:#ac2828!important}"
  ].join("");
  document.head.append(css);
  const wrap=el("div","lwb-op-wrap"),bell=el("button","lwb-op-bell","🔔"),count=el("span","lwb-op-count","0");
  bell.id="lwbOpsBell";bell.type="button";
  bell.setAttribute("aria-label","ERP Notifications");bell.setAttribute("aria-expanded","false");
  bell.append(count);
  const panel=el("section","lwb-op-panel"),head=el("div","lwb-op-head"),reload=el("button",null,"Refresh"),allRead=el("button",null,"Mark all read");
  panel.hidden=true;panel.setAttribute("aria-label","ERP Notifications");
  reload.type="button";allRead.type="button";allRead.hidden=true;
  const btns=el("span");btns.style.cssText="display:flex;gap:6px";btns.append(allRead,reload);
  head.append(el("strong",null,"🔔 ERP Notifications"),btns);
  const list=el("div");panel.append(head,list);wrap.append(bell,panel);mount.prepend(wrap);
  async function reloadData(){
   const {data,error}=await db.from("erp_notifications")
    .select("id,title,message,order_id,notification_type,is_read,created_at")
    .eq("user_id",user.id).order("created_at",{ascending:false}).limit(70);
   if(error){list.replaceChildren(el("p","lwb-op-error","Notification error: "+error.message));return}
   // Driver sees no history: only the last 12 hours.
   const rows=(data||[]).filter(n=>String(role||"").toLowerCase()!=="driver"||Date.now()-new Date(n.created_at)<12*36e5),unread=rows.filter(n=>!n.is_read).length;
   count.textContent=unread>99?"99+":String(unread);count.style.display=unread?"inline-block":"none";
   list.replaceChildren();
   popup(rows,pages,id=>db.from("erp_notifications").update({is_read:true}).eq("id",id).eq("user_id",user.id));
   if(!rows.length){list.append(el("p",null,"No notifications yet."));return}
   allRead.hidden=!unread;
   for(const n of rows){
    const box=el("div","lwb-op-msg"+(n.is_read?"":" unread")),sum=summary(n);
    const href=route(n,pages),row=el("div","lwb-op-row"+(href?" link":""));
    row.title=href?"Open":"Click to view details";
    row.append(el("span","lwb-op-ic",sum.icon),el("span","lwb-op-sum",sum.text),el("span","lwb-op-time",ago(n.created_at)));
    if(href)row.append(el("span","lwb-op-go","›"));
    const full=el("p",null,(n.title?n.title+": ":"")+(n.message||""));full.hidden=true;
    // Click opens the page of this notification (and marks it read); others show the full text.
    row.addEventListener("click",async e=>{
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
     row.append(read);
    }
    box.append(row,full);
    list.append(box);
   }
  }
  allRead.addEventListener("click",async()=>{
   allRead.disabled=true;
   const {error:err}=await db.from("erp_notifications").update({is_read:true}).eq("user_id",user.id).eq("is_read",false);
   allRead.disabled=false;
   if(err)list.prepend(el("p","lwb-op-error",err.message));else await reloadData();
  });
  bell.addEventListener("click",()=>{
    panel.hidden=!panel.hidden;bell.setAttribute("aria-expanded",String(!panel.hidden));
    if(!panel.hidden)reloadData();
  });
  reload.addEventListener("click",reloadData);
  document.addEventListener("click",e=>{
   if(!wrap.contains(e.target)){panel.hidden=true;bell.setAttribute("aria-expanded","false")}
  });
  reloadData();
  setInterval(()=>{if(!document.hidden)reloadData()},30000);
  // Instant: a new row for this login reloads the bell (and pops it up) at once.
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
