/* LUXURY WRIST BRAND ERP — one Party list from Customer / Party Master.
   Any input with data-party-list gets a dropdown of every active party.
   LWBParties.load() returns [{customer_name, customer_code}] for pages that
   fill their own select. Read only; RLS decides who can see the list. */
(function(){
  let cache=null;
  function client(){
    if(!window.supabase)return null;
    if(!client.c)client.c=window.supabase.createClient("https://txkbhadzdbxpieunfvox.supabase.co","sb_publishable_W4I3Q5ODf0g17sq5uDml2Q_sLolXYEk");
    return client.c;
  }
  async function load(){
    if(cache)return cache;
    cache=(async()=>{
      try{
        const db=client();if(!db)return [];
        const {data:{session}}=await db.auth.getSession();if(!session)return [];
        const {data,error}=await db.from("lwb_customer_master").select("customer_name,customer_code").eq("is_active",true).order("customer_name").limit(5000);
        return error?[]:(data||[]).filter(p=>String(p.customer_name||"").trim());
      }catch(e){return []}
    })();
    const list=await cache;
    if(!list.length)cache=null; // not logged in yet or no access: try again next time
    return list;
  }
  async function attach(inputs){
    const list=await load();
    if(!list.length)return list;
    let dl=document.getElementById("lwbPartyList");
    if(!dl){dl=document.createElement("datalist");dl.id="lwbPartyList";document.body.appendChild(dl)}
    dl.replaceChildren(...list.map(p=>{const o=document.createElement("option");o.value=String(p.customer_name).trim();if(p.customer_code)o.label=p.customer_code;return o}));
    (inputs||document.querySelectorAll("[data-party-list]")).forEach(i=>i.setAttribute("list","lwbPartyList"));
    return list;
  }
  window.LWBParties={load,attach};
  const go=()=>{if(document.querySelector("[data-party-list]"))attach()};
  if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",go);else go();
})();
