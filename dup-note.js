/* LUXURY WRIST BRAND ERP — duplicate / torn note from a party (Mohit, 26 Nov 2026). Database: lwb_acc_dup_note_setup.sql
   The cashier enters it with the party payment (only the good cash is in the payment, the note stays due on the party).
   This file shows the reminder wherever the party comes up: PO list / PO popup / PO print, New PO, Ledger & Outstanding.

   LWBDup.pending(client)      -> Promise [ {id, party, kind, notes, notes_text, amount, day, keys[]} ]  (cached 60 s)
   LWBDup.forParty(client, n)  -> Promise rows of one party (any login; New PO)
   LWBDup.of(list, name)       -> rows whose party / bill names match this name
   LWBDup.badge(rows)          -> small red chip html ("🧾 Dup ₹500")
   LWBDup.strip(rows, {po})    -> amber strip html (po: true = "collect on this trip" wording)
   LWBDup.print(rows)          -> boxed text for a printed PO / challan */
(function(){
  if(window.LWBDup)return;
  const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const key=v=>String(v==null?"":v).toUpperCase().replace(/[^A-Z0-9]+/g," ").trim();
  const rs=v=>"₹"+Math.round(Number(v)||0).toLocaleString("en-IN");
  const dm=d=>d?String(d).slice(8,10)+"/"+String(d).slice(5,7):"";
  const kindTxt=k=>k==="TORN"?"torn":"duplicate";
  const cnt=r=>Object.values(r.notes||{}).reduce((a,v)=>a+(Number(v)||0),0);
  const notesTxt=r=>Object.entries(r.notes||{}).sort((a,b)=>Number(b[0])-Number(a[0])).map(([n,c])=>c+" × ₹"+n).join(" + ");
  // "1 duplicate ₹500 note" / "3 torn notes (1 × ₹500 + 2 × ₹100)"
  const one=r=>{const c=cnt(r),ks=Object.keys(r.notes||{});
    return c===1&&ks.length===1?"1 "+kindTxt(r.kind)+" ₹"+ks[0]+" note":c+" "+kindTxt(r.kind)+" notes ("+notesTxt(r)+")"};
  const total=rows=>rows.reduce((a,r)=>a+(Number(r.amount)||0),0);
  function css(){
    if(document.getElementById("lwb-dup-css"))return;
    const s=document.createElement("style");s.id="lwb-dup-css";
    s.textContent=`.dupb{display:inline-flex;align-items:center;gap:3px;margin-left:5px;padding:1px 7px;border-radius:99px;background:#fdecee;color:#b3122b;border:1px solid #f3b8c1;font-size:11.5px;font-weight:800;white-space:nowrap;vertical-align:middle}
.dups{display:flex;align-items:flex-start;gap:8px;margin:6px 0;padding:7px 10px;border:1px solid #f3b8c1;border-left:4px solid #c8102e;border-radius:8px;background:#fff5f6;color:#5c1320;font-size:13px;line-height:1.35}
.dups>b:first-child{font-size:16px;line-height:1}.dups div{min-width:0;flex:1 1 auto}.dups strong{color:#b3122b}.dups small{display:block;color:#7a4a52;font-size:12px}`;
    document.head.appendChild(s);
  }
  let cache=null,at=0;
  function pending(client,fresh){
    if(!client)return Promise.resolve([]);
    if(cache&&!fresh&&Date.now()-at<60000)return cache;
    at=Date.now();
    cache=client.rpc("lwb_dup_pending").then(r=>r.error||!Array.isArray(r.data)?[]:r.data,()=>[]);
    return cache;
  }
  function forParty(client,name){
    if(!client||!String(name||"").trim())return Promise.resolve([]);
    return client.rpc("lwb_dup_for_party",{p_name:name}).then(r=>r.error||!Array.isArray(r.data)?[]:r.data,()=>[]);
  }
  function of(list,name){const k=key(name);if(!k||!list||!list.length)return [];
    return list.filter(r=>key(r.party)===k||(r.keys||[]).includes(k))}
  function badge(rows){if(!rows||!rows.length)return "";css();
    return '<span class="dupb" title="'+esc(rows.map(one).join(", "))+' pending: collect a good note">🧾 '+(rows.some(r=>r.kind!=="TORN")?"Dup":"Torn")+" "+rs(total(rows))+"</span>"}
  function strip(rows,o){if(!rows||!rows.length)return "";css();o=o||{};
    const t=rs(total(rows));
    return '<div class="dups" role="note"><b>🧾</b><div><strong>'+esc(rows.map(one).join(" + "))+" pending · "+t+"</strong>"+
      "<small>"+(o.po?"Take the note back to the party and collect "+t+" (good notes) on this trip. Give it to the cashier.":
        "This "+t+" is still in the party's balance. Collect a good note on the next trip.")+
      " Given on "+esc(rows.map(r=>dm(r.day)).join(", "))+".</small></div></div>"}
  function print(rows){if(!rows||!rows.length)return "";
    const t=rs(total(rows));
    return "<div style='border:2px solid #000;padding:4px 6px;margin:6px 0;font-weight:700'>COLLECT: "+esc(rows.map(one).join(" + ")).toUpperCase()+
      " · "+t+"<br><span style='font-weight:400'>Give the "+(rows.length===1&&cnt(rows[0])===1?"note":"notes")+" back to the party and take "+t+" good cash. Hand it to the cashier.</span></div>"}
  window.LWBDup={pending,forParty,of,badge,strip,print,one,total,key,css};
})();
