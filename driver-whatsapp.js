/*
  Luxury Wrist Brand — shared browser helper for Driver WhatsApp.
  The WhatsApp access token NEVER appears in this file. Sending happens
  server-side via Supabase Edge Function driver-assignment-whatsapp.
*/
(function(){
  "use strict";
  async function send({db,orderId,optInConfirmed}){
    if(!optInConfirmed)return {
      status:"skipped",message:"WhatsApp not sent: driver opt-in was not confirmed."
    };
    if(!db?.functions?.invoke)return {
      status:"error",message:"WhatsApp integration is not loaded. Assignment is saved; check Edge Function deployment."
    };
    try {
      const {data,error}=await db.functions.invoke("driver-assignment-whatsapp",{
        body:{order_id:orderId,driver_opt_in_confirmed:true}
      });
      if(error){
        let detail=error.message||"Unknown Edge Function error";
        if(error.context&&typeof error.context.json==="function"){
          try{
            const body=await error.context.json();
            detail=body?.error||body?.detail||detail;
          }catch{/* ignore response decoding */}
        }
        return {
          status:"error",
          message:"Assignment SAVED. WhatsApp NOT confirmed: "+detail+
            ". Check Supabase Edge Function, Meta Token and Approved Template."
        };
      }
      if(data?.status==="accepted"){
        const accepted=Number(data.accepted_parts||0);
        const old=Number(data.already_sent_parts||0);
        const partCount=Number(data.total_parts||0);
        return {
          status:"accepted",
          message:accepted
            ? "WhatsApp request accepted by Meta for "+(accepted+old)+"/"+partCount+
              " SKU part(s). This does NOT yet confirm actual delivery."
            : "The same Driver WhatsApp notification was already sent to Meta ("+partCount+" part(s))."
        };
      }
      if(data?.status==="in_progress"){
        return {
          status:"in_progress",
          message:"Assignment SAVED. Driver WhatsApp notification is being processed. Check message logs."
        };
      }
      const issues=Array.isArray(data?.errors)?data.errors.join(" | "):"";
      return {
        status:"partial_failed",
        message:"Assignment SAVED but some WhatsApp SKU parts were not accepted ("+
          Number(data?.accepted_parts||0)+"/"+Number(data?.total_parts||0)+
          "). "+(issues||"Check Supabase WhatsApp logs.")+
          " You can retry the same assignment; accepted parts will not be duplicated."
      };
    }catch(error){
      return {
        status:"error",
        message:"Assignment SAVED but WhatsApp notification failed to start: "+
          (error?.message||"Unknown error")+
          ". Check Supabase Edge Function deployment."
      };
    }
  }
  window.LWBDriverWhatsApp=Object.freeze({send});
})();
