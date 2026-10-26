/* LUXURY WRIST BRAND ERP — Cashbook data in the ERP database.
   cashbook.html is the same Cashbook app; only its data is kept here instead of in the browser.
   The data is read and saved only through lwb_cashbook_* functions (lwb_cashbook_tally_check_setup.sql),
   which open only for Admin and the users ticked "Cashbook" in Manage Users > Pages.
   Every save sends the version it started from; when someone else saved first, the newer
   data is loaded and shown, and the change made here has to be done again.
   Secret link (lwb_cashbook_secure_setup.sql): once Admin creates it, every function also needs
   the key from the link (#k=...). The key is kept for this tab only and taken out of the address bar. */
(function(){
  const db=supabase.createClient("https://txkbhadzdbxpieunfvox.supabase.co","sb_publishable_W4I3Q5ODf0g17sq5uDml2Q_sLolXYEk");
  const CHECK_EVERY=20000;
  const CB={data:null,erpAdmin:false,onReplace:null,isBusy:()=>false};
  let version=0,latest=null,sending=false,again=false;

  // key from the secret link: kept for this tab only, removed from the address bar
  let key="";
  try{
    const m=location.hash.match(/^#k=([A-Za-z0-9_-]{20,})$/);
    if(m){sessionStorage.setItem("cbk",m[1]);history.replaceState(null,"",location.pathname+location.search)}
    key=sessionStorage.getItem("cbk")||"";
  }catch(e){}
  const rpc=(fn,args)=>db.rpc(fn,Object.assign({},args,{p_key:key}));

  function gate(title,text,link){
    document.addEventListener("DOMContentLoaded",()=>show(title,text,link),{once:true});
    if(document.readyState!=="loading")show(title,text,link);
  }
  function show(title,text,link){
    const app=document.getElementById("app");if(!app)return;
    const box=document.createElement("div");box.className="gate";
    const h=document.createElement("h1");h.textContent=title;
    const p=document.createElement("p");p.className="sub";p.textContent=text;
    box.append(h,p);
    if(link){const a=document.createElement("a");a.className="btn primary";a.href=link.h;a.textContent=link.t;a.style.justifyContent="center";box.append(a)}
    app.replaceChildren(box);
  }
  // red bar at the top while a change is not saved
  function bar(text,retry){
    let b=document.getElementById("cbSaveBar");
    if(!text){if(b)b.remove();return}
    if(!b){
      b=document.createElement("div");b.id="cbSaveBar";b.setAttribute("role","alert");
      b.style.cssText="position:sticky;top:0;z-index:40;background:var(--out);color:#fff;padding:10px 16px;font-weight:600;display:flex;gap:12px;align-items:center;flex-wrap:wrap";
      document.body.prepend(b);
    }
    b.replaceChildren(document.createTextNode(text));
    if(retry){const r=document.createElement("button");r.type="button";r.className="btn sm";r.textContent="Try again";r.onclick=retry;b.append(r)}
  }
  const tell=(msg)=>{const t=document.getElementById("toast");if(!t)return;t.textContent=msg;t.hidden=false;clearTimeout(tell._t);tell._t=setTimeout(()=>t.hidden=true,4000)};

  async function load(){
    const {data,error}=await rpc("lwb_cashbook_load");
    if(error)throw error;
    return data;
  }
  function replaceWith(d,msg){
    version=Number(d.version)||0;
    if(CB.onReplace)CB.onReplace(d.data&&Array.isArray(d.data.books)?d.data:{books:[]},msg);
  }

  CB.save=function(state){
    latest=state;
    if(sending){again=true;return}
    send();
  };
  async function send(){
    if(!latest)return;
    sending=true;again=false;
    let body;
    try{body=JSON.parse(JSON.stringify(latest))}catch(e){sending=false;bar("Not saved: "+e.message);return}
    const {data,error}=await rpc("lwb_cashbook_save",{p_data:body,p_version:version});
    sending=false;
    if(error){
      if(/CONFLICT/.test(error.message)){
        again=false;
        try{replaceWith(await load(),"Someone else saved the Cashbook just now. Their data is shown. Please make your last change again.");bar("")}
        catch(e){bar("Not saved. "+e.message,send)}
        return;
      }
      if(/NO_ACCESS/.test(error.message)){bar("Not saved: you no longer have access to the Cashbook.");return}
      bar("Not saved. Check the internet and try again. ("+error.message+")",send);
      return;
    }
    version=Number(data)||version+1;
    bar("");
    if(again)send();
  }
  window.addEventListener("beforeunload",e=>{if(sending||again||document.getElementById("cbSaveBar")){e.preventDefault();e.returnValue=""}});

  // another user's saved changes appear here too (checked every 20 seconds while nothing is open)
  async function watch(){
    if(document.hidden||sending||again||CB.isBusy()||document.getElementById("cbSaveBar"))return;
    const {data,error}=await rpc("lwb_cashbook_version");
    if(error||Number(data)<=version||sending||again||CB.isBusy())return;
    try{const d=await load();if(Number(d.version)>version&&!sending&&!again&&!CB.isBusy())replaceWith(d,"Updated with the latest entries")}catch(e){}
  }

  // payments drivers reported in the Driver Portal (lwb_cashbook_driver_cash_setup.sql)
  CB.driverCash=async function(){
    const {data,error}=await rpc("lwb_cashbook_driver_cash",{p_days:15});
    if(error)throw error;
    return data||[];
  };

  // history of every change, newest first; party = party name, entry = entry id (both optional)
  CB.history=async function(party,entry){
    const {data,error}=await rpc("lwb_cashbook_history",{p_party:party||null,p_entry:entry||null,p_limit:1000});
    if(error)throw error;
    return data||[];
  };

  // Admin: make a new secret link; the old link stops working
  CB.newLink=async function(){
    const a=new Uint8Array(24);crypto.getRandomValues(a);
    const k=btoa(String.fromCharCode(...a)).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");
    const {error}=await rpc("lwb_cashbook_set_link",{p_new_key:k});
    if(error)throw error;
    key=k;CB.hasLink=true;
    try{sessionStorage.setItem("cbk",k)}catch(e){}
    return location.origin+location.pathname+"#k="+k;
  };

  // the name of the login and the time across the page, so a photo of the screen shows who opened it
  function watermark(){
    let w=document.getElementById("cbMark");
    if(!w){
      w=document.createElement("div");w.id="cbMark";w.setAttribute("aria-hidden","true");
      w.style.cssText="position:fixed;inset:0;z-index:9999;pointer-events:none;background-repeat:repeat;opacity:.09";
      document.body.append(w);
    }
    const d=new Date(),p=n=>String(n).padStart(2,"0");
    const t=(CB.name+" · "+p(d.getDate())+"-"+p(d.getMonth()+1)+"-"+d.getFullYear()+" "+p(d.getHours())+":"+p(d.getMinutes())).replace(/[&<>"']/g,"");
    const dark=matchMedia("(prefers-color-scheme: dark)").matches;
    const svg='<svg xmlns="http://www.w3.org/2000/svg" width="340" height="190"><text x="10" y="120" transform="rotate(-24 170 95)" font-family="sans-serif" font-size="15" font-weight="700" fill="'+(dark?"#fff":"#000")+'">'+t+'</text></svg>';
    w.style.backgroundImage='url("data:image/svg+xml,'+encodeURIComponent(svg)+'")';
  }
  // page is blurred while it is not in front (app switcher pictures, screen share of another window)
  function cover(){document.body.style.filter=document.hidden?"blur(14px)":""}

  // Admin: earlier copies kept by the ERP, inside the Backup window
  CB.copiesBox=async function(box,confirmPop,onRestored){
    const {data,error}=await rpc("lwb_cashbook_copies_list");
    if(error){box.textContent="Could not load copies: "+error.message;return}
    if(!data||!data.length){box.textContent="No earlier copies yet.";return}
    const NAME={save:"Timed copy",cleared:"Before data was cleared","before restore":"Before a restore"};
    const pad=n=>String(n).padStart(2,"0");
    const when=v=>{const d=new Date(v);return pad(d.getDate())+"-"+pad(d.getMonth()+1)+" "+pad(d.getHours())+":"+pad(d.getMinutes())};
    const list=document.createElement("div");list.className="pk-list";list.style.maxHeight="240px";
    data.forEach(c=>{
      const b=document.createElement("button");b.type="button";
      const l=document.createElement("span");l.textContent=when(c.saved_at)+" · "+(NAME[c.reason]||c.reason)+" · "+c.saved_by;
      const r=document.createElement("span");r.className="hint";r.textContent=c.books+" books, "+c.entries+" entries";
      b.append(l,r);
      b.onclick=()=>confirmPop({title:"Restore this copy?",msg:when(c.saved_at)+": "+c.books+" books, "+c.entries+" entries. It replaces the Cashbook for everyone. The data now is kept as a copy too.",yes:"Yes, restore",danger:true},async()=>{
        const {data:d,error:e}=await rpc("lwb_cashbook_restore",{p_copy_id:c.id});
        if(e){box.textContent="Restore failed: "+e.message;return}
        version=Number(d.version)||version;
        onRestored(d.data);
      });
      list.append(b);
    });
    box.replaceChildren(list);
  };

  window.CashbookERP={start:async function(app){
    try{
      const {data:{session}}=await db.auth.getSession();
      if(!session){location.replace("login.html");return}
      let d;
      try{d=await load()}
      catch(e){
        if(/NO_ACCESS/.test(e.message)){try{sessionStorage.removeItem("cbk")}catch(_){}return gate("Private page","This page opens only from its private link, for the logins Admin allows.",{t:"Back to ERP",h:"dashboard.html"})}
        if(/lwb_cashbook_load|function|schema cache/i.test(e.message))return gate("Setup pending","Run lwb_cashbook_secure_setup.sql once in the Supabase SQL Editor, then open this page again. ("+e.message+")",{t:"Back to ERP",h:"dashboard.html"});
        return gate("Could not open the Cashbook",e.message+" Check the internet and reload the page.",null);
      }
      version=Number(d.version)||0;
      CB.data=d.data&&Array.isArray(d.data.books)?d.data:{books:[]};
      CB.erpAdmin=d.erp_admin===true;
      CB.hasLink=d.has_link===true;
      CB.name=d.name||"User";
      watermark();setInterval(watermark,60000);
      document.addEventListener("visibilitychange",cover);
      app(CB);
      setInterval(watch,CHECK_EVERY);
      document.addEventListener("visibilitychange",()=>{if(!document.hidden)watch()});
    }catch(e){gate("Could not open the Cashbook",e.message,null)}
  }};
})();
