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
 function summary(n){
  const t=String(n.notification_type||"").toUpperCase(),m=String(n.message||""),title=String(n.title||"");
  const order=(m.match(/\b[A-Z]{2,6}-\d{3,}\b/)||[])[0]||"";
  const amt=(m.match(/(?:Rs\.?|₹)\s?([\d,]+(?:\.\d+)?)/i)||[])[1];
  const val=amt?Number(amt.replace(/,/g,"")):0;
  const money=amt?"₹"+val.toLocaleString("en-IN",{minimumFractionDigits:val%1?2:0,maximumFractionDigits:2}):"";
  const join=a=>a.filter(Boolean).join(" · ");
  if(t.startsWith("DELIVERY_RETURN"))return {icon:"↩",text:join(["Return",order,money,t.endsWith("OPERATIONS")?"Warehouse check":"Verify"])};
  if(t.startsWith("LOADING_ASSIGNMENT")){
   const veh=(m.match(/Vehicle ([A-Z0-9]+)/)||[])[1],drv=((m.match(/Driver ([^(·]+)/)||[])[1]||"").trim();
   return {icon:"🚚",text:join([/updated|changed|badla/i.test(title)?"Loading updated":"Loading",order,veh,drv])};
  }
  if(t.startsWith("GODOWN_")){const id=(m.match(/GDN-\d+/)||[])[0]||"";return {icon:"🏭",text:join([title.replace(/^Godown: /,"Godown · "),id])}}
  if(t.startsWith("ORDER_")){const ic={ORDER_DELIVERED:"✅",ORDER_PARTIAL:"🟠",ORDER_NOT_DELIVERED:"⚠",ORDER_CANCELLED:"✖",ORDER_EDITED:"✏"}[t]||"•";
   return {icon:ic,text:join([title,order])}}
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
 function init({db,user,mount}){
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
   const rows=data||[],unread=rows.filter(n=>!n.is_read).length;
   count.textContent=unread>99?"99+":String(unread);count.style.display=unread?"inline-block":"none";
   list.replaceChildren();
   if(!rows.length){list.append(el("p",null,"No notifications yet."));return}
   allRead.hidden=!unread;
   for(const n of rows){
    const box=el("div","lwb-op-msg"+(n.is_read?"":" unread")),sum=summary(n);
    const row=el("div","lwb-op-row");row.title="Click to view details";
    row.append(el("span","lwb-op-ic",sum.icon),el("span","lwb-op-sum",sum.text),el("span","lwb-op-time",ago(n.created_at)));
    const full=el("p",null,(n.title?n.title+": ":"")+(n.message||""));full.hidden=true;
    row.addEventListener("click",e=>{if(e.target.closest("button"))return;full.hidden=!full.hidden});
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
 }
 window.LWBOperationsNotifications={init};
})();
