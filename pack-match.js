/* LUXURY WRIST BRAND ERP — find the Rate & Scheme pack for a SKU name.
   "250ML COKE 1X28 MRP 20" -> pack "250ML CSD MRP.20": same size, MRP and
   product tag (MZ, KS, KW, MONSTER ...); plain cola SKUs go to the untagged
   (CSD) pack. Can / not can must match unless only one pack fits otherwise.
   Only a single clear match is returned; anything else is left to the person. */
(function(){
  const TAGS=[["MZ",/\bMZ\b|MAAZA/],["MMPO",/MMPO|PULPY|MINUTE ?MAID/],["KS",/\bKS\b|SODA/],
    ["KW",/\bKW\b|WATER|KIN(?:LE|EL)Y(?!.*SODA)/],["MONSTER",/MONSTER/],["UL",/\bUL\b|ULTRA/],
    ["PREDATOR",/PR?E?A?D[AE]{1,2}TOR/],["TONIC",/TONIC/],["DIET",/DIET/],["ZERO",/ZERO/],["RIMZIM",/RIMZ?J?H?IM/]];
  function shape(v){
    const t=String(v||"").trim().toUpperCase().replace(/MRP[.\s]*(\d+)/,(m,x)=>" MRP"+x+" ");
    const sz=t.match(/(\d+(?:\.\d+)?)\s*(ML|LTR|L)?\b/),mrp=(t.match(/MRP(\d+)/)||[])[1];
    return {size:sz?(+sz[1])*(/^L/.test(sz[2]||"")?1000:1):null,mrp:mrp?+mrp:null,can:/\bCAN\b|^CAN/.test(t),
      tags:TAGS.filter(([,re])=>re.test(t)).map(([k])=>k).join(",")};
  }
  // packs: [{pack_name, active, ...}] — returns one pack or null.
  function match(name,packs){
    const a=shape(name);if(a.size==null)return null;
    const fit=(p,can)=>{if(p.active===false)return false;const b=shape(p.pack_name);
      return b.size===a.size&&b.tags===a.tags&&(!can||b.can===a.can)&&(a.mrp==null||b.mrp==null||a.mrp===b.mrp)};
    let hits=packs.filter(p=>fit(p,true));
    if(!hits.length)hits=packs.filter(p=>fit(p,false));
    return hits.length===1?hits[0]:null;
  }
  // Case config shared by every pack of this size (and can / not can), for SKUs with no exact pack.
  function caseFor(name,packs){
    const p=match(name,packs);if(p&&+p.case_config>0)return +p.case_config;
    const a=shape(name);if(a.size==null)return null;
    const cc=[...new Set(packs.filter(x=>x.active!==false&&+x.case_config>0).filter(x=>{const b=shape(x.pack_name);return b.size===a.size&&b.can===a.can}).map(x=>+x.case_config))];
    return cc.length===1?cc[0]:null;
  }
  // SKU-level brand, so "1.25L FX MRP.70" finds the existing "1.25L FANTA 1X12 MRP 70".
  const BRANDS=[["TH",/\bTH\b|THUMS/],["SP",/\bSP\b|SPRITE/],["FX",/\bFX\b|FANTA/],["LI",/\bLI\b|LIMCA/],
    ["CO",/\bCO\b|COKE|COCA/],["CH",/\bCH\b|CHARGED/]];
  function skuShape(v){const t=String(v||"").toUpperCase(),s=shape(v);
    s.brand=BRANDS.filter(([,re])=>re.test(t)).map(([k])=>k).join(",");return s}
  // Existing SKU rows [{sku_name}] that are the same product as name — one row or null.
  function sameSku(name,rows){
    const a=skuShape(name);if(a.size==null)return null;
    const hits=rows.filter(r=>{const b=skuShape(r.sku_name);
      return b.size===a.size&&b.can===a.can&&b.tags===a.tags&&b.brand===a.brand&&(a.mrp==null||b.mrp==null||a.mrp===b.mrp)});
    return hits.length===1?hits[0]:hits.length>1?hits:null;
  }
  window.LWBPackMatch={shape,match,caseFor,skuShape,sameSku};
})();
