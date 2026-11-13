/* LUXURY WRIST BRAND ERP — Order History Days (lwb_order_visibility_setup.sql).
   Admin sets per role how many days after delivery an order stays in that role's lists
   (Settings > Order History Days). ERPOrderDays.filter(client, rows, key) drops the orders
   the logged-in user should no longer see. key = order id field ("id" by default) or a function.
   Admin, roles with no limit, and a database without the SQL: rows come back unchanged. */
(function(){
  let mine; // undefined = not asked yet; null = no limit
  async function days(client){
    if(mine!==undefined)return mine;
    try{const r=await client.rpc("lwb_order_visibility_mine");mine=r.error?null:(r.data==null?null:Number(r.data));}
    catch(e){mine=null}
    return mine;
  }
  async function hidden(client,ids){
    const out=new Set();
    for(let i=0;i<ids.length;i+=2000){
      const r=await client.rpc("lwb_order_hidden_ids",{p_ids:ids.slice(i,i+2000)});
      if(r.error)return new Set();
      (r.data||[]).forEach(x=>out.add(String(x)));
    }
    return out;
  }
  async function filter(client,rows,key){
    if(!client||!Array.isArray(rows)||!rows.length)return rows;
    const get=typeof key==="function"?key:(r=>r&&r[key||"id"]);
    if((await days(client))==null)return rows;
    const ids=[...new Set(rows.map(get).filter(Boolean).map(String))];
    if(!ids.length)return rows;
    const h=await hidden(client,ids);
    return h.size?rows.filter(r=>!h.has(String(get(r)))):rows;
  }
  window.ERPOrderDays={filter,days};
})();
