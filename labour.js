/* LUXURY WRIST BRAND ERP — Daily labour (dihadi) helpers (Mohit, 26 Nov 2026). Data: lwb_daily_labour_setup.sql.
 * LWBLabour.popup(client, role)  once a day: how many outside labour came, total charge, cash given / due, per Godown Manager.
 *   Shown from 5 PM (India time) for today; before that, yesterday's if it was not seen. Admin, Sales Head, Accounts,
 *   Cashier and the Godown Manager (his own). Nothing is shown when no labour was entered that day.
 */
(function(){
  "use strict";
  const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const num=v=>Number(v)||0;
  const inr=n=>"₹"+Math.round(num(n)).toLocaleString("en-IN");
  const ist=(d)=>new Date(d||Date.now()).toLocaleDateString("en-CA",{timeZone:"Asia/Kolkata"});
  const hour=()=>Number(new Date().toLocaleString("en-GB",{timeZone:"Asia/Kolkata",hour:"2-digit",hour12:false}));
  const dmy=v=>window.LWBDate?LWBDate.d(v):String(v||"").slice(0,10);
  const ROLES=["admin","manager","accounts","cashier","warehouse"];
  const seen=day=>{try{return localStorage.getItem("lwbLabourSeen")===day}catch(e){return false}};
  const mark=day=>{try{localStorage.setItem("lwbLabourSeen",day)}catch(e){}};
  const CSS='.lb-pop{position:fixed;inset:0;background:rgba(0,20,25,.45);z-index:2000;display:grid;place-items:center;padding:16px}'+
    '.lb-pop .bx{background:#fff;border-radius:12px;width:min(440px,100%);max-height:calc(100vh - 32px);overflow:auto;box-shadow:0 20px 60px rgba(0,0,0,.3);padding:14px 16px}'+
    '.lb-pop h3{margin:0 0 2px;font-size:17px}.lb-pop .sub{font-size:12.5px;color:#66727d;margin-bottom:10px}'+
    '.lb-pop .big{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin-bottom:10px}'+
    '.lb-pop .big div{border:1px solid #e3e7eb;border-radius:8px;padding:6px 8px}.lb-pop .big span{display:block;font-size:11px;color:#66727d;font-weight:700;text-transform:uppercase}'+
    '.lb-pop .big b{font-size:19px}.lb-pop .big .c b{color:#2362a4}.lb-pop .big .t b{color:#b0123b}.lb-pop .big .d b{color:#c77700}.lb-pop .big .ok b{color:#1d7a46}'+
    '.lb-pop table{width:100%;border-collapse:collapse;font-size:13px}.lb-pop td,.lb-pop th{padding:5px 4px;border-top:1px solid #eef0f3;text-align:left}'+
    '.lb-pop th{font-size:11px;color:#66727d;text-transform:uppercase}.lb-pop .n{text-align:right;white-space:nowrap}'+
    '.lb-pop .row{display:flex;gap:8px;justify-content:flex-end;margin-top:12px}'+
    '.lb-pop a,.lb-pop button{font:inherit;font-size:13.5px;font-weight:700;border-radius:8px;padding:7px 14px;cursor:pointer;text-decoration:none;border:1.5px solid #002f37}'+
    '.lb-pop a.go{background:#002f37;color:#fff!important}.lb-pop button{background:#fff;color:#002f37}';
  function show(d,label){
    if(!document.getElementById("lbPopCss")){const s=document.createElement("style");s.id="lbPopCss";s.textContent=CSS;document.head.appendChild(s)}
    const gms=(d.gms||[]).filter(g=>num(g.count)>0);
    const w=document.createElement("div");w.className="lb-pop";w.setAttribute("role","dialog");w.setAttribute("aria-modal","true");
    w.innerHTML='<div class="bx"><h3>👷 '+esc(label)+': '+num(d.count)+' outside labour</h3><div class="sub">Daily labour (dihadi) · '+esc(dmy(d.day))+'</div>'+
      '<div class="big"><div class="t"><span>Total charge</span><b>'+inr(d.total)+'</b></div><div class="ok"><span>Cash given</span><b>'+inr(d.paid)+'</b></div>'+
      '<div class="'+(num(d.due)>0?"d":"ok")+'"><span>Still to give</span><b>'+inr(d.due)+'</b></div></div>'+
      (gms.length>1||!d.is_gm?'<table data-cf-off><thead><tr><th>Godown Manager</th><th class="n">Labour</th><th class="n">Charge</th><th class="n">Given</th></tr></thead><tbody>'+
        gms.map(g=>'<tr><td><b>'+esc(g.name)+'</b>'+(g.over_plan?' <small style="color:#c77700;font-weight:700">above plan</small>':"")+'</td><td class="n">'+num(g.count)+(g.plan?' / '+num(g.plan.count):"")+'</td><td class="n"><b>'+inr(g.total)+'</b></td><td class="n">'+inr(g.paid)+'</td></tr>').join("")+'</tbody></table>':"")+
      '<div class="row"><button type="button" data-x>Close</button><a class="go" href="labour.html?day='+esc(d.day)+'">Open Daily Labour</a></div></div>';
    const close=()=>{w.remove();document.removeEventListener("keydown",k)};
    const k=e=>{if(e.key==="Escape")close()};
    w.addEventListener("click",e=>{if(e.target===w||e.target.closest("[data-x]"))close()});
    document.addEventListener("keydown",k);document.body.appendChild(w);
  }
  async function popup(client,role){
    role=String(role||"").toLowerCase();
    if(!ROLES.includes(role))return;
    const today=ist(),yest=ist(Date.now()-864e5);
    const day=hour()>=17?today:yest;
    if(seen(day))return;
    try{
      const {data,error}=await client.rpc("lwb_labour_day",{p_day:day});
      if(error||!data||!num(data.count))return;
      mark(day);show(data,day===today?"Today":"Yesterday");
    }catch(e){}
  }
  window.LWBLabour={popup,show,inr,num,esc,ist};
})();
