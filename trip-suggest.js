/* LUXURY WRIST BRAND ERP — Suggest trips by area + vehicle size, and the one-time Party area screen.
 * Needs lwb_trip_suggest_setup.sql.
 *   LWBSuggest.open({db, orders, vehicles, onMake})  ready POs -> groups by area (or salesman area), packed up to the
 *        vehicle size. onMake(orderIds, vehicleNo) opens the normal One trip popup.
 *   LWBSuggest.areas({db, onSaved})                   one-time Party area screen (guessed area, save all).
 *   LWBSuggest.group(items, {mode, cap, vehicles})    the grouping itself (pure, for tests).
 * Area order: saved area > name in brackets > GPS (nearest party within 3 km) > pincode > city > salesman area.
 * Two parties with GPS within NEAR_KM are one area even when the area names differ; a far party stays alone.
 */
(function(){
  'use strict';
  const NEAR_KM=3;
  const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const kgf=n=>new Intl.NumberFormat('en-IN',{maximumFractionDigits:0}).format(Math.round(Number(n)||0));
  const km=(a,b)=>{if(a.lat==null||b.lat==null||a.lng==null||b.lng==null)return null;const r=x=>x*Math.PI/180,dl=r(b.lat-a.lat),dg=r(b.lng-a.lng);
    const h=Math.sin(dl/2)**2+Math.cos(r(a.lat))*Math.cos(r(b.lat))*Math.sin(dg/2)**2;return 2*6371*Math.asin(Math.min(1,Math.sqrt(h)));};
  const SRC={SAVED:'Saved',NAME:'Name (…)',GPS:'GPS (near party)',PINCODE:'Pincode',CITY:'City',SALESMAN:'Salesman'};
  const srcText=r=>!r.src?'':r.src==='PINCODE'?'Pincode '+(r.pincode||''):r.src==='SALESMAN'?'Salesman'+(r.salesman?': '+r.salesman:''):SRC[r.src]||r.src;

  function css(){
    if(document.getElementById('lwb-sug-css'))return;
    const s=document.createElement('style');s.id='lwb-sug-css';
    s.textContent=`.sg-ov{position:fixed;inset:0;background:#0009;display:flex;align-items:center;justify-content:center;padding:10px;z-index:4000}
.sg-m{background:#f3f5f8;width:min(1150px,100%);max-height:96vh;overflow:auto;border-radius:12px;font:14px Arial,sans-serif;color:#182230}
.sg-hd{position:sticky;top:0;z-index:2;background:#111;color:#fff;padding:10px 12px;display:flex;align-items:center;gap:8px}
.sg-hd b{flex:1;font-size:16px;min-width:0}.sg-hd button{border:0;border-radius:7px;padding:6px 10px;font-weight:bold;background:#ffffff26;color:#fff;cursor:pointer}
.sg-bd{padding:10px 12px}.sg-top{display:flex;gap:6px;align-items:center;flex-wrap:wrap;margin-bottom:10px}
.sg-chip{border:1.5px solid #cfd6de;border-radius:99px;padding:5px 11px;font-weight:700;font-size:13px;background:#fff;cursor:pointer;color:#182230}
.sg-chip.on{background:#0d2230;color:#fff;border-color:#0d2230}.sg-kg{display:flex;align-items:center;gap:4px;font-weight:700;font-size:13px}
.sg-kg input{width:82px;padding:5px 7px;border:1px solid #cfd5df;border-radius:7px;font:inherit}
.sg-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(310px,1fr));gap:10px}
.sg-g{background:#fff;border:1px solid #e2e6ed;border-radius:10px;padding:10px;display:flex;flex-direction:column;gap:6px}
.sg-gh{display:flex;justify-content:space-between;gap:8px;align-items:flex-start}.sg-gh b{font-size:15px}
.sg-gh small{display:block;color:#667085;font-size:12px;margin-top:2px}.sg-t{font-weight:800;font-size:15px;white-space:nowrap}
.sg-bar{height:8px;border-radius:5px;background:#e3e8ee;overflow:hidden}.sg-bar i{display:block;height:100%;background:#13824a}.sg-bar.w i{background:#d08a00}
.sg-po{display:flex;align-items:center;gap:7px;font-size:13px;border-top:1px dashed #e3e7ec;padding-top:5px;cursor:pointer}
.sg-po input{width:17px;height:17px;margin:0;flex:none}.sg-po span{flex:1;min-width:0}.sg-po small{color:#667085;white-space:nowrap}
.sg-po.off span{color:#98a2b3;text-decoration:line-through}
.sg-why{font-size:12px;color:#1a47a8;background:#eef4ff;border-radius:6px;padding:4px 7px}.sg-why.w{color:#7b5200;background:#fff6dc}
.sg-btns{display:flex;gap:6px}.sg-btn{flex:1;border:0;border-radius:8px;padding:8px 6px;font-weight:700;font-size:13.5px;background:#e9edf3;color:#172033;cursor:pointer}
.sg-btn.p{background:#1769df;color:#fff}.sg-btn:disabled{opacity:.5;cursor:default}
.sg-empty{text-align:center;color:#667085;padding:30px;background:#fff;border-radius:10px}
.sg-tag{display:inline-block;border-radius:99px;padding:1px 7px;font-size:11px;font-weight:700;background:#e4edff;color:#1a47a8;white-space:nowrap}
.sg-tag.GPS,.sg-tag.SAVED{background:#d9f7e7;color:#06653a}.sg-tag.SALESMAN{background:#fff1c9;color:#7b5200}.sg-tag.none{background:#ffe5e5;color:#a11320}
.sg-tb{width:100%;border-collapse:collapse;font-size:13px;background:#fff;border-radius:10px;overflow:hidden}
.sg-tb th{background:#f0f2f6;text-align:left;padding:7px 6px;font-size:11.5px}.sg-tb td{padding:5px 6px;border-top:1px solid #e5e8ee}
.sg-tb input{width:100%;min-width:0;border:1px solid #cfd5df;border-radius:6px;padding:5px 7px;font:inherit;font-size:13px}
.sg-tb input.ch{border-color:#1769df;background:#f3f8ff}
.sg-q{flex:1;min-width:150px;border:1px solid #cfd5df;border-radius:7px;padding:6px 9px;font:inherit}
.sg-foot{position:sticky;bottom:0;background:#f3f5f8;padding:8px 0 2px}
@media(max-width:600px){.sg-grid{grid-template-columns:1fr}.sg-hide{display:none}.sg-ov{padding:4px}.sg-bd{padding:8px}}`;
    document.head.appendChild(s);
  }

  function modal(title){
    css();const ov=document.createElement('div');ov.className='sg-ov';
    ov.innerHTML=`<div class="sg-m" role="dialog" aria-modal="true"><div class="sg-hd"><b>${esc(title)}</b><button type="button" data-x>✕</button></div><div class="sg-bd"></div></div>`;
    const close=()=>{ov.remove();document.removeEventListener('keydown',key);};
    const key=e=>{if(e.key==='Escape')close();};
    ov.querySelector('[data-x]').onclick=close;ov.addEventListener('click',e=>{if(e.target===ov)close();});document.addEventListener('keydown',key);
    document.body.appendChild(ov);
    return {ov,bd:ov.querySelector('.sg-bd'),title:t=>{ov.querySelector('.sg-hd b').textContent=t;},close};
  }

  // items: [{id, order_no, party, kg, area, src, lat, lng, sm_area, salesman}]
  function group(items,o){
    const mode=o.mode||'area',cap=Number(o.cap)||0;
    const keyOf=it=>{const a=mode==='salesman'?(it.sm_area||it.area):it.area;return a?String(a).trim().toLowerCase():'';};
    const n=items.length,par=items.map((_,i)=>i),find=i=>par[i]===i?i:(par[i]=find(par[i])),join=(a,b)=>{par[find(a)]=find(b);};
    for(let i=0;i<n;i++)for(let j=i+1;j<n;j++){const a=items[i],b=items[j],ka=keyOf(a),kb=keyOf(b);
      // same area name; a party with no area joins a party within NEAR_KM (GPS)
      if(ka&&ka===kb)join(i,j);else if(mode==='area'&&(!ka||!kb)){const d=km(a,b);if(d!=null&&d<=NEAR_KM)join(i,j);}}
    const sets=new Map(),unknown=[];
    items.forEach((it,i)=>{if(!keyOf(it)&&it.lat==null){unknown.push(it);return;}const r=find(i);if(!sets.has(r))sets.set(r,[]);sets.get(r).push(it);});
    // neighbouring areas (GPS centres within NEAR_KM) share a vehicle while the total still fits: nearest pair first
    let groups=[...sets.values()];
    const ctr=l=>{const g=l.filter(x=>x.lat!=null&&x.lng!=null);return g.length?{lat:g.reduce((s,x)=>s+x.lat,0)/g.length,lng:g.reduce((s,x)=>s+x.lng,0)/g.length}:{lat:null,lng:null};};
    const wt=l=>l.reduce((s,x)=>s+(Number(x.kg)||0),0);
    if(mode==='area'&&cap>0)for(;;){let best=null;
      for(let i=0;i<groups.length;i++)for(let j=i+1;j<groups.length;j++){if(wt(groups[i])+wt(groups[j])>cap)continue;const d=km(ctr(groups[i]),ctr(groups[j]));
        if(d!=null&&d<=NEAR_KM&&(!best||d<best.d))best={i,j,d};}
      if(!best)break;groups[best.i]=groups[best.i].concat(groups[best.j]);groups.splice(best.j,1);}
    const out=[];
    for(const list of groups){
      const cnt=new Map();list.forEach(it=>{const a=mode==='salesman'?(it.sm_area||it.area):it.area;if(a)cnt.set(a,(cnt.get(a)||0)+1);});
      const names=[...cnt.entries()].sort((a,b)=>b[1]-a[1]).map(x=>x[0]);
      const name=names[0]||('Near '+list[0].party);
      // first-fit decreasing; a PO bigger than the vehicle goes alone
      const bins=[];
      list.slice().sort((a,b)=>(Number(b.kg)||0)-(Number(a.kg)||0)).forEach(it=>{const w=Number(it.kg)||0;
        const bin=cap>0?bins.find(b=>b.kg+w<=cap):bins[0];if(bin){bin.items.push(it);bin.kg+=w;}else bins.push({items:[it],kg:w});});
      bins.forEach((b,i)=>out.push({name,part:bins.length>1?(i+1)+'/'+bins.length:'',areas:names,items:b.items,kg:b.kg}));
    }
    // spread and nearest other trip (GPS)
    out.forEach(t=>{let s=0;for(const a of t.items)for(const b of t.items){const d=km(a,b);if(d!=null&&d>s)s=d;}t.spread=s;
      let near=null;for(const u of out){if(u===t||u.name===t.name)continue;for(const a of t.items)for(const b of u.items){const d=km(a,b);if(d!=null&&(near==null||d<near))near=d;}}t.near=near;});
    // a free vehicle that fits, smallest first, each used once
    const used=new Set(),free=(o.vehicles||[]).filter(v=>!(v.on_trip&&v.on_trip.length)&&Number(v.capacity_kg)>0).sort((a,b)=>a.capacity_kg-b.capacity_kg);
    out.sort((a,b)=>b.kg-a.kg);
    out.forEach(t=>{const v=free.find(v=>!used.has(v.vehicle_no)&&Number(v.capacity_kg)>=t.kg);if(v){used.add(v.vehicle_no);t.vehicle=v;}});
    return {trips:out,unknown};
  }

  // ready POs -> items for group(): one RPC; {items} or {error}
  async function items(db,orders){
    const ready=(orders||[]).filter(x=>x&&x.id);if(!ready.length)return {items:[]};
    const r=await db.rpc('lwb_trip_suggest_data',{p_order_ids:ready.map(x=>x.id)});
    if(r.error)return {error:r.error};
    const by=new Map((r.data||[]).map(x=>[String(x.order_id),x]));
    return {items:ready.map(x=>{const d=by.get(String(x.id))||{};return {id:x.id,order_no:x.order_no,party:x.customer_name||'',kg:Number(x.total_weight)||0,area:d.area||null,src:d.src||null,lat:d.lat??null,lng:d.lng??null,sm_area:d.sm_area||null,salesman:d.salesman||null};})};
  }

  async function open(o){
    const {db}=o,ready=(o.orders||[]).filter(x=>x&&x.id);
    const m=modal('💡 Suggested trips · '+ready.length+' ready PO');
    if(!ready.length){m.bd.innerHTML='<div class="sg-empty">No ready PO to suggest. Approved POs that are not allocated show here.</div>';return;}
    m.bd.innerHTML='<div class="sg-empty">Finding party areas…</div>';
    const r=await db.rpc('lwb_trip_suggest_data',{p_order_ids:ready.map(x=>x.id)});
    if(r.error){m.bd.innerHTML=`<div class="sg-empty">Could not load: ${esc(/lwb_trip_suggest_data/.test(r.error.message)?'run lwb_trip_suggest_setup.sql first':r.error.message)}</div>`;return;}
    const by=new Map((r.data||[]).map(x=>[String(x.order_id),x]));
    const items=ready.map(x=>{const d=by.get(String(x.id))||{};return {id:x.id,order_no:x.order_no,party:x.customer_name||'',kg:Number(x.total_weight)||0,area:d.area||null,src:d.src||null,lat:d.lat??null,lng:d.lng??null,sm_area:d.sm_area||null,salesman:d.salesman||null};});
    const caps=[...new Set((o.vehicles||[]).map(v=>Number(v.capacity_kg)).filter(c=>c>0))].sort((a,b)=>a-b);
    let saved=null;try{saved=JSON.parse(localStorage.getItem('lwbSugPref')||'null');}catch(_){}
    const st={mode:saved&&saved.mode==='salesman'?'salesman':'area',cap:Number(saved&&saved.cap)||caps[caps.length-1]||1700,off:new Set()};
    const keep=()=>{try{localStorage.setItem('lwbSugPref',JSON.stringify({mode:st.mode,cap:st.cap}));}catch(_){}};
    function paint(){
      const g=group(items,{mode:st.mode,cap:st.cap,vehicles:o.vehicles});
      const chips=`<div class="sg-top"><button type="button" class="sg-chip ${st.mode==='area'?'on':''}" data-mode="area">By area</button><button type="button" class="sg-chip ${st.mode==='salesman'?'on':''}" data-mode="salesman">By salesman</button>
        ${caps.map(c=>`<button type="button" class="sg-chip ${c===st.cap?'on':''}" data-cap="${c}">${kgf(c)} kg</button>`).join('')}
        <label class="sg-kg">Vehicle <input type="number" min="100" step="50" value="${st.cap}" data-capin> kg</label>
        <button type="button" class="sg-chip" data-areas>📍 Party area</button></div>`;
      const card=(t,i)=>{const on=t.items.filter(x=>!st.off.has(x.id)),kg=on.reduce((s,x)=>s+x.kg,0),pa=new Set(on.map(x=>x.party.trim().toUpperCase())).size;
        const pct=st.cap?Math.min(100,Math.round(kg/st.cap*100)):0,over=st.cap&&kg>st.cap,zero=on.filter(x=>!x.kg);
        const sub=[on.length+' PO',pa+' part'+(pa===1?'y':'ies')];if(t.areas.length>1)sub.push(t.areas.join(', '));if(t.spread>0.05)sub.push('within '+(t.spread<1?'1':Math.round(t.spread))+' km (GPS)');
        if(t.items.length===1&&t.near!=null)sub.push('alone · nearest other party '+Math.round(t.near)+' km');
        const why=[];
        if(over)why.push(`<div class="sg-why w">⚠ ${kgf(kg-st.cap)} kg over ${kgf(st.cap)} kg: bigger vehicle, or untick a PO</div>`);
        else if(t.vehicle)why.push(`<div class="sg-why">✓ Fits · ${esc(t.vehicle.vehicle_no)} free (${kgf(t.vehicle.capacity_kg)} kg)</div>`);
        else if(st.cap&&kg<st.cap*0.6)why.push(`<div class="sg-why">Room for ${kgf(st.cap-kg)} kg more on this side</div>`);
        else why.push(`<div class="sg-why">✓ Fits ${kgf(st.cap)} kg vehicle</div>`);
        if(zero.length)why.push(`<div class="sg-why w">⚠ Weight 0 kg in PO: ${zero.map(x=>esc(x.order_no)).join(', ')}</div>`);
        return `<div class="sg-g" data-trip="${i}"><div class="sg-gh"><div><b>Trip ${i+1} · ${esc(t.name)}${t.part?' ('+t.part+')':''}</b><small>${esc(sub.join(' · '))}</small></div><span class="sg-t">${kgf(kg)} kg</span></div>
          <div class="sg-bar ${over?'w':''}"><i style="width:${pct}%"></i></div>
          ${t.items.map(x=>`<label class="sg-po ${st.off.has(x.id)?'off':''}"><input type="checkbox" data-po="${esc(x.id)}" ${st.off.has(x.id)?'':'checked'}><span>${esc(x.order_no)} · ${esc(x.party)}</span><small>${kgf(x.kg)} kg${x.kg?'':' ⚠'}</small></label>`).join('')}
          ${why.join('')}<div class="sg-btns"><button type="button" class="sg-btn p" data-make="${i}" ${on.length?'':'disabled'}>🚚 Make this trip${on.length>1?' ('+on.length+' PO)':''}</button></div></div>`;};
      const unk=g.unknown.length?`<div class="sg-g"><div class="sg-gh"><div><b>Area not known (${g.unknown.length})</b><small>No area in name, no GPS, no salesman area. Set it once.</small></div><span class="sg-t">${kgf(g.unknown.reduce((s,x)=>s+x.kg,0))} kg</span></div>
          ${g.unknown.map(x=>`<div class="sg-po"><span>${esc(x.order_no)} · ${esc(x.party)}</span><small>${kgf(x.kg)} kg${x.kg?'':' ⚠'}</small></div>`).join('')}
          <div class="sg-btns"><button type="button" class="sg-btn p" data-areas>📍 Set area</button></div></div>`:'';
      m.bd.innerHTML=chips+`<div class="sg-grid">${g.trips.map(card).join('')}${unk}</div>`;
      m.bd._trips=g.trips;
    }
    m.bd.addEventListener('click',e=>{
      const md=e.target.closest('[data-mode]');if(md){st.mode=md.dataset.mode;keep();paint();return;}
      const cp=e.target.closest('[data-cap]');if(cp){st.cap=Number(cp.dataset.cap);keep();paint();return;}
      if(e.target.closest('[data-areas]')){areas({db,onSaved:async()=>{m.close();open(o);}});return;}
      const mk=e.target.closest('[data-make]');if(mk){const t=m.bd._trips[Number(mk.dataset.make)];const ids=t.items.filter(x=>!st.off.has(x.id)).map(x=>x.id);if(!ids.length)return;m.close();o.onMake&&o.onMake(ids,t.vehicle?t.vehicle.vehicle_no:'');}
    });
    m.bd.addEventListener('change',e=>{
      const c=e.target.closest('[data-po]');if(c){c.checked?st.off.delete(c.dataset.po):st.off.add(c.dataset.po);paint();return;}
      const ci=e.target.closest('[data-capin]');if(ci){const v=Number(ci.value);if(v>0){st.cap=v;keep();paint();}}
    });
    paint();
  }

  async function areas(o){
    const {db}=o,m=modal('📍 Party area');
    const st={missing:true,q:'',data:null,val:new Map()};
    async function load(){m.bd.innerHTML='<div class="sg-empty">Loading parties…</div>';
      const r=await db.rpc('lwb_party_area_list',{p_only_missing:st.missing});
      if(r.error){m.bd.innerHTML=`<div class="sg-empty">Could not load: ${esc(r.error.message)}</div>`;return;}
      st.data=r.data;st.val=new Map((r.data.rows||[]).map(x=>[x.id,x.saved||x.area||'']));paint();}
    const changed=()=>(st.data.rows||[]).filter(x=>(st.val.get(x.id)||'').trim()!==(x.saved||''));
    function paint(){const d=st.data,q=st.q.toLowerCase();
      m.title('📍 Party area · '+d.total+' parties · '+d.missing+' not set');
      const rows=(d.rows||[]).filter(x=>!q||String(x.name).toLowerCase().includes(q)||String(st.val.get(x.id)).toLowerCase().includes(q));
      const tag=x=>x.saved?'<span class="sg-tag SAVED">Saved</span>':x.src?`<span class="sg-tag ${esc(x.src)}">${esc(srcText(x))}</span>`:'<span class="sg-tag none">Not known</span>';
      m.bd.innerHTML=`<div class="sg-top"><button type="button" class="sg-chip ${st.missing?'on':''}" data-miss="1">Not set</button><button type="button" class="sg-chip ${st.missing?'':'on'}" data-miss="0">All</button><input class="sg-q" type="search" placeholder="Search party / area" value="${esc(st.q)}" data-q></div>
        <datalist id="sgAreas">${(d.areas||[]).map(a=>`<option value="${esc(a)}">`).join('')}</datalist>
        ${rows.length?`<table class="sg-tb"><thead><tr><th>Party</th><th style="width:38%">Area (suggested)</th><th class="sg-hide">From</th></tr></thead><tbody>
        ${rows.slice(0,400).map(x=>`<tr><td><b>${esc(x.name)}</b></td><td><input list="sgAreas" maxlength="60" data-id="${esc(x.id)}" value="${esc(st.val.get(x.id))}" placeholder="Type area" class="${(st.val.get(x.id)||'').trim()!==(x.saved||'')?'ch':''}"></td><td class="sg-hide">${tag(x)}</td></tr>`).join('')}</tbody></table>`:'<div class="sg-empty">'+(st.missing?'Every party has an area. ✓':'No party found.')+'</div>'}
        <div class="sg-foot sg-btns"><button type="button" class="sg-btn" data-x2>Close</button><button type="button" class="sg-btn p" data-save>✓ Save ${changed().length} area${changed().length===1?'':'s'}</button></div>`;
    }
    const foot=()=>{const b=m.bd.querySelector('[data-save]'),n=changed().length;if(b){b.textContent='✓ Save '+n+' area'+(n===1?'':'s');b.disabled=!n;}};
    m.bd.addEventListener('input',e=>{const i=e.target.closest('[data-id]');if(i){st.val.set(i.dataset.id,i.value);const x=st.data.rows.find(r=>r.id===i.dataset.id);i.classList.toggle('ch',i.value.trim()!==(x&&x.saved||''));foot();return;}
      const q=e.target.closest('[data-q]');if(q){st.q=q.value;paint();const n=m.bd.querySelector('[data-q]');n.focus();n.setSelectionRange(n.value.length,n.value.length);}});
    m.bd.addEventListener('click',async e=>{
      const ms=e.target.closest('[data-miss]');if(ms){st.missing=ms.dataset.miss==='1';load();return;}
      if(e.target.closest('[data-x2]')){m.close();return;}
      const sv=e.target.closest('[data-save]');if(sv){const rows=changed().map(x=>({id:x.id,area:(st.val.get(x.id)||'').trim()}));if(!rows.length)return;
        sv.disabled=true;sv.textContent='Saving…';const r=await db.rpc('lwb_party_area_save',{p_rows:rows});
        if(r.error){sv.disabled=false;sv.textContent='✓ Save';alert('Could not save: '+r.error.message);return;}
        m.close();o.onSaved&&o.onSaved(r.data);}
    });
    load();
  }

  window.LWBSuggest={open,areas,group,items,css,kgf,srcText};
})();
