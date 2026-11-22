/* LUXURY WRIST BRAND ERP — 🚨 Urgent task siren (Mohit, 22 Nov 2026; lwb_task_siren_setup.sql)
   An URGENT task rings the person every 20 minutes (9 AM - 8 PM IST) until it is Done.
   On the phone the push banner arrives (sw.js); when the ERP is open (any page) this file shows a
   full-screen red alarm and plays a loud two-tone siren made with Web Audio (no sound file):
     ✅ Done  -> marks the task done, the siren stops for good.
     ⏰ Remind in 20 min -> hides the alarm; it rings again at the next 20-minute time.
     Open task -> tasks.html?id=..
   Browsers allow sound only after the person has touched the page once; until then the alarm shows
   "Tap to sound the siren". Admin: LWBSiren.demo() plays the same alarm with a sample task. */
(function(){
  if(window.LWBSiren)return;
  const esc=s=>String(s==null?"":s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  let db=null,me=null,timer=0,box=null,cur=null,ctx=null,nodes=null,stopAt=0,buzz=0,skip=new Set();

  const css=`
  .lsr{position:fixed;inset:0;z-index:2147483000;display:flex;align-items:center;justify-content:center;padding:16px;box-sizing:border-box;
    background:#7f0000;animation:lsrBg 1s steps(1) infinite;font-family:inherit;color:#fff}
  @keyframes lsrBg{0%{background:#b71c1c}50%{background:#5d0000}}
  .lsr-card{width:100%;max-width:440px;background:#fff;color:#1c232b;border-radius:14px;box-shadow:0 18px 60px #0008;overflow:hidden}
  .lsr-top{background:#c62828;color:#fff;display:flex;align-items:center;gap:10px;padding:12px 14px}
  .lsr-ic{font-size:34px;line-height:1;animation:lsrRing .5s ease-in-out infinite alternate}
  @keyframes lsrRing{from{transform:rotate(-14deg) scale(1)}to{transform:rotate(14deg) scale(1.12)}}
  .lsr-top b{font-size:17px;letter-spacing:.6px;display:block}
  .lsr-top small{font-size:12.5px;opacity:.9}
  .lsr-mute{margin-left:auto;border:0;background:#fff2;color:#fff;border-radius:18px;padding:6px 10px;font:inherit;font-size:13px;font-weight:700;cursor:pointer}
  .lsr-body{padding:14px}
  .lsr-t{font-size:20px;font-weight:800;line-height:1.25;overflow-wrap:anywhere;margin:0 0 6px}
  .lsr-d{font-size:13.5px;color:#4b5763;white-space:pre-wrap;overflow-wrap:anywhere;max-height:90px;overflow:auto;margin:0 0 8px}
  .lsr-m{display:flex;flex-wrap:wrap;gap:6px;font-size:12.5px;margin-bottom:12px}
  .lsr-m span{background:#f1f3f5;border-radius:10px;padding:3px 8px;color:#4b5763}
  .lsr-m span.r{background:#fdecea;color:#c62828;font-weight:800}
  .lsr-tap{display:none;background:#fff3c4;color:#7a4a00;border-radius:8px;padding:8px 10px;font-weight:700;font-size:13.5px;margin-bottom:10px;text-align:center}
  .lsr.locked .lsr-tap{display:block}
  .lsr-btns{display:flex;gap:8px}
  .lsr-btns button{flex:1;min-width:0;height:48px;border-radius:10px;font:inherit;font-size:15px;font-weight:800;cursor:pointer;border:2px solid transparent;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .lsr-done{background:#1b7f3b;color:#fff}
  .lsr-done.sure{background:#0d5c28;box-shadow:0 0 0 3px #b9e6c8}
  .lsr-later{background:#fff;color:#1c232b;border-color:#d5dae0!important}
  .lsr-open{flex:0 0 auto!important;background:#fff;color:#c62828;border-color:#f3c2c2!important;padding:0 12px}
  .lsr-foot{font-size:11.5px;color:#7a838c;text-align:center;margin-top:10px}
  .lsr-foot button{border:0;background:none;color:#1a56b0;font:inherit;font-size:12px;font-weight:700;cursor:pointer;padding:0 2px}
  @media(max-width:380px){.lsr-btns button{font-size:14px}.lsr-t{font-size:18px}}`;

  // ---------- Sound: police-style siren, wail (slow up/down) then yelp (fast), loud and clear ----------
  function startSound(){
    try{
      ctx=ctx||new (window.AudioContext||window.webkitAudioContext)();
      if(ctx.state==="suspended")ctx.resume().catch(()=>{});
      stopSound(true);
      const out=ctx.createDynamicsCompressor();out.threshold.value=-10;out.ratio.value=8;
      const g=ctx.createGain();g.gain.value=0.0001;g.gain.exponentialRampToValueAtTime(0.95,ctx.currentTime+0.15);
      const o1=ctx.createOscillator(),o2=ctx.createOscillator(),g2=ctx.createGain();
      o1.type="sawtooth";o2.type="square";g2.gain.value=0.35;
      const t0=ctx.currentTime,f1=o1.frequency,f2=o2.frequency;
      // 60 seconds: 4 s wail, 2 s yelp, repeat.
      let t=t0;
      f1.setValueAtTime(620,t);f2.setValueAtTime(622,t);
      while(t<t0+60){
        for(let i=0;i<2;i++){ // wail: 2 slow sweeps
          f1.linearRampToValueAtTime(1450,t+1);f1.linearRampToValueAtTime(620,t+2);
          f2.linearRampToValueAtTime(1453,t+1);f2.linearRampToValueAtTime(622,t+2);t+=2;
        }
        for(let i=0;i<8;i++){ // yelp: fast sweeps
          f1.linearRampToValueAtTime(1500,t+0.125);f1.linearRampToValueAtTime(700,t+0.25);
          f2.linearRampToValueAtTime(1503,t+0.125);f2.linearRampToValueAtTime(702,t+0.25);t+=0.25;
        }
      }
      o1.connect(g);o2.connect(g2);g2.connect(g);g.connect(out);out.connect(ctx.destination);
      o1.start();o2.start();o1.stop(t0+60);o2.stop(t0+60);
      nodes={o1,o2,g};stopAt=Date.now()+60000;
      if(navigator.vibrate){const v=()=>{try{navigator.vibrate([900,250,900,250,900])}catch(e){}};v();clearInterval(buzz);buzz=setInterval(()=>{if(Date.now()>stopAt)clearInterval(buzz);else v()},3500)}
      setTimeout(()=>{if(box)box.classList.toggle("locked",ctx.state!=="running")},250);
    }catch(e){if(box)box.classList.add("locked")}
  }
  function stopSound(keepCtx){
    clearInterval(buzz);try{navigator.vibrate&&navigator.vibrate(0)}catch(e){}
    if(nodes){try{nodes.g.gain.cancelScheduledValues(0);nodes.o1.stop();nodes.o2.stop()}catch(e){}nodes=null}
    if(!keepCtx&&box){const m=box.querySelector(".lsr-mute");if(m)m.textContent="🔊 Sound"}
  }

  // ---------- Full-screen alarm ----------
  function show(t,opt){
    opt=opt||{};cur=t;
    if(!document.getElementById("lsr-css")){const s=document.createElement("style");s.id="lsr-css";s.textContent=css;document.head.appendChild(s)}
    if(box)box.remove();
    box=document.createElement("div");box.className="lsr";box.setAttribute("role","alertdialog");box.setAttribute("aria-label","Urgent task");
    const by=esc(t.assigned_by_name||"Admin")+(t.assigned_by_role?" ("+esc(t.assigned_by_role)+")":"");
    const every=t.every_min||20;
    box.innerHTML='<div class="lsr-card"><div class="lsr-top"><span class="lsr-ic">🚨</span><div><b>URGENT TASK</b><small>'+(opt.demo?"DEMO · how it rings on staff phones":"Ring "+(t.siren_count||1)+" · rings every "+every+" min till done")+'</small></div>'+
      '<button type="button" class="lsr-mute" data-s="mute">🔇 Mute</button></div><div class="lsr-body">'+
      '<p class="lsr-t">'+esc(t.title)+"</p>"+(t.details?'<p class="lsr-d">'+esc(t.details)+"</p>":"")+
      '<div class="lsr-m"><span class="r">TSK-'+esc(t.id)+'</span><span>From '+by+"</span>"+(t.due_date?"<span>Due "+esc(window.LWBDate?LWBDate.d(t.due_date):t.due_date)+"</span>":"")+"</div>"+
      '<div class="lsr-tap">🔊 Tap anywhere to sound the siren</div>'+
      '<div class="lsr-btns"><button type="button" class="lsr-done" data-s="done">✅ Done</button><button type="button" class="lsr-later" data-s="later" title="Hide now, ring again in '+every+' min">⏰ Later '+every+"m</button>"+
      (opt.demo?"":'<button type="button" class="lsr-open" data-s="open" title="Open task">Open</button>')+"</div>"+
      '<div class="lsr-foot">'+(opt.demo?'Demo only, no task is changed. <button type="button" data-s="phone">📱 Send a demo siren to my phone</button>':"Rings only 9 AM - 8 PM. Stops when the task is Done.")+"</div></div></div>";
    document.body.appendChild(box);
    box.addEventListener("pointerdown",()=>{if(ctx&&ctx.state!=="running"){ctx.resume().then(()=>{box&&box.classList.remove("locked")}).catch(()=>{})}},true);
    box.addEventListener("click",e=>{const b=e.target.closest("[data-s]");if(b)act(b,opt)});
    startSound();
  }
  function hide(){stopSound();if(box){box.remove();box=null}cur=null}
  async function act(b,opt){
    const s=b.dataset.s,t=cur;if(!t)return;
    if(s==="mute"){if(nodes){stopSound();b.textContent="🔊 Sound"}else{startSound();b.textContent="🔇 Mute"}return}
    if(s==="phone"){
      b.disabled=true;const r=await db.rpc("lwb_task_siren_test");b.disabled=false;
      b.textContent=r.error?"Could not send: "+(/lwb_task_siren/.test(r.error.message)?"run lwb_task_siren_setup.sql":r.error.message):"✓ Sent. Check your phone in a few seconds.";return}
    if(opt.demo){if(s==="done"&&!b.classList.contains("sure")){b.classList.add("sure");b.textContent="Tap again: Done";return}hide();return}
    if(s==="done"){
      if(!b.classList.contains("sure")){b.classList.add("sure");b.textContent="Tap again: Done";return}
      b.disabled=true;b.textContent="Saving...";
      const r=await db.rpc("lwb_task_update",{p_id:t.id,p_status:"DONE",p_note:"Done (from the siren alarm)",p_due:null});
      if(r.error){b.disabled=false;b.classList.remove("sure");b.textContent="✅ Done";alert("Could not save: "+r.error.message);return}
      hide();toast("TSK-"+t.id+" done. Siren stopped.");document.dispatchEvent(new CustomEvent("lwb:task-changed"));return;
    }
    db.rpc("lwb_task_siren_seen",{p_id:t.id}).then(()=>{}).catch(()=>{});
    if(s==="open"){hide();location.href="tasks.html?id="+encodeURIComponent(t.id);return}
    hide();toast("OK. It rings again in "+(t.every_min||20)+" min if not done.");
  }
  function toast(m){try{window.ERPShell&&ERPShell.toast?ERPShell.toast(m):null}catch(e){}}

  // ---------- Check for my sirens ----------
  async function check(){
    if(!db||box||document.hidden)return;
    const r=await db.rpc("lwb_task_my_sirens");
    if(r.error){if(/lwb_task_my_sirens|function/i.test(r.error.message))clearInterval(timer);return}
    const t=(r.data||[]).find(x=>!skip.has(x.id+"@"+x.siren_count));
    if(t){skip.add(t.id+"@"+t.siren_count);show(t)}
  }
  function init(o){
    if(db)return;db=o.db;me=o.user;
    const q=new URLSearchParams(location.search).get("siren");
    if(q==="demo"&&String(o.role||"").toLowerCase()==="admin")setTimeout(()=>demo(),300);
    check();timer=setInterval(check,60000);
    document.addEventListener("visibilitychange",()=>{if(!document.hidden)check()});
    if(navigator.serviceWorker)navigator.serviceWorker.addEventListener("message",e=>{if(e.data&&e.data.type==="LWB_SIREN")setTimeout(check,1500)});
  }
  function demo(t){
    show(Object.assign({id:"DEMO",title:"Send the Coca-Cola truck to Shree Dev Trading now",details:"Party is waiting since morning. Call me when it leaves.",
      assigned_by_name:"Mohit",assigned_by_role:"Admin",due_date:new Date(Date.now()+19800000).toISOString().slice(0,10),siren_count:1,every_min:20},t||{}),{demo:true});
  }
  window.LWBSiren={init,demo,show,hide,check};
})();
