/* LUXURY WRIST BRAND ERP — role a page treats the logged-in user as.
   His own role, or, when Admin ticked this page of another role for him in
   Manage Users > Pages, that page's role. Waits for erp-shell.js (loaded deferred). */
window.lwbPageRole=async function(role){
  const r=String(role||"").trim().toLowerCase();
  if(!window.ERPShell)await new Promise(ok=>document.readyState==="loading"?document.addEventListener("DOMContentLoaded",ok,{once:true}):ok());
  if(!window.ERPShell||!ERPShell.pageRoleFresh)return role;
  const pr=await ERPShell.pageRoleFresh(r);
  return pr===r?role:pr;
};
