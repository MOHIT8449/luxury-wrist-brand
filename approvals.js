/* LUXURY WRIST BRAND ERP — Approvals: everything waiting for Admin / Sales Head in one place.
 * Mohit (7 Nov 2026): the "Market order — please check once" popup kept coming again and again. One small
 * dashboard instead: every kind of permission is its own card with its pending count (and ₹ total), the card
 * opens its list and the approval is given right there. The main Dashboard shows the same counts.
 *
 * LWBApprovals.load(client, {uid, role}) -> [{key, icon, title, sub, count, amount, items, bulk, page, err}]
 * Every list comes from an RPC / table the ERP already has; this file adds no SQL. A list this login
 * may not read (RPC error) is left out, so each role sees only what it can act on. Supabase RLS / RPC
 * checks stay the real permission check.
 */
(function(){
  "use strict";
  const esc=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const num=v=>{const n=Number(v);return Number.isFinite(n)?n:0};
  const inr=n=>(num(n)<0?"−":"")+"₹"+Math.abs(num(n)).toLocaleString("en-IN",{maximumFractionDigits:2});
  const short=n=>{n=num(n);const a=Math.abs(n);
    if(a>=1e7)return "₹"+(n/1e7).toLocaleString("en-IN",{maximumFractionDigits:2})+" Cr";
    if(a>=1e5)return "₹"+(n/1e5).toLocaleString("en-IN",{maximumFractionDigits:2})+" L";
    return inr(n)};
  const dmy=v=>v?(window.LWBDate?LWBDate.d(v):String(v).slice(0,10)):"";
  const errText=e=>String((e&&e.message)||e||"Something went wrong").replace(/^.*?ERROR:\s*/,"");
  const sum=(a,f)=>a.reduce((t,x)=>t+num(f(x)),0);
  const PO_PENDING=["pending","submitted","pending_manager","pending_approval","pending_review","new"];
  const MODE={CASH:"Cash",UPI:"UPI",BANK:"Bank / NEFT",RTGS:"RTGS",NEFT:"NEFT",CHEQUE:"Cheque",CARD:"Card",ONLINE:"Online"};
  async function rpc(c,name,args){const {data,error}=await c.rpc(name,args);if(error)throw Error(errText(error));return data}
  // Same check the bell uses: the bell row is "read" once Admin has looked at it.
  async function readBells(c,uid,type,orderIds){
    let q=c.from("erp_notifications").update({is_read:true}).eq("user_id",uid).eq("is_read",false).eq("notification_type",type);
    if(orderIds)q=q.in("order_id",orderIds);
    const {error}=await q;if(error)throw Error(errText(error));
  }
  const orderLink=id=>"warehouse-orders.html?order="+encodeURIComponent(id);

  // Each section: roles that see it, load(c, ctx) -> {items, amount?, bulk?} or null (not for this login).
  // item = {id, ref, party, amount, when, lines:[text], meta:[text], field?, acts:[{t, kind, href|run}]}
  // act kind: ok (green, does it here), no (red), go (opens the page). run(c, item, fieldValue, ui).
  const SECTIONS=[
    {key:"rate",icon:"₹",title:"Rate OK",sub:"Rate below min",roles:["admin"],page:"warehouse-orders.html",
     async load(c){
       const rows=(await rpc(c,"lwb_rate_waiting"))||[];
       const items=rows.filter(r=>r.can_approve).map(r=>{
         const lines=(r.lines||[]),val=sum(lines,l=>num(l.qty)*num(l.rate));
         return {id:r.order_id,ref:r.order_no,party:r.party,amount:val,when:r.requested_at,
           lines:lines.filter(l=>l.min_rate!=null&&num(l.rate)<num(l.min_rate)).map(l=>l.sku+" · ₹"+num(l.rate)+" (min ₹"+num(l.min_rate)+")"+(l.landing!=null?" · landing ₹"+num(l.landing):"")),
           meta:[r.brand,r.sales_person&&"By "+r.sales_person,r.slip?"Rajnigandha slip":"",r.note].filter(Boolean),
           acts:[{t:"✓ Approve rate",kind:"ok",confirm:"Approve the rate of "+r.order_no+"?\n\n"+(r.slip?"The slip is made and goes to Accounts.":"The PO is approved and goes on for transport."),
                  run:c2=>rpc(c2,"lwb_rate_approve",{p_order_id:r.order_id})},
                 {t:"Open PO",kind:"go",href:"warehouse-orders.html?rate="+encodeURIComponent(r.order_id)}]};
       });
       return {items,amount:sum(items,i=>i.amount)};
     }},
    {key:"market",icon:"⚠",title:"Market check",sub:"Low rate / wrong slab",roles:["admin","manager"],page:"warehouse-orders.html",
     async load(c,ctx){
       if(!ctx.bells)return null;
       const seen=new Set(),items=[];
       for(const n of ctx.bells.filter(b=>b.notification_type==="ORDER_RATE_CHECK")){
         if(!n.order_id||seen.has(n.order_id))continue;seen.add(n.order_id);
         const seg=String(n.message||"").split(" · "),why=seg.slice(3).join(" · ").split(" | ").filter(Boolean);
         const o=ctx.orders.get(n.order_id);
         items.push({id:n.order_id,ref:seg[0]||(o&&o.order_no)||"PO",party:seg[1]||(o&&o.customer_name)||"",amount:o?num(o.total_amount):null,when:n.created_at,
           lines:why,meta:[seg[2]&&"By "+seg[2]].filter(Boolean),
           acts:[{t:"✓ Checked OK",kind:"ok",run:c2=>readBells(c2,ctx.uid,"ORDER_RATE_CHECK",[n.order_id])},
                 {t:"Open PO",kind:"go",href:orderLink(n.order_id)}]});
       }
       return {items,amount:sum(items,i=>i.amount),
         bulk:items.length>1?{t:"✓ All checked",confirm:"Mark all "+items.length+" market orders as checked?",run:c2=>readBells(c2,ctx.uid,"ORDER_RATE_CHECK")}:null};
     }},
    {key:"po",icon:"🛒",title:"New PO",sub:"Salesman orders",roles:["admin","manager"],page:"warehouse-orders.html",
     async load(c,ctx){
       if(!ctx.pending)return null;
       const items=ctx.pending.map(o=>({id:o.id,ref:o.order_no,party:o.customer_name,amount:num(o.total_amount),when:o.created_at||o.order_date,
         lines:[],meta:[dmy(o.order_date),o.sales_person&&"By "+o.sales_person,o.transportation].filter(Boolean),
         acts:[{t:"Open & approve",kind:"go",href:orderLink(o.id)}]}));
       return {items,amount:sum(items,i=>i.amount)};
     }},
    {key:"change",icon:"✏",title:"PO change",sub:"Qty / rate / SKU after bill",roles:["admin"],page:"party-billing.html?tab=chg",
     async load(c){
       const rows=((await rpc(c,"lwb_bill_change_list",{p_days:1}))||[]).filter(r=>r.status==="WAITING");
       const K={QTY:"Qty",RATE:"Rate",SKU:"SKU",ADD:"Added",REMOVE:"Removed"};
       const items=rows.map(r=>({id:r.id,ref:r.order_no,party:r.party,amount:num(r.diff),signed:true,when:r.requested_at,
         lines:(r.lines||[]).filter(l=>l.kind).map(l=>{
           const k=String(l.kind).toUpperCase(),sku=l.sku||l.sku_old||"";
           if(k==="ADD")return "Added "+sku+" · "+num(l.qty)+" × ₹"+num(l.rate);
           if(k==="REMOVE")return "Removed "+(l.sku_old||sku)+" · "+num(l.qty_old)+" × ₹"+num(l.rate_old);
           const p=[];if(l.sku_old&&l.sku&&l.sku_old!==l.sku)p.push(l.sku_old+" → "+l.sku);else p.push(sku);
           if(l.qty_old!=null&&num(l.qty_old)!==num(l.qty))p.push("qty "+num(l.qty_old)+" → "+num(l.qty));
           if(l.rate_old!=null&&num(l.rate_old)!==num(l.rate))p.push("rate ₹"+num(l.rate_old)+" → ₹"+num(l.rate));
           return (K[k]?K[k]+": ":"")+p.join(" · ");
         }),
         meta:[inr(r.old_value)+" → "+inr(r.new_value),r.bill_no&&"Bill "+r.bill_no,r.reason,r.note,r.by&&"By "+r.by].filter(Boolean),
         acts:[{t:"✓ Approve",kind:"ok",confirm:"Approve the change of "+r.order_no+"?\n\nPO lines and the bill amount change now.",
                run:c2=>rpc(c2,"lwb_bill_change_decide",{p_id:r.id,p_approve:true,p_reply:null})},
               {t:"↩ Send back",kind:"no",ask:"Why is it sent back?",run:(c2,i,f,why)=>rpc(c2,"lwb_bill_change_decide",{p_id:r.id,p_approve:false,p_reply:why})},
               {t:"Open",kind:"go",href:"party-billing.html?tab=chg&change="+encodeURIComponent(r.order_id)}]}));
       return {items,amount:sum(items,i=>i.amount)};
     }},
    {key:"rent",icon:"🚚",title:"Trip rent",sub:"Fixed rent per party",roles:["admin"],page:"fleet-master.html#rates",
     async load(c){
       const d=await rpc(c,"lwb_hired_rate_list");
       if(!d||!d.is_admin)return null;
       const items=(d.groups||[]).filter(g=>g.status==="WAITING"&&g.rate_id).map(g=>({id:String(g.rate_id),ref:g.no,party:g.party,amount:num(g.rate)*num(g.days),when:g.set_at,
         lines:[num(g.days)+(num(g.days)===1?" trip day":" trip days")+" · "+dmy(g.first_date)+(g.last_date&&g.last_date!==g.first_date?" to "+dmy(g.last_date):""),
                (g.orders||[]).length?"PO "+(g.orders||[]).join(", "):""].filter(Boolean),
         meta:[g.owner,g.set_by_name&&"Set by "+g.set_by_name,g.note].filter(Boolean),
         field:{type:"number",label:"₹ per trip",value:num(g.rate)},
         acts:[{t:"✓ Verify",kind:"ok",run:(c2,i,rate)=>{const v=num(rate);if(!(v>0))throw Error("Enter the rent per trip");return rpc(c2,"lwb_hired_rate_verify",{p_rate_id:g.rate_id,p_ok:true,p_rate:v,p_note:null})}},
               {t:"↩ Send back",kind:"no",ask:"Why is it sent back?",run:(c2,i,f,why)=>rpc(c2,"lwb_hired_rate_verify",{p_rate_id:g.rate_id,p_ok:false,p_rate:null,p_note:why})}]}));
       return {items,amount:sum(items,i=>i.amount)};
     }},
    {key:"bank",icon:"🏦",title:"Bank check",sub:"Payments to verify",roles:["admin"],page:"accounts-dashboard.html#verify",
     async load(c){
       const day=new Date().toLocaleDateString("en-CA",{timeZone:"Asia/Kolkata"});
       const D=await rpc(c,"lwb_acc_dashboard",{p_from:day,p_to:day});
       if(!D||!D.is_admin)return null;
       const banks=(D.banks||[]).filter(b=>b.active),name=id=>{const b=(D.banks||[]).find(x=>String(x.id)===String(id));return b?b.name:""};
       const opts=[{v:"",t:"Choose bank…"}].concat(banks.map(b=>({v:String(b.id),t:b.name+(b.account_no?" · "+b.account_no:"")})));
       const items=(D.pending||[]).map(p=>({id:p.src+"|"+p.id,ref:p.kind==="DEPOSIT"?"Cash deposit":(MODE[p.mode]||p.mode||"Bank"),party:p.kind==="DEPOSIT"?"Cash deposited in "+(name(p.bank_id)||"bank"):(p.party||p.category||""),
         amount:num(p.amount),when:p.at||p.date,group:p.bank_id?String(p.bank_id):"",groupName:name(p.bank_id)||"Bank not chosen yet",
         lines:[],meta:[dmy(p.date),p.ref&&"Ref "+p.ref,p.order_no,p.category&&p.party?p.category:"",p.by&&"By "+p.by,p.remark].filter(Boolean),
         field:{type:"select",label:"Bank",value:p.bank_id?String(p.bank_id):"",options:opts},
         acts:[{t:"✓ In bank",kind:"ok",run:(c2,i,b)=>{if(!b)throw Error("Choose the bank where this money came");return rpc(c2,"lwb_acc_verify_line",{p_src:p.src,p_id:p.id,p_ok:true,p_bank_id:Number(b),p_note:null})}},
               {t:"✗ Not in bank",kind:"no",ask:"Why is it not in the bank?",run:(c2,i,f,why)=>rpc(c2,"lwb_acc_verify_line",{p_src:p.src,p_id:p.id,p_ok:false,p_bank_id:null,p_note:why})}]}));
       // per bank: count + total (bank not chosen last)
       const g=new Map();items.forEach(i=>{const x=g.get(i.group)||{name:i.groupName,count:0,amount:0};x.count++;x.amount+=i.amount;g.set(i.group,x)});
       const groups=[...g.entries()].sort((a,b)=>(a[0]==="")-(b[0]==="")||b[1].amount-a[1].amount).map(([k,v])=>({key:k,...v}));
       return {items,amount:sum(items,i=>i.amount),groups};
     }},
    {key:"stock",icon:"📦",title:"Stock move",sub:"Godown stock moves",roles:["admin","manager"],page:"stock-transfer.html#approvals",
     async load(c){
       const rows=((await rpc(c,"lwb_stx_moves",{p_status:"PENDING",p_from:null,p_to:null}))||[]).filter(m=>m.can_decide);
       const lab=b=>String(b||"").replace(/_/g," ").toLowerCase().replace(/^./,x=>x.toUpperCase());
       const cs=m=>{const p=num(m.pcs_per_case)||1,q=num(m.qty_pcs);return Math.floor(q/p)+" CS"+(q%p?" "+(q%p)+" PCS":"")};
       const items=rows.map(m=>({id:String(m.id),ref:"STM-"+m.id,party:m.sku_name,amount:null,when:m.requested_at,
         lines:[lab(m.from_bucket)+" → "+lab(m.to_bucket)+" · "+cs(m)],
         meta:[dmy(m.move_date),m.reason,m.note,m.requested_by_name&&"By "+m.requested_by_name].filter(Boolean),
         acts:[{t:"✓ Approve",kind:"ok",confirm:"Approve STM-"+m.id+"?\n\n"+m.sku_name+" · "+cs(m)+"\nStock moves now.",run:c2=>rpc(c2,"lwb_stx_decide",{p_ids:[m.id],p_action:"APPROVE",p_note:null,p_qty:null})},
               {t:"✗ Reject",kind:"no",ask:"Reason for rejecting (the godown will see it)",run:(c2,i,f,why)=>rpc(c2,"lwb_stx_decide",{p_ids:[m.id],p_action:"REJECT",p_note:why,p_qty:null})},
               {t:"Open",kind:"go",href:"stock-transfer.html#approvals"}]}));
       return {items};
     }},
    {key:"dreturn",icon:"↩",title:"Driver return",sub:"Goods back from party",roles:["admin","manager"],page:"driver-returns.html",
     async load(c){
       const rows=(await rpc(c,"lwb_office_list_driver_returns",{p_status:"PENDING_OFFICE"}))||[];
       const items=rows.map(r=>({id:String(r.id||r.return_id||r.order_id),ref:r.order_no||"Return",party:r.party_name||r.customer_name||"",amount:num(r.total_return_amount||r.amount),when:r.created_at,
         lines:(r.items||[]).map(li=>li.sku+" · "+num(li.qty_cases||li.qty)+" "+(li.qty_cases!=null?"CS":(li.uom||""))+(li.reason?" · "+li.reason:"")),
         meta:[r.driver_name&&"Driver "+r.driver_name,r.vehicle_no,r.note].filter(Boolean),
         acts:[{t:"Open & verify",kind:"go",href:"driver-returns.html"+(r.order_id?"?order="+encodeURIComponent(r.order_id):"")}]}));
       return {items,amount:sum(items,i=>i.amount)};
     }},
    {key:"sreturn",icon:"↩",title:"Sales return",sub:"Return to approve",roles:["admin"],page:"sales-return.html",
     async load(c){
       const {data,error}=await c.from("sales_returns").select("id,order_id,return_no,return_date,total_amount,approval_status,created_at").ilike("approval_status","pending").order("created_at",{ascending:false}).limit(200);
       if(error)return null;
       const items=(data||[]).map(r=>({id:String(r.id),ref:r.return_no||"Return",party:"",amount:num(r.total_amount),when:r.created_at,lines:[],meta:[dmy(r.return_date)].filter(Boolean),
         acts:[{t:"Open & approve",kind:"go",href:"sales-return.html"}]}));
       return {items,amount:sum(items,i=>i.amount)};
     }},
    {key:"party",icon:"👤",title:"New party",sub:"Added by salesman",roles:["admin","manager"],page:"customer-master.html",
     async load(c,ctx){
       if(!ctx.bells)return null;
       const items=ctx.bells.filter(b=>b.notification_type==="PARTY_CREATED").map(n=>{
         const m=String(n.message||""),head=m.split(". ")[0].split(" · ");
         return {id:String(n.id),ref:"Party",party:head[0]||"",amount:null,when:n.created_at,lines:[],
           meta:head.slice(1).concat(((m.match(/Added by ([^.]+?) from/)||[])[1]||"")?["By "+(m.match(/Added by ([^.]+?) from/)||[])[1]]:[]),
           acts:[{t:"✓ Checked OK",kind:"ok",run:async c2=>{const {error}=await c2.from("erp_notifications").update({is_read:true}).eq("id",n.id).eq("user_id",ctx.uid);if(error)throw Error(errText(error))}},
                 {t:"Open Party Master",kind:"go",href:"customer-master.html"}]};
       });
       return {items,bulk:items.length>1?{t:"✓ All checked",confirm:"Mark all "+items.length+" new parties as checked?",run:c2=>readBells(c2,ctx.uid,"PARTY_CREATED")}:null};
     }}
  ];

  async function load(c,{uid,role}){
    role=String(role||"").toLowerCase();
    const list=SECTIONS.filter(s=>s.roles.includes(role));
    const ctx={uid,role,orders:new Map(),bells:null,pending:null};
    const [b,p]=await Promise.all([
      c.from("erp_notifications").select("id,order_id,title,message,notification_type,created_at").eq("user_id",uid).eq("is_read",false)
        .in("notification_type",["ORDER_RATE_CHECK","PARTY_CREATED"]).order("created_at",{ascending:false}).limit(300),
      c.from("orders").select("id,order_no,order_date,created_at,customer_name,sales_person,total_amount,status,transportation")
        .or("status.is.null,status.in.("+PO_PENDING.join(",")+")").order("order_date",{ascending:false}).limit(500)]);
    ctx.bells=b.error?null:(b.data||[]);
    ctx.pending=p.error?null:(p.data||[]);
    (ctx.pending||[]).forEach(o=>ctx.orders.set(o.id,o));
    const need=[...new Set((ctx.bells||[]).map(x=>x.order_id).filter(id=>id&&!ctx.orders.has(id)))];
    if(need.length){try{const r=await c.from("orders").select("id,order_no,customer_name,total_amount").in("id",need.slice(0,200));(r.data||[]).forEach(o=>ctx.orders.set(o.id,o))}catch(e){}}
    const res=await Promise.all(list.map(s=>s.load(c,ctx).then(r=>r,e=>({err:errText(e)}))));
    let out=list.map((s,i)=>res[i]&&!res[i].err?Object.assign({},s,res[i],{count:res[i].items.length}):null).filter(Boolean);
    // A PO waiting for the Admin rate OK is counted there, not again as a new PO.
    const rate=out.find(s=>s.key==="rate"),po=out.find(s=>s.key==="po");
    if(rate&&po){const ids=new Set(rate.items.map(i=>i.id));po.items=po.items.filter(i=>!ids.has(i.id));po.count=po.items.length;po.amount=sum(po.items,i=>i.amount)}
    return out;
  }
  const total=secs=>secs.reduce((t,s)=>t+s.count,0);

  window.LWBApprovals={load,total,SECTIONS,esc,inr,short,dmy,errText};
})();
