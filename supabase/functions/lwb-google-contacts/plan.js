// Duplicate number cleaner: the plan (pure functions, tested in tests/gmail-dedupe). Mohit, 28 Nov 2026.
// contacts: [{acc, rn, name, phones:[raw text], erp:boolean}]  (acc 0 = main Gmail, 1.. = extra Gmail)
// erpNames: Map mobile(10 digit) -> ERP phone name
export const mob=v=>{const d=String(v||'').replace(/\D/g,'');return /^(91|0)?[6-9]\d{9}$/.test(d)?d.slice(-10):null;};

// Groups: every mobile saved in 2+ contacts. keep = the contact whose name stays.
//   ERP number with its LWB ERP contact in Gmail: that contact, fixed (Admin cannot change it).
//   Else: the longest name, main Gmail first (Admin can pick another).
export function makePlan(contacts,erpNames){
  const by=new Map();
  contacts.forEach((c,i)=>{const ms=[...new Set((c.phones||[]).map(mob).filter(Boolean))];
    ms.forEach(m=>{if(!by.has(m))by.set(m,[]);by.get(m).push(i);});});
  const groups=[];
  for(const [m,ids] of by){
    if(ids.length<2)continue;
    const en=erpNames.get(m)||null,erp=ids.filter(i=>contacts[i].erp);
    let keep,fixed=false;
    if(en&&erp.length){keep=erp[0];fixed=true;}
    else keep=ids.slice().sort((a,b)=>String(contacts[b].name||'').trim().length-String(contacts[a].name||'').trim().length||contacts[a].acc-contacts[b].acc||a-b)[0];
    groups.push({m,erp_name:en,fixed,keep,ids});
  }
  groups.sort((a,b)=>Number(b.fixed)-Number(a.fixed)||a.m.localeCompare(b.m));
  return groups;
}

// What to do in Gmail. picks: {mobile: contact index} for groups that are not fixed (others: the plan's keep).
// A contact whose every phone is a dropped number is deleted; one that also has another phone only loses the
// dropped numbers. LWB ERP contacts are never touched.
export function actions(contacts,groups,picks){
  const drop=new Map();
  for(const g of groups){
    let keep=g.keep;
    if(!g.fixed&&picks&&picks[g.m]!=null){const p=Number(picks[g.m]);if(!g.ids.includes(p))throw Error('Wrong choice for a number');keep=p;}
    for(const i of g.ids)if(i!==keep&&!contacts[i].erp){if(!drop.has(i))drop.set(i,new Set());drop.get(i).add(g.m);}
  }
  const del=[],upd=[];
  for(const [i,ms] of drop){
    const c=contacts[i],ph=c.phones||[];
    if(ph.length&&ph.every(p=>ms.has(mob(p))))del.push({i,acc:c.acc,rn:c.rn});
    else upd.push({i,acc:c.acc,rn:c.rn,drop:[...ms]});
  }
  return {del,upd};
}

export const mask=m=>m?m.slice(0,2)+'•••••'+m.slice(-3):'';
