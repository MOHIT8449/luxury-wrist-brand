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

// ---- Everything into the main Gmail (Mohit, 28 Nov 2026) ----
// contacts: [{acc, rn, name, phones:[raw], emails:[text], person}]  person = Google person (names, phoneNumbers ...)
// Copy each contact of the other Gmail into the main Gmail once. A number or email the main Gmail already has is not
// copied again (a contact with nothing new is skipped). Nothing is deleted: the other Gmail keep their contacts.
// Only fields Google lets us write (output-only ones like displayName / formattedType would be refused).
const pick=(o,ks)=>{const y={};for(const k of ks)if(o&&o[k]!=null&&o[k]!=='')y[k]=o[k];return y;};
const FIELDS={names:x=>pick({...x,unstructuredName:x.unstructuredName||x.displayName},['unstructuredName','givenName','familyName','middleName','honorificPrefix','honorificSuffix']),
  organizations:x=>pick(x,['name','title','department']),addresses:x=>pick(x,['streetAddress','extendedAddress','city','region','postalCode','country','type']),
  biographies:x=>pick(x,['value','contentType']),birthdays:x=>pick(x,['date','text']),urls:x=>pick(x,['value','type']),nicknames:x=>pick(x,['value'])};
export function movePlan(contacts){
  const seenM=new Set(),seenE=new Set(),low=e=>String(e||'').trim().toLowerCase();
  for(const c of contacts)if(c.acc===0){(c.phones||[]).map(mob).filter(Boolean).forEach(m=>seenM.add(m));(c.emails||[]).map(low).filter(Boolean).forEach(e=>seenE.add(e));}
  const extra=contacts.map((c,i)=>({c,i})).filter(x=>x.c.acc>0)
    .sort((a,b)=>String(b.c.name||'').trim().length-String(a.c.name||'').trim().length||a.c.acc-b.c.acc||a.i-b.i);
  const copy=[],skip=[];
  for(const {c,i} of extra){
    const p=c.person||{},ph=(p.phoneNumbers||[]).filter(n=>{const m=mob(n.value||n.canonicalForm);return !m||!seenM.has(m);});
    const newM=ph.map(n=>mob(n.value||n.canonicalForm)).filter(Boolean);
    const em=(p.emailAddresses||[]).filter(e=>low(e.value)&&!seenE.has(low(e.value)));
    const hadNum=(p.phoneNumbers||[]).length>0,hadMail=(p.emailAddresses||[]).length>0;
    // nothing new: every number (and email) is already in the main Gmail
    if(!newM.length&&!em.length&&(hadNum||hadMail)&&!ph.length){skip.push(i);continue;}
    if(!hadNum&&!hadMail){skip.push(i);continue;}
    newM.forEach(m=>seenM.add(m));em.forEach(e=>seenE.add(low(e.value)));
    const body={};
    for(const [f,fn] of Object.entries(FIELDS))if(Array.isArray(p[f])&&p[f].length){const v=p[f].map(fn).filter(y=>Object.keys(y).length);if(v.length)body[f]=v.slice(0,f==='names'?1:20);}
    if(ph.length)body.phoneNumbers=ph.map(n=>pick(n,['value','type']));
    if(em.length)body.emailAddresses=em.map(e=>pick(e,['value','type']));
    copy.push({i,acc:c.acc,name:c.name,body});
  }
  return {copy,skip};
}
