/* Trip rent popup (lwb_trip_party_set_rent_setup.sql): after Transport Assignment, a per party hired vehicle's trip
   with no rent asks for it. One party: asked once per vehicle + party. Two or more parties together: asked once
   for that set of parties. Admin saves = verified; Manager / Transport = waits for Admin to verify.
   Use: LWBRentAsk.check(db) after the page loads and after each save. */
(function(){
  const css=`.lra-ov{position:fixed;inset:0;background:rgba(16,24,40,.55);display:flex;align-items:center;justify-content:center;z-index:9999;padding:10px}
.lra{background:#fff;border-radius:12px;width:min(560px,100%);max-height:92vh;display:flex;flex-direction:column;box-shadow:0 20px 50px rgba(0,0,0,.3);font:15px Arial,sans-serif;color:#182230}
.lra-h{display:flex;align-items:center;gap:8px;padding:12px 14px;border-bottom:1px solid #e0e4ea}.lra-h b{font-size:17px;flex:1}
.lra-h .n{background:#fdecef;color:#b3122b;border-radius:99px;padding:1px 8px;font-size:13px;font-weight:800}
.lra-b{padding:10px 14px;overflow-y:auto;display:flex;flex-direction:column;gap:8px}
.lra-b p{margin:0 0 2px;color:#667085;font-size:13px}
.lra-c{border:1px solid #f1d391;background:#fff8e8;border-radius:10px;padding:9px 11px;display:flex;flex-direction:column;gap:6px}
.lra-c .t{display:flex;flex-wrap:wrap;gap:4px 8px;align-items:center;font-size:14px}.lra-c .p{font-weight:800;font-size:15px}
.lra-c small{color:#667085;font-size:12.5px}.lra-c .bk{color:#9e2525;font-size:12.5px;font-weight:700}
.lra-tag{display:inline-block;padding:2px 8px;border-radius:5px;font-size:12px;font-weight:800}.lra-tag.sz{background:#e8f1ff;color:#194c85}.lra-tag.tg{background:#efe9ff;color:#4b2a9a}
.lra-r{display:flex;gap:6px}.lra-r input{flex:1;min-width:0;height:40px;border:1.5px solid #cfd5df;border-radius:6px;padding:0 10px;font:inherit;font-size:16px;font-weight:700}
.lra-r button,.lra-f button{height:40px;border-radius:6px;padding:0 14px;font:inherit;font-size:14px;font-weight:700;cursor:pointer;border:1px solid #13824a;background:#13824a;color:#fff;white-space:nowrap}
.lra-f{display:flex;justify-content:flex-end;padding:10px 14px;border-top:1px solid #e0e4ea}.lra-f button{background:#fff;color:#182230;border-color:#cfd5df}
.lra-ok{color:#0d6b36;font-weight:700;font-size:13px}`;
  const esc=s=>String(s==null?"":s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const rs=n=>"₹"+Number(n||0).toLocaleString("en-IN",{maximumFractionDigits:2});
  const day=d=>{const [y,m,x]=String(d||"").split("-");return x?x+"/"+m+"/"+y:""};
  const ton=t=>Number(t)?String(Number(t))+" Ton":"";
  const kg=v=>Number(v)?(Number(v)/1000).toFixed(2).replace(/\.?0+$/,"")+" T":"";
  let open=false;
  async function check(db){
    if(open||!db)return;
    let r;try{r=await db.rpc("lwb_trip_rent_todo")}catch(e){return}
    if(!r||r.error||!r.data||!(r.data.rows||[]).length)return;
    show(db,r.data);
  }
  function show(db,D){
    if(!document.getElementById("lraCss")){const s=document.createElement("style");s.id="lraCss";s.textContent=css;document.head.appendChild(s)}
    open=true;const rows=D.rows,adm=D.is_admin,ov=document.createElement("div");ov.className="lra-ov";
    const close=()=>{ov.remove();open=false};
    ov.innerHTML='<div class="lra" role="dialog" aria-modal="true" aria-labelledby="lraT"><div class="lra-h"><b id="lraT">Enter trip rent</b><span class="n">'+rows.length+'</span></div><div class="lra-b"><p>Hired vehicle trips with no rent yet. Enter the rent once: the next trip of the same vehicle to the same party (or the same parties together) uses it.'+(adm?"":" Admin verifies it.")+'</p>'+
      rows.map((x,i)=>'<div class="lra-c" data-i="'+i+'"><div class="t"><b>🚚 '+esc(x.vehicle_no)+'</b>'+(ton(x.size_ton)?'<span class="lra-tag sz">'+ton(x.size_ton)+'</span>':"")+(x.together?'<span class="lra-tag tg">'+x.party.split(" + ").length+' parties together</span>':"")+'<small>'+esc(x.trip_no||"")+' · '+day(x.trip_date)+(x.owner?' · '+esc(x.owner):"")+'</small></div>'+
        '<div class="p">'+esc(x.party).split(" + ").join(' <span style="color:#4b2a9a">+</span> ')+'</div><small>'+esc((x.order_nos||[]).join(", "))+(kg(x.load_kg)?' · Load '+kg(x.load_kg):"")+'</small>'+
        (x.rate_status==="SENT_BACK"?'<div class="bk">Sent back by Admin ('+rs(x.rate)+'): '+esc(x.note||"")+'</div>':"")+
        '<div class="lra-r"><input type="number" min="0" step="any" inputmode="decimal" placeholder="₹ rent for this trip" aria-label="Rent"><button type="button">'+(adm?"Save":"Send to Admin")+'</button></div></div>').join("")+
      '</div><div class="lra-f"><button type="button" class="lra-x">Later</button></div></div>';
    document.body.appendChild(ov);
    ov.querySelector(".lra-x").onclick=close;
    ov.querySelectorAll(".lra-c").forEach(c=>{const x=rows[+c.dataset.i],inp=c.querySelector("input"),b=c.querySelector("button");
      const go=async()=>{const v=Number(inp.value);if(!(v>0)){inp.focus();inp.style.borderColor="#b3122b";return}
        b.disabled=true;b.textContent="Saving...";
        const r=await db.rpc("lwb_trip_rent_set",{p_pending:x.id,p_rate:v});
        if(r.error){b.disabled=false;b.textContent=adm?"Save":"Send to Admin";alert(String(r.error.message||r.error).replace(/^.*?ERROR:\s*/,""));return}
        c.querySelector(".lra-r").outerHTML='<div class="lra-ok">✓ '+rs(v)+(r.data&&r.data.status==="VERIFIED"?" saved"+(r.data.posted>1?" · "+r.data.posted+" trips":""):" sent to Admin")+'</div>';
        c.style.background="#e4f6e9";c.style.borderColor="#bfe5cb";
        if(![...ov.querySelectorAll(".lra-c input")].length)setTimeout(close,900)};
      b.onclick=go;inp.onkeydown=e=>{if(e.key==="Enter")go()}});
    const f=ov.querySelector(".lra-c input");if(f)f.focus();
  }
  window.LWBRentAsk={check};
})();
