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
   ".lwb-op-panel{position:absolute;top:calc(100% + 9px);right:0;z-index:99999;width:min(380px,90vw);max-height:440px;overflow-y:auto;background:#fff;color:#173450;border:1px solid #cbd5e2;border-radius:10px;box-shadow:0 12px 35px #0003;padding:12px;font:13px/1.4 Arial,sans-serif;white-space:normal;text-align:left}",
   ".lwb-op-panel[hidden]{display:none}.lwb-op-head{display:flex;align-items:center;justify-content:space-between;gap:9px;margin-bottom:8px}",
   ".lwb-op-panel button{padding:7px 9px;border:1px solid #bbd1e7;background:#eef5fc;color:#164679;border-radius:6px;cursor:pointer;font:12px Arial,sans-serif}",
   ".lwb-op-msg{padding:11px 4px;border-top:1px solid #e0e8f1;color:#173450}",
   ".lwb-op-msg.unread{background:#fff8e0}.lwb-op-msg p{margin:4px 0;color:#51657a;overflow-wrap:anywhere}",
   ".lwb-op-msg small{display:block;color:#71849a;margin:6px 0}.lwb-op-error{color:#ac2828!important}"
  ].join("");
  document.head.append(css);
  const wrap=el("div","lwb-op-wrap"),bell=el("button","lwb-op-bell","🔔"),count=el("span","lwb-op-count","0");
  bell.id="lwbOpsBell";bell.type="button";
  bell.setAttribute("aria-label","ERP Notifications");bell.setAttribute("aria-expanded","false");
  bell.append(count);
  const panel=el("section","lwb-op-panel"),head=el("div","lwb-op-head"),reload=el("button",null,"Refresh");
  panel.hidden=true;panel.setAttribute("aria-label","ERP Notifications");
  reload.type="button";head.append(el("strong",null,"🔔 ERP Notifications"),reload);
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
   for(const n of rows){
    const box=el("div","lwb-op-msg"+(n.is_read?"":" unread"));
    box.append(el("strong",null,n.title||"ERP Notification"),el("p",null,n.message||""));
    if(n.created_at)box.append(el("small",null,new Date(n.created_at).toLocaleString("en-IN")));
    if(!n.is_read){
     const read=el("button",null,"Mark as read");read.type="button";
     read.addEventListener("click",async()=>{
      read.disabled=true;
      const {error:err}=await db.from("erp_notifications").update({is_read:true})
       .eq("id",n.id).eq("user_id",user.id);
      if(err){read.disabled=false;box.append(el("p","lwb-op-error",err.message))}
      else await reloadData();
     });
     box.append(read);
    }
    list.append(box);
   }
  }
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
