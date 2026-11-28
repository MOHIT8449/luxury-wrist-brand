/* Dial Book helpers (Mohit, 27 Nov 2026, lwb_dial_book_setup.sql). Needs vehicle-no.js.
   LWBDial.call({client, kind, ref, source, name})  asks the full number (logged), opens the phone dialer,
                                                     then a small "How was the call?" bar for a result / note.
   LWBDial.driverPopup({client, vehicle, ecrs, trucks, onDone})  vehicle no. + driver mobile once, linked;
                                                     "📍 Save + WhatsApp location" sends the godown location.
   LWBDial.sendLoc({client, vehicle})                WhatsApp the godown location again.
   LWBDial.drivers(client, vehicles)                 Map vehicle key -> {name, masked, loc_sent_at ...}
   LWBDial.rowBtns(vehicle, map)                     HTML: 📞 + 📍 buttons, or "+ Driver" (data-dial-* attributes).
   LWBDial.wire(root, {client, source, trucks, onDone}) one click handler for those buttons. */
(function(){
  'use strict';
  const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const RESULTS=[["TALKED","✅ Baat hui"],["NO_ANSWER","📵 Nahi uthaya"],["ORDER","🛒 Order mila"],["PAYMENT","💰 Payment"],
    ["ON_WAY","🚚 Raste me"],["BUSY","⏳ Busy / baad me"],["WRONG","❌ Galat number"]];
  const toast=(m,t)=>{if(window.ERPShell&&ERPShell.toast)ERPShell.toast(m,t||"success");else if(t==="error")alert(m)};
  const nice=m=>/lwb_dial|lwb_vehicle/.test(m||"")&&/function|does not exist|schema cache/.test(m||"")?"Dial Book is not set up yet (lwb_dial_book_setup.sql).":String(m||"Something went wrong");
  function css(){
    if(document.getElementById("lwbDialCss"))return;
    const s=document.createElement("style");s.id="lwbDialCss";
    s.textContent=`.dl-back{position:fixed;inset:0;background:rgba(15,23,42,.45);z-index:960;display:flex;align-items:flex-start;justify-content:center;padding:5vh 10px;overflow:auto}
.dl-pop{width:min(440px,100%);background:#fff;border-radius:12px;box-shadow:0 24px 60px rgba(15,23,42,.3);color:#1f2a37;font-size:14px}
.dl-h{display:flex;align-items:center;gap:8px;padding:10px 14px;border-bottom:1px solid #e3e7ec}.dl-h h3{margin:0;font-size:16px;flex:1;min-width:0}
.dl-h h3 small{display:block;font-size:12px;color:#6b7785;font-weight:500}
.dl-x{border:1px solid #e3e7ec;background:#fff;border-radius:6px;width:32px;height:32px;font-size:15px;cursor:pointer;flex:none}
.dl-b{padding:10px 14px;display:grid;gap:9px}
.dl-b label{display:flex;flex-direction:column;gap:3px;font-size:12px;color:#4b5763;font-weight:600;min-width:0}
.dl-b input,.dl-b select{height:38px;border:1.5px solid #d5dbe1;border-radius:6px;padding:0 9px;font:inherit;font-size:15px;width:100%;box-sizing:border-box;background:#fff;color:#1f2a37;min-width:0}
.dl-two{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.dl-wa{background:#e7fbe0;border-radius:8px;padding:8px 10px;font-size:12.5px;white-space:pre-line;color:#1f3a1a;overflow-wrap:anywhere}
.dl-hint{font-size:12px;color:#6b7785;margin:0}
.dl-name{font-size:12.5px;margin:0;padding:7px 9px;border-radius:8px;background:#eef7f1;color:#1d4d33}.dl-name b{letter-spacing:.2px}
.dl-err{background:#ffebeb;color:#9b2020;padding:7px 10px;border-radius:6px;font-size:13px}
.dl-ft{display:flex;gap:6px;padding:10px 14px;border-top:1px solid #e3e7ec}
.dl-ft button{height:40px;padding:0 10px;border-radius:6px;border:1px solid #e3e7ec;background:#fff;color:#1f2a37;font:inherit;font-size:13.5px;font-weight:700;cursor:pointer;flex:1 1 0;min-width:0;white-space:nowrap}
.dl-ft .wa{background:#1f9d55;border-color:#1f9d55;color:#fff;flex:2 1 0}
.dl-bar{position:fixed;left:50%;bottom:14px;transform:translateX(-50%);z-index:965;width:min(520px,calc(100% - 20px));background:#fff;border:1px solid #d5dbe1;border-radius:12px;box-shadow:0 14px 40px rgba(15,23,42,.25);padding:9px 11px;font-size:13.5px;color:#1f2a37}
.dl-bar .t{display:flex;gap:6px;align-items:center;margin-bottom:7px}.dl-bar .t b{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.dl-bar .t button{border:0;background:none;font-size:16px;cursor:pointer;color:#6b7785}
.dl-chips{display:flex;flex-wrap:wrap;gap:5px}.dl-chips button{border:1px solid #d5dbe1;background:#fff;border-radius:15px;padding:5px 10px;font:inherit;font-size:12.5px;cursor:pointer;color:#1f2a37}
.dl-chips button.on{background:#00434d;border-color:#00434d;color:#fff}
.dl-note{display:flex;gap:6px;margin-top:7px}.dl-note input{flex:1;min-width:0;height:34px;border:1.5px solid #d5dbe1;border-radius:6px;padding:0 8px;font:inherit;font-size:14px}
.dl-note button{height:34px;border-radius:6px;border:0;background:#00434d;color:#fff;font-weight:700;padding:0 12px;cursor:pointer}
.dl-rb{display:inline-flex;gap:4px;align-items:center;flex-wrap:nowrap}
.dl-rb>button{height:30px!important;min-height:0!important;min-width:34px!important;padding:0 9px!important;border-radius:6px!important;border:1px solid #d5dbe1!important;background:#fff!important;cursor:pointer;font:inherit;font-size:13px!important;font-weight:700!important;color:#1f2a37!important;white-space:nowrap;box-shadow:none!important;line-height:1!important}
.dl-rb>button.c{background:#13824a!important;border-color:#13824a!important;color:#fff!important;padding:0 12px!important}
.dl-rb small{display:block;font-size:11.5px;color:#6b7785}
.dl-cb{display:inline-flex!important;align-items:center;justify-content:center;gap:2px;height:26px!important;min-height:0!important;min-width:30px!important;width:auto!important;padding:0 7px!important;margin:0 0 0 5px!important;border:1px solid #13824a!important;background:#e9f7ef!important;color:#13824a!important;border-radius:6px!important;font:inherit;font-size:13px!important;font-weight:700!important;line-height:1!important;cursor:pointer;vertical-align:middle;flex:none!important;box-shadow:none!important;white-space:nowrap}
.dl-cb[hidden]{display:none!important}.dl-cb:hover{background:#13824a!important;color:#fff!important}
.dl-pc{position:fixed;right:14px;top:132px;z-index:966;width:300px;max-width:calc(100% - 20px);background:#fff;border:1.5px solid #13824a;border-radius:12px;box-shadow:0 14px 40px rgba(15,23,42,.25);padding:10px 12px;font-size:13px;color:#1f2a37}
.dl-pc .t{display:flex;gap:6px;align-items:center}.dl-pc .t b{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:14px}
.dl-pc .t button{border:0;background:none;font-size:16px;cursor:pointer;color:#6b7785}
.dl-pc .n{font-size:20px;font-weight:800;color:#13824a;letter-spacing:.5px;margin:2px 0}
.dl-pc p{margin:0 0 8px;color:#4b5763;font-size:12.5px}
.dl-pc .b{display:flex;gap:5px}.dl-pc .b button{flex:1 1 0;min-width:0;height:32px;border:1px solid #d5dbe1;border-radius:6px;background:#fff;font:inherit;font-size:12.5px;font-weight:700;cursor:pointer;white-space:nowrap;color:#1f2a37}
.dl-pc .b button[data-tel]{background:#13824a;border-color:#13824a;color:#fff}
.dl-steps{margin:0;padding:0;list-style:none;counter-reset:s;display:grid;gap:7px}
.dl-steps li{display:flex;gap:8px;align-items:flex-start;counter-increment:s;font-size:13px;line-height:1.4}
.dl-steps li::before{content:counter(s);flex:none;width:22px;height:22px;border-radius:50%;background:#00434d;color:#fff;font-weight:800;font-size:12px;display:flex;align-items:center;justify-content:center}
.dl-steps li span{flex:none;width:44px;font-size:11px;font-weight:800;color:#13824a;text-transform:uppercase;padding-top:3px}
@media(max-width:540px){.dl-back{padding:0}.dl-pop{border-radius:0;min-height:100%}.dl-bar{bottom:64px}}`;
    document.head.appendChild(s);
  }
  // ---- Call ----
  async function call({client,kind,ref,source,name,numberId}){
    css();
    const r=await client.rpc("lwb_dial_call",{p_kind:kind,p_ref:String(ref),p_source:source||null,p_number_id:numberId||null});
    if(r.error){toast(nice(r.error.message),"error");return null}
    const x=r.data||{};
    const pc=isPC()&&PC_ROLES.includes(await myRole(client));
    location.href="tel:+91"+x.mobile;
    if(pc)pcBar(x.mobile,x.name||name||"");
    // Reason / result only for party calls (sales work). Team, staff, driver, services: just logged (Mohit, 27 Nov).
    if(kind==="PARTY")setTimeout(()=>resultBar(client,x.id,x.name||name||""),400);
    return x;
  }
  // ---- PC call through Windows Phone Link (Mohit, 28 Nov 2026: demo for Admin first) ----
  // On a PC the same tel: link opens Phone Link, which rings from the Android phone paired by Bluetooth (same SIM number).
  const PC_ROLES=["admin"];
  const isPC=()=>!/Android|iPhone|iPad|iPod|Mobile/i.test(navigator.userAgent||"")&&!(window.matchMedia&&matchMedia("(pointer:coarse)").matches);
  let roleP=null;
  function myRole(client){
    if(!roleP)roleP=(async()=>{try{const s=await client.auth.getSession();const id=s.data&&s.data.session&&s.data.session.user.id;if(!id)return"";
      const r=await client.from("user_profiles").select("role").eq("id",id).maybeSingle();return String(r.data&&r.data.role||"").trim().toLowerCase()}catch(_){return""}})();
    return roleP;
  }
  const spaced=m=>String(m||"").replace(/^(\d{5})(\d{5})$/,"$1 $2");
  function pcBar(mobile,name){
    css();document.querySelectorAll(".dl-pc").forEach(b=>b.remove());
    const bar=document.createElement("div");bar.className="dl-pc";
    bar.innerHTML='<div class="t">💻 <b>'+esc(name)+'</b><button type="button" data-x aria-label="Close">✕</button></div>'+
      '<div class="n">+91 '+esc(spaced(mobile))+'</div><p>Phone Link se aapke phone (SIM) se call lag raha hai. Awaaz PC ke speaker / headset me.</p>'+
      '<div class="b"><button type="button" data-tel>📞 Dobara</button><button type="button" data-cp>📋 Copy</button><button type="button" data-help>❓ Setup</button></div>';
    document.body.appendChild(bar);
    bar.addEventListener("click",async e=>{
      if(e.target.closest("[data-x]")){bar.remove();return}
      if(e.target.closest("[data-tel]")){location.href="tel:+91"+mobile;return}
      if(e.target.closest("[data-cp]")){try{await navigator.clipboard.writeText(mobile);toast("Number copy ho gaya")}catch(_){prompt("Number",mobile)}return}
      if(e.target.closest("[data-help]"))pcHelp();
    });
  }
  const PC_STEPS=[
    ["PC","Windows 10 / 11 me Start dabake <b>Phone Link</b> app kholein (pehle se hota hai)."],
    ["Phone","Android phone me Play Store se <b>Link to Windows</b> app daalein. PC par aaya QR code phone se scan karein."],
    ["Dono","Phone aur PC dono me <b>Bluetooth ON</b>. Phone Link me <b>Calls</b> → <b>Get started</b> → dono par same code aaye to <b>Pair</b>."],
    ["Phone","Phone par jo bhi permission maange (Phone, Contacts, Call history) sab <b>Allow</b>."],
    ["PC","PC <b>Settings → Apps → Default apps</b> → upar search me <b>TEL</b> likhein → <b>Phone Link</b> chunein."],
    ["ERP","Kisi bhi page par 📞 dabayein. Chrome puchhe \"Open Phone Link?\" to <b>Always allow</b> tick karke <b>Open</b>. Bas, call lag jayega."]];
  function pcHelp(){
    css();document.querySelectorAll(".dl-back.pch").forEach(b=>b.remove());
    const back=document.createElement("div");back.className="dl-back pch";
    back.innerHTML='<div class="dl-pop" role="dialog" aria-modal="true" aria-label="PC se call setup"><div class="dl-h"><h3>💻 PC se call (Phone Link)<small>Ek baar setup, phir ERP ka 📞 PC se chalega</small></h3><button type="button" class="dl-x" data-x aria-label="Close">✕</button></div>'+
      '<div class="dl-b"><ol class="dl-steps">'+PC_STEPS.map(([w,t])=>"<li><span>"+w+"</span><div>"+t+"</div></li>").join("")+"</ol>"+
      '<p class="dl-name">✅ Call aapke <b>usi phone ke number</b> se jayega. Phone jeb ya table par rahe, 10 meter ke andar, Bluetooth ON.</p>'+
      '<p class="dl-hint">Headset / earphone PC me lagayein to awaaz saaf rahegi. iPhone bhi chalega (Windows 11). Har call ERP me log hota hai.</p></div>'+
      '<div class="dl-ft"><button type="button" class="wa" data-x>Theek hai</button></div></div>';
    document.body.appendChild(back);
    back.addEventListener("click",e=>{if(e.target===back||e.target.closest("[data-x]"))back.remove()});
  }
  function resultBar(client,id,name){
    document.querySelectorAll(".dl-bar").forEach(b=>b.remove());
    const bar=document.createElement("div");bar.className="dl-bar";let pick=null;
    bar.innerHTML='<div class="t">📞 <b>'+esc(name)+'</b><small style="color:#6b7785">Call kaisa raha?</small><button type="button" data-x aria-label="Close">✕</button></div>'+
      '<div class="dl-chips">'+RESULTS.map(([k,l])=>'<button type="button" data-r="'+k+'">'+esc(l)+"</button>").join("")+"</div>"+
      '<div class="dl-note"><input maxlength="300" placeholder="Note (optional)"><button type="button" data-save>Save</button></div>';
    document.body.appendChild(bar);
    const close=()=>bar.remove();
    const save=async()=>{
      const note=bar.querySelector("input").value.trim();
      if(!pick&&!note){close();return}
      const r=await client.rpc("lwb_dial_note",{p_id:id,p_result:pick,p_note:note||null});
      if(r.error){toast(nice(r.error.message),"error");return}
      toast("Call note saved");close();document.dispatchEvent(new CustomEvent("lwb-dial-saved"));
    };
    bar.addEventListener("click",e=>{
      if(e.target.closest("[data-x]")){close();return}
      const b=e.target.closest("[data-r]");
      if(b){pick=pick===b.dataset.r?null:b.dataset.r;bar.querySelectorAll("[data-r]").forEach(x=>x.classList.toggle("on",x.dataset.r===pick));
        if(pick&&!bar.querySelector("input").value.trim())save();return}
      if(e.target.closest("[data-save]"))save();
    });
    bar.querySelector("input").addEventListener("keydown",e=>{if(e.key==="Enter")save()});
    setTimeout(()=>{if(document.body.contains(bar)&&!bar.matches(":focus-within"))close()},120000);
  }
  // ---- WhatsApp godown location ----
  function waText(x){
    // Google Maps place link first (Mohit, 28 Nov): WhatsApp shows the godown photo card for it. lat / lng only if no link.
    const maps=x.map_url||("https://maps.google.com/?q="+Number(x.lat).toFixed(6)+","+Number(x.lng).toFixed(6));
    // Message in Hindi (Mohit, 28 Nov): drivers read Hindi best. Link + address: Live Tracking > ⚙ Settings (lwb_godown_link_edit_setup.sql).
    const hi=String(x.address||"").trim();
    return maps+"\n\nनमस्ते"+(x.name?" "+x.name+" जी":"")+",\nलक्ज़री रिस्ट ब्रांड गोदाम (लक्ज़री वेयरहाउस, सूरत) का लोकेशन ऊपर दिया है।"+
      (hi?"\nपता: "+hi:"")+"\nगाड़ी: "+x.vehicle_no+
      (x.my_mobile?"\nपहुँचकर इस नंबर पर कॉल करें: "+x.my_mobile+(x.my_name?" ("+String(x.my_name).split(/\s+/)[0]+")":""):"");
  }
  async function sendLoc({client,vehicle,win}){
    const w=win||window.open("","_blank");
    const r=await client.rpc("lwb_vehicle_loc_sent",{p_vehicle:vehicle});
    if(r.error){if(w)w.close();toast(nice(r.error.message),"error");return false}
    const url="https://wa.me/91"+r.data.mobile+"?text="+encodeURIComponent(waText(r.data));
    if(w)w.location.href=url;else location.href=url;
    toast("📍 WhatsApp opened: press Send");
    return true;
  }
  // ---- Transport short name + phone name (same rule as lwb_transport_short / lwb_vehicle_save_as) ----
  const STOP=new Set("ROAD ROADS LINE LINES ROADLINE ROADLINES ROADWAY ROADWAYS TRANSPORT TRANSPORTS TRANSPORTER TRANSPORTERS TRANSPORTATION TRAILER TRAILERS TRAILOR TRAILORS TRAILLER CARRIER CARRIERS CARGO CARGOS LOGISTIC LOGISTICS MOVERS PACKERS FREIGHT FREIGHTS SERVICE SERVICES CO COMPANY PVT PRIVATE LTD LIMITED LLP AND THE GOODS TRUCK TRUCKS TEMPO FLEET EXPRESS ENTERPRISE ENTERPRISES AGENCY AGENCIES CORPORATION CORP INDIA SHREE SHRI SRI SHRE NEW JAY JAI".split(" "));
  function trShort(t){
    const w=String(t||"").toUpperCase().replace(/^\s*M\s*\/\s*S\b\.?/,"").replace(/[^A-Z0-9 ]+/g," ").trim().split(/\s+/).filter(Boolean);
    if(!w.length)return "";
    let k=w.filter(x=>!STOP.has(x));if(!k.length)k=[w[0]];
    const j=[];k.forEach(x=>{if(x.length===1&&j.length&&j[j.length-1][0]==="#")j[j.length-1]+=x;else j.push(x.length===1?"#"+x:x)});
    const v=j[0][0]==="#"?j[0].slice(1):j[0].length<=3&&j.length>1?j[0]+" "+j[1].replace("#",""):j[0];
    return v.slice(0,14).trim();
  }
  function saveAs(veh,name,tr){
    const v=window.LWBVeh&&LWBVeh.check(veh).ok?LWBVeh.check(veh).value:String(veh||"").trim();
    return [v,String(name||"").trim()||"DRIVER",tr===NEWTR?"":trShort(tr)].filter(Boolean).join(" ").toUpperCase();
  }
  let trList=null;
  async function transports(client){
    if(trList)return trList;
    const r=await client.rpc("lwb_transport_names");trList=r.error?[]:(r.data||[]);return trList;
  }
  // Transport dropdown: every active transport of Transport Master + "New transport" (lwb_transport_add).
  const NEWTR="__new__";
  function trFill(sel,L,keep){
    const v=keep!=null?keep:sel.value,has=L.some(t=>t.name.toUpperCase()===String(v||"").toUpperCase());
    sel.innerHTML='<option value="">— Transport chuniye —</option>'+L.map(t=>'<option value="'+esc(t.name)+'">'+esc(t.name)+(t.short?" ("+esc(t.short)+")":"")+'</option>').join("")+
      (v&&!has?'<option value="'+esc(v)+'">'+esc(v)+'</option>':"")+'<option value="'+NEWTR+'">➕ Naya transport…</option>';
    const m=L.find(t=>t.name.toUpperCase()===String(v||"").toUpperCase());sel.value=m?m.name:(v||"");
  }
  function trInput(client,id,value){
    setTimeout(async()=>{
      const sel=document.getElementById(id);if(!sel)return;
      trFill(sel,await transports(client),value||"");
      let prev=sel.value;
      sel.addEventListener("change",async()=>{
        if(sel.value!==NEWTR){prev=sel.value;return}
        const name=String(window.prompt("Naye transport ka pura naam (jaise VIKAS ROAD LINES):","")||"").replace(/\s+/g," ").trim().toUpperCase();
        if(!name){sel.value=prev;return}
        const r=await client.rpc("lwb_transport_add",{p_name:name});
        if(r.error){alert("Transport save nahi hua: "+nice(r.error.message));sel.value=prev;return}
        trList=null;trFill(sel,await transports(client),r.data&&r.data.name||name);prev=sel.value;
        sel.dispatchEvent(new Event("input",{bubbles:true}));
      });
    },0);
    return '<select id="'+id+'" required><option value="'+esc(value||"")+'">'+esc(value||"— Transport chuniye —")+'</option></select>';
  }
  // ---- Vehicle + driver popup ----
  function driverPopup({client,vehicle,ecrs,trucks,known,onDone}){
    css();
    const T=(trucks||[]).filter(t=>t&&t.id);
    const back=document.createElement("div");back.className="dl-back";
    back.innerHTML=`<div class="dl-pop" role="dialog" aria-modal="true" aria-label="Vehicle and driver">
      <div class="dl-h"><h3>🚚 Gaadi + Driver<small>Ek baar daalo: number is gaadi se jud jayega</small></h3><button type="button" class="dl-x" data-x aria-label="Close">✕</button></div>
      <div class="dl-b">
        ${T.length?`<label>ECRS order (optional)<select id="dlEcrs"><option value="">— Not from ECRS —</option>${T.map(t=>`<option value="${esc(t.id)}"${String(t.id)===String(ecrs||"")?" selected":""}>${esc(t.label||("Order "+(t.no||t.id)))}</option>`).join("")}</select></label>`:""}
        <div class="dl-two"><label>Gaadi number *<input id="dlVeh" maxlength="20" placeholder="GJ05 BX 4471" autocomplete="off" value="${esc(vehicle||"")}"></label>
          <label>Driver mobile *<input id="dlMob" type="tel" inputmode="tel" maxlength="16" placeholder="10-digit mobile" autocomplete="off"></label></div>
        <div class="dl-two"><label>Driver naam *<input id="dlName" maxlength="80" autocomplete="off" value="${esc(known&&known.name||"")}"></label>
          <label>Transport *${trInput(client,"dlTr",known&&known.transport)}</label></div>
        <p class="dl-name">📱 Phone / Gmail me naam: <b id="dlAs"></b></p>
        <p class="dl-hint" id="dlKnown"></p>
        ${known&&known.masked?`<p class="dl-hint">Abhi ka driver: ${esc(known.masked)}${known.name?" · "+esc(known.name):""}. Naya driver daaloge to woh bhi jud jayega, purana number bhi save rahega.</p>`:""}
        ${known&&known.old_drivers&&known.old_drivers.length?`<p class="dl-hint">Purane driver: ${known.old_drivers.slice(0,4).map(o=>esc((o.name||"Driver")+" "+o.masked)).join(" · ")}</p>`:""}
        <div id="dlErr" class="dl-err" hidden></div>
        <p class="dl-hint">📍 WhatsApp dabane par driver ko godown ka Google Maps location jayega (Live Tracking settings wala). Aapko WhatsApp me sirf Send dabana hai.</p>
      </div>
      <div class="dl-ft"><button type="button" data-x>Cancel</button><button type="button" data-save>Save</button><button type="button" class="wa" data-wa>📍 Save + WhatsApp</button></div></div>`;
    document.body.appendChild(back);
    const $=s=>back.querySelector(s),veh=$("#dlVeh");
    if(window.LWBVeh)LWBVeh.attach(veh,{required:true});
    const as=()=>{$("#dlAs").textContent=saveAs(veh.value||"GJ05 BX 4471",$("#dlName").value,$("#dlTr").value)};
    ["#dlVeh","#dlName","#dlTr"].forEach(s=>$(s).addEventListener("input",as));$("#dlTr").addEventListener("change",as);as();
    // gaadi number typed: show who drove it before + fill its transport
    let lastK="";
    veh.addEventListener("blur",async()=>{
      const c=window.LWBVeh?LWBVeh.check(veh.value):{ok:false};if(!c.ok)return;
      const k=vkey(c.value);if(k===lastK)return;lastK=k;
      const m=await drivers(client,[c.value]),d=m.get(k),box=$("#dlKnown");
      if(!d){box.innerHTML="Nayi gaadi: pehli baar save ho rahi hai.";return}
      if(d.transport&&!$("#dlTr").value)trFill($("#dlTr"),await transports(client),d.transport);
      const old=(d.old_drivers||[]).slice(0,4).map(o=>esc((o.name||"Driver")+" "+o.masked));
      box.innerHTML="Pichhla driver: <b>"+esc((d.name||"Driver")+" "+d.masked)+"</b>"+(old.length?" · Purane: "+old.join(" · "):"")+". Wahi driver hai to wahi mobile daaliye, naya hai to naya: dono save rahenge.";
      as();
    });
    const close=()=>back.remove();
    const err=m=>{$("#dlErr").hidden=!m;$("#dlErr").textContent=m||""};
    const mobOk=v=>/^(?:\+?91|0)?[6-9]\d{9}$/.test(String(v||"").replace(/[\s()-]/g,""));
    async function save(wa){
      const c=window.LWBVeh?LWBVeh.check(veh.value):{ok:!!veh.value.trim(),value:veh.value.trim()};
      if(veh.lwbVehShow)veh.lwbVehShow();
      if(!c.ok){err("Gaadi number sahi likhiye: GJ05 BX 4471");veh.focus();return}
      if(!mobOk($("#dlMob").value)){err("Driver ka 10-digit mobile likhiye");$("#dlMob").focus();return}
      if(!$("#dlName").value.trim()){err("Driver ka naam likhiye");$("#dlName").focus();return}
      if(!$("#dlTr").value||$("#dlTr").value===NEWTR){err("Transport chuniye");$("#dlTr").focus();return}
      err("");
      const w=wa?window.open("","_blank"):null;
      back.querySelectorAll(".dl-ft button").forEach(b=>b.disabled=true);
      const r=await client.rpc("lwb_vehicle_driver_save",{p_vehicle:c.value,p_mobile:$("#dlMob").value,p_name:$("#dlName").value.trim()||null,
        p_ecrs:$("#dlEcrs")&&$("#dlEcrs").value?Number($("#dlEcrs").value):null,p_transport:$("#dlTr").value||null});
      if(r.error){if(w)w.close();err(nice(r.error.message));back.querySelectorAll(".dl-ft button").forEach(b=>b.disabled=false);return}
      if(wa)await sendLoc({client,vehicle:r.data.vehicle_no,win:w});else toast("Saved: "+(r.data.save_as||r.data.vehicle_no)+" · "+r.data.masked);
      close();if(onDone)onDone(r.data);
    }
    back.addEventListener("click",e=>{
      if(e.target===back||e.target.closest("[data-x]")){close();return}
      if(e.target.closest("[data-save]"))save(false);
      if(e.target.closest("[data-wa]"))save(true);
    });
    setTimeout(()=>(vehicle?$("#dlMob"):veh).focus(),50);
    return back;
  }
  // ---- Vehicle rows (Purchase List, ECRS) ----
  async function drivers(client,vehicles){
    const list=[...new Set((vehicles||[]).filter(Boolean).map(String))];
    const m=new Map();if(!list.length)return m;
    const r=await client.rpc("lwb_vehicle_drivers",{p_vehicles:list});
    if(!r.error)(r.data||[]).forEach(d=>m.set(d.vehicle_key,d));
    return m;
  }
  const vkey=v=>window.LWBVeh?LWBVeh.key(v):String(v||"").toUpperCase().replace(/[^A-Z0-9]/g,"");
  function rowBtns(vehicle,map,opt){
    css();opt=opt||{};
    const k=vkey(vehicle),d=k&&map&&map.get(k);
    const ec=opt.ecrs?' data-dial-ecrs="'+esc(opt.ecrs)+'"':"";
    if(!d)return opt.canSave&&!opt.noAdd?'<span class="dl-rb"><button type="button" data-dial-add="'+esc(vehicle||"")+'"'+ec+' title="Driver mobile + WhatsApp location">+ Driver</button></span>':"";
    const sent=d.loc_sent_at?new Date(d.loc_sent_at).toLocaleString("en-IN",{day:"2-digit",month:"2-digit",hour:"2-digit",minute:"2-digit",hour12:false,timeZone:"Asia/Kolkata"}):"";
    return '<span class="dl-rb"><button type="button" class="c" data-dial-call="'+esc(k)+'" data-dial-name="'+esc(d.vehicle_no+(d.name?" · "+d.name:""))+'" title="Call driver '+esc(d.masked)+'">📞</button>'+
      (opt.canSave?'<button type="button" data-dial-loc="'+esc(d.vehicle_no)+'" title="WhatsApp godown location">📍</button>':"")+"</span>"+
      (opt.line===false?"":'<small>'+esc((d.name?d.name+" · ":"")+d.masked)+(sent?" · 📍 "+esc(sent):"")+"</small>");
  }
  function wire(root,{client,source,trucks,onDone}){
    (root||document).addEventListener("click",e=>{
      const c=e.target.closest("[data-dial-call]");
      if(c){e.preventDefault();e.stopPropagation();call({client,kind:"VEHICLE",ref:c.dataset.dialCall,source,name:c.dataset.dialName});return}
      const l=e.target.closest("[data-dial-loc]");
      if(l){e.preventDefault();e.stopPropagation();sendLoc({client,vehicle:l.dataset.dialLoc}).then(ok=>{if(ok&&onDone)onDone()});return}
      const a=e.target.closest("[data-dial-add]");
      if(a){e.preventDefault();e.stopPropagation();driverPopup({client,vehicle:a.dataset.dialAdd,ecrs:a.dataset.dialEcrs,trucks:typeof trucks==="function"?trucks():trucks,onDone})}
    });
  }
  // ---- 📞 on every page (Mohit, 28 Nov 2026; lwb_dial_find_setup.sql) ----
  // LWBDial.btn(k, v, name): a 📞 button, hidden until the contact is found in MY Dial Book (salesman: own parties only).
  //   k = PARTY (party name or id) | USER (login id) | MOB (mobile) | VEH (vehicle no.). The click asks the full number
  //   from lwb_dial_call (logged, log seen by Admin only) and opens the phone. Any page that loads this file gets it.
  const SB_URL="https://qstgwhbgbznxemajtave.supabase.co",SB_KEY="sb_publishable_YA2Pow327REqgrWPzVCZiA_nw1F32_o";
  const found=new Map();let scanT=0,scanning=false,again=false;
  function btn(k,v,name,label){
    v=String(v==null?"":v).trim();if(!v)return "";
    return '<button type="button" class="dl-cb" hidden data-dc-k="'+esc(k)+'" data-dc-v="'+esc(v)+'" data-dc-n="'+esc(name||"")+'" title="Call'+(name?" "+esc(name):"")+'" aria-label="Call'+(name?" "+esc(name):"")+'">📞'+(label?"<span> "+esc(label)+"</span>":"")+"</button>";
  }
  function cli(){
    if(window.__lwbBellClient)return window.__lwbBellClient;
    return window.supabase&&window.supabase.createClient?(window.__lwbBellClient=window.supabase.createClient(SB_URL,SB_KEY)):null;
  }
  const keyOf=b=>b.dataset.dcK+"|"+b.dataset.dcV;
  async function scan(){
    if(scanning){again=true;return}
    const bs=[...document.querySelectorAll("[data-dc-k]")];if(!bs.length)return;
    const need=[],seen=new Set();
    bs.forEach(b=>{const k=keyOf(b);if(found.has(k))b.hidden=!found.get(k);else if(!seen.has(k)){seen.add(k);need.push({k:b.dataset.dcK,v:b.dataset.dcV})}});
    if(!need.length)return;
    const c=cli();if(!c)return;
    scanning=true;
    try{
      for(let i=0;i<need.length;i+=500){
        const part=need.slice(i,i+500),r=await c.rpc("lwb_dial_find",{p_items:part});
        const hit=new Map((r.error?[]:r.data||[]).map(x=>[x.k+"|"+x.v,{kind:x.kind,ref:x.ref}]));
        part.forEach(x=>{const k=x.k.toUpperCase()+"|"+x.v;found.set(x.k+"|"+x.v,hit.get(k)||null)});
      }
    }finally{scanning=false}
    document.querySelectorAll("[data-dc-k]").forEach(b=>{const k=keyOf(b);if(found.has(k))b.hidden=!found.get(k)});
    if(again){again=false;scan()}
  }
  const page=()=>{const t=(document.body&&document.body.dataset.dialSource)||String(document.title||"").split(/\s[|·–—-]\s/)[0].trim();return t||location.pathname.split("/").pop().replace(/\.html$/,"")};
  function autoStart(){
    css();
    new MutationObserver(()=>{clearTimeout(scanT);scanT=setTimeout(scan,150)}).observe(document.body,{childList:true,subtree:true});
    document.addEventListener("click",e=>{
      const b=e.target.closest&&e.target.closest("[data-dc-k]");if(!b)return;
      e.preventDefault();e.stopPropagation();
      const x=found.get(keyOf(b));if(!x)return;
      call({client:cli(),kind:x.kind,ref:x.ref,source:page(),name:b.dataset.dcN});
    },true);
    scan();
  }
  if(document.body)autoStart();else document.addEventListener("DOMContentLoaded",autoStart);
  window.LWBDial={call,pcHelp,isPC,myRole,PC_ROLES,driverPopup,sendLoc,drivers,rowBtns,wire,RESULTS,waText,trShort,saveAs,trInput,btn,scan};
})();
