/* LUXURY WRIST BRAND ERP — STTS Ledger matching (Mohit, 13 Nov 2026).
   Pure functions, no database. Used by stts-ledger.html (and tests).

   Three numbers for every bill (invoice) and pack:
     1. Rate List  : what we should give = paid cases × scheme of that day (free bottles / case, or ₹ off / case)
     2. Given      : what the bill in the company DMS (Sales Register) really gave
     3. STTS       : what the company accepted in the STTS Ledger (the money it pays back)
   Bill no. (Document Number in Sales Register = Doc No in STTS) joins them; pack = first word of the item
   name (e.g. "250MLPLBTN1X28"), so a free Thums Up 250 line counts against all 250 ml PET paid on that bill. */
(function(root){
  const num=v=>{if(v==null||v==="")return 0;if(typeof v==="number")return v;const n=+String(v).replace(/[,₹\s]/g,"");return isFinite(n)?n:0};
  const norm=v=>String(v==null?"":v).replace(/[^A-Za-z0-9%]+/g," ").trim().toUpperCase();
  const r2=n=>Math.round(n*100)/100;
  const MON={JAN:1,FEB:2,MAR:3,APR:4,MAY:5,JUN:6,JUL:7,AUG:8,SEP:9,OCT:10,NOV:11,DEC:12};
  // "04-11-2026", "04/11/2026", "01 Nov 2026", Excel serial, Date -> "2026-11-04"
  function day(v){
    if(v==null||v==="")return "";
    if(v instanceof Date&&!isNaN(v))return v.getFullYear()+"-"+String(v.getMonth()+1).padStart(2,"0")+"-"+String(v.getDate()).padStart(2,"0");
    if(typeof v==="number"&&v>20000&&v<80000){const d=new Date(Math.round((v-25569)*864e5));return d.toISOString().slice(0,10)}
    const s=String(v).trim();let m;
    if((m=s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})/)))return m[1]+"-"+m[2].padStart(2,"0")+"-"+m[3].padStart(2,"0");
    if((m=s.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})/)))return m[3]+"-"+m[2].padStart(2,"0")+"-"+m[1].padStart(2,"0");
    if((m=s.match(/^(\d{1,2})[\s-]([A-Za-z]{3})[A-Za-z]*[\s-](\d{4})/))&&MON[m[2].toUpperCase()])return m[3]+"-"+String(MON[m[2].toUpperCase()]).padStart(2,"0")+"-"+m[1].padStart(2,"0");
    return "";
  }
  const packOf=item=>String(item||"").trim().split(/\s+/)[0].toUpperCase();

  // aoa = rows of cells (SheetJS header:1). Finds the header row by the wanted columns.
  function table(aoa,need){
    const hi=aoa.findIndex(r=>need.every(h=>r.some(c=>norm(c)===norm(h))));
    if(hi<0)return null;
    const head=aoa[hi].map(norm);
    return aoa.slice(hi+1).filter(r=>r.some(c=>c!==""&&c!=null)).map(r=>{const o={};head.forEach((h,i)=>{if(h)o[h]=r[i]});return o});
  }
  const get=(o,...ks)=>{for(const k of ks){const v=o[norm(k)];if(v!==undefined)return v}return undefined};

  /* Sales Register (DMS export, CSV). One row per bill line. */
  function parseSales(aoa){
    const t=table(aoa,["Document Number","Item Name","Qty (PC)"]);
    if(!t)throw Error("This is not the Sales Register: columns Document Number, Item Name, Qty (PC) not found.");
    return t.map(o=>{
      const line=num(get(o,"Line Amount")),disc=num(get(o,"Discount Amount"));
      return {
        doc:String(get(o,"Document Number")||"").trim(),line_no:num(get(o,"Line No")),day:day(get(o,"Document Date")),
        type:String(get(o,"TransactionType")||"").trim(),
        outlet_code:String(get(o,"Outlet Code")||"").trim(),outlet:String(get(o,"Outlet Name")||"").trim(),
        item_code:String(get(o,"Item Code")||"").trim().replace(/^0+/,""),item:String(get(o,"Item Name")||"").replace(/\s+/g," ").trim(),
        brand:String(get(o,"Brand")||"").trim(),bpc:num(get(o,"BPC")),pc:num(get(o,"Qty (PC)")),ea:num(get(o,"Qty (EA)")),
        line,disc,net:num(get(o,"Net Amt")),promo:num(get(o,"Promotion Total")),landed:num(get(o,"Landed Price")),
        salesman:String(get(o,"Salesman Name")||"").replace(/^SM-/,"").trim(),
        free:line>0&&disc>=0.85*line   // the free-goods line: almost all of it is discount (₹1 a bottle stays)
      };
    }).filter(r=>r.doc&&r.item);
  }

  /* STTS Ledger (company portal export, XLS). PI = purchase margin, SI = scheme on our sales bills. */
  function parseStts(aoa){
    const t=table(aoa,["Doc Type","Doc No","Sale Type"]);
    if(!t)throw Error("This is not the STTS Ledger: columns Doc Type, Doc No, Sale Type not found.");
    return t.map(o=>({
      doc_type:String(get(o,"Doc Type")||"").trim().toUpperCase(),mer:String(get(o,"MER No")||"").trim(),
      sale_type:String(get(o,"Sale Type")||"").trim(),outlet_code:String(get(o,"Outlet Code")||"").trim(),outlet:String(get(o,"Outlet Name")||"").trim(),
      doc:String(get(o,"Doc No")||"").trim(),day:day(get(o,"Doc Date")),
      item_code:String(get(o,"Item ID")||"").trim().replace(/^0+/,""),item:String(get(o,"Item Name")||"").replace(/\s+/g," ").trim(),
      pc:num(get(o,"Quantity PC")),uc:num(get(o,"Quantity UC")),amt:num(get(o,"Discount")),paid:String(get(o,"IsPaid Out")||"").trim()
    })).filter(r=>r.doc&&r.doc_type);
  }

  /* Merge an upload into what is saved, like the bank statement:
     Sales Register: same bill + line no. = replaced by the new upload, other bills stay.
     STTS: the portal gives the whole month every time, so the newest upload replaces every STTS row of the
     dates it covers (from its first to its last date); older months stay. */
  function mergeSales(old,add){
    const k=r=>r.doc+"#"+r.line_no,m=new Map(old.map(r=>[k(r),r]));let added=0,same=0,changed=0;
    for(const r of add){const o=m.get(k(r));if(!o)added++;else if(JSON.stringify(o)===JSON.stringify(r))same++;else changed++;m.set(k(r),r)}
    return {rows:[...m.values()],added,same,changed};
  }
  function mergeStts(old,add){
    const days=add.map(r=>r.day).filter(Boolean).sort();if(!days.length)return {rows:old,from:"",to:"",removed:0,added:0};
    const from=days[0],to=days[days.length-1];
    const keep=old.filter(r=>!(r.day>=from&&r.day<=to));
    return {rows:keep.concat(add),from,to,removed:old.length-keep.length,added:add.length};
  }

  /* STTS "Sale Type": "Free goods (Exclusive)" = free bottles, "Amount off line item" = cash (₹) off.
     Other types (QPS etc.) are not counted here. */
  const isFreeT=t=>/free\s*goods|free/i.test(t||""),isOffT=t=>!isFreeT(t)&&/amount\s*off|cash\s*off/i.test(t||"");

  /* rateFor(pack, day) -> {fb, oms, name, from} from the Rate List ledger valid on that day (or null).
     fb = free bottles per paid case, oms = ₹ off per case incl. GST. */
  function match(sales,stts,rateFor,opt){
    opt=opt||{};const tolB=opt.tolBottles!=null?opt.tolBottles:1,tolR=opt.tolRupees!=null?opt.tolRupees:2;
    const si=stts.filter(r=>r.doc_type==="SI");
    const sIdx=new Map();for(const r of si){const k=r.doc+"|"+packOf(r.item);if(!sIdx.has(k))sIdx.set(k,[]);sIdx.get(k).push(r)}
    const groups=new Map();
    for(const r of sales){const k=r.doc+"|"+packOf(r.item);if(!groups.has(k))groups.set(k,[]);groups.get(k).push(r)}
    const out=[];
    for(const [k,ls] of groups){
      const f=ls[0],pack=packOf(f.item),rate=rateFor?rateFor(pack,f.day):null,bpc=ls.find(x=>x.bpc)?.bpc||0;
      const paid=ls.filter(x=>!x.free),freeL=ls.filter(x=>x.free),st=sIdx.get(k)||[];
      const paidPc=r2(paid.reduce((a,x)=>a+x.pc,0)),items=[...new Set(paid.map(x=>x.item))];
      const base={key:k,doc:f.doc,day:f.day,outlet:f.outlet,outlet_code:f.outlet_code,salesman:f.salesman,pack,items,paidPc,bpc,rate,
        value:r2(paid.reduce((a,x)=>a+x.net,0))};
      const stFree=st.filter(x=>isFreeT(x.sale_type)),stOff=st.filter(x=>isOffT(x.sale_type));
      // Free bottles
      const fbRate=rate&&rate.fb>0?rate.fb:0;
      if(fbRate||freeL.length||stFree.length){
        const exp=fbRate?Math.floor(paidPc*fbRate+1e-6):null,given=freeL.reduce((a,x)=>a+x.ea,0);
        const sttsB=Math.round(stFree.reduce((a,x)=>a+x.pc*(bpc||28),0)),sttsRs=r2(stFree.reduce((a,x)=>a+x.amt,0));
        const perB=sttsB?sttsRs/sttsB:(freeL[0]?Math.max(0,freeL[0].landed-1):0);
        const givenRs=r2(freeL.reduce((a,x)=>a+x.promo,0))||r2(given*perB);
        const flags=[];
        if(exp!=null&&given===0&&exp>0)flags.push("NOT_GIVEN");
        else if(exp!=null&&given<exp-tolB)flags.push("GIVEN_LESS");
        else if(exp!=null&&given>exp+tolB)flags.push("GIVEN_MORE");
        if(exp==null&&given>0)flags.push("NO_RATE");
        if(given>0&&!stFree.length)flags.push("NOT_IN_STTS");
        else if(given>0&&sttsB<given-tolB)flags.push("STTS_SHORT");
        else if(sttsB>given+tolB)flags.push("STTS_MORE");
        out.push({...base,kind:"FREE",freeItem:freeL[0]?freeL[0].item:(stFree[0]?stFree[0].item:""),
          exp,given,stts:sttsB,expRs:exp!=null?r2(exp*perB):null,givenRs,sttsRs,
          perCaseGiven:paidPc?r2(given/paidPc):0,perCaseStts:paidPc?r2(sttsB/paidPc):0,
          shortRs:r2(Math.max(0,given-sttsB)*perB),diffRs:r2((sttsB-(exp!=null?exp:given))*perB),flags,mer:[...new Set(stFree.map(x=>x.mer))].join(", ")});
      }
      // ₹ off per case (OMS)
      const omsRate=rate&&rate.oms>0?rate.oms:0,offL=paid.filter(x=>x.disc>0);
      if((omsRate&&opt.offRequired)||offL.length||stOff.length){
        const exp=omsRate?r2(paidPc*omsRate):null,given=r2(offL.reduce((a,x)=>a+x.promo,0)),sttsRs=r2(stOff.reduce((a,x)=>a+x.amt,0));
        const flags=[];
        // ₹ off is given only on some bills (big orders), so a bill without it is not a problem unless asked
        if(exp!=null&&given===0&&exp>0){if(opt.offRequired)flags.push("NOT_GIVEN")}
        else if(exp!=null&&given<exp-tolR)flags.push("GIVEN_LESS");
        else if(exp!=null&&given>exp+tolR)flags.push("GIVEN_MORE");
        if(exp==null&&given>0)flags.push("NO_RATE");
        if(given>0&&!stOff.length)flags.push("NOT_IN_STTS");
        else if(given>0&&sttsRs<given-tolR)flags.push("STTS_SHORT");
        else if(sttsRs>given+tolR)flags.push("STTS_MORE");
        out.push({...base,kind:"OFF",exp,given,stts:sttsRs,expRs:exp,givenRs:given,sttsRs,
          perCaseGiven:paidPc?r2(given/paidPc):0,perCaseStts:paidPc?r2(sttsRs/paidPc):0,
          shortRs:r2(Math.max(0,given-sttsRs)),diffRs:r2(sttsRs-(exp!=null?exp:given)),flags,mer:[...new Set(stOff.map(x=>x.mer))].join(", ")});
      }
    }
    // STTS lines whose bill is not in the Sales Register
    const have=new Set(sales.map(r=>r.doc));
    const orphan=si.filter(r=>!have.has(r.doc));
    out.sort((a,b)=>a.day<b.day?1:a.day>b.day?-1:a.doc<b.doc?1:-1);
    return {rows:out,orphan,pi:stts.filter(r=>r.doc_type==="PI")};
  }
  const FLAG={NOT_GIVEN:"Scheme not given",GIVEN_LESS:"Given less than Rate List",GIVEN_MORE:"Given more than Rate List",NO_RATE:"No Rate List scheme",
    NOT_IN_STTS:"Not in STTS",STTS_SHORT:"STTS short",STTS_MORE:"STTS more"};
  root.LWBStts={num,day,packOf,parseSales,parseStts,mergeSales,mergeStts,match,FLAG};
})(typeof window!=="undefined"?window:globalThis);
