/* LUXURY WRIST BRAND ERP — 🔔 New-notification popup + sound (Mohit, 27 Nov 2026)
   "Koi bhi notification aaye to popup aaye aur sound baje; new order ka sound alag, task ka alag."
   erp-operations-notifications.js feeds every bell load here. A row that is NEW since this page opened
   (not old history) shows a small popup at the top and plays the sound of its type.
   Sounds are made with Web Audio (no sound files), one per type:
     order    New order          bright 3-note rising chime
     approve  Approve / check    ding-dong doorbell
     task     Task / complaint   3 quick knocks
     money    Payment / cash     coin "cha-ching"
     delivery Vehicle / delivery  2 low horn beeps
     stock    Stock / purchase   soft wood (marimba) 2 notes
     alert    Late / rejected    falling warning tone
     other    Any other update   one soft ding
   No mute (Mohit 27 Nov): the same sounds ring for every login. "Try sounds" in the bell plays each one.
   Browsers play sound only after the person has
   touched the page once; until then the popup still shows. Several open tabs: only one popup/sound. */
(function(){
 "use strict";
 if(window.LWBNotifyPopup)return;
 const SEEN="lwbPopSeen";

 // ---------- Sounds ----------
 let ctx=null;
 function ac(){
  try{ctx=ctx||new (window.AudioContext||window.webkitAudioContext)();if(ctx.state==="suspended")ctx.resume().catch(()=>{});return ctx}catch(e){return null}
 }
 // Unlock audio on the first touch / key (browser rule), so a later popup can ring.
 const unlock=()=>{ac();removeEventListener("pointerdown",unlock,true);removeEventListener("keydown",unlock,true)};
 addEventListener("pointerdown",unlock,true);addEventListener("keydown",unlock,true);
 // One note: start s, length d, frequency f (or [from,to] slide), wave w, volume v.
 function note(c,out,s,d,f,w,v){
  const o=c.createOscillator(),g=c.createGain(),t=c.currentTime+s;
  o.type=w||"sine";
  if(Array.isArray(f)){o.frequency.setValueAtTime(f[0],t);o.frequency.exponentialRampToValueAtTime(f[1],t+d)}else o.frequency.setValueAtTime(f,t);
  g.gain.setValueAtTime(0.0001,t);g.gain.exponentialRampToValueAtTime(v||0.5,t+0.012);g.gain.exponentialRampToValueAtTime(0.0001,t+d);
  o.connect(g);g.connect(out);o.start(t);o.stop(t+d+0.05);
 }
 const SOUNDS={
  order:[[0,.22,1047,"triangle",.55],[.13,.22,1319,"triangle",.55],[.26,.5,1568,"triangle",.6],[.26,.5,3136,"sine",.12]],
  approve:[[0,.55,1319,"sine",.6],[0,.55,2638,"sine",.1],[.32,.8,988,"sine",.6],[.32,.8,1976,"sine",.1]],
  task:[[0,.09,880,"square",.22],[.14,.09,880,"square",.22],[.28,.16,1175,"square",.25]],
  money:[[0,.08,1976,"triangle",.4],[.07,.4,2637,"triangle",.5],[.07,.4,3951,"sine",.15],[.18,.3,3520,"sine",.12]],
  delivery:[[0,.22,330,"sawtooth",.28],[0,.22,415,"sawtooth",.18],[.3,.32,330,"sawtooth",.28],[.3,.32,415,"sawtooth",.18]],
  stock:[[0,.25,784,"sine",.55],[0,.08,2352,"sine",.12],[.16,.35,587,"sine",.55],[.16,.08,1761,"sine",.12]],
  alert:[[0,.22,[988,740],"square",.25],[.26,.22,[880,660],"square",.25],[.52,.4,[784,523],"square",.28]],
  other:[[0,.6,1175,"sine",.5],[0,.3,2350,"sine",.08]]
 };
 const LABEL={order:"New order",approve:"Approval",task:"Task",money:"Payment",delivery:"Delivery",stock:"Stock",alert:"Alert",other:"Update"};
 function play(k){
  const c=ac();if(!c)return false;
  const out=c.createGain();out.gain.value=0.9;out.connect(c.destination);
  for(const n of SOUNDS[k]||SOUNDS.other)note(c,out,...n);
  return c.state==="running";
 }
 // Which sound a notification gets (sum = the bell's summary: cat, tone, action).
 function soundOf(type,sum){
  if(sum.tone==="bad")return "alert";
  if(type==="ORDER_NEW")return "order";
  if(sum.cat==="task")return "task";
  if(/^Approve$|^Verify$|^Check$/.test(sum.action||"")&&sum.cat!=="money")return "approve";
  if(sum.cat==="money")return "money";
  if(sum.cat==="delivery")return "delivery";
  if(sum.cat==="stock")return "stock";
  if(sum.cat==="order")return sum.action?"approve":"other";
  return "other";
 }

 // ---------- Popup ----------
 const css=`
 .lnp{position:fixed;top:62px;right:14px;z-index:2147482000;display:flex;flex-direction:column;gap:8px;width:min(360px,calc(100vw - 16px));pointer-events:none;font:13px/1.35 'Segoe UI',Roboto,Arial,sans-serif}
 .lnp-t{pointer-events:auto;display:flex;gap:9px;align-items:flex-start;background:#fff;color:#1f2a37;border:1px solid #dde3ea;border-left:5px solid var(--c);border-radius:11px;box-shadow:0 10px 28px rgba(16,24,40,.22);padding:9px 10px;cursor:pointer;animation:lnpIn .25s ease-out}
 .lnp-t.out{animation:lnpOut .25s ease-in forwards}
 @keyframes lnpIn{from{transform:translateY(-14px);opacity:0}}@keyframes lnpOut{to{transform:translateX(30px);opacity:0}}
 .lnp-ic{flex:0 0 34px;height:34px;border-radius:9px;display:flex;align-items:center;justify-content:center;background:var(--b);color:var(--c)}
 .lnp-bd{flex:1;min-width:0}
 .lnp-l{display:flex;align-items:center;gap:6px;min-width:0}
 .lnp-tag{flex:0 0 auto;font-size:10px;font-weight:800;letter-spacing:.3px;text-transform:uppercase;padding:1px 6px;border-radius:999px;background:var(--b);color:var(--c)}
 .lnp-h{font-weight:800;font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
 .lnp-x{margin-left:auto;flex:0 0 auto;border:0;background:none;color:#8a96a3;font-size:16px;line-height:1;cursor:pointer;padding:0 2px}
 .lnp-p{flex:1;min-width:0;color:#3b4652;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:2px}
 .lnp-a{flex:0 0 auto;font-weight:800;color:#1f2a37;margin-top:2px}
 .lnp-d{color:#7a8794;font-size:11.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:1px}
 .lnp-go{flex:0 0 auto;align-self:center;border:0;background:#c8102e;color:#fff;font:700 12px 'Segoe UI',Roboto,Arial,sans-serif;border-radius:7px;padding:6px 10px;cursor:pointer}
 .lnp-more{pointer-events:auto;align-self:flex-end;background:#1f2a37;color:#fff;border-radius:999px;padding:4px 11px;font-weight:700;font-size:12px;cursor:pointer;box-shadow:0 6px 16px rgba(16,24,40,.25)}
 .lnp-t.c-order{--c:#1d5fbf;--b:#e8f0fc}.lnp-t.c-delivery{--c:#0f7b6c;--b:#e3f5f1}.lnp-t.c-money{--c:#1b7f3b;--b:#e6f4ea}
 .lnp-t.c-stock{--c:#6f42c1;--b:#f0eafb}.lnp-t.c-task{--c:#b85a00;--b:#fdefe0}.lnp-t.c-other{--c:#56677a;--b:#eef1f5}
 .lnp-t.t-bad{--c:#c8102e;--b:#fdecef}
 @media(max-width:560px){.lnp{top:56px;left:8px;right:8px;width:auto}.lnp-go{padding:6px 8px}}`;
 let box=null,more=null,queue=[];
 const MAX=3;
 function ensure(){
  if(box&&document.body.contains(box))return box;
  if(!document.getElementById("lnp-css")){const s=document.createElement("style");s.id="lnp-css";s.textContent=css;document.head.append(s)}
  box=document.createElement("div");box.className="lnp";box.setAttribute("role","status");box.setAttribute("aria-live","polite");
  document.body.append(box);return box;
 }
 const mk=(tag,cls,txt)=>{const x=document.createElement(tag);if(cls)x.className=cls;if(txt!=null)x.textContent=String(txt);return x};
 function close(t){if(!t||t.classList.contains("out"))return;t.classList.add("out");clearTimeout(t._tm);setTimeout(()=>{t.remove();pump()},260)}
 function pump(){
  const b=ensure();
  while(queue.length&&b.querySelectorAll(".lnp-t:not(.out)").length<MAX)b.insertBefore(card(queue.shift()),more&&more.parentNode?more:null);
  if(queue.length){
   if(!more){more=mk("div","lnp-more");more.addEventListener("click",()=>{queue=[];more.remove();const bell=document.getElementById("lwbOpsBell");bell&&bell.click()})}
   more.textContent="+"+queue.length+" more · open 🔔";b.append(more);
  }else if(more)more.remove();
 }
 function card(it){
  const {sum,tag,svg,href,open}=it;
  const t=mk("div","lnp-t c-"+sum.cat+" t-"+sum.tone);t.title=href?"Open":"Show in notifications";
  const ic=mk("span","lnp-ic");ic.innerHTML=svg;
  const bd=mk("div","lnp-bd"),l1=mk("div","lnp-l"),x=mk("button","lnp-x","×");x.type="button";x.setAttribute("aria-label","Close");
  l1.append(mk("span","lnp-tag",tag),mk("b","lnp-h",sum.head),x);
  const l2=mk("div","lnp-l");l2.append(mk("span","lnp-p",sum.line2||""));if(sum.amount)l2.append(mk("b","lnp-a",sum.amount));
  bd.append(l1,l2);
  if(sum.details&&sum.details.length)bd.append(mk("div","lnp-d",sum.details.join(" · ")));
  t.append(ic,bd);
  if(sum.action&&href){const go=mk("button","lnp-go",sum.action);go.type="button";t.append(go)}
  t.addEventListener("click",e=>{
   if(e.target===x){close(t);return}
   close(t);open();
  });
  // Work to do stays longer; plain updates go after 8 s. Hover / touch keeps it.
  const life=sum.action&&sum.tone!=="ok"?15000:8000;
  const arm=()=>{clearTimeout(t._tm);t._tm=setTimeout(()=>close(t),life)};
  t.addEventListener("mouseenter",()=>clearTimeout(t._tm));t.addEventListener("mouseleave",arm);
  arm();return t;
 }
 // Only one open tab shows a given notification (the first one to claim it).
 function claim(id){
  try{const s=JSON.parse(localStorage.getItem(SEEN)||"[]");if(s.includes(id))return false;s.push(id);localStorage.setItem(SEEN,JSON.stringify(s.slice(-80)));return true}catch(e){return true}
 }

 // ---------- Feed from the bell ----------
 // items: [{n,sum,href,tag,svg,open}] newest first. The first feed only remembers what is already there.
 let known=null;
 function feed(items){
  const ids=items.map(it=>String(it.n.id));
  if(!known){known=new Set(ids);return}
  const fresh=items.filter(it=>!known.has(String(it.n.id)));
  ids.forEach(id=>known.add(id));
  const show=fresh.filter(it=>!it.n.is_read&&!/^CC_/i.test(String(it.n.notification_type||""))&&Date.now()-new Date(it.n.created_at)<15*60000&&claim(String(it.n.id)));
  if(!show.length)return;
  // Highest-priority sound of the batch, once.
  const rank=["alert","order","approve","task","money","delivery","stock","other"];
  const snd=show.map(it=>soundOf(String(it.n.notification_type||"").toUpperCase(),it.sum)).sort((a,b)=>rank.indexOf(a)-rank.indexOf(b))[0];
  play(snd);
  // Purchase vehicle arrived has its own big popup (purchase-damage.js): sound only.
  queue.push(...show.filter(it=>String(it.n.notification_type||"").toUpperCase()!=="PURCHASE_ARRIVED").reverse());
  pump();
 }

 // ---------- Sound switch + try sounds (bell footer) ----------
 function controls(mount){
  if(!mount||mount.querySelector(".lnp-set"))return;
  const st=document.createElement("style");st.textContent=
   ".lnp-set{display:flex;flex-wrap:wrap;align-items:center;gap:5px;padding-bottom:7px;margin-bottom:7px;border-bottom:1px dashed #e3e7ec}"+
   ".lnp-set b{font-size:12px;margin-right:2px;color:#1f2a37!important}.lnp-set button{border:1px solid #dfe5ec;background:#fff;color:#3b4652;border-radius:999px;padding:3px 9px;font:600 11.5px 'Segoe UI',Roboto,Arial,sans-serif;cursor:pointer;min-height:0}"+
   ".lnp-set button.on{background:#1b7f3b;border-color:#1b7f3b;color:#fff}.lnp-set button.off{background:#fdecef;border-color:#f3c2c8;color:#c8102e}"+
   ".lnp-try{display:none;flex-wrap:wrap;gap:5px;width:100%}.lnp-set.open .lnp-try{display:flex}";
  document.head.append(st);
  const row=mk("div","lnp-set"),tr=mk("button",null,"▶ Try sounds"),list=mk("div","lnp-try");
  tr.type="button";
  tr.addEventListener("click",e=>{e.stopPropagation();row.classList.toggle("open")});
  for(const k of Object.keys(SOUNDS)){const b=mk("button",null,"▶ "+LABEL[k]);b.type="button";b.addEventListener("click",e=>{e.stopPropagation();play(k)});list.append(b)}
  row.append(mk("b",null,"🔊 Notification sounds"),tr,list);
  mount.prepend(row);
 }
 window.LWBNotifyPopup={feed,play,controls,soundOf,sounds:Object.keys(SOUNDS),
  // Admin / testing: LWBNotifyPopup.demo() shows sample popups with their sounds.
  demo(){known=known||new Set();const S=[
   {cat:"order",tone:"act",head:"New order",action:"Approve",line2:"Shree Dev Trading",amount:"₹48,600",details:["LXY-00712","120 CS","By Ramesh"]},
   {cat:"task",tone:"act",head:"Call party for payment",action:"",line2:"From Mohit (Admin)",amount:"",details:["TSK-58"]},
   {cat:"money",tone:"money",head:"Cash collected",action:"",line2:"Jagdish Traders",amount:"₹12,500",details:["LXY-00698","By Driver Suresh"]}];
   S.forEach((sum,i)=>{const it={n:{id:"demo"+Date.now()+i,is_read:false,created_at:new Date().toISOString(),notification_type:i?"":"ORDER_NEW"},sum,tag:["Order","Task","Payment"][i],svg:"",href:"",open:()=>{}};queue.push(it)});
   play("order");pump()}};
})();
