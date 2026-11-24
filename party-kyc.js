/* Party GST / PAN verify (Mohit, 24 Nov 2026).
 * Party popup: type a GSTIN or PAN and the legal name (GST: address + Active status) is fetched
 * by the lwb-party-kyc Edge Function and shown with a green / red badge. Empty fields are filled,
 * a different typed party name shows a warning with "Use this name".
 * Free checks run here with no API call: GSTIN check digit, state from the first 2 digits,
 * PAN from GSTIN, PAN holder type (4th letter). Each number is verified once per page (paid API).
 * Needs on the page: inputs #name #regStatus #pan #gstin #address #city #state #pincode and the
 * global Supabase client `db` (customer-master.html). */
(function(){
'use strict';
const STATES={'01':'Jammu and Kashmir','02':'Himachal Pradesh','03':'Punjab','04':'Chandigarh','05':'Uttarakhand','06':'Haryana','07':'Delhi','08':'Rajasthan','09':'Uttar Pradesh','10':'Bihar','11':'Sikkim','12':'Arunachal Pradesh','13':'Nagaland','14':'Manipur','15':'Mizoram','16':'Tripura','17':'Meghalaya','18':'Assam','19':'West Bengal','20':'Jharkhand','21':'Odisha','22':'Chhattisgarh','23':'Madhya Pradesh','24':'Gujarat','26':'Dadra and Nagar Haveli and Daman and Diu','27':'Maharashtra','29':'Karnataka','30':'Goa','31':'Lakshadweep','32':'Kerala','33':'Tamil Nadu','34':'Puducherry','35':'Andaman and Nicobar Islands','36':'Telangana','37':'Andhra Pradesh','38':'Ladakh'};
const PAN_TYPE={P:'Individual',C:'Company',F:'Firm / LLP',H:'HUF',A:'AOP',T:'Trust',B:'BOI',L:'Local Authority',J:'Artificial Person',G:'Government'};
const C36='0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const panOk=p=>/^[A-Z]{3}[PCFHATBLJG][A-Z][0-9]{4}[A-Z]$/.test(p);
function gstCheck(g){let s=0;for(let i=0;i<14;i++){const v=C36.indexOf(g[i])*(i%2?2:1);s+=Math.floor(v/36)+v%36}return C36[(36-s%36)%36]}
function gstOk(g){if(!/^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/.test(g))return 'GSTIN format is wrong (15 characters, e.g. 24ABCDE1234F1Z5).';
  if(!STATES[g.slice(0,2)])return 'First 2 digits ('+g.slice(0,2)+') are not a valid state code.';
  if(gstCheck(g)!==g[14])return 'GSTIN last character is wrong (check digit). Check for a typing mistake.';return ''}
// Loose name compare: M/S, SHREE, punctuation, spaces ignored.
const SKIP=new Set('M S MS MESSRS SHREE SHRI SRI THE AND'.split(' '));
const words=t=>String(t||'').toUpperCase().replace(/[^A-Z0-9 ]/g,' ').split(/\s+/).filter(w=>w&&!SKIP.has(w));
function nameMatch(a,b){const x=words(a),y=words(b);if(!x.length||!y.length)return 0;if(x.join('')===y.join(''))return 100;
  const sy=new Set(y);const hit=x.filter(w=>sy.has(w)).length;return Math.round(200*hit/(x.length+y.length))}
const esc=s=>String(s??'').replace(/[<>&"]/g,c=>({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;'}[c]));
const $=id=>document.getElementById(id);
const cache=new Map();let busy='';

function css(){const s=document.createElement('style');s.textContent=`
.kyc-in{display:flex;gap:6px}.kyc-in input{flex:1;min-width:0}
.kyc-in button{padding:0 10px;font-size:12.5px;white-space:nowrap;background:#002f37;flex:0 0 auto}.kyc-in input{letter-spacing:.2px}
.kyc-in button.done{background:#18613c}.kyc-in button.bad{background:#b42318}
.kyc-box{grid-column:1/-1;display:none;border:1.5px solid #d5dde8;border-radius:10px;padding:8px 10px;font-size:13px;line-height:1.45;background:#fbfcfe}
.kyc-box.show{display:block}.kyc-box.ok{border-color:#9fd8b3;background:#f2fbf5}.kyc-box.no{border-color:#f3b4ae;background:#fff6f5}.kyc-box.wait{color:#61738a}
.kyc-row{display:flex;align-items:center;gap:6px;flex-wrap:wrap}
.kyc-b{display:inline-block;border-radius:999px;padding:2px 9px;font-size:11.5px;font-weight:700;white-space:nowrap}
.kyc-b.g{background:#18613c;color:#fff}.kyc-b.r{background:#b42318;color:#fff}.kyc-b.a{background:#fdf0d5;color:#8a5300}.kyc-b.d{background:#eef1f5;color:#5b6b80}
.kyc-nm{font-weight:800;font-size:14.5px;color:#0c2340}.kyc-sub{color:#61738a;font-size:12px}
.kyc-warn{margin-top:5px;padding:5px 8px;border-radius:7px;background:#fff4dc;color:#7a4a00;font-size:12.5px;display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.kyc-warn button,.kyc-use{padding:4px 10px;font-size:12px;background:#c9b26a;color:#002f37}
.kyc-box+.kyc-box{margin-top:-4px}
@media(max-width:700px){.pm-card .grid .kyc-f{grid-column:span 2}}`;document.head.append(s)}

function wrap(id,label){const inp=$(id),f=inp.closest('.field');const w=document.createElement('div');w.className='kyc-in';inp.before(w);w.append(inp);
  const b=document.createElement('button');b.type='button';b.textContent='Verify';b.id=id+'Verify';b.title='Fetch the '+label+' holder name';w.append(b);
  const box=document.createElement('div');box.className='kyc-box';box.id=id+'Kyc';box.setAttribute('aria-live','polite');return {inp,f,b,box}}

let G,P;
function boxes(){// GSTIN first (it gives the PAN too), each result box full width under its field.
  G.f.classList.add('kyc-f');P.f.classList.add('kyc-f');P.f.before(G.f);G.f.after(G.box);P.f.after(P.box)}
function clear(o){o.box.className='kyc-box';o.box.innerHTML='';o.b.className='';o.b.textContent='Verify'}
function show(o,cls,html){o.box.className='kyc-box show '+cls;o.box.innerHTML=html}
const fill=(id,v)=>{if(v&&!$(id).value.trim()){$(id).value=v;return 1}return 0};

function warnName(o,legal){const typed=$('name').value.trim();if(!typed||!legal)return '';const sc=nameMatch(typed,legal);
  if(sc>=80)return '<div class="kyc-sub" style="margin-top:3px">✓ Party name matches ('+sc+'%)</div>';
  return '<div class="kyc-warn">⚠ Typed name <b>'+esc(typed)+'</b> is different ('+sc+'% match).<button type="button" class="kyc-fix">Use '+esc(legal)+'</button></div>'}
function wire(o,legal){const f=o.box.querySelector('.kyc-fix');if(f)f.onclick=()=>{$('name').value=legal;render(o)}
  const u=o.box.querySelector('.kyc-use');if(u)u.onclick=()=>{$('name').value=legal;render(o)}}

function render(o){const r=o.last;if(!r)return;const demo=r.demo?' <span class="kyc-b d" title="No API key yet: sample answer, not from GST / Income Tax">DEMO</span>':'';
  if(r.error){show(o,'no','<div class="kyc-row"><span class="kyc-b r">✕ Not verified</span>'+demo+'<span>'+esc(r.error)+'</span></div>');o.b.className='bad';o.b.textContent='Retry';return}
  if(r.kind==='GST'){const act=/^active$/i.test(r.status||'');const legal=r.legal_name||'';
    const badge=r.valid===false?'<span class="kyc-b r">✕ GSTIN not found</span>':act?'<span class="kyc-b g">✓ GST Active</span>':'<span class="kyc-b r">✕ GST '+esc(r.status||'Not active')+'</span>';
    show(o,r.valid!==false&&act?'ok':'no','<div class="kyc-row">'+badge+demo+(legal?'<span class="kyc-nm">'+esc(legal)+'</span>':'')+'</div>'+
      (r.trade_name&&r.trade_name!==legal?'<div class="kyc-sub">Trade name: <b>'+esc(r.trade_name)+'</b></div>':'')+
      (r.address?'<div class="kyc-sub">'+esc(r.address)+'</div>':'')+
      ((r.constitution||r.registered_on)?'<div class="kyc-sub">'+esc([r.constitution,r.registered_on&&'Since '+r.registered_on].filter(Boolean).join(' · '))+'</div>':'')+
      (act||r.valid===false?'':'<div class="kyc-warn">⚠ This GSTIN is not Active. Do not make a GST bill on it without checking.</div>')+warnName(o,legal));
    o.b.className=act?'done':'bad';o.b.textContent=act?'✓ OK':'Check';wire(o,legal);return}
  const ok=r.valid!==false;const legal=r.name||'';
  show(o,ok?'ok':'no','<div class="kyc-row">'+(ok?'<span class="kyc-b g">✓ PAN Valid</span>':'<span class="kyc-b r">✕ PAN not found</span>')+demo+(legal?'<span class="kyc-nm">'+esc(legal)+'</span>':'')+
    (r.pan_type?'<span class="kyc-sub">'+esc(r.pan_type)+'</span>':'')+'</div>'+(ok?warnName(o,legal):''));
  o.b.className=ok?'done':'bad';o.b.textContent=ok?'✓ OK':'Check';wire(o,legal)}

async function call(body){if(typeof db==='undefined'||!db)return {error:'Not connected. Refresh the page.'};
  try{const {data,error}=await db.functions.invoke('lwb-party-kyc',{body});
    if(error){let msg=error.message||'Verify failed';try{const j=await error.context?.json?.();if(j&&j.error)msg=j.error}catch{}
      if(/Failed to send|not found|404/i.test(msg))msg='Verify service is not set up yet.';return {error:msg}}
    return data||{error:'No answer'}}catch(e){return {error:'Verify failed: '+(e.message||e)}}}

async function verifyGst(auto){const g=G.inp.value.trim().toUpperCase();G.inp.value=g;if(!g){clear(G);return}
  const bad=gstOk(g);if(bad){if(auto&&g.length<15){clear(G);return}G.last={kind:'GST',error:bad};render(G);return}
  // Free: state + PAN from the number itself.
  fill('state',STATES[g.slice(0,2)]);fill('pan',g.slice(2,12));if($('regStatus').value!=='REGISTERED')$('regStatus').value='REGISTERED';
  if(busy==='G'+g)return;let r=cache.get('G'+g);
  if(!r){busy='G'+g;G.b.disabled=true;G.b.textContent='…';show(G,'wait','Checking '+esc(g)+' with GST…');r=await call({gstin:g});busy='';G.b.disabled=false;if(!r.error||r.demo)cache.set('G'+g,r)}
  G.last={kind:'GST',...r};
  if(!r.error&&r.valid!==false){fill('name',r.legal_name);fill('address',r.address);fill('city',r.city);fill('pincode',r.pincode);
    // PAN box: the GSTIN already proves the PAN, so no second paid call.
    if($('pan').value.trim().toUpperCase()===g.slice(2,12)){P.last={kind:'PAN',valid:true,name:r.legal_name,pan_type:PAN_TYPE[g[5]]||'',demo:r.demo,fromGst:true};P.box.className='kyc-box';P.b.className='done';P.b.textContent='✓ OK'}}
  render(G)}

async function verifyPan(auto){const p=P.inp.value.trim().toUpperCase();P.inp.value=p;if(!p){clear(P);return}
  if(!panOk(p)){if(auto&&p.length<10){clear(P);return}P.last={kind:'PAN',error:'PAN format is wrong (5 letters + 4 numbers + 1 letter, e.g. ABCPE1234F).'};render(P);return}
  const g=G.inp.value.trim().toUpperCase();if(G.last&&!G.last.error&&g.slice(2,12)===p){P.box.className='kyc-box';P.b.className='done';P.b.textContent='✓ OK';return}
  if(busy==='P'+p)return;let r=cache.get('P'+p);
  if(!r){busy='P'+p;P.b.disabled=true;P.b.textContent='…';show(P,'wait','Checking PAN '+esc(p)+' with Income Tax…');r=await call({pan:p,name:$('name').value.trim()});busy='';P.b.disabled=false;if(!r.error||r.demo)cache.set('P'+p,r)}
  P.last={kind:'PAN',pan_type:PAN_TYPE[p[3]]||'',...r};if(!r.error&&r.valid!==false)fill('name',r.name);render(P)}

function init(){if(!$('gstin')||!$('pan'))return;css();G=wrap('gstin','GSTIN');P=wrap('pan','PAN');boxes();
  G.b.onclick=()=>verifyGst(false);P.b.onclick=()=>verifyPan(false);
  // Auto verify when the full number is typed / pasted.
  G.inp.addEventListener('input',()=>{G.last=null;clear(G);if(G.inp.value.trim().length===15)verifyGst(true)});
  P.inp.addEventListener('input',()=>{P.last=null;clear(P);if(P.inp.value.trim().length===10)verifyPan(true)});
  G.inp.addEventListener('change',()=>verifyGst(true));P.inp.addEventListener('change',()=>verifyPan(true));
  $('name').addEventListener('change',()=>{if(G.last)render(G);if(P.last&&P.box.classList.contains('show'))render(P)})}
window.LWBPartyKyc={reset(){if(G){G.last=null;P.last=null;clear(G);clear(P)}},gstOk,panOk,nameMatch,STATES};
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();
