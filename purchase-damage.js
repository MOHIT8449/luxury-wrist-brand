/* LUXURY WRIST BRAND ERP — Godown damage report for purchase vehicles (purchase-damage.js, 6 Nov 2026).
 *
 * Needs lwb_purchase_damage_report_setup.sql. Loaded by the bell (erp-operations-notifications.js)
 * and by the Purchase List.
 *
 *   LWBPurchaseDamage.form({client, id, role, onDone})  -> popup: All OK, or lines (SKU · type · cases · PCS) + photos + note.
 *                                                         Submit = lwb_purchase_damage_report (Admin + Sales Head get the report).
 *   LWBPurchaseDamage.view({client, id, role, onEdit})  -> read-only report: lines, photos, who / when, claim status.
 *   LWBPurchaseDamage.arrivals({client, rows, role, onDone}) -> "Purchase vehicle arrived" popup for unread
 *                                                         PURCHASE_ARRIVED bells (ref_id = purchase bill id).
 * Phone: one column, no left-right scroll; buttons in one row.
 */
(function(){
  'use strict';
  const ISSUES=[['DAMAGE','Damage'],['LEAKAGE','Leakage'],['SHORTAGE','Shortage']];
  const esc=v=>String(v==null?'':v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const num=v=>Number(v||0);
  const fmt=v=>num(v).toLocaleString('en-IN');
  const dmy=d=>d?String(d).slice(8,10)+'/'+String(d).slice(5,7)+'/'+String(d).slice(0,4):'—';
  const today=()=>new Date().toLocaleDateString('en-CA',{timeZone:'Asia/Kolkata'});
  const toast=(t,k)=>window.ERPShell&&ERPShell.toast?ERPShell.toast(t,k):alert(t);
  const qtyTxt=(c,p)=>[c?fmt(c)+' cs':'',p?fmt(p)+' pcs':''].filter(Boolean).join(' + ')||'0';
  const pick=(o,keys)=>{for(const k of keys)if(o&&o[k]!=null&&o[k]!=='')return o[k];return null};
  const vehOf=b=>String(b.vehicle_no||'').toUpperCase().replace(/[^A-Z0-9]/g,'')||'No vehicle no.';

  function css(){
    if(document.getElementById('lwb-pd-css'))return;
    const s=document.createElement('style');s.id='lwb-pd-css';
    s.textContent=`
.pd-back{position:fixed;inset:0;z-index:4700;background:rgba(15,23,42,.5);display:grid;place-items:center;padding:10px}
.pd-pop{width:min(640px,100%);max-height:94vh;overflow-y:auto;overflow-x:hidden;background:#fff;border-radius:12px;box-shadow:0 24px 60px rgba(15,23,42,.3);padding:14px;font:14px/1.4 var(--erp-font,"Segoe UI",Roboto,Arial,sans-serif);color:#1f2a37;box-sizing:border-box}
.pd-pop *{box-sizing:border-box}
.pd-h{display:flex;gap:8px;align-items:flex-start;margin-bottom:8px}
.pd-h .ic{flex:0 0 36px;height:36px;border-radius:50%;display:grid;place-items:center;background:#fff2dc;font-size:18px}
.pd-h h3{margin:0;font-size:16.5px;line-height:1.25;overflow-wrap:anywhere}
.pd-h small{display:block;color:#6b7785;font-size:12.5px;margin-top:2px;overflow-wrap:anywhere}
.pd-h .x{margin-left:auto;flex:none;border:0;background:none;font-size:20px;line-height:1;padding:2px 4px;cursor:pointer;color:#6b7785}
.pd-skus{margin:0 0 8px;padding:6px 8px;background:#f6f7f9;border-radius:8px;font-size:12.5px;color:#4b5763}
.pd-skus b{color:#1f2a37;font-weight:600}
.pd-pick{display:grid;grid-template-columns:1fr 1fr;gap:6px;margin-bottom:8px}
.pd-pick button{height:40px;border-radius:8px;border:1.5px solid #cfd6de;background:#fff;font:inherit;font-weight:700;font-size:14px;cursor:pointer;color:#1f2a37;padding:0 6px}
.pd-pick button.on.ok{background:#e4f6e9;border-color:#13824a;color:#0d6b36}
.pd-pick button.on.bad{background:#fdecef;border-color:#c8102e;color:#9e1528}
.pd-lab{font-size:12.5px;font-weight:700;color:#4b5763;margin:8px 0 4px}
.pd-line{display:grid;grid-template-columns:minmax(0,1fr) 104px 58px 58px 32px;gap:5px;align-items:center;margin-bottom:5px}
.pd-line select,.pd-line input,.pd-note{height:36px;border:1.5px solid #e3e7ec;border-radius:6px;padding:0 6px;font:inherit;font-size:14px;background:#fff;min-width:0;width:100%}
.pd-line input{text-align:right}
.pd-line .rm{height:36px;border:1px solid #e3e7ec;border-radius:6px;background:#fff;cursor:pointer;color:#9e1528;font-size:14px;padding:0}
.pd-hd{display:grid;grid-template-columns:minmax(0,1fr) 104px 58px 58px 32px;gap:5px;font-size:11.5px;font-weight:700;color:#6b7785;text-transform:uppercase;letter-spacing:.2px}
.pd-hd span:nth-child(3),.pd-hd span:nth-child(4){text-align:right}
.pd-add{height:32px;border:1px dashed #9aa6b2;border-radius:6px;background:#fbfcfd;font:inherit;font-size:13px;font-weight:600;cursor:pointer;padding:0 10px;color:#1f2a37}
.pd-err{color:#b42318;font-size:12.5px;margin-top:4px}
.pd-foot{display:flex;gap:6px;margin-top:10px;position:sticky;bottom:-14px;background:#fff;padding:8px 0 2px}
.pd-foot button{flex:1;height:40px;border-radius:8px;border:1px solid #cfd6de;background:#fff;font:inherit;font-weight:700;font-size:14px;cursor:pointer;color:#1f2a37;white-space:nowrap;padding:0 8px;min-width:0}
.pd-foot button.go{background:var(--erp-red,#00434d);border-color:var(--erp-red,#00434d);color:#fff}
.pd-foot button.ok{background:#13824a;border-color:#13824a;color:#fff}
.pd-foot button:disabled{opacity:.5;cursor:wait}
.pd-pop .ed-wrap{grid-template-columns:1fr}
.pd-card{border:1px solid #e3e7ec;border-left:4px solid #e3a008;border-radius:8px;padding:8px 10px;margin-bottom:8px}
.pd-card b{font-size:14.5px}.pd-card small{display:block;color:#6b7785;font-size:12.5px;overflow-wrap:anywhere}
.pd-card .row{display:flex;gap:6px;margin-top:6px}
.pd-card .row button{flex:1;height:36px;border-radius:7px;border:1px solid #cfd6de;background:#fff;font:inherit;font-weight:700;font-size:13.5px;cursor:pointer;white-space:nowrap;padding:0 6px;min-width:0}
.pd-card .row button.bad{background:#fdecef;border-color:#e9a5b0;color:#9e1528}.pd-card .row button.ok{background:#e4f6e9;border-color:#9fd3b4;color:#0d6b36}
.pd-t{width:100%;border-collapse:collapse;font-size:13.5px;margin:4px 0 8px;table-layout:fixed}
.pd-t th,.pd-t td{border-bottom:1px solid #e3e7ec;padding:5px 6px;text-align:left;overflow-wrap:anywhere}
.pd-t th{font-size:11.5px;color:#6b7785;text-transform:uppercase;background:#f6f7f9}
.pd-t .n{text-align:right;width:96px}.pd-t .ty{width:86px}
.pd-chip{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:700}
.pd-chip.ok{background:#e4f6e9;color:#0d6b36}.pd-chip.bad{background:#fdecef;color:#9e1528}.pd-chip.warn{background:#fff2dc;color:#8a5300}
.pd-meta{font-size:12.5px;color:#4b5763;margin:2px 0 8px}
@media(max-width:560px){
  .pd-back{padding:0;place-items:end stretch}
  .pd-pop{width:100%;max-height:96vh;border-radius:12px 12px 0 0;padding:12px}
  .pd-line,.pd-hd{grid-template-columns:minmax(0,1fr) 58px 58px 32px}
  .pd-line select.sku{grid-column:1/-1}
  .pd-hd span:first-child{display:none}
  .pd-hd span:nth-child(2){grid-column:1}
  .pd-line{padding-bottom:6px;border-bottom:1px solid #eef0f3;margin-bottom:6px}
  .pd-t .n{width:82px}.pd-t .ty{width:74px}
}`;
    document.head.append(s);
  }
  async function needDocs(){
    if(window.ERPDocs)return true;
    try{await new Promise((ok,bad)=>{const s=document.createElement('script');s.src='erp-docs.js';s.onload=ok;s.onerror=bad;document.head.append(s)});return !!window.ERPDocs}catch(e){return false}
  }
  function shell(html){
    css();
    const back=document.createElement('div');back.className='pd-back';
    back.innerHTML='<div class="pd-pop" role="dialog" aria-modal="true">'+html+'</div>';
    document.body.append(back);
    return back;
  }
  // Bill + lines + SKU names + check, in one go.
  async function loadBill(client,id){
    const [g,it,ck]=await Promise.all([
      client.from('lwb_goods_inward').select('*').eq('id',id).maybeSingle(),
      client.from('lwb_goods_inward_items').select('*').eq('inward_id',id),
      client.from('lwb_purchase_checks').select('*,lwb_purchase_check_items(*)').eq('inward_id',id).maybeSingle()]);
    if(g.error)throw g.error;if(!g.data)throw Error('Purchase bill not found');
    const lines=it.data||[],skuIds=[...new Set(lines.map(l=>l.sku_id).filter(Boolean))];
    let sk=new Map();
    if(skuIds.length){const s=await client.from('sku_master').select('id,sku_name,pcs_per_case').in('id',skuIds);sk=new Map((s.data||[]).map(x=>[String(x.id),x]))}
    const skus=lines.map(l=>{const s=sk.get(String(l.sku_id))||{};const pack=Math.max(1,num(s.pcs_per_case||pick(l,['pcs_per_case']))||1);
      const cs=num(pick(l,['cases','quantity_cases'])),pc=num(pick(l,['pcs','loose_pcs']));
      return {id:l.sku_id?String(l.sku_id):'',name:pick(l,['sku_name'])||s.sku_name||'SKU',pack,cs,pc,billed:num(pick(l,['quantity_pcs','total_pcs']))||cs*pack+pc}});
    return {bill:g.data,skus,check:ck.error?null:ck.data};
  }
  const billCases=d=>d.skus.reduce((a,s)=>a+s.cs,0);
  const subOf=d=>[d.bill.supplier_name,'Inv '+d.bill.invoice_no,'Recd '+dmy(d.bill.received_date),fmt(billCases(d))+' CS'].filter(Boolean).join(' · ');

  /* ---------------- report form ---------------- */
  async function form(o){
    const client=o.client;let d;
    try{d=await loadBill(client,o.id)}catch(e){toast('Could not open the bill: '+(e.message||e),'error');return}
    const ck=d.check;
    if(ck&&o.role==='warehouse'&&!['NONE','PENDING'].includes(ck.claim_status)){toast('The claim is already with the company. Ask Admin / Sales Head to change it.','error');return view(o)}
    let mode=ck?(ck.has_damage?'dmg':'ok'):'';
    let lines=(ck&&ck.lwb_purchase_check_items||[]).map(i=>({sku:String(i.sku_id||''),name:i.sku_name,issue:i.issue,cs:i.cases||'',pc:i.pcs||''}));
    const first=()=>({sku:d.skus.length===1?d.skus[0].id:'',issue:'DAMAGE',cs:'',pc:''});
    const back=shell('<div class="pd-h"><span class="ic">🚛</span><div><h3>'+esc(vehOf(d.bill))+' · Vehicle check</h3><small>'+esc(subOf(d))+'</small></div><button type="button" class="x" data-a="close" aria-label="Close">✕</button></div>'+
      '<div class="pd-skus">'+d.skus.map(s=>'<b>'+esc(s.name)+'</b> '+qtyTxt(s.cs,s.pc)).join(' · ')+'</div>'+
      '<div class="pd-pick"><button type="button" class="ok" data-m="ok">✓ All OK</button><button type="button" class="bad" data-m="dmg">⚠ Damage / Leak / Short</button></div>'+
      '<div class="pd-dmg" hidden><div class="pd-hd"><span>SKU</span><span>Type</span><span>Cases</span><span>PCS</span><span></span></div><div class="pd-lines"></div><button type="button" class="pd-add" data-a="add">+ Add line</button><div class="pd-err" hidden></div>'+
      '<div class="pd-lab">Photos of damaged / leaking cases</div><div class="pd-photos"></div></div>'+
      '<div class="pd-lab">Note</div><input class="pd-note" maxlength="300" placeholder="e.g. 2 cases wet near the door">'+
      '<div class="pd-foot"><button type="button" class="go" data-a="save" disabled>Submit</button><button type="button" data-a="close">Later</button></div>');
    const $=s=>back.querySelector(s);
    $('.pd-note').value=ck&&ck.note||'';
    let docs=null;
    if(await needDocs()){docs=ERPDocs.panel({client,mount:$('.pd-photos'),entity:'PURCHASE_BILL',id:o.id,slots:['DAMAGE']})}else $('.pd-photos').textContent='Photos: not available on this page.';
    const skuOpts=v=>'<option value="">Choose SKU</option>'+d.skus.map(s=>'<option value="'+esc(s.id)+'"'+(s.id===v?' selected':'')+'>'+esc(s.name)+' ('+qtyTxt(s.cs,s.pc)+')</option>').join('');
    function readLines(){back.querySelectorAll('.pd-line').forEach((r,i)=>{const L=lines[i];if(!L)return;L.sku=r.querySelector('.sku').value;L.issue=r.querySelector('.ty').value;L.cs=r.querySelector('.cs').value;L.pc=r.querySelector('.pc').value})}
    function drawLines(){
      $('.pd-lines').innerHTML=lines.map((L,i)=>'<div class="pd-line"><select class="sku" aria-label="SKU">'+skuOpts(L.sku)+'</select><select class="ty" aria-label="Type">'+ISSUES.map(([k,l])=>'<option value="'+k+'"'+(k===L.issue?' selected':'')+'>'+l+'</option>').join('')+'</select>'+
        '<input class="cs" type="number" min="0" step="1" inputmode="numeric" placeholder="Cs" aria-label="Cases" value="'+esc(L.cs)+'"><input class="pc" type="number" min="0" step="1" inputmode="numeric" placeholder="PCS" aria-label="PCS" value="'+esc(L.pc)+'">'+
        '<button type="button" class="rm" data-rm="'+i+'" aria-label="Remove line" title="Remove line">✕</button></div>').join('');
    }
    function draw(){
      back.querySelectorAll('.pd-pick button').forEach(b=>b.classList.toggle('on',b.dataset.m===mode));
      $('.pd-dmg').hidden=mode!=='dmg';
      if(mode==='dmg'&&!lines.length){lines.push(first())}
      if(mode==='dmg')drawLines();
      const s=$('[data-a="save"]');s.disabled=!mode;s.className=mode==='ok'?'ok':'go';
      s.textContent=mode==='ok'?'✓ Submit: All OK':mode==='dmg'?'Submit report':'Submit';
    }
    function collect(){
      readLines();const out=[],err=[];const per=new Map();
      for(const L of lines){
        const c=L.cs===''?0:Number(L.cs),p=L.pc===''?0:Number(L.pc);
        if(!L.sku&&c+p===0)continue;
        if(!L.sku){err.push('Choose the SKU on every line.');continue}
        if(![c,p].every(n=>Number.isInteger(n)&&n>=0)){err.push('Cases and PCS must be whole numbers.');continue}
        if(c+p===0){err.push('Enter cases or PCS on every line.');continue}
        const s=d.skus.find(x=>x.id===L.sku)||{name:L.name||'SKU',pack:1,billed:0};
        const k=L.sku+'|'+L.issue,old=out.find(x=>x.k===k);
        if(old){old.cases+=c;old.pcs+=p}else out.push({k,sku_id:L.sku,sku_name:s.name,pcs_per_case:s.pack,issue:L.issue,cases:c,pcs:p});
        per.set(L.sku,(per.get(L.sku)||0)+c*s.pack+p);
        if(s.billed&&per.get(L.sku)>s.billed)err.push(s.name+': more than the bill ('+qtyTxt(s.cs,s.pc)+').');
      }
      if(!err.length&&!out.length)err.push('Add at least one line, or press All OK.');
      return {items:out.map(({k,...x})=>x),err:[...new Set(err)]};
    }
    let busy=false;
    const close=()=>{if(docs&&docs.busy()){toast('Photo upload in progress, please wait.','error');return}back.remove()};
    back.addEventListener('click',async e=>{
      if(e.target===back)return close();
      const b=e.target.closest('button');if(!b||!back.contains(b)||b.closest('.ed-root'))return;
      if(b.dataset.m){readLines();mode=b.dataset.m;return draw()}
      if(b.dataset.rm!=null){readLines();lines.splice(Number(b.dataset.rm),1);if(!lines.length)lines.push(first());return drawLines()}
      const a=b.dataset.a;
      if(a==='close')return close();
      if(a==='add'){readLines();lines.push({...first(),sku:''});drawLines();const l=back.querySelectorAll('.pd-line .sku');l[l.length-1].focus();return}
      if(a==='save'&&!busy){
        let items=[];
        if(mode==='dmg'){const r=collect();const er=$('.pd-err');er.hidden=!r.err.length;er.textContent=r.err.join(' ');if(r.err.length)return;items=r.items}
        if(docs&&docs.busy())return toast('Photo upload in progress, please wait.','error');
        const photos=docs?docs.has('DAMAGE'):0;
        const txt=mode==='ok'?'All goods OK: no damage, leakage or shortage.':items.map(x=>x.sku_name+' · '+x.issue.charAt(0)+x.issue.slice(1).toLowerCase()+': '+qtyTxt(x.cases,x.pcs)).join('\n')+'\nPhotos: '+photos;
        if(mode==='dmg'&&docs&&!photos&&!await confirm('NO PHOTO ADDED\n\nA photo helps the company accept the claim. Submit without a photo?'))return;
        if(!await confirm((mode==='ok'?'SUBMIT: ALL OK?':'SUBMIT DAMAGE REPORT?')+'\n\n'+vehOf(d.bill)+' · Inv '+d.bill.invoice_no+'\n'+txt+'\n\nAdmin and Sales Head will get this report.'))return;
        busy=true;b.disabled=true;
        const r=await client.rpc('lwb_purchase_damage_report',{p_inward_id:o.id,p_verified_on:ck&&ck.verified_on||today(),p_note:$('.pd-note').value.trim(),p_items:items});
        busy=false;b.disabled=false;
        if(r.error)return toast('Not submitted: '+r.error.message,'error');
        let msg=mode==='ok'?'Vehicle checked: all OK. Admin and Sales Head informed.':'Damage report sent to Admin and Sales Head. Damaged goods are kept out of saleable stock.';
        // Admin / Sales Head saved damage without a photo: the Godown Manager gets the photo task (as before).
        if(r.data&&r.data.damage&&!r.data.photos&&['admin','manager'].includes(o.role)){const t=await client.rpc('lwb_purchase_photo_task',{p_inward:o.id});if(!t.error&&(t.data||[]).length)msg+=' Godown Manager got a photo task.'}
        toast(msg,'success');back.remove();o.onDone&&o.onDone(r.data);
      }
    });
    draw();
  }

  /* ---------------- read-only report ---------------- */
  async function view(o){
    const client=o.client;let d;
    try{d=await loadBill(client,o.id)}catch(e){toast('Could not open the report: '+(e.message||e),'error');return}
    const ck=d.check,it=(ck&&ck.lwb_purchase_check_items||[]).slice().sort((a,b)=>a.sku_name.localeCompare(b.sku_name)||a.issue.localeCompare(b.issue));
    let who='';
    if(ck&&(ck.updated_by||ck.created_by)){try{const p=await client.from('user_profiles').select('full_name').eq('id',ck.updated_by||ck.created_by).maybeSingle();who=p.data&&p.data.full_name||''}catch(e){}}
    const claim={PENDING:'Claim: mail not sent',SENT:'Claim: awaiting company',APPROVED:'Claim approved',RECEIVED:'Claim amount received',REJECTED:'Claim rejected'}[ck&&ck.claim_status]||'';
    const chip=!ck?'<span class="pd-chip warn">Not checked yet</span>':ck.has_damage?'<span class="pd-chip bad">⚠ Damage reported</span>':'<span class="pd-chip ok">✓ All OK</span>';
    const cs=it.reduce((a,i)=>a+i.cases+i.pcs/Math.max(1,i.pcs_per_case),0);
    const canEdit=['admin','manager'].includes(o.role)||(o.role==='warehouse'&&(!ck||['NONE','PENDING'].includes(ck.claim_status)));
    const back=shell('<div class="pd-h"><span class="ic">'+(ck&&ck.has_damage?'⚠':'🚛')+'</span><div><h3>'+esc(vehOf(d.bill))+' · Damage report</h3><small>'+esc(subOf(d))+'</small></div><button type="button" class="x" data-a="close" aria-label="Close">✕</button></div>'+
      '<div class="pd-meta">'+chip+(claim&&ck.has_damage?' <span class="pd-chip warn">'+esc(claim)+'</span>':'')+'<br>'+(ck?'Checked '+dmy(ck.verified_on)+(who?' by '+esc(who):''):'The Godown Manager has not checked this vehicle yet.')+'</div>'+
      (it.length?'<table class="pd-t"><thead><tr><th>SKU</th><th class="ty">Type</th><th class="n">Qty</th></tr></thead><tbody>'+it.map(i=>'<tr><td>'+esc(i.sku_name)+'</td><td class="ty">'+esc(i.issue.charAt(0)+i.issue.slice(1).toLowerCase())+'</td><td class="n">'+qtyTxt(i.cases,i.pcs)+'</td></tr>').join('')+
        '<tr><td colspan="2"><b>Total</b></td><td class="n"><b>'+fmt(Math.round(cs*10)/10)+' cs</b></td></tr></tbody></table><div class="pd-meta">Stock: damage and leakage moved out of saleable to Damage / Leakage; shortage taken off saleable (Loss).</div>':'')+
      (ck&&ck.note?'<div class="pd-meta"><b>Note:</b> '+esc(ck.note)+'</div>':'')+
      '<div class="pd-lab">Photos</div><div class="pd-photos"></div>'+
      '<div class="pd-foot">'+(canEdit?'<button type="button" class="go" data-a="edit">'+(ck?'✏ Change':'Check now')+'</button>':'')+(ck&&ck.has_damage&&['admin','manager'].includes(o.role)?'<button type="button" data-a="claim">Claims →</button>':'')+'<button type="button" data-a="close">Close</button></div>');
    if(await needDocs())ERPDocs.panel({client,mount:back.querySelector('.pd-photos'),entity:'PURCHASE_BILL',id:o.id,slots:['DAMAGE'],canEdit:false});
    back.addEventListener('click',e=>{
      if(e.target===back)return back.remove();
      const b=e.target.closest('button');if(!b||b.closest('.ed-root'))return;
      if(b.dataset.a==='close')back.remove();
      if(b.dataset.a==='edit'){back.remove();form(o)}
      if(b.dataset.a==='claim')location.href='purchase-claims.html';
    });
  }

  /* ---------------- "vehicle arrived" popup ---------------- */
  const SNOOZE='lwbPurchaseSnooze';
  let open=false;
  async function arrivals(o){
    if(open)return;
    try{if(Date.now()<Number(localStorage.getItem(SNOOZE)||0))return}catch(e){}
    const client=o.client,byBill=new Map();
    for(const n of o.rows||[])if(n.ref_id&&!byBill.has(n.ref_id))byBill.set(n.ref_id,n);
    if(!byBill.size)return;
    const ids=[...byBill.keys()];
    const [g,c]=await Promise.all([client.from('lwb_goods_inward').select('id,invoice_no,supplier_name,vehicle_no,received_date').in('id',ids),
      client.from('lwb_purchase_checks').select('inward_id').in('inward_id',ids)]);
    if(g.error)return;
    const done=new Set((c.data||[]).map(x=>x.inward_id));
    const gone=ids.filter(id=>done.has(id)||!(g.data||[]).some(b=>b.id===id));
    // Already checked (or bill removed): mark those bells read, no popup.
    if(gone.length)await client.from('erp_notifications').update({is_read:true}).in('id',gone.map(id=>byBill.get(id).id)).eq('notification_type','PURCHASE_ARRIVED');
    const bills=(g.data||[]).filter(b=>!done.has(b.id));
    if(!bills.length){o.onDone&&o.onDone();return}
    open=true;
    const msgOf=b=>String(byBill.get(b.id).message||'');
    const back=shell('<div class="pd-h"><span class="ic">🚛</span><div><h3>Purchase vehicle arrived'+(bills.length>1?' ('+bills.length+')':'')+'</h3><small>Check the goods. Any damage, leakage or shortage? Report it with photos.</small></div></div>'+
      bills.map(b=>'<div class="pd-card"><b>'+esc(vehOf(b))+'</b><small>'+esc([b.supplier_name,'Inv '+b.invoice_no,(msgOf(b).match(/\b[\d,]+ CS\b/)||[''])[0],'Recd '+dmy(b.received_date)].filter(Boolean).join(' · '))+'</small>'+
        '<div class="row"><button type="button" class="bad" data-dmg="'+esc(b.id)+'">⚠ Report damage</button><button type="button" class="ok" data-ok="'+esc(b.id)+'">✓ All OK</button></div></div>').join('')+
      '<div class="pd-foot"><button type="button" data-a="later">Later (15 min)</button></div>');
    const close=()=>{back.remove();open=false};
    back.addEventListener('click',async e=>{
      const t=e.target.closest('button');if(!t)return;
      if(t.dataset.a==='later'){try{localStorage.setItem(SNOOZE,String(Date.now()+15*60e3))}catch(er){}return close()}
      if(t.dataset.dmg){close();return form({client,id:t.dataset.dmg,role:o.role,onDone:o.onDone})}
      if(t.dataset.ok){
        const b=bills.find(x=>x.id===t.dataset.ok);
        if(!await confirm('ALL GOODS OK?\n\n'+vehOf(b)+' · Inv '+b.invoice_no+'\nNo damage, leakage or shortage.\n\nAdmin and Sales Head will get this report.'))return;
        t.disabled=true;
        const r=await client.rpc('lwb_purchase_damage_report',{p_inward_id:b.id,p_verified_on:today(),p_note:'',p_items:[]});
        t.disabled=false;
        if(r.error)return toast('Not submitted: '+r.error.message,'error');
        toast('Vehicle '+vehOf(b)+': all OK. Admin and Sales Head informed.','success');
        t.closest('.pd-card').remove();bills.splice(bills.indexOf(b),1);
        if(!bills.length)close();
        o.onDone&&o.onDone(r.data);
      }
    });
  }
  window.LWBPurchaseDamage={form,view,arrivals};
})();
