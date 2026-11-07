/* LUXURY WRIST BRAND ERP — Trips: Own / Transport / Porter, many POs in one trip, Porter rent later (trip-rent.js, 7 Nov 2026).
 *
 * Needs lwb_trip_rent_setup.sql. Without it every call returns null and the pages work as before.
 *
 *   LWBTrip.mount(el, {kind, rent, pay_mode, paid_by})  -> Own / Transport / Porter buttons + Porter rent box (all optional).
 *                                                         Returns {get(), set(o), kind(k, auto), onKind(cb), el}.
 *   LWBTrip.guess(vehicleNo, fleetVehicles)            -> 'OWN' | 'TRANSPORT' | 'PORTER' | '' (Vehicle Master ownership).
 *   LWBTrip.find(client, vehicleNo, skipOrderId)        -> today's open trip of that vehicle (no PO loaded yet) or null.
 *   LWBTrip.open(client, p)                             -> lwb_trip_open (trip made / picked before the assignment row is saved) or null.
 *   LWBTrip.ofOrders(client, ids)                       -> Map order_id -> {trip_no, kind, rent, pos}.
 *   LWBTrip.fill({client, trip, onDone})                -> popup: enter the Porter rent of one trip later.
 *   LWBTrip.remind(client)                              -> "Porter rent to fill" popup: rent left empty, 2 hours old / older day / after 7 pm.
 *                                                         "Later" = 1 hour. Called by erp-shell.js for Admin / Sales Head / Transport.
 * Phone: no left-right scroll, buttons in one row.
 */
(function(){
  'use strict';
  const esc=v=>String(v==null?'':v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const key=v=>String(v||'').toUpperCase().replace(/[^A-Z0-9]/g,'');
  const rs=n=>'₹'+Number(n||0).toLocaleString('en-IN',{maximumFractionDigits:2});
  const dm=d=>d?String(d).slice(8,10)+'/'+String(d).slice(5,7):'';
  const toast=(t,k)=>window.ERPShell&&ERPShell.toast?ERPShell.toast(t,k):alert(t);
  const missing=e=>e&&(e.code==='PGRST202'||e.code==='42883'||/could not find the function|does not exist/i.test(e.message||''));
  const KINDS=[['OWN','Own'],['TRANSPORT','Transport'],['PORTER','Porter']];
  const PAY=[['CASH','Cash now'],['ONLINE','Online / UPI'],['ACCOUNTS','Accounts later']];

  function css(){
    if(document.getElementById('lwb-trip-css'))return;
    const s=document.createElement('style');s.id='lwb-trip-css';
    s.textContent=`
.tr-box{display:flex;flex-direction:column;gap:6px;min-width:0}
.tr-lab{font-size:12px;font-weight:700;color:#4b5763;text-transform:uppercase;letter-spacing:.3px}
.tr-row{display:flex;gap:6px;min-width:0}
.tr-row button{flex:1 1 0;min-width:0;height:36px;border:1.5px solid #cfd6de;border-radius:8px;background:#fff;font:inherit;font-size:13.5px;font-weight:700;color:#1f2a37;cursor:pointer;padding:0 4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tr-row button[aria-pressed=true]{background:#0d2230;border-color:#0d2230;color:#fff}
.tr-pay button[aria-pressed=true]{background:#e4f6e9;border-color:#13824a;color:#0d6b36}
.tr-porter{display:flex;flex-direction:column;gap:6px;border:1px dashed #c9d2dc;border-radius:8px;padding:8px;background:#fafbfc}
.tr-porter[hidden]{display:none}
.tr-two{display:grid;grid-template-columns:1fr 1fr;gap:6px}
.tr-two label{display:flex;flex-direction:column;gap:3px;font-size:12.5px;font-weight:700;color:#4b5763;min-width:0}
.tr-two input{height:36px;border:1.5px solid #d5dce5;border-radius:7px;padding:0 8px;font:inherit;font-size:15px;width:100%;min-width:0;box-sizing:border-box;background:#fff}
.tr-hint{font-size:12.5px;color:#5b6773;line-height:1.35}
.tr-hint b{color:#1f2a37}
.tr-join{display:flex;gap:8px;align-items:flex-start;border:1px solid #c7d7ea;background:#f3f8ff;border-radius:8px;padding:7px 9px;font-size:13px;line-height:1.35}
.tr-join input{width:18px;height:18px;flex:none;margin:1px 0 0}
.tr-join[hidden]{display:none}
.tr-back{position:fixed;inset:0;z-index:4800;background:rgba(15,23,42,.5);display:grid;place-items:center;padding:10px}
.tr-pop{width:min(560px,100%);max-height:94vh;overflow-y:auto;overflow-x:hidden;background:#fff;border-radius:12px;box-shadow:0 24px 60px rgba(15,23,42,.3);padding:12px;font:14px/1.4 var(--erp-font,"Segoe UI",Roboto,Arial,sans-serif);color:#1f2a37;box-sizing:border-box}
.tr-pop *{box-sizing:border-box}
.tr-h{display:flex;gap:8px;align-items:flex-start;margin-bottom:8px}
.tr-h .ic{flex:0 0 34px;height:34px;border-radius:50%;display:grid;place-items:center;background:#fff2dc;font-size:17px}
.tr-h h3{margin:0;font-size:16px;line-height:1.25}.tr-h small{display:block;color:#6b7785;font-size:12.5px;margin-top:2px}
.tr-h .x{margin-left:auto;flex:none;border:0;background:none;font-size:20px;line-height:1;padding:2px 4px;cursor:pointer;color:#6b7785}
.tr-card{border:1px solid #e3e7ec;border-radius:10px;padding:8px;margin-bottom:8px;display:flex;flex-direction:column;gap:6px}
.tr-card>b{font-size:14.5px}.tr-card>small{color:#5b6773;font-size:12.5px;overflow-wrap:anywhere}
.tr-foot{display:flex;gap:6px}.tr-foot button,.tr-card .tr-save{flex:1;height:38px;border-radius:8px;border:0;font:inherit;font-weight:700;font-size:14px;cursor:pointer;background:#eef0f3;color:#1f2a37}
.tr-card .tr-save,.tr-foot .go{background:#1769df;color:#fff}
.tr-tag{display:inline-block;border-radius:99px;padding:1px 7px;font-size:11px;font-weight:700;background:#e4edff;color:#1a47a8;white-space:nowrap}
.tr-tag.p{background:#fff1c9;color:#7b5200}
`;
    document.head.appendChild(s);
  }

  function guess(no,fleet){
    const k=key(no);if(!k)return '';
    const v=(fleet||[]).find(x=>key(x.vehicle_no)===k);
    if(!v)return 'PORTER';
    return String(v.ownership||'').toUpperCase()==='TRANSPORTER'?'TRANSPORT':'OWN';
  }

  // Own / Transport / Porter + the Porter rent box (rent, paid how, paid by: all optional).
  function mount(el,o){
    css();o=o||{};
    el.innerHTML='<div class="tr-box"><span class="tr-lab">Vehicle</span>'+
      '<div class="tr-row tr-kind">'+KINDS.map(k=>'<button type="button" data-k="'+k[0]+'" aria-pressed="false">'+k[1]+'</button>').join('')+'</div>'+
      '<div class="tr-porter" hidden><div class="tr-two"><label>Rent ₹ <span style="font-weight:400">(optional)</span><input type="number" inputmode="decimal" min="1" max="100000" step="1" data-f="rent" placeholder="Fill later"></label>'+
      '<label>Paid by <span style="font-weight:400">(optional)</span><input data-f="paid_by" maxlength="120" placeholder="Name"></label></div>'+
      '<div class="tr-row tr-pay">'+PAY.map(p=>'<button type="button" data-p="'+p[0]+'" aria-pressed="false">'+p[1]+'</button>').join('')+'</div>'+
      '<div class="tr-hint">Empty now? A popup asks for the rent after 2 hours and at day close. The rent goes to <b>Accounts → Porter rent</b>.</div></div>'+
      '<div class="tr-hint" data-h="hired" hidden>Same vehicle, 2-3 parties at a time = <b>one trip, one rent</b>. Per party rent = the highest party rate of the trip.</div></div>';
    let kind='',pay='',manual=false,cb=null;
    const q=s=>el.querySelector(s);
    const paint=()=>{
      el.querySelectorAll('[data-k]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.k===kind)));
      el.querySelectorAll('[data-p]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.p===pay)));
      q('.tr-porter').hidden=kind!=='PORTER';q('[data-h=hired]').hidden=kind!=='TRANSPORT';
    };
    el.addEventListener('click',e=>{
      const k=e.target.closest('[data-k]'),p=e.target.closest('[data-p]');
      if(k){kind=k.dataset.k;manual=true;paint();cb&&cb(kind)}
      if(p){pay=pay===p.dataset.p?'':p.dataset.p;paint()}
    });
    const api={
      el,
      get(){const r=q('[data-f=rent]').value.trim(),by=q('[data-f=paid_by]').value.trim();
        return {kind,rent:kind==='PORTER'&&r?Number(r):null,pay_mode:kind==='PORTER'?pay||null:null,paid_by:kind==='PORTER'?by||null:null}},
      set(x){x=x||{};kind=x.kind||'';pay=x.pay_mode||'';manual=!!x.kind;q('[data-f=rent]').value=x.rent?Number(x.rent):'';q('[data-f=paid_by]').value=x.paid_by||'';paint()},
      // auto = from the typed vehicle; a button the user pressed is kept
      kind(k,auto){if(auto&&manual)return;kind=k||'';paint()},
      onKind(f){cb=f}
    };
    api.set(o);
    return api;
  }

  async function find(client,no,skip){
    if(!key(no))return null;
    const r=await client.rpc('lwb_trip_find',{p_vehicle_no:no,p_skip_order:skip==null?null:String(skip)});
    if(r.error)return null;
    return r.data||null;
  }
  async function open(client,p){
    const r=await client.rpc('lwb_trip_open',{p});
    if(r.error){if(missing(r.error))return null;throw r.error}
    return r.data||null;
  }
  async function ofOrders(client,ids){
    const m=new Map();if(!ids||!ids.length)return m;
    for(let i=0;i<ids.length;i+=200){
      const r=await client.rpc('lwb_trip_of_orders',{p_order_ids:ids.slice(i,i+200).map(String)});
      if(r.error)return m;
      (r.data||[]).forEach(x=>m.set(String(x.order_id),x));
    }
    return m;
  }

  // One card: rent + paid how + paid by, Save.
  function card(t){
    return '<div class="tr-card" data-trip="'+esc(t.id)+'"><b>'+esc(t.trip_no)+' · '+esc(t.vehicle_no)+' <span class="tr-tag p">Porter</span></b>'+
      '<small>'+esc([dm(t.date),t.driver,t.owner,(t.orders||[]).map(o=>o.order_no+' '+(o.party||'')).join(', ')].filter(Boolean).join(' · '))+'</small>'+
      '<div class="tr-two"><label>Rent ₹<input type="number" inputmode="decimal" min="1" max="100000" data-f="rent" placeholder="₹"></label>'+
      '<label>Paid by<input data-f="paid_by" maxlength="120" value="'+esc(t.paid_by||'')+'" placeholder="Name (optional)"></label></div>'+
      '<div class="tr-row tr-pay">'+PAY.map(p=>'<button type="button" data-p="'+p[0]+'" aria-pressed="'+(t.pay_mode===p[0])+'">'+p[1]+'</button>').join('')+'</div>'+
      '<button type="button" class="tr-save">Save rent</button></div>';
  }
  function bindCard(client,box,t,after){
    let pay=t.pay_mode||'';
    box.addEventListener('click',async e=>{
      const p=e.target.closest('[data-p]');
      if(p){pay=pay===p.dataset.p?'':p.dataset.p;box.querySelectorAll('[data-p]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.p===pay)));return}
      if(!e.target.closest('.tr-save'))return;
      const rent=Number(box.querySelector('[data-f=rent]').value);
      if(!(rent>0)){toast('Enter the rent of this trip','error');box.querySelector('[data-f=rent]').focus();return}
      const btn=box.querySelector('.tr-save');btn.disabled=true;btn.textContent='Saving...';
      const r=await client.rpc('lwb_trip_rent_set',{p_trip:t.id,p:{rent,pay_mode:pay||null,paid_by:box.querySelector('[data-f=paid_by]').value.trim()||null}});
      if(r.error){btn.disabled=false;btn.textContent='Save rent';toast(r.error.message,'error');return}
      toast(t.trip_no+': rent '+rs(rent)+' saved. Sent to Accounts.');
      after&&after();
    });
  }
  function popup(html){
    css();
    const back=document.createElement('div');back.className='tr-back';
    back.innerHTML='<div class="tr-pop" role="dialog" aria-modal="true">'+html+'</div>';
    document.body.appendChild(back);
    return back;
  }

  function fill(o){
    const t=o.trip;
    const back=popup('<div class="tr-h"><span class="ic">🚚</span><div><h3>Porter rent · '+esc(t.trip_no)+'</h3><small>Enter what was paid for this trip.</small></div><button type="button" class="x" aria-label="Close">✕</button></div>'+card(t));
    back.querySelector('.x').onclick=()=>back.remove();
    bindCard(o.client,back.querySelector('.tr-card'),t,()=>{back.remove();o.onDone&&o.onDone()});
  }

  const SNOOZE='lwbTripRentSnooze';
  let showing=false,timer=null;
  async function remind(client){
    if(!client)return;
    const run=async()=>{
      if(showing||document.hidden)return;
      try{if(Date.now()<Number(localStorage.getItem(SNOOZE)||0))return}catch(e){}
      const r=await client.rpc('lwb_trip_rent_due');
      if(r.error)return;
      const all=r.data||[];
      if(!all.some(t=>t.due))return;
      showing=true;
      const back=popup('<div class="tr-h"><span class="ic">⏳</span><div><h3>Porter rent to fill ('+all.length+')</h3><small>Rent was left empty at assignment. Fill it now so Accounts can pay.</small></div></div>'+
        all.map(card).join('')+'<div class="tr-foot"><button type="button" data-a="later">Later (1 hour)</button></div>');
      const left=new Set(all.map(t=>String(t.id)));
      const done=()=>{showing=false;back.remove()};
      back.querySelectorAll('.tr-card').forEach(c=>{const t=all.find(x=>String(x.id)===c.dataset.trip);
        bindCard(client,c,t,()=>{c.remove();left.delete(String(t.id));if(!left.size)done()})});
      back.querySelector('[data-a=later]').onclick=()=>{try{localStorage.setItem(SNOOZE,String(Date.now()+60*60e3))}catch(e){}done()};
    };
    run();
    if(!timer)timer=setInterval(run,10*60e3);
  }

  window.LWBTrip={mount,guess,find,open,ofOrders,fill,remind,css};
})();
