/* LUXURY WRIST BRAND ERP — Team Chat (Mohit, 12 Nov 2026).
   Round chat button in the bottom-right corner of every ERP page / the phone app (loaded by erp-shell.js).
   - Personal chat (tag one person) and @All groups; @name in a message highlights it for that person.
   - New message: a small card above the button for 5 seconds (stays while the mouse / finger is on it),
     at most 3 at once; the button keeps the unread count until the chat is read.
   - Admin: "Everyone's chats" tab (only looks), deletes a message or a whole chat.
   Needs lwb_team_chat_setup.sql; until it is run the button does not show. Database rules are the real check. */
(function(){
  "use strict";
  if(window.LWBChat)return;
  const POP_MS=5000,MAX_POPS=3,PAGE=60;
  const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const ICON='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z"/><path d="M8 11h8M8 14h5"/></svg>';
  const COLORS=["#00434d","#13824a","#c8102e","#1d5fbf","#b26b00","#7a4b9a","#0f766e","#9a3412"];
  const color=s=>{let h=0;for(const c of String(s||""))h=(h*31+c.charCodeAt(0))>>>0;return COLORS[h%COLORS.length]};
  const initials=s=>{const w=String(s||"?").replace(/^@all\s*/i,"").split(/[^\p{L}\p{N}]+/u).filter(Boolean);return ((w[0]||"?")[0]+((w[1]||"")[0]||"")).toUpperCase()};
  const av=(name,group,cls)=>'<span class="lc-av'+(cls?" "+cls:"")+'" style="background:'+color(name)+'">'+(group?"ALL":esc(initials(name)))+'</span>';
  function when(t){
    if(!t)return "";const d=new Date(t),now=new Date();
    const hm=d.toLocaleTimeString("en-IN",{hour:"numeric",minute:"2-digit"});
    if(d.toDateString()===now.toDateString())return hm;
    const y=new Date(now);y.setDate(now.getDate()-1);
    if(d.toDateString()===y.toDateString())return "Yesterday";
    return d.toLocaleDateString("en-IN",{day:"numeric",month:"short"});
  }
  const dayOf=t=>{const d=new Date(t),n=new Date();if(d.toDateString()===n.toDateString())return "Today";const y=new Date(n);y.setDate(n.getDate()-1);return d.toDateString()===y.toDateString()?"Yesterday":d.toLocaleDateString("en-IN",{day:"numeric",month:"short",year:"numeric"})};

  const CSS=`
.lc-root{font:13px/1.35 "Segoe UI",Roboto,Arial,sans-serif;color:#10262b;--lc-teal:var(--erp-red-dark,#002f37);--lc-gold:#c9b26a;--lc-line:#e3e6e2;--lc-mut:#55686c}
.lc-root *{box-sizing:border-box}
.lc-fab{position:fixed;right:18px;bottom:calc(18px + var(--lc-lift,0px));z-index:4400;display:flex;align-items:center;gap:8px}
.lc-fab .lc-lbl{background:var(--lc-gold);color:var(--lc-teal);font-weight:700;font-size:12px;padding:4px 9px;border-radius:6px;box-shadow:0 2px 6px rgba(0,0,0,.15);cursor:pointer}
.lc-btn{position:relative;width:54px;height:54px;border-radius:50%;background:var(--lc-teal);color:#fff;display:grid;place-items:center;border:3px solid var(--lc-gold);box-shadow:0 6px 16px rgba(0,47,55,.35);cursor:pointer;padding:0}
.lc-btn svg{width:25px;height:25px}
.lc-btn.open{background:#fff;color:var(--lc-teal)}
.lc-badge{position:absolute;top:-5px;right:-5px;min-width:20px;background:#c62828;color:#fff;font-size:11px;font-weight:700;border-radius:10px;padding:1px 5px;border:2px solid #fff;text-align:center}
.lc-badge.at{background:#e0a100;color:#10262b}
.lc-pops{position:fixed;right:18px;bottom:calc(84px + var(--lc-lift,0px));z-index:4401;display:flex;flex-direction:column;gap:8px;width:300px;max-width:calc(100vw - 28px)}
.lc-pop{position:relative;background:#fff;border-radius:12px;box-shadow:0 8px 22px rgba(0,0,0,.2);padding:8px 26px 10px 10px;display:flex;gap:8px;border-left:4px solid #13824a;cursor:pointer;overflow:hidden;animation:lcIn .18s ease-out}
.lc-pop.at{border-left-color:#e0a100;background:#fffcf0}
@keyframes lcIn{from{transform:translateY(8px);opacity:0}}
.lc-pop b{font-size:12.5px}.lc-pop small{color:var(--lc-mut);font-size:10.5px}
.lc-pop p{margin:2px 0 5px;font-size:12px;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;word-break:break-word}
.lc-pop .lc-x{position:absolute;top:4px;right:6px;border:0;background:none;color:var(--lc-mut);font-size:14px;cursor:pointer;padding:2px 4px}
.lc-pop .lc-bar{position:absolute;left:0;bottom:0;height:3px;background:#13824a;width:100%;transform-origin:left}
.lc-pop.at .lc-bar{background:#e0a100}
.lc-acts{display:flex;gap:6px}
.lc-acts button,.lc-sbtn{font:600 11.5px inherit;font-family:inherit;border:1px solid var(--lc-line);border-radius:6px;padding:2px 8px;background:#fff;color:var(--lc-teal);cursor:pointer;white-space:nowrap}
.lc-av{width:34px;height:34px;border-radius:50%;display:grid;place-items:center;color:#fff;font-weight:700;font-size:12px;flex:none}
.lc-av.sm{width:24px;height:24px;font-size:10px}
.lc-av svg{width:15px;height:15px}
.lc-panel{position:fixed;right:18px;bottom:calc(84px + var(--lc-lift,0px));z-index:4402;width:370px;height:min(560px,calc(100vh - 110px));background:#fff;border-radius:14px;box-shadow:0 12px 32px rgba(0,0,0,.25);display:flex;flex-direction:column;overflow:hidden}
.lc-panel[hidden]{display:none}
.lc-ph{background:var(--lc-teal);color:#fff;padding:8px 10px;display:flex;align-items:center;gap:8px;flex:none}
.lc-ph .lc-t{flex:1;min-width:0}.lc-ph b{display:block;font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.lc-ph small{display:block;color:#a9c7c9;font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.lc-ph button{border:1px solid rgba(255,255,255,.25);background:none;color:#e6f0f0;border-radius:6px;padding:3px 8px;font:600 12px inherit;font-family:inherit;cursor:pointer;white-space:nowrap}
.lc-ph .lc-back{border:0;font-size:18px;padding:0 4px}
.lc-seg{display:flex;margin:8px 10px 4px;border:1px solid var(--lc-line);border-radius:8px;overflow:hidden;flex:none}
.lc-seg button{flex:1;border:0;background:#fff;padding:5px;font:600 12px inherit;font-family:inherit;color:var(--lc-mut);cursor:pointer}
.lc-seg button.on{background:#e6f0f0;color:var(--lc-teal)}
.lc-find{margin:4px 10px 6px;border:1px solid var(--lc-line);border-radius:8px;padding:6px 10px;font:13px inherit;font-family:inherit;width:calc(100% - 20px);flex:none}
.lc-list{flex:1;overflow-y:auto;overscroll-behavior:contain}
.lc-sec{font-size:10.5px;font-weight:700;color:var(--lc-mut);letter-spacing:.05em;padding:6px 12px 2px;text-transform:uppercase}
.lc-row{display:flex;gap:8px;align-items:center;padding:6px 12px;border-bottom:1px solid #f0efea;cursor:pointer;width:100%;background:#fff;border-left:0;border-right:0;border-top:0;text-align:left;font:inherit;color:inherit}
.lc-row:hover,.lc-row.kb{background:#f3f8f8}
.lc-row .lc-tx{flex:1;min-width:0}.lc-row b{display:block;font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.lc-row p{margin:1px 0 0;color:var(--lc-mut);font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.lc-row.un p{color:#10262b;font-weight:600}
.lc-row .lc-r{text-align:right;font-size:10.5px;color:var(--lc-mut);flex:none}
.lc-row .lc-n{display:inline-block;background:#13824a;color:#fff;border-radius:9px;padding:0 6px;margin-top:3px;font-size:10.5px;font-weight:700}
.lc-row .lc-n.at{background:#e0a100;color:#10262b}
.lc-tag{font-size:10px;font-weight:700;border-radius:4px;padding:0 4px;margin-left:4px;background:#f6e7a8;color:#8a6400;vertical-align:1px}
.lc-empty{padding:18px 12px;color:var(--lc-mut);text-align:center}
.lc-ban{padding:4px 10px;font-size:11px;background:#eef5ff;color:#0b4f94;flex:none}
.lc-ban.adm{background:#fff4d6;color:#7a5600}
.lc-msgs{flex:1;overflow-y:auto;overscroll-behavior:contain;padding:8px 10px;background:#f3f1ea;display:flex;flex-direction:column;gap:5px}
.lc-day{align-self:center;font-size:11px;background:#fff;color:var(--lc-mut);padding:2px 8px;border-radius:8px;margin:3px 0}
.lc-m{display:flex;gap:6px;max-width:86%;align-items:flex-end}
.lc-m.me{align-self:flex-end;flex-direction:row-reverse}
.lc-bb{background:#fff;border-radius:8px;padding:4px 8px;border:1px solid var(--lc-line);min-width:0}
.lc-m.me .lc-bb{background:#dff3e6;border-color:#c5e6d1}
.lc-m.hl .lc-bb{background:#fff7d9;border-color:#e8c95a;box-shadow:0 0 0 2px #f6e7a8}
.lc-bb .lc-who{font-size:11px;font-weight:700}.lc-bb .lc-who small{font-weight:400;color:var(--lc-mut)}
.lc-bb p{margin:0;white-space:pre-wrap;word-break:break-word}
.lc-bb .lc-tm{font-size:10px;color:var(--lc-mut);text-align:right;display:flex;gap:6px;justify-content:flex-end;align-items:center}
.lc-del{border:0;background:none;cursor:pointer;font-size:11px;color:#c62828;padding:0}
.lc-mt{color:#0b5fb0;font-weight:700;background:#e5efff;border-radius:4px;padding:0 2px}
.lc-mt.me{color:#7a5600;background:#f6e7a8}
.lc-more{align-self:center;font-size:11.5px}
.lc-comp{display:flex;gap:6px;align-items:flex-end;padding:7px 10px;border-top:1px solid var(--lc-line);position:relative;flex:none}
.lc-comp textarea{flex:1;min-width:0;border:1px solid var(--lc-line);border-radius:18px;padding:7px 12px;font:13px/1.35 inherit;font-family:inherit;resize:none;max-height:96px;height:34px;outline:none}
.lc-comp textarea:focus{border-color:var(--lc-teal)}
.lc-send{width:34px;height:34px;border-radius:50%;border:0;background:var(--lc-teal);color:#fff;font-size:15px;cursor:pointer;flex:none}
.lc-send:disabled{opacity:.5}
.lc-ro{padding:7px 10px;border-top:1px solid var(--lc-line);display:flex;gap:6px;align-items:center;font-size:12px;color:var(--lc-mut);flex:none}
.lc-ro span{flex:1}
.lc-sug{position:absolute;left:10px;right:10px;bottom:calc(100% + 2px);background:#fff;border:1px solid var(--lc-line);border-radius:8px;box-shadow:0 -4px 14px rgba(0,0,0,.1);max-height:190px;overflow-y:auto}
.lc-sug button{display:flex;gap:8px;align-items:center;width:100%;border:0;background:#fff;padding:5px 8px;font:12.5px inherit;font-family:inherit;cursor:pointer;text-align:left}
.lc-sug button.kb,.lc-sug button:hover{background:#e6f0f0}
.lc-sug small{margin-left:auto;color:var(--lc-mut);font-size:11px}
.lc-err{color:#c62828;font-size:11.5px;padding:2px 10px;flex:none}
body.kb-open .lc-fab,body.kb-open .lc-pops{display:none}
.lwbk-tip{right:86px!important}
@media(max-width:600px){
 .lc-fab{right:12px}.lc-fab .lc-lbl{display:none}
 .lc-pops{right:12px;left:12px;width:auto;max-width:none}
 .lc-panel{left:0;right:0;bottom:0;top:var(--erp-top,58px);width:auto;height:auto;border-radius:14px 14px 0 0}
 body.lc-open .lc-fab{display:none}
 body.lc-open{overflow:hidden}
}
@media print{.lc-root{display:none!important}}`;

  let db,me,myRole,isAdmin=false,root,fab,badge,pops,panel;
  let ready=false,rooms=[],people=[],peopleById=new Map(),lastSeen=new Map(),view={mode:"list",tab:"mine"},openRoom=null,msgs=[],loadingMore=false,mentionsPick=new Map();

  async function init(opts){
    if(root)return;
    db=opts.db;me=opts.user;myRole=String(opts.role||"").toLowerCase();isAdmin=myRole==="admin";
    const first=await db.rpc("lwb_chat_rooms_list",{p_all:false});
    if(first.error)return; // setup SQL not run yet: no chat button
    build();
    applyRooms(first.data||[],true);
    loadPeople();
    live();
    setInterval(()=>{if(!document.hidden)refresh(true)},30000);
    document.addEventListener("visibilitychange",()=>{if(!document.hidden)refresh(true)});
    if(/^#chat\b/.test(location.hash))openPanel();
  }

  function build(){
    const st=document.createElement("style");st.textContent=CSS;document.head.appendChild(st);
    root=document.createElement("div");root.className="lc-root";root.setAttribute("data-nocaps","");
    root.innerHTML='<div class="lc-pops" aria-live="polite"></div>'+
      '<section class="lc-panel" hidden role="dialog" aria-label="Team Chat"></section>'+
      '<div class="lc-fab"><span class="lc-lbl">Team Chat</span><button class="lc-btn" type="button" aria-label="Team Chat" title="Team Chat">'+ICON+'<span class="lc-badge" hidden></span></button></div>';
    document.body.appendChild(root);
    lift();addEventListener("resize",lift);setTimeout(lift,1500);
    fab=root.querySelector(".lc-fab");badge=root.querySelector(".lc-badge");pops=root.querySelector(".lc-pops");panel=root.querySelector(".lc-panel");
    fab.addEventListener("click",()=>panel.hidden?openPanel():closePanel());
    document.addEventListener("keydown",e=>{if(e.key==="Escape"&&!panel.hidden&&!e.defaultPrevented){e.preventDefault();e.stopPropagation();if(view.mode!=="list")showList();else closePanel()}},true);
  }

  // Sit above a page's own bottom menu (Salesman quick bar, Driver menu).
  function lift(){
    let h=0;
    document.querySelectorAll(".erp-bnav,.dnav").forEach(b=>{const r=b.getBoundingClientRect(),cs=getComputedStyle(b);
      if(cs.display!=="none"&&cs.visibility!=="hidden"&&r.height>0&&r.bottom>=innerHeight-2)h=Math.max(h,Math.round(r.height))});
    root.style.setProperty("--lc-lift",h+"px");
  }
  async function loadPeople(){
    const r=await db.rpc("lwb_chat_people");
    if(!r.error){people=r.data||[];peopleById=new Map(people.map(p=>[p.id,p]))}
  }

  // ---------- chat list + unread ----------
  function applyRooms(list,quiet){
    rooms=list;
    for(const r of rooms){
      const before=lastSeen.has(r.id)?lastSeen.get(r.id):(ready?0:null);
      // Without live updates (or a missed one): a chat that got new unread messages since the last check pops up.
      if(!quiet&&before!=null&&r.unread>before&&!(openRoom&&openRoom.id===r.id&&!panel.hidden)&&r.last_by_name)
        popup({room_id:r.id,sender_name:r.last_by_name,body:r.last_text||"",mention:r.mention},r);
      lastSeen.set(r.id,r.unread);
    }
    ready=true;
    const n=rooms.reduce((s,r)=>s+(r.unread||0),0),at=rooms.some(r=>r.mention);
    badge.hidden=!n;badge.textContent=n>99?"99+":String(n);badge.classList.toggle("at",at);
    fab.querySelector(".lc-btn").setAttribute("aria-label","Team Chat"+(n?", "+n+" unread":""));
    if(!panel.hidden&&view.mode==="list"&&view.tab==="mine")drawList();
  }
  async function refresh(popNew){
    const r=await db.rpc("lwb_chat_rooms_list",{p_all:false});
    if(!r.error)applyRooms(r.data||[],!popNew);
    lift();
    if(!panel.hidden&&view.mode==="list"&&view.tab==="all")loadAll();
  }

  // ---------- live ----------
  let soon=0;
  function live(){
    try{
      db.channel("lwb-chat-"+me.id).on("postgres_changes",{event:"INSERT",schema:"public",table:"lwb_chat_messages"},p=>onNew(p.new)).subscribe();
    }catch(e){}
  }
  function onNew(m){
    if(!m||!m.id)return;
    const mine=m.sender===me.id;
    if(openRoom&&openRoom.id===m.room_id&&!panel.hidden&&view.mode==="room"){
      if(!msgs.some(x=>x.id===m.id)){msgs.push(m);drawMsgs(true)}
      if(!mine&&openRoom.member)db.rpc("lwb_chat_read",{p_room:m.room_id});
    }else if(!mine){
      const r=rooms.find(x=>x.id===m.room_id);
      if(r){r.unread=(r.unread||0)+1;if((m.mentions||[]).includes(me.id))r.mention=true;lastSeen.set(r.id,r.unread);popup({...m,mention:(m.mentions||[]).includes(me.id)},r);applyRooms(rooms,true)}
      else{clearTimeout(soon);soon=setTimeout(()=>refresh(true),700);return} // a new personal chat for me (or Admin's view of others)
    }
    clearTimeout(soon);soon=setTimeout(()=>refresh(false),700);
  }

  // ---------- popups: 5 s, pause while hovered / pressed, max 3 ----------
  function popup(m,r){
    const group=r.kind==="GROUP",at=!!m.mention||(!group);
    while(pops.children.length>=MAX_POPS)pops.firstElementChild.remove();
    const el=document.createElement("div");el.className="lc-pop"+(at?" at":"");el.setAttribute("role","status");
    el.innerHTML=av(group?r.name:m.sender_name,group)+'<div style="min-width:0;flex:1"><b>'+esc(group?r.name:m.sender_name)+'</b> <small>· '+(group?esc(m.sender_name)+" · ":"Personal · ")+'now</small>'+
      '<p>'+fmtBody(m.body)+'</p><div class="lc-acts"><button type="button" data-a="reply">↩ Reply</button><button type="button" data-a="open">Open</button></div></div>'+
      '<button class="lc-x" type="button" aria-label="Close">✕</button><span class="lc-bar"></span>';
    pops.appendChild(el);
    const bar=el.querySelector(".lc-bar");let left=POP_MS,start=Date.now(),t=0,paused=false;
    const anim=bar.animate([{transform:"scaleX(1)"},{transform:"scaleX(0)"}],{duration:POP_MS,fill:"forwards"});
    const go=()=>{start=Date.now();t=setTimeout(()=>el.remove(),left);anim.play()};
    const stop=()=>{if(paused)return;paused=true;clearTimeout(t);left=Math.max(600,left-(Date.now()-start));anim.pause()};
    const resume=()=>{if(!paused)return;paused=false;go()};
    el.addEventListener("pointerenter",stop);el.addEventListener("pointerleave",resume);
    el.addEventListener("pointerdown",stop);el.addEventListener("pointerup",e=>{if(e.pointerType!=="mouse")setTimeout(resume,1500)});
    el.addEventListener("click",e=>{
      e.stopPropagation();clearTimeout(t);
      if(e.target.closest(".lc-x")){el.remove();return}
      el.remove();openPanel(r.id,e.target.closest('[data-a="reply"]')?"focus":"");
    });
    go();
  }

  // ---------- panel ----------
  function openPanel(roomId,focus){
    panel.hidden=false;document.body.classList.add("lc-open");
    const b=fab.querySelector(".lc-btn");b.classList.add("open");b.innerHTML='<span style="font-size:20px;font-weight:700">✕</span>';
    fab.querySelector(".lc-lbl").hidden=true;
    pops.replaceChildren();
    if(roomId)openChat(roomId,focus);else showList();
  }
  function closePanel(){
    panel.hidden=true;document.body.classList.remove("lc-open");openRoom=null;
    const b=fab.querySelector(".lc-btn");b.classList.remove("open");b.innerHTML=ICON;b.appendChild(badge);
    fab.querySelector(".lc-lbl").hidden=false;
    if(/^#chat\b/.test(location.hash))history.replaceState(null,"",location.pathname+location.search);
  }

  function head(html){return '<header class="lc-ph">'+html+'<button type="button" class="lc-close" aria-label="Close">✕</button></header>'}
  function bindHead(){panel.querySelector(".lc-close").onclick=closePanel;const bk=panel.querySelector(".lc-back");if(bk)bk.onclick=showList}

  function showList(tab){
    view={mode:"list",tab:tab||view.tab||"mine"};openRoom=null;
    panel.innerHTML=head('<span class="lc-av sm" style="background:#c9b26a;color:#002f37">'+ICON+'</span><div class="lc-t"><b>Team Chat</b><small>'+esc(people.length+1)+' people</small></div><button type="button" class="lc-new">+ New</button>')+
      (isAdmin?'<div class="lc-seg"><button type="button" data-t="mine">My chats</button><button type="button" data-t="all">Everyone\'s chats 👁</button></div>':"")+
      '<input class="lc-find" type="search" placeholder="Search name or message" aria-label="Search chats">'+
      '<div class="lc-list"></div>';
    bindHead();
    panel.querySelector(".lc-new").onclick=showNew;
    panel.querySelectorAll(".lc-seg button").forEach(b=>{b.classList.toggle("on",b.dataset.t===view.tab);b.onclick=()=>showList(b.dataset.t)});
    panel.querySelector(".lc-find").addEventListener("input",()=>view.tab==="all"?drawAll():drawList());
    if(view.tab==="all")loadAll();else drawList();
  }
  function rowHtml(r,admin){
    const group=r.kind==="GROUP";
    return '<button type="button" class="lc-row'+(r.unread?" un":"")+'" data-id="'+r.id+'">'+av(r.name,group)+
      '<span class="lc-tx"><b>'+esc(r.name)+(group?'<span class="lc-tag">Group</span>':"")+'</b>'+
      '<p>'+(r.last_text?esc((r.last_by_name&&(group||admin)?r.last_by_name+": ":"")+r.last_text):'<i>'+esc(r.sub||"")+'</i>')+'</p></span>'+
      '<span class="lc-r">'+esc(when(r.last_at))+(r.unread?'<br><span class="lc-n'+(r.mention?" at":"")+'">'+(r.mention?"@ ":"")+r.unread+'</span>':"")+'</span></button>';
  }
  function matches(r,q){return !q||(r.name+" "+(r.last_text||"")+" "+(r.sub||"")).toLowerCase().includes(q)}
  function drawList(){
    const box=panel.querySelector(".lc-list");if(!box)return;
    const q=(panel.querySelector(".lc-find").value||"").trim().toLowerCase();
    const dm=rooms.filter(r=>r.kind==="DIRECT"&&matches(r,q)),gr=rooms.filter(r=>r.kind==="GROUP"&&matches(r,q));
    let h="";
    if(dm.length)h+='<div class="lc-sec">Personal 🔒</div>'+dm.map(r=>rowHtml(r)).join("");
    if(gr.length)h+='<div class="lc-sec">Groups (@All)</div>'+gr.map(r=>rowHtml(r)).join("");
    if(!dm.length&&!q)h='<div class="lc-empty">No personal chat yet. Tap <b>+ New</b> and pick a person.</div>'+h;
    if(!h)h='<div class="lc-empty">Nothing found</div>';
    box.innerHTML=h;
    box.querySelectorAll(".lc-row").forEach(b=>b.onclick=()=>openChat(Number(b.dataset.id)));
  }
  let allRooms=[];
  async function loadAll(){
    const box=panel.querySelector(".lc-list");if(!box)return;
    if(!allRooms.length)box.innerHTML='<div class="lc-empty">Loading…</div>';
    const r=await db.rpc("lwb_chat_rooms_list",{p_all:true});
    if(r.error){box.innerHTML='<div class="lc-empty">'+esc(r.error.message)+'</div>';return}
    allRooms=r.data||[];drawAll();
  }
  function drawAll(){
    const box=panel.querySelector(".lc-list");if(!box||view.tab!=="all")return;
    const q=(panel.querySelector(".lc-find").value||"").trim().toLowerCase();
    const list=allRooms.filter(r=>matches(r,q));
    box.innerHTML='<div class="lc-sec">Everyone\'s personal chats (only Admin sees this)</div>'+(list.map(r=>rowHtml(r,true)).join("")||'<div class="lc-empty">No chats</div>');
    box.querySelectorAll(".lc-row").forEach(b=>b.onclick=()=>openChat(Number(b.dataset.id),"",true));
  }

  // ---------- new chat: pick a person (personal) or a group ----------
  function showNew(){
    view={mode:"new",tab:view.tab};
    panel.innerHTML=head('<button type="button" class="lc-back" aria-label="Back">←</button><div class="lc-t"><b>New chat</b><small>One name = personal chat · @All = group</small></div>')+
      '<input class="lc-find" type="search" placeholder="@ Type a name or group" aria-label="Find a person">'+
      '<div class="lc-list"></div>';
    bindHead();
    const inp=panel.querySelector(".lc-find"),box=panel.querySelector(".lc-list");
    let pos=0;
    function draw(){
      const q=inp.value.replace(/^@/,"").trim().toLowerCase();
      const ps=people.filter(p=>!q||(p.name+" "+p.role_label).toLowerCase().includes(q)).sort((a,b)=>(a.name.toLowerCase().startsWith(q)?0:1)-(b.name.toLowerCase().startsWith(q)?0:1));
      const gs=rooms.filter(r=>r.kind==="GROUP"&&(!q||r.name.toLowerCase().includes(q)));
      box.innerHTML=(ps.length?'<div class="lc-sec">One person (personal chat 🔒)</div>'+ps.map(p=>'<button type="button" class="lc-row" data-p="'+esc(p.id)+'">'+av(p.name)+'<span class="lc-tx"><b>'+esc(p.name)+'</b><p>'+esc(p.role_label)+'</p></span></button>').join(""):"")+
        (gs.length?'<div class="lc-sec">Group (everyone sees, everyone can reply)</div>'+gs.map(r=>'<button type="button" class="lc-row" data-id="'+r.id+'">'+av(r.name,true)+'<span class="lc-tx"><b>'+esc(r.name)+'</b><p>'+esc(r.sub)+'</p></span></button>').join(""):"")||'<div class="lc-empty">Nobody found</div>';
      pos=0;mark();
      box.querySelectorAll(".lc-row").forEach(b=>b.onclick=()=>pick(b));
    }
    const rows=()=>[...box.querySelectorAll(".lc-row")];
    function mark(){rows().forEach((b,i)=>b.classList.toggle("kb",i===pos&&!!inp.value.trim()))}
    async function pick(b){
      if(b.dataset.id)return openChat(Number(b.dataset.id),"focus");
      b.disabled=true;
      const r=await db.rpc("lwb_chat_open_direct",{p_user:b.dataset.p});
      if(r.error){b.disabled=false;box.insertAdjacentHTML("afterbegin",'<p class="lc-err">'+esc(r.error.message)+'</p>');return}
      const p=peopleById.get(b.dataset.p)||{};
      if(!rooms.some(x=>x.id===r.data))rooms.unshift({id:r.data,kind:"DIRECT",name:p.name,sub:p.role_label,other_id:p.id,unread:0,member:true});
      openChat(Number(r.data),"focus");
    }
    inp.addEventListener("input",draw);
    inp.addEventListener("keydown",e=>{
      const rs=rows();
      if((e.key==="ArrowDown"||e.key==="ArrowUp")&&rs.length){e.preventDefault();pos=(pos+(e.key==="ArrowDown"?1:rs.length-1))%rs.length;mark();rs[pos].scrollIntoView({block:"nearest"})}
      else if(e.key==="Enter"&&rs[pos]){e.preventDefault();e.stopPropagation();pick(rs[pos])}
    });
    draw();setTimeout(()=>inp.focus(),30);
  }

  // ---------- one chat ----------
  async function openChat(id,focus,adminView){
    let r=rooms.find(x=>x.id===id)||allRooms.find(x=>x.id===id);
    if(!r){await refresh(false);r=rooms.find(x=>x.id===id)}
    if(!r)return showList();
    const member=!adminView&&r.member!==false;
    openRoom={...r,member};view={mode:"room",tab:view.tab};msgs=[];mentionsPick=new Map();
    const group=r.kind==="GROUP";
    const other=!group&&peopleById.get(r.other_id);
    panel.innerHTML=head('<button type="button" class="lc-back" aria-label="Back">←</button>'+av(r.name,group,"sm")+'<div class="lc-t"><b>'+esc(r.name)+'</b><small>'+esc(group?(r.sub||"")+" · everyone can reply":(other?other.role_label:(r.sub||"")))+'</small></div>'+
      (isAdmin?'<button type="button" class="lc-delall" title="Delete every message of this chat">🗑 Delete</button>':""))+
      (!member?'<div class="lc-ban adm">👁 You are only looking. These two people are not told.</div>':(!group?'<div class="lc-ban">🔒 Personal chat: only you and '+esc(r.name)+(isAdmin?"":" (Admin can see the record)")+'</div>':""))+
      '<div class="lc-msgs"><div class="lc-empty">Loading…</div></div>'+
      (member?'<p class="lc-err" hidden></p><div class="lc-comp"><textarea rows="1" placeholder="'+esc(group?"Message the group… (@ to tag)":"Message "+r.name+"…")+'" aria-label="Message"></textarea><button type="button" class="lc-send" aria-label="Send">➤</button></div>'
        :'<div class="lc-ro"><span>Admin only looks here.</span></div>');
    bindHead();
    const del=panel.querySelector(".lc-delall");
    if(del)del.onclick=async()=>{
      const ok=window.ERPShell&&ERPShell.confirm?await ERPShell.confirm("Delete every message of "+r.name+"?\n\nThis cannot be undone.",{danger:true,ok:"Delete",title:"Delete chat"}):confirm("Delete every message of "+r.name+"?");
      if(!ok)return;
      const x=await db.rpc("lwb_chat_delete",{p_room:id,p_message:null});
      if(x.error)return showErr(x.error.message);
      allRooms=allRooms.filter(a=>a.id!==id);await refresh(false);showList();
    };
    const box=panel.querySelector(".lc-msgs");
    box.addEventListener("scroll",()=>{if(box.scrollTop<40)loadMore()});
    box.addEventListener("click",async e=>{
      const d=e.target.closest(".lc-del");if(!d)return;
      const ok=window.ERPShell&&ERPShell.confirm?await ERPShell.confirm("Delete this message?",{danger:true,ok:"Delete",title:"Delete message"}):confirm("Delete this message?");
      if(!ok)return;
      const x=await db.rpc("lwb_chat_delete",{p_room:id,p_message:Number(d.dataset.id)});
      if(x.error)return showErr(x.error.message);
      msgs=msgs.filter(m=>m.id!==Number(d.dataset.id));drawMsgs(false);
    });
    if(member)bindComposer(group);
    const q=await db.from("lwb_chat_messages").select("*").eq("room_id",id).order("id",{ascending:false}).limit(PAGE);
    if(!openRoom||openRoom.id!==id)return;
    if(q.error){box.innerHTML='<div class="lc-empty">'+esc(q.error.message)+'</div>';return}
    msgs=(q.data||[]).reverse();openRoom.more=(q.data||[]).length===PAGE;
    drawMsgs(true);
    if(member&&(r.unread||r.mention)){db.rpc("lwb_chat_read",{p_room:id}).then(()=>refresh(false));r.unread=0;r.mention=false;lastSeen.set(id,0);applyRooms(rooms,true)}
    if(focus){const t=panel.querySelector(".lc-comp textarea");if(t)t.focus()}
  }
  async function loadMore(){
    if(loadingMore||!openRoom||!openRoom.more||!msgs.length)return;
    loadingMore=true;const id=openRoom.id,box=panel.querySelector(".lc-msgs"),h=box.scrollHeight;
    const q=await db.from("lwb_chat_messages").select("*").eq("room_id",id).lt("id",msgs[0].id).order("id",{ascending:false}).limit(PAGE);
    loadingMore=false;
    if(q.error||!openRoom||openRoom.id!==id)return;
    msgs=(q.data||[]).reverse().concat(msgs);openRoom.more=(q.data||[]).length===PAGE;
    drawMsgs(false);box.scrollTop=box.scrollHeight-h;
  }
  function showErr(t){const e=panel.querySelector(".lc-err");if(e){e.hidden=!t;e.textContent=t||""}else if(t&&window.ERPShell)ERPShell.alert(t,{kind:"error"})}

  // @Name in a message: highlighted; my own name in gold.
  function fmtBody(body,mentions){
    let h=esc(body);
    const names=new Set();
    (mentions||[]).forEach(id=>{const p=peopleById.get(id);if(p)names.add(p.name)});
    if(mentions&&mentions.includes(me.id))names.add("__me__");
    people.forEach(p=>names.add(p.name));
    const mine=myName();
    const list=[...names].filter(n=>n&&n!=="__me__").sort((a,b)=>b.length-a.length);
    if(mine)list.unshift(mine);
    for(const n of list){
      const re=new RegExp("@"+esc(n).replace(/[.*+?^${}()|[\]\\]/g,"\\$&")+"(?![\\w])","gi");
      h=h.replace(re,s=>'<span class="lc-mt'+(n===mine?" me":"")+'">'+s+'</span>');
    }
    return h.replace(/@All( (Team|Sales Team|Drivers|Godown|Accounts))?/g,s=>'<span class="lc-mt">'+s+'</span>');
  }
  function myName(){const w=document.querySelector(".erp-user .who b");return (w&&w.textContent.trim())||""}

  function drawMsgs(toEnd){
    const box=panel.querySelector(".lc-msgs");if(!box||!openRoom)return;
    const group=openRoom.kind==="GROUP";let day="",h=openRoom.more?'<button type="button" class="lc-sbtn lc-more">Older messages</button>':"";
    if(!msgs.length)h='<div class="lc-empty">'+(openRoom.member?"No message yet. Say hello 👋":"No message")+'</div>';
    for(const m of msgs){
      const d=dayOf(m.created_at);if(d!==day){day=d;h+='<span class="lc-day">'+esc(d)+'</span>'}
      const mine=m.sender===me.id,hl=!mine&&(m.mentions||[]).includes(me.id);
      const showWho=!mine&&(group||!openRoom.member);
      h+='<div class="lc-m'+(mine?" me":"")+(hl?" hl":"")+'">'+(mine?"":av(m.sender_name,false,"sm"))+'<div class="lc-bb">'+
        (showWho?'<div class="lc-who">'+esc(m.sender_name)+' <small>'+esc(roleLabel(m.sender_role))+'</small></div>':"")+
        '<p>'+fmtBody(m.body,m.mentions)+'</p><div class="lc-tm">'+(isAdmin?'<button type="button" class="lc-del" data-id="'+m.id+'" title="Delete message">🗑</button>':"")+esc(new Date(m.created_at).toLocaleTimeString("en-IN",{hour:"numeric",minute:"2-digit"}))+'</div></div></div>';
    }
    box.innerHTML=h;
    const more=box.querySelector(".lc-more");if(more)more.onclick=loadMore;
    if(toEnd)box.scrollTop=box.scrollHeight;
  }
  const roleLabel=r=>({admin:"Admin",manager:"Sales Head",warehouse:"Godown Manager",accounts:"Accounts",sales:"Salesman",driver:"Driver",transport:"Transport"}[String(r||"").toLowerCase()]||"");

  function members(group){
    if(!group)return people.filter(p=>p.id===openRoom.other_id);
    const g=String(openRoom.name||"");
    const roles={"@All Sales Team":["sales"],"@All Drivers":["driver","transport"],"@All Godown":["warehouse"],"@All Accounts":["accounts"]}[g];
    return people.filter(p=>!roles||["admin","manager"].includes(p.role)||roles.includes(p.role));
  }
  function bindComposer(group){
    const comp=panel.querySelector(".lc-comp"),ta=comp.querySelector("textarea"),send=comp.querySelector(".lc-send");
    let sug=null,pos=0,hits=[];
    const grow=()=>{ta.style.height="34px";ta.style.height=Math.min(96,ta.scrollHeight+2)+"px"};
    function token(){const v=ta.value.slice(0,ta.selectionStart);const m=v.match(/(^|\s)@([^\s@]{0,20})$/);return m?{q:m[2].toLowerCase(),at:v.length-m[2].length-1}:null}
    function close(){if(sug){sug.remove();sug=null}}
    function suggest(){
      const t=token();if(!t){close();return}
      hits=members(group).filter(p=>p.name.toLowerCase().includes(t.q)||p.role_label.toLowerCase().includes(t.q)).slice(0,8);
      if(!hits.length){close();return}
      if(!sug){sug=document.createElement("div");sug.className="lc-sug";comp.appendChild(sug)}
      pos=0;
      sug.innerHTML=hits.map((p,i)=>'<button type="button" data-i="'+i+'"'+(i===0?' class="kb"':"")+'>'+av(p.name,false,"sm")+'@'+esc(p.name)+'<small>'+esc(p.role_label)+'</small></button>').join("");
      sug.querySelectorAll("button").forEach(b=>b.onmousedown=e=>{e.preventDefault();put(hits[+b.dataset.i])});
    }
    function put(p){
      const t=token();if(!t||!p)return;
      const before=ta.value.slice(0,t.at),after=ta.value.slice(ta.selectionStart);
      const ins="@"+p.name+" ";ta.value=before+ins+after;
      const c=(before+ins).length;ta.setSelectionRange(c,c);mentionsPick.set(p.id,p.name);close();grow();ta.focus();
    }
    async function go(){
      const body=ta.value.trim();if(!body||send.disabled)return;
      // Tagged = picked from the list (or typed exactly) and still in the text.
      const tags=members(group).filter(p=>body.toLowerCase().includes("@"+p.name.toLowerCase())).map(p=>p.id);
      send.disabled=true;showErr("");
      const r=await db.rpc("lwb_chat_send",{p_room:openRoom.id,p_body:body,p_mentions:tags});
      send.disabled=false;
      if(r.error){showErr(r.error.message);return}
      const id=Number(r.data);
      if(!msgs.some(m=>m.id===id)){msgs.push({id,room_id:openRoom.id,sender:me.id,sender_name:myName(),body,mentions:tags,created_at:new Date().toISOString()});drawMsgs(true)}
      ta.value="";mentionsPick.clear();grow();ta.focus();refresh(false);
    }
    ta.addEventListener("input",()=>{grow();suggest()});
    ta.addEventListener("blur",()=>setTimeout(close,150));
    ta.addEventListener("keydown",e=>{
      if(sug&&(e.key==="ArrowDown"||e.key==="ArrowUp")){e.preventDefault();e.stopPropagation();pos=(pos+(e.key==="ArrowDown"?1:hits.length-1))%hits.length;sug.querySelectorAll("button").forEach((b,i)=>b.classList.toggle("kb",i===pos));return}
      if(sug&&(e.key==="Enter"||e.key==="Tab")){e.preventDefault();e.stopPropagation();put(hits[pos]);return}
      if(sug&&e.key==="Escape"){e.preventDefault();e.stopPropagation();close();return}
      if(e.key==="Enter"&&!e.shiftKey&&!e.isComposing){e.preventDefault();e.stopPropagation();go()}
    });
    send.onclick=go;
  }

  window.LWBChat={init,open:openPanel};
})();
