/* LUXURY WRIST BRAND ERP — documents and photos for any record (erp-docs.js).
 *
 * One private bucket (lwb-documents) + table lwb_documents (lwb_documents_setup.sql).
 * A file is stored at  ENTITY/<record id>/<DOC TYPE>/<user id without dashes>-<time>-<random>.<jpg|pdf>.
 *
 *   ERPDocs.panel({client, mount, entity, id, slots, canEdit, info})
 *       Shows the document slots of one record (Staff photo, Aadhaar, PAN, Bank, Licence ...).
 *       id = null: a new record. Files wait in memory; call  await panel.flush(newId)  after saving.
 *       id set: a chosen file is uploaded at once.
 *       panel.missing() -> labels of required slots that still have no file (block Save with it).
 *       info: true shows Aadhaar no. / PAN / bank details boxes (saved by flush()).
 *   ERPDocs.open({client, entity, id, title, slots, canEdit, info}) -> popup with a panel.
 *   ERPDocs.summary(client, entity) -> Map(record id -> Set of doc types it has).
 *   ERPDocs.badge(entity, types)    -> HTML: "Photo missing" / "📎 3".
 *   ERPDocs.avatars(client, entity, ids) -> Map(record id -> signed photo URL).
 *
 * Images are resized on the phone (photos 1600px, bills / documents 2200px) before upload.
 * PDF files up to 10 MB are uploaded as they are. A browser can not start a printer's
 * scanner: scan to PDF / JPG on the computer (or take a phone photo), then choose the file.
 */
(function(){
  'use strict';
  const BUCKET='lwb-documents',MAX_MB=10;
  const PHOTO={k:'PHOTO',l:'Photo',img:1,cam:'user',max:1};
  const S={ // slots per record type; req = must be there before Save
    STAFF:[{...PHOTO,l:'Employee photo',req:1},{k:'AADHAAR',l:'Aadhaar card (front + back)',req:1,max:4},{k:'BANK',l:'Bank passbook / cheque',max:2},{k:'PAN',l:'PAN card',max:2},{k:'OTHER',l:'Other document',max:6}],
    DRIVER:[{...PHOTO,l:'Driver photo',req:1},{k:'DL',l:'Driving licence (front + back)',req:1,max:4},{k:'AADHAAR',l:'Aadhaar card (front + back)',req:1,max:4},{k:'BANK',l:'Bank passbook / cheque',max:2},{k:'PAN',l:'PAN card',max:2},{k:'OTHER',l:'Other document',max:6}],
    USER:[{...PHOTO,l:'Staff photo',req:1},{k:'AADHAAR',l:'Aadhaar card',max:4},{k:'BANK',l:'Bank passbook / cheque',max:2},{k:'PAN',l:'PAN card',max:2},{k:'OTHER',l:'Other document',max:6}],
    VEHICLE:[{k:'PHOTO',l:'Vehicle photo (number plate visible)',img:1,cam:'environment',max:4,want:1},{k:'RC',l:'RC book',max:4},{k:'INSURANCE',l:'Insurance',max:4},{k:'PUC',l:'PUC',max:2},{k:'FITNESS',l:'Fitness',max:2},{k:'PERMIT',l:'Permit',max:4},{k:'OTHER',l:'Other document',max:6}],
    PARTY:[{k:'SHOP',l:'Shop photo',img:1,cam:'environment',max:4,want:1},{k:'PAN',l:'PAN card',max:2},{k:'GST',l:'GST certificate',max:4},{k:'OWNER',l:'Owner photo',img:1,cam:'environment',max:2},{k:'CHEQUE',l:'Cancelled cheque',max:2},{k:'OTHER',l:'Other document',max:6}],
    SUPPLIER:[{k:'GST',l:'GST certificate',max:4},{k:'PAN',l:'PAN card',max:2},{k:'CHEQUE',l:'Cancelled cheque',max:2},{k:'OTHER',l:'Other document',max:6}],
    PURCHASE_BILL:[{k:'BILL',l:'Purchase bill (PDF / scan / photo)',doc:1,max:10,want:1},{k:'DAMAGE',l:'Damage / leakage / breakage photos',img:1,cam:'environment',max:10},{k:'OTHER',l:'LR / other',max:6}],
    ASSET:[{k:'PHOTO',l:'Asset photo',img:1,cam:'environment',req:1,max:6},{k:'BILL',l:'Purchase bill (PDF / scan / photo)',doc:1,max:6},{k:'WARRANTY',l:'Warranty card',max:4},{k:'OTHER',l:'Other document',max:6}],
    STOCK_MOVE:[{k:'DAMAGE',l:'Damage / leakage / breakage photos',img:1,cam:'environment',req:1,max:6}],
    ORDER:[{k:'LOADED',l:'Loaded vehicle photo',img:1,cam:'environment',max:4},{k:'DAMAGE',l:'Damage / leakage / breakage at loading',img:1,cam:'environment',max:6}]
  };
  const INFO={ // KYC numbers kept with the documents (lwb_doc_info)
    STAFF:['aadhaar_no','pan_no','bank_holder','bank_name','bank_account','bank_ifsc','upi_id'],
    DRIVER:['aadhaar_no','pan_no','bank_holder','bank_name','bank_account','bank_ifsc','upi_id'],
    USER:['aadhaar_no','pan_no','bank_holder','bank_name','bank_account','bank_ifsc','upi_id']
  };
  const INFO_L={aadhaar_no:['Aadhaar number','12 digits'],pan_no:['PAN number','ABCDE1234F'],bank_holder:['Account holder name',''],bank_name:['Bank name','e.g. SBI'],
    bank_account:['Bank account number','6–18 digits'],bank_ifsc:['IFSC code','SBIN0001234'],upi_id:['UPI ID (optional)','name@upi']};
  const INFO_CHECK={aadhaar_no:v=>/^[2-9]\d{11}$/.test(v)||'Aadhaar number must be 12 digits.',pan_no:v=>/^[A-Z]{5}\d{4}[A-Z]$/.test(v)||'PAN must be 5 letters + 4 numbers + 1 letter.',
    bank_account:v=>/^\d{6,18}$/.test(v)||'Bank account number: 6 to 18 digits.',bank_ifsc:v=>/^[A-Z]{4}0[A-Z0-9]{6}$/.test(v)||'IFSC: 11 characters, e.g. SBIN0001234.',
    upi_id:v=>/^[\w.\-]{2,}@[a-zA-Z]{2,}$/.test(v)||'UPI ID looks wrong (name@bank).'};
  const cleanInfo=(k,v)=>{v=String(v||'').trim();if(k==='aadhaar_no'||k==='bank_account')return v.replace(/\D/g,'');if(k==='pan_no'||k==='bank_ifsc')return v.toUpperCase().replace(/\s/g,'');return v.replace(/\s+/g,' ')};

  const esc=v=>String(v==null?'':v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const toast=(t,k)=>window.ERPShell&&ERPShell.toast?ERPShell.toast(t,k):alert(t);
  const slotsOf=(entity,keys)=>{const all=S[entity]||[];if(!keys)return all;return keys.map(k=>typeof k==='string'?all.find(s=>s.k===k):k).filter(Boolean)};
  const setupMsg=e=>/lwb_doc_|lwb_documents|bucket/i.test((e&&e.message)||'')?'Documents are not set up in Supabase yet (lwb_documents_setup.sql).':(e&&e.message)||String(e);

  function css(){
    if(document.getElementById('erp-docs-css'))return;
    const s=document.createElement('style');s.id='erp-docs-css';
    s.textContent=`
.ed-wrap{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:10px;font-size:14px}
.ed-slot{border:1.5px dashed #cfd6de;border-radius:10px;padding:10px;background:#fbfcfd;min-width:0}
.ed-slot.req.miss{border-color:#d93025;background:#fff6f5}.ed-slot.ok{border-style:solid;border-color:#9fd3b4;background:#f5fbf7}
.ed-h{display:flex;justify-content:space-between;gap:6px;align-items:baseline;font-weight:700;color:#1f2a37;margin-bottom:6px}
.ed-h small{font-weight:600;color:#6b7785;white-space:nowrap}.ed-h .r{color:#d93025}
.ed-files{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:6px}
.ed-f{position:relative;width:64px;height:64px;border-radius:8px;overflow:hidden;border:1px solid #dfe3e8;background:#eef1f4;display:grid;place-items:center;cursor:pointer;font-size:11px;font-weight:700;color:#55606b;text-align:center}
.ed-f img{width:100%;height:100%;object-fit:cover}.ed-f.wait{opacity:.6}.ed-f.wait::after{content:"⏳";position:absolute;inset:auto 2px 2px auto;font-size:12px}
.ed-f .x{position:absolute;top:1px;right:1px;width:20px;height:20px;border-radius:50%;border:0;background:rgba(0,0,0,.6);color:#fff;font-size:12px;line-height:20px;padding:0;cursor:pointer}
.ed-btns{display:flex;flex-wrap:wrap;gap:6px}
.ed-btn{display:inline-flex;align-items:center;gap:4px;height:34px;padding:0 10px;border-radius:7px;border:1px solid #cfd6de;background:#fff;color:#1f2a37;font:inherit;font-size:13px;font-weight:600;cursor:pointer}
.ed-btn:disabled{opacity:.45;cursor:not-allowed}.ed-btn.main{background:var(--erp-red,#00434d);border-color:var(--erp-red,#00434d);color:#fff}
.ed-hint{font-size:12px;color:#6b7785;margin-top:4px;line-height:1.4}
.ed-info{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:10px;margin-top:12px}
.ed-info label{display:block;font-size:13px;font-weight:600;color:#4b5763;margin-bottom:4px}
.ed-info input{width:100%;height:40px;border:1.5px solid #e3e7ec;border-radius:6px;padding:0 10px;font:inherit;font-size:14px;box-sizing:border-box}
.ed-title{font-weight:700;font-size:15px;margin:2px 0 8px;color:#1f2a37}
.ed-back{position:fixed;inset:0;z-index:4800;background:rgba(15,23,42,.5);display:grid;place-items:center;padding:12px}
.ed-pop{width:min(860px,100%);max-height:92vh;overflow:auto;background:#fff;border-radius:12px;box-shadow:0 24px 60px rgba(15,23,42,.3);padding:16px}
.ed-pop-h{display:flex;justify-content:space-between;align-items:center;gap:10px;margin-bottom:10px}.ed-pop-h h3{margin:0;font-size:17px}
.ed-view{position:fixed;inset:0;z-index:4900;background:rgba(0,0,0,.85);display:grid;place-items:center;padding:12px}
.ed-view img{max-width:96vw;max-height:84vh;border-radius:6px}.ed-view .bar{position:fixed;top:10px;right:10px;display:flex;gap:8px}
.ed-tag{display:inline-block;font-size:11.5px;font-weight:700;border-radius:999px;padding:2px 8px;margin:2px 2px 0 0;white-space:nowrap}
.ed-tag.bad{background:#fdecec;color:#b42318}.ed-tag.ok{background:#e3f7e9;color:#18613c}.ed-tag.warn{background:#fff4e0;color:#8a5300}
.ed-av{width:36px;height:36px;border-radius:50%;object-fit:cover;border:1px solid #dfe3e8;vertical-align:middle;margin-right:8px;background:#eef1f4;display:inline-block}
@media(max-width:540px){.ed-wrap{grid-template-columns:1fr}.ed-pop{padding:12px}}`;
    document.head.append(s);
  }

  // Phone photos are large: resize to JPEG before upload. PDF / small PNG stay as they are.
  function shrink(file,maxSide){
    return new Promise((ok,bad)=>{
      const img=new Image(),url=URL.createObjectURL(file);
      img.onload=()=>{const s=Math.min(1,maxSide/Math.max(img.width,img.height)),c=document.createElement('canvas');
        c.width=Math.round(img.width*s);c.height=Math.round(img.height*s);const g=c.getContext('2d');g.fillStyle='#fff';g.fillRect(0,0,c.width,c.height);g.drawImage(img,0,0,c.width,c.height);
        URL.revokeObjectURL(url);c.toBlob(b=>b?ok(b):bad(Error('Photo could not be read')),'image/jpeg',0.82)};
      img.onerror=()=>{URL.revokeObjectURL(url);bad(Error('This file could not be read as a photo. Choose a JPG / PNG photo or a PDF.'))};
      img.src=url;
    });
  }
  async function prepare(file,slot){
    const pdf=file.type==='application/pdf'||/\.pdf$/i.test(file.name||'');
    if(pdf){if(slot.img)throw Error(slot.l+': choose a photo, not a PDF.');if(file.size>MAX_MB*1048576)throw Error('PDF is bigger than '+MAX_MB+' MB. Scan at 150–200 DPI or split it.');return {blob:file,mime:'application/pdf',ext:'pdf'}}
    if(!/^image\//.test(file.type||'')&&!/\.(jpe?g|png|webp|heic|heif)$/i.test(file.name||''))throw Error('Only photos (JPG / PNG) and PDF files can be uploaded.');
    const blob=await shrink(file,slot.doc?2200:1600);
    return {blob,mime:'image/jpeg',ext:'jpg'};
  }
  const rnd=()=>Math.random().toString(36).slice(2,8);

  async function uid(client){const {data}=await client.auth.getSession();if(!data.session)throw Error('Login again and retry');return data.session.user.id.replace(/-/g,'')}
  async function upload(client,entity,id,slot,prep,file){
    const path=entity+'/'+id+'/'+slot.k+'/'+(await uid(client))+'-'+Date.now()+'-'+rnd()+'.'+prep.ext;
    const up=await client.storage.from(BUCKET).upload(path,prep.blob,{contentType:prep.mime,upsert:false});
    if(up.error)throw Error('Upload failed: '+setupMsg(up.error));
    const r=await client.rpc('lwb_doc_add',{p_entity:entity,p_entity_id:String(id),p_doc_type:slot.k,p_path:path,p_file_name:String(file.name||'').slice(0,150)||null,p_mime:prep.mime,p_size:prep.blob.size||0,p_note:null});
    if(r.error){await client.storage.from(BUCKET).remove([path]).catch(()=>{});throw Error(setupMsg(r.error))}
    return {id:r.data,doc_type:slot.k,path,mime:prep.mime,file_name:file.name};
  }
  async function signed(client,paths){
    if(!paths.length)return new Map();
    const r=await client.storage.from(BUCKET).createSignedUrls(paths,3600);
    return new Map((r.data||[]).filter(x=>x.signedUrl).map(x=>[x.path,x.signedUrl]));
  }
  async function list(client,entity,ids){
    const r=await client.rpc('lwb_doc_list',{p_entity:entity,p_entity_ids:ids.map(String)});
    if(r.error)throw r.error;return r.data||[];
  }
  function viewer(url,isPdf){
    if(isPdf){window.open(url,'_blank','noopener');return}
    const v=document.createElement('div');v.className='ed-view';
    v.innerHTML='<div class="bar"><a class="ed-btn" target="_blank" rel="noopener">Open full</a><button type="button" class="ed-btn">Close ✕</button></div><img alt="Document">';
    v.querySelector('img').src=url;v.querySelector('a').href=url;
    v.onclick=e=>{if(e.target===v||e.target.tagName==='BUTTON')v.remove()};document.body.append(v);
  }

  function panel(o){
    css();
    const client=o.client,entity=o.entity,slots=slotsOf(entity,o.slots),canEdit=o.canEdit!==false,infoKeys=o.info?(INFO[entity]||[]):[];
    let id=o.id==null||o.id===''?null:String(o.id),files=[],pending=[],info={},infoLoaded=false,busy=0,err='';
    const root=document.createElement('div');root.className='ed-root';
    if(o.mount){o.mount.replaceChildren(root)}
    const pickers={};
    function picker(slot,cam){
      const i=document.createElement('input');i.type='file';i.hidden=true;
      i.accept=slot.img?'image/*':'image/*,application/pdf';if(cam)i.setAttribute('capture',slot.cam||'environment');
      if((slot.max||1)>1)i.multiple=true;
      i.onchange=()=>{const fl=[...i.files];i.value='';add(slot,fl)};root.append(i);return i;
    }
    function have(k){return files.filter(f=>f.doc_type===k).length+pending.filter(p=>p.slot.k===k).length}
    async function add(slot,fl){
      if(!fl.length)return;
      const room=(slot.max||1)-have(slot.k);
      if(room<=0&&(slot.max||1)===1&&id==null){pending=pending.filter(p=>p.slot.k!==slot.k)}
      else if(room<=0){toast(slot.l+': maximum '+(slot.max||1)+' file(s). Remove one first.','error');return}
      for(const f of fl.slice(0,Math.max(1,room))){
        let prep;try{prep=await prepare(f,slot)}catch(e){toast(e.message,'error');continue}
        const p={slot,file:f,prep,url:prep.mime==='application/pdf'?'':URL.createObjectURL(prep.blob),key:rnd()};
        pending.push(p);
        if(id!=null){render();await send(p)}
      }
      render();o.onChange&&o.onChange();
    }
    async function send(p){
      busy++;render();
      try{const d=await upload(client,entity,id,p.slot,p.prep,p.file);pending=pending.filter(x=>x!==p);d.url=p.url;files.push(d)}
      catch(e){p.fail=e.message;toast(p.slot.l+': '+e.message,'error')}
      finally{busy--;render()}
    }
    async function load(){
      files=[];err='';
      if(id==null){render();return}
      try{
        const rows=await list(client,entity,[id]);
        const urls=await signed(client,rows.filter(r=>r.mime!=='application/pdf').map(r=>r.path));
        files=rows.map(r=>({...r,url:urls.get(r.path)||''}));
        if(infoKeys.length&&!infoLoaded){const r=await client.rpc('lwb_doc_info_get',{p_entity:entity,p_entity_ids:[id]});if(!r.error){info=(r.data&&r.data[0]&&r.data[0].info)||{};infoLoaded=true}}
      }catch(e){err=setupMsg(e)}
      render();
    }
    async function remove(d){
      if(!await confirm('Remove this file?\n\n'+(slots.find(s=>s.k===d.doc_type)||{l:d.doc_type}).l+'\n\nThe file is kept in the record history (Admin can see it).'))return;
      const r=await client.rpc('lwb_doc_remove',{p_id:d.id});
      if(r.error){toast('Could not remove: '+setupMsg(r.error),'error');return}
      files=files.filter(x=>x!==d);render();o.onChange&&o.onChange();
    }
    function readInfo(){
      for(const k of infoKeys){const x=root.querySelector('[data-info="'+k+'"]');if(x)info[k]=cleanInfo(k,x.value)}
      return info;
    }
    function infoError(){
      readInfo();
      for(const k of infoKeys){const v=info[k];if(v&&INFO_CHECK[k]){const ok=INFO_CHECK[k](v);if(ok!==true)return ok}}
      return '';
    }
    function render(){
      if(infoKeys.length&&root.querySelector('[data-info]'))readInfo(); // keep what was typed
      const fileTile=(d,canX)=>{
        const pdf=d.mime==='application/pdf'||(d.prep&&d.prep.mime==='application/pdf');
        return '<div class="ed-f'+(d.prep&&id!=null?' wait':'')+'" data-k="'+esc(d.key||d.id)+'" title="'+esc(d.file_name||(d.file&&d.file.name)||'')+'">'+
          (pdf?'📄 PDF':d.url?'<img alt="" src="'+esc(d.url)+'">':'🖼')+(canX?'<button type="button" class="x" data-x="'+esc(d.key||d.id)+'" aria-label="Remove">✕</button>':'')+'</div>';
      };
      root.innerHTML=(err?'<div class="ed-hint" style="color:#b42318">'+esc(err)+'</div>':'')+
        '<div class="ed-wrap">'+slots.map(s=>{
          const mine=files.filter(f=>f.doc_type===s.k),wait=pending.filter(p=>p.slot.k===s.k),n=mine.length+wait.length;
          const cls='ed-slot'+(s.req?' req':'')+(n?' ok':s.req?' miss':'');
          return '<div class="'+cls+'"><div class="ed-h"><span>'+esc(s.l)+(s.req?' <span class="r">*</span>':'')+'</span><small>'+(n?'✓ '+n:s.req?'Required':s.want?'Recommended':'Optional')+'</small></div>'+
            (n?'<div class="ed-files">'+mine.map(d=>fileTile(d,canEdit)).join('')+wait.map(p=>fileTile(p,canEdit)).join('')+'</div>':'')+
            (canEdit?'<div class="ed-btns">'+(s.doc?'':'<button type="button" class="ed-btn" data-cam="'+s.k+'">📷 Camera</button>')+
              '<button type="button" class="ed-btn" data-pick="'+s.k+'">'+(s.img?'🖼 Gallery':s.doc?'📄 PDF / Scan / Photo':'📎 Photo / PDF')+'</button>'+
              (s.doc?'<button type="button" class="ed-btn" data-cam="'+s.k+'">📷 Phone camera</button>':'')+'</div>':'')+
            (s.doc&&canEdit?'<div class="ed-hint">Scanner: scan the bill to PDF / JPG on the computer (printer\'s scan button or app), then choose the file here. On a phone, use 📷 for each page.</div>':'')+
            (wait.some(p=>p.fail)?'<div class="ed-hint" style="color:#b42318">Not uploaded. Remove and try again.</div>':'')+
            (id==null&&wait.length?'<div class="ed-hint">Will upload when you Save.</div>':'')+'</div>';
        }).join('')+'</div>'+
        (infoKeys.length?'<div class="ed-info">'+infoKeys.map(k=>'<div><label>'+esc(INFO_L[k][0])+'</label><input data-info="'+k+'" maxlength="60" placeholder="'+esc(INFO_L[k][1])+'" value="'+esc(info[k]||'')+'"'+(canEdit?'':' disabled')+(k==='aadhaar_no'||k==='bank_account'?' inputmode="numeric"':'')+'></div>').join('')+'</div>':'')+
        (busy?'<div class="ed-hint">Uploading…</div>':'');
      for(const s of slots){if(!pickers[s.k]){pickers[s.k]={cam:picker(s,true),pick:picker(s,false)}}else{root.append(pickers[s.k].cam,pickers[s.k].pick)}}
    }
    root.addEventListener('click',e=>{
      const b=e.target.closest('button,.ed-f');if(!b||!root.contains(b))return;
      if(b.dataset.cam){pickers[b.dataset.cam].cam.click();return}
      if(b.dataset.pick){pickers[b.dataset.pick].pick.click();return}
      if(b.dataset.x){e.stopPropagation();const k=b.dataset.x,p=pending.find(x=>x.key===k);
        if(p){pending=pending.filter(x=>x!==p);render();o.onChange&&o.onChange();return}
        const d=files.find(x=>String(x.id)===k);if(d)remove(d);return}
      if(b.classList.contains('ed-f')){const k=b.dataset.k,d=files.find(x=>String(x.id)===k)||pending.find(x=>x.key===k);if(!d)return;
        const pdf=d.mime==='application/pdf'||(d.prep&&d.prep.mime==='application/pdf');
        if(d.url){viewer(d.url,false);return}
        if(pdf&&d.path){client.storage.from(BUCKET).createSignedUrl(d.path,3600).then(r=>{if(r.data)viewer(r.data.signedUrl,true)});return}
        if(pdf&&d.prep){viewer(URL.createObjectURL(d.prep.blob),true)}}
    });
    load();
    return {
      el:root,
      get id(){return id},
      missing(){return slots.filter(s=>s.req&&!have(s.k)).map(s=>s.l)},
      count(){return files.length+pending.length},
      has(k){return have(k)},
      busy(){return busy>0},
      infoError,
      async setId(newId){id=newId==null?null:String(newId);pending=[];infoLoaded=false;info={};await load()},
      // After the record is saved: upload waiting files + save the details. Returns a list of problems ('' = all fine).
      async flush(newId){
        if(newId!=null)id=String(newId);
        if(id==null)return 'Record not saved yet';
        const bad=[];
        for(const p of pending.slice()){if(p.fail){p.fail='';}await send(p);if(p.fail)bad.push(p.slot.l+': '+p.fail)}
        if(infoKeys.length&&canEdit){const ie=infoError();if(ie)bad.push(ie);else{
          const r=await client.rpc('lwb_doc_info_save',{p_entity:entity,p_entity_id:id,p_info:readInfo()});if(r.error)bad.push('Details not saved: '+setupMsg(r.error))}}
        render();return bad.join('\n');
      },
      reload:load
    };
  }

  function open(o){
    css();
    return new Promise(done=>{
      const back=document.createElement('div');back.className='ed-back';
      back.innerHTML='<div class="ed-pop" role="dialog" aria-modal="true"><div class="ed-pop-h"><h3></h3><div class="ed-btns">'+(o.info&&o.canEdit!==false?'<button type="button" class="ed-btn main" data-a="save">Save details</button>':'')+'<button type="button" class="ed-btn" data-a="close">Close ✕</button></div></div><div class="ed-body"></div><p class="ed-hint">Files upload as soon as you choose them. Only office staff with access can open them.</p></div>';
      back.querySelector('h3').textContent=o.title||'Documents & photos';
      document.body.append(back);
      const p=panel({...o,mount:back.querySelector('.ed-body')});
      const close=()=>{back.remove();done(p)};
      back.addEventListener('click',async e=>{
        const a=e.target.dataset&&e.target.dataset.a;
        if(e.target===back||a==='close'){if(p.busy()){toast('Upload in progress, please wait.','error');return}close();return}
        if(a==='save'){e.target.disabled=true;const bad=await p.flush();e.target.disabled=false;toast(bad||'Details saved.',bad?'error':'success')}
      });
    });
  }

  async function summary(client,entity){
    const r=await client.rpc('lwb_doc_summary',{p_entity:entity});
    if(r.error)return null;
    return new Map((r.data||[]).map(x=>[String(x.entity_id),new Set(x.doc_types||[])]));
  }
  // types: Set of doc types of one record (null = documents not set up -> '').
  function badge(entity,types,keys){
    if(!types)return '';
    const sl=slotsOf(entity,keys),miss=sl.filter(s=>s.req&&!types.has(s.k)).map(s=>s.l.replace(/ \(.*\)$/,'')),want=sl.filter(s=>s.want&&!types.has(s.k)).map(s=>s.l.replace(/ \(.*\)$/,''));
    return miss.map(m=>'<span class="ed-tag bad">'+esc(m)+' missing</span>').join('')+want.map(m=>'<span class="ed-tag warn">No '+esc(m.toLowerCase())+'</span>').join('')+
      (types.size&&!miss.length?'<span class="ed-tag ok">📎 '+types.size+' doc type'+(types.size>1?'s':'')+'</span>':'');
  }
  function missingOf(entity,types,keys){if(!types)return [];return slotsOf(entity,keys).filter(s=>s.req&&!types.has(s.k)).map(s=>s.l)}
  async function avatars(client,entity,ids){
    const out=new Map();if(!ids.length)return out;
    try{
      const rows=(await list(client,entity,ids)).filter(r=>(r.doc_type==='PHOTO'||r.doc_type==='SHOP')&&r.mime!=='application/pdf');
      const first=new Map();for(const r of rows)if(!first.has(String(r.entity_id)))first.set(String(r.entity_id),r.path);
      const urls=await signed(client,[...first.values()]);
      for(const [k,p] of first)if(urls.get(p))out.set(k,urls.get(p));
    }catch(e){}
    return out;
  }
  window.ERPDocs={panel,open,summary,badge,missingOf,avatars,slots:slotsOf,BUCKET,css};
})();
