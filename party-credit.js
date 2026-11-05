/* Party credit check (lwb_party_credit_limit_setup.sql): brand-wise balance, oldest unpaid
   bill, credit days and credit limit of a party. Used on New PO and PO / Sales review.
   LWBCredit.load(db, party, companies)  -> [{company, ...lwb_party_credit row}] (one per brand)
   LWBCredit.order(db, orderId)         -> [{company:null, ...}] for a saved PO
   LWBCredit.box(rows)                  -> element (or null when nothing is due)
   LWBCredit.bad(rows)                  -> rows over limit or past credit days */
(function(){
  const rs=n=>"₹"+Math.round(Number(n)||0).toLocaleString("en-IN");
  const css=".lwb-cr{border:1px solid #f3b5b5;background:#fdecec;border-radius:8px;padding:6px 9px;margin:6px 0;font-size:12.5px;line-height:1.45;color:#1f2a37}"+
    ".lwb-cr.ok{border-color:#e3e7ec;background:#f6f8fa}.lwb-cr b.r{color:#c62828}.lwb-cr .h{font-weight:700;margin-bottom:2px}"+
    ".lwb-cr .ln{display:flex;flex-wrap:wrap;gap:2px 10px}.lwb-cr .ln span{white-space:nowrap}";
  function style(){if(document.getElementById("lwbCrCss"))return;const s=document.createElement("style");s.id="lwbCrCss";s.textContent=css;document.head.appendChild(s)}
  async function one(db,party,company){
    const {data,error}=await db.rpc("lwb_party_credit",{p_party:party,p_company:company?company.id:null});
    if(error)return {error};
    return data?{...data,company}:null;
  }
  async function load(db,party,companies){
    if(!db||!party)return [];
    const list=(companies&&companies.length?companies:[null]);
    const out=await Promise.all(list.map(c=>one(db,party,c).catch(e=>({error:e}))));
    if(out.some(x=>x&&x.error))return out.filter(x=>x&&x.error).length===out.length?null:out.filter(x=>x&&!x.error);
    return out.filter(Boolean);
  }
  async function order(db,id){
    const {data,error}=await db.rpc("lwb_order_credit",{p_order_id:id});
    if(error||!data)return null;
    return [{...data,company:null}];
  }
  const bad=rows=>(rows||[]).filter(r=>r.over_limit||r.over_days);
  function line(r,withName){
    const p=[];
    if(withName&&r.company)p.push("<b>"+r.company.name+"</b>");
    p.push("Due <b"+(r.over_limit?' class="r"':"")+">"+rs(r.balance)+"</b>"+(r.credit_limit?" / limit "+rs(r.credit_limit):""));
    if(r.oldest_days!=null)p.push("Oldest bill <b"+(r.over_days?' class="r"':"")+">"+r.oldest_days+" days</b>"+(r.credit_days?" (credit "+r.credit_days+" days)":""));
    return '<div class="ln">'+p.map(x=>"<span>"+x+"</span>").join("")+"</div>";
  }
  function box(rows){
    style();
    rows=(rows||[]).filter(r=>Number(r.balance)>0.5||r.over_limit||r.over_days);
    if(!rows.length)return null;
    const b=bad(rows).length;
    const el=document.createElement("div");el.className="lwb-cr"+(b?"":" ok");el.setAttribute("role","status");
    el.innerHTML='<div class="h">'+(b?"⚠ This party has money due":"Party due")+"</div>"+rows.map(r=>line(r,rows.length>1||!!r.company)).join("");
    return el;
  }
  function text(rows){
    return bad(rows).map(r=>(r.company?r.company.name+": ":"")+"Due "+rs(r.balance)+(r.over_limit?" (over limit "+rs(r.credit_limit)+")":"")+
      (r.over_days?", oldest bill "+r.oldest_days+" days (credit "+r.credit_days+" days)":"")).join("\n");
  }
  window.LWBCredit={load,order,box,bad,text};
})();
