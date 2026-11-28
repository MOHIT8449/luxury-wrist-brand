/* LUXURY WRIST BRAND ERP — Evening report (Daily Report PDF) after the cash handover (evening-report.js, 26 Nov 2026).
 *
 * Needs lwb_evening_report_setup.sql. Without it nothing shows.
 *
 *   LWBEvening.init({db, role})        Admin only (erp-shell.js calls it on every page): once today's cash handover /
 *                                      Close Day is done, a popup "Evening report ready" with ⬇ Download PDF.
 *                                      Not downloaded -> it comes back every 5 minutes ("Later" = 5 minutes).
 *                                      Downloaded -> nothing more today; tomorrow again after tomorrow's handover.
 *   LWBEvening.open(db, date)           the same popup for any day (WhatsApp Reports page button).
 *   LWBEvening.download(db, date)       straight to the PDF.
 *
 * The PDF is drawn by the same code as the WhatsApp PDF (supabase/functions/lwb-daily-whatsapp/render.mjs),
 * with pdf-lib in the browser: vector text, small file. Phone: no left-right scroll, buttons in one row.
 */
(function(){
  'use strict';
  const esc=v=>String(v==null?'':v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const rs=n=>'₹'+Math.round(Number(n)||0).toLocaleString('en-IN');
  const dmy=d=>String(d||'').slice(0,10).split('-').reverse().join('/');
  const hm=t=>t?new Date(t).toLocaleTimeString('en-IN',{hour:'2-digit',minute:'2-digit',timeZone:'Asia/Kolkata'}):'';
  const toast=(t,k)=>window.ERPShell&&ERPShell.toast?ERPShell.toast(t,k):alert(t);
  const missing=e=>e&&(e.code==='PGRST202'||e.code==='42883'||/could not find the function|does not exist/i.test(e.message||''));
  const SNOOZE_MIN=5, CHECK_MS=60*1000, ASK_MS=5*60*1000;
  const LIB={pdf:'https://cdnjs.cloudflare.com/ajax/libs/pdf-lib/1.17.1/pdf-lib.min.js',
             fontkit:'https://cdn.jsdelivr.net/npm/@pdf-lib/fontkit@1.1.1/dist/fontkit.umd.min.js',
             render:'/supabase/functions/lwb-daily-whatsapp/render.mjs?v=20261126'};
  const store={get(k){try{return localStorage.getItem(k)}catch(e){return null}},set(k,v){try{localStorage.setItem(k,v)}catch(e){}}};

  function css(){
    if(document.getElementById('lwb-ev-css'))return;
    const s=document.createElement('style');s.id='lwb-ev-css';
    s.textContent=`
.ev-back{position:fixed;inset:0;z-index:4900;background:rgba(15,23,42,.5);display:grid;place-items:center;padding:10px}
.ev-pop{width:min(460px,100%);max-height:94vh;overflow-y:auto;overflow-x:hidden;background:#fff;border-radius:12px;box-shadow:0 24px 60px rgba(15,23,42,.3);padding:12px;font:14px/1.4 var(--erp-font,"Segoe UI",Roboto,Arial,sans-serif);color:#1f2a37;box-sizing:border-box}
.ev-pop *{box-sizing:border-box}
.ev-h{display:flex;gap:8px;align-items:flex-start;margin-bottom:8px}
.ev-h .ic{flex:0 0 34px;height:34px;border-radius:50%;display:grid;place-items:center;background:#e9eefc;font-size:17px}
.ev-h h3{margin:0;font-size:16px;line-height:1.25}.ev-h small{display:block;color:#6b7785;font-size:12.5px;margin-top:2px}
.ev-h .x{margin-left:auto;flex:none;border:0;background:none;font-size:20px;line-height:1;padding:2px 4px;cursor:pointer;color:#6b7785}
.ev-ho{display:flex;gap:6px;align-items:center;flex-wrap:wrap;background:#eefaf2;border:1px solid #bfe6cc;border-radius:8px;padding:6px 8px;font-size:13px;margin-bottom:8px}
.ev-ho b{color:#0d6b36}
.ev-ho.no{background:#fff6e5;border-color:#f3d79b}.ev-ho.no b{color:#8a5a00}
.ev-grid{display:grid;grid-template-columns:1fr 1fr;gap:6px;margin-bottom:8px}
.ev-k{border:1px solid #e3e7ec;border-radius:8px;padding:6px 8px;min-width:0}
.ev-k small{display:block;color:#6b7785;font-size:11.5px;font-weight:600;text-transform:uppercase;letter-spacing:.3px}
.ev-k b{display:block;font-size:16px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ev-k.s b{color:#0f4c5c}.ev-k.r b{color:#13824a}.ev-k.p b{color:#9a5b00}.ev-k.b b{color:#1d4ed8}
.ev-note{font-size:12.5px;color:#5b6773;margin:0 0 8px}
.ev-note .tag{display:inline-block;border-radius:99px;padding:1px 7px;font-size:11.5px;font-weight:700;background:#e3f4ea;color:#13824a}
.ev-foot{display:flex;gap:6px}
.ev-foot button{flex:1;min-width:0;height:38px;border-radius:8px;border:0;font:inherit;font-weight:700;font-size:14px;cursor:pointer;background:#eef0f3;color:#1f2a37;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding:0 6px}
.ev-foot .go{flex:1.4;background:#0f4c5c;color:#fff}.ev-foot .wa{background:#e3f4ea;color:#0d6b36}
.ev-foot button:disabled{opacity:.6;cursor:wait}
.ev-err{background:#ffebeb;color:#9b2020;border-radius:8px;padding:6px 8px;font-size:13px;margin-bottom:8px}
@media(max-width:420px){.ev-k b{font-size:15px}.ev-foot button{font-size:13px}}
`;
    document.head.appendChild(s);
  }

  // ---------- PDF ----------
  const script=src=>new Promise((ok,bad)=>{const s=document.createElement('script');s.src=src;s.onload=ok;s.onerror=()=>bad(Error('Could not load '+src.split('/')[2]));document.head.appendChild(s)});
  let libs=null;
  function loadLibs(){
    if(!libs)libs=(async()=>{
      if(!window.PDFLib)await script(LIB.pdf);
      if(!window.fontkit)await script(LIB.fontkit);
      const R=await import(LIB.render);
      const fonts=await Promise.all(R.FONT_URLS.map(async u=>{const r=await fetch(u);if(!r.ok)throw Error('Font download failed');return new Uint8Array(await r.arrayBuffer())}));
      return {R,fonts};
    })().catch(e=>{libs=null;throw e});
    return libs;
  }
  async function pdfBytes(doc,date){
    const {R,fonts}=await loadLibs();
    return R.buildPdf(doc,{PDFDocument:PDFLib.PDFDocument,rgb:PDFLib.rgb},window.fontkit,fonts,{title:'Daily Report',sub:'Evening report',date:dmy(date),footer:'For Admin'});
  }
  function save(bytes,name){
    const u=URL.createObjectURL(new Blob([bytes],{type:'application/pdf'})),a=document.createElement('a');
    a.href=u;a.download=name;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(u),4000);
  }
  const fileName=d=>'Evening-report-'+dmy(d).replace(/\//g,'-')+'.pdf';
  async function report(db,date){
    const r=await db.rpc('lwb_evening_report',{p_date:date||null});if(r.error)throw r.error;return r.data;
  }
  async function download(db,date,rep){
    rep=rep||await report(db,date);
    save(await pdfBytes(rep.doc,rep.date),fileName(rep.date));
    const m=await db.rpc('lwb_evening_mark',{p_date:rep.date});if(m.error)throw m.error;
    if(rep.date===today())store.set('lwbEvDone',rep.date);
    return rep;
  }
  const today=()=>new Date().toLocaleDateString('en-CA',{timeZone:'Asia/Kolkata'});

  // ---------- popup ----------
  let open_=false;
  async function open(db,date,auto){
    if(open_)return;open_=true;css();
    const back=document.createElement('div');back.className='ev-back';
    back.innerHTML='<div class="ev-pop" role="dialog" aria-modal="true" aria-label="Evening report"><div class="ev-h"><span class="ic">🌙</span><div><h3>Evening report ready</h3><small>Loading '+esc(dmy(date||today()))+'…</small></div><button type="button" class="x" aria-label="Close">×</button></div></div>';
    document.body.appendChild(back);
    const pop=back.querySelector('.ev-pop');
    const close=snooze=>{back.remove();open_=false;if(snooze)store.set('lwbEvSnooze',String(Date.now()+SNOOZE_MIN*60000))};
    back.querySelector('.x').onclick=()=>close(auto);
    let rep;
    try{rep=await report(db,date)}catch(e){
      pop.insertAdjacentHTML('beforeend','<div class="ev-err">'+esc(e.message||e)+'</div>');
      return;
    }
    const S=rep.sum||{},H=rep.handover;
    pop.innerHTML='<div class="ev-h"><span class="ic">🌙</span><div><h3>Evening report · '+esc(dmy(rep.date))+'</h3><small>Daily Report PDF · company-wise sales, payments, purchase, bank</small></div><button type="button" class="x" aria-label="Close">×</button></div>'+
      (H?'<div class="ev-ho">✅ <b>Cash handover done</b> '+esc(H.by)+(H.to?' → '+esc(H.to):'')+' · <b>'+rs(H.amount)+'</b> · '+esc(hm(H.at))+'</div>'
        :'<div class="ev-ho no">⏳ <b>Cash handover not done yet</b> for this day</div>')+
      '<div class="ev-grid"><div class="ev-k s"><small>Sales today</small><b>'+rs(S.sales)+'</b></div><div class="ev-k r"><small>Received today</small><b>'+rs(S.received)+'</b></div>'+
      '<div class="ev-k p"><small>Purchase today</small><b>'+rs(S.purchase)+'</b></div><div class="ev-k b"><small>Bank balance</small><b>'+rs(S.bank)+'</b></div></div>'+
      '<p class="ev-note">'+(rep.downloaded_at?'<span class="tag">✓ Downloaded '+esc(hm(rep.downloaded_at))+'</span> ':'')+(auto?'Not downloaded = this comes again in '+SNOOZE_MIN+' minutes.':'Same PDF goes on WhatsApp with the daily reports.')+'</p>'+
      '<div class="ev-err" hidden></div>'+
      '<div class="ev-foot"><button type="button" class="go">⬇ Download PDF</button><button type="button" class="wa" title="Send this PDF to my WhatsApp">📲 WhatsApp</button><button type="button" class="later">'+(auto?'Later':'Close')+'</button></div>';
    const err=pop.querySelector('.ev-err'),say=t=>{err.textContent=t;err.hidden=false};
    pop.querySelector('.x').onclick=()=>close(auto);
    pop.querySelector('.later').onclick=()=>close(auto);
    const go=pop.querySelector('.go'),wa=pop.querySelector('.wa');
    go.onclick=async()=>{
      go.disabled=true;go.textContent='Making PDF…';err.hidden=true;
      try{await download(db,rep.date,rep);toast('Evening report downloaded');close(false)}
      catch(e){say(e.message||String(e));go.disabled=false;go.textContent='⬇ Download PDF'}
    };
    wa.onclick=async()=>{
      wa.disabled=true;err.hidden=true;
      try{const r=await db.rpc('lwb_daily_wa_send',{p_date:rep.date,p_mode:'TEST_EVENING'});if(r.error)throw r.error;toast('Sending… check WhatsApp in a minute')}
      catch(e){say(e.message||String(e))}
      wa.disabled=false;
    };
  }

  // ---------- Admin: watch for today's handover ----------
  let started=false,lastAsk=0,busy=false;
  async function check(db){
    if(busy||open_||document.hidden)return;
    const t=today();
    if(store.get('lwbEvDone')===t)return;
    if(Number(store.get('lwbEvSnooze')||0)>Date.now())return;
    if(Date.now()-lastAsk<ASK_MS&&lastAsk)return;
    busy=true;lastAsk=Date.now();
    try{
      const r=await db.rpc('lwb_evening_due');
      if(r.error){if(missing(r.error))started='off';return}
      const d=r.data||{};
      if(d.downloaded_at&&d.date===t){store.set('lwbEvDone',t);return}
      if(d.due){lastAsk=0;await open(db,d.date,true)}
    }catch(e){}finally{busy=false}
  }
  function init(o){
    const db=o&&o.db,role=String(o&&o.role||'').toLowerCase();
    if(started||!db||role!=='admin')return;started=true;
    check(db);
    const t=setInterval(()=>{if(started==='off'){clearInterval(t);return}check(db)},CHECK_MS);
    document.addEventListener('visibilitychange',()=>{if(!document.hidden)check(db)});
  }

  window.LWBEvening={init,open:(db,date)=>open(db,date,false),download,report};
})();
