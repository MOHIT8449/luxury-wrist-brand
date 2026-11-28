/* LUXURY WRIST BRAND ERP — shared app shell.
   ERPShell.mount({role, name, onLogout}) adds the top bar (menu button,
   breadcrumb, module search, user) and the role-based side menu.
   Menu visibility is navigation only; Supabase RLS/RPC checks stay the
   real permission check on every page. */
(function(){
  // Quick unlock (quick-unlock.js): while the ERP is locked after 15 idle minutes, every ERP
  // page goes to the lock screen first, and a lock in another tab locks this tab too.
  const toLock=()=>{document.documentElement.style.visibility="hidden";location.replace("login.html?lock=1")};
  try{if(localStorage.getItem("lwbLocked"))toLock()}catch(e){}
  window.addEventListener("storage",e=>{if(e.key==="lwbLocked"&&e.newValue)toLock()});
  // With fingerprint unlock ON for this login on this phone, a Logout button (top bar or a page's
  // own) LOCKS instead, so the next open needs only the fingerprint. "Login with password instead"
  // on the lock screen still ends the session fully.
  function unlockUid(){
    try{
      const t=JSON.parse(localStorage.getItem("sb-qstgwhbgbznxemajtave-auth-token")||"null");
      const uid=t&&t.user&&t.user.id;return uid&&lockOn(uid)?uid:"";
    }catch(e){return ""}
  }
  // Fingerprint (lwbUnlock) or MPIN (lwbMpin) on for this login on this phone.
  // Website in a browser: never locks (Logout and 15 idle minutes log out). Only the Android app
  // (quick-unlock.js isApp) locks with MPIN / fingerprint.
  function appMode(){
    try{
      if(/^android-app:\/\//i.test(document.referrer||""))sessionStorage.setItem("lwbApp","1");
      if(sessionStorage.getItem("lwbApp")==="1")return true;
      return /Android/i.test(navigator.userAgent)&&["standalone","fullscreen","minimal-ui"].some(m=>matchMedia("(display-mode: "+m+")").matches);
    }catch(e){return false}
  }
  function lockOn(uid){
    if(!appMode())return false;
    try{
      const on=JSON.parse(localStorage.getItem("lwbUnlock")||"null"),pin=JSON.parse(localStorage.getItem("lwbMpin")||"null");
      return !!(uid&&((on&&on.uid===uid&&on.cred)||(pin&&pin.uid===uid)));
    }catch(e){return false}
  }
  function lockNow(uid,why){
    try{localStorage.setItem("lwbLocked",JSON.stringify({uid,why,back:why==="logout"?"dashboard.html":location.pathname.replace(/^\//,"")+location.search+location.hash,at:Date.now()}))}catch(e){}
    try{localStorage.removeItem("lwbLastActive")}catch(e){}
    location.replace("login.html?lock=1");
  }
  document.addEventListener("click",e=>{
    const b=e.target.closest&&e.target.closest("button,a");
    if(!b||!(b.classList.contains("erp-logout")||b.id==="logout"||/^\s*logout\s*$/i.test(b.textContent||"")))return;
    // Phone alerts stop only on a real Logout tap (erp-push.js), not on the 15-minute idle logout.
    try{localStorage.setItem("lwbPushLogout",String(Date.now()))}catch(e){}
    const uid=unlockUid();if(!uid)return;
    e.preventDefault();e.stopImmediatePropagation();
    lockNow(uid,"logout");
  },true);
  // Shared "i" info icon (erp-info.js): help text opens on click instead of filling the page.
  if(!window.ERPInfo&&!document.querySelector('script[src*="erp-info.js"]')){
    const cur=document.currentScript,base=cur&&cur.src?cur.src.replace(/[^/]*$/,""):"";
    const s=document.createElement("script");s.src=base+"erp-info.js";
    (document.head||document.documentElement).appendChild(s);
  }
  // Maintenance mode (erp-maintenance.js): Admin's top bar switch; everyone else sees
  // "System under maintenance" while it is ON (the database refuses them anyway).
  if(!window.LWBMaintenance&&!document.querySelector('script[src*="erp-maintenance.js"]')){
    const cur=document.currentScript,base=cur&&cur.src?cur.src.replace(/[^/]*$/,""):"";
    const s=document.createElement("script");s.src=base+"erp-maintenance.js";
    (document.head||document.documentElement).appendChild(s);
  }
  // Typed text in CAPITAL letters on every page (erp-caps.js).
  if(!window.ERPCaps&&!document.querySelector('script[src*="erp-caps.js"]')){
    const cur=document.currentScript,base=cur&&cur.src?cur.src.replace(/[^/]*$/,""):"";
    const s=document.createElement("script");s.src=base+"erp-caps.js";
    (document.head||document.documentElement).appendChild(s);
  }
  // Excel-style filter on every list table + page search (erp-autofilter.js, 20 Nov 2026).
  if(!window.LWBAuto&&!document.querySelector('script[src*="erp-autofilter.js"]')){
    const cur=document.currentScript,base=cur&&cur.src?cur.src.replace(/[^/]*$/,""):"";
    const s=document.createElement("script");s.src=base+"erp-autofilter.js";
    (document.head||document.documentElement).appendChild(s);
  }
  const ICON={
    home:'<path d="M3 11l9-8 9 8v9a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z"/>',
    cart:'<path d="M3 4h2l2.4 11h10.2L20 7H6.2"/><circle cx="9" cy="19" r="1.5"/><circle cx="17" cy="19" r="1.5"/>',
    check:'<path d="M4 12l5 5L20 6"/>',
    box:'<path d="M3 7l9-4 9 4-9 4-9-4z"/><path d="M3 7v10l9 4 9-4V7"/><path d="M12 11v10"/>',
    truck:'<path d="M2 6h11v10H2z"/><path d="M13 9h4l4 4v3h-8"/><circle cx="6" cy="18" r="2"/><circle cx="17" cy="18" r="2"/>',
    bill:'<path d="M6 2h12v20l-3-2-3 2-3-2-3 2z"/><path d="M9 7h6M9 11h6M9 15h4"/>',
    cash:'<rect x="2" y="6" width="20" height="12" rx="2"/><circle cx="12" cy="12" r="3"/>',
    book:'<path d="M4 4h10a4 4 0 0 1 4 4v12H8a4 4 0 0 1-4-4z"/><path d="M8 8h6"/>',
    pin:'<path d="M12 22s7-7 7-12a7 7 0 0 0-14 0c0 5 7 12 7 12z"/><circle cx="12" cy="10" r="2.5"/>',
    undo:'<path d="M9 14L4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 0 12h-3"/>',
    note:'<path d="M5 3h10l4 4v14H5z"/><path d="M9 12h6M9 16h6"/>',
    users:'<circle cx="9" cy="8" r="3.5"/><path d="M2 20c0-3.5 3-6 7-6s7 2.5 7 6"/><circle cx="17" cy="9" r="2.5"/><path d="M16 14c3 0 6 2 6 5"/>',
    tag:'<path d="M3 3h8l10 10-8 8L3 11z"/><circle cx="7.5" cy="7.5" r="1.5"/>',
    inbox:'<path d="M3 13l3-9h12l3 9v7H3z"/><path d="M3 13h5l1 3h6l1-3h5"/>',
    factory:'<path d="M3 21V10l6 4V10l6 4V5h6v16z"/>',
    layers:'<path d="M12 3l9 5-9 5-9-5z"/><path d="M3 13l9 5 9-5"/>',
    gear:'<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
    stock:'<path d="M3 21V9l9-5 9 5v12"/><path d="M7 21v-8h10v8"/><path d="M7 17h10"/>',
    chart:'<path d="M4 20V11"/><path d="M10 20V5"/><path d="M16 20v-6"/><path d="M2 20h20"/>',
    phone:'<path d="M5 3h4l2 5-3 2a11 11 0 0 0 6 6l2-3 5 2v4a2 2 0 0 1-2 2A17 17 0 0 1 3 5a2 2 0 0 1 2-2z"/>',
    chat:'<path d="M4 5h16v11H9l-5 4z"/><path d="M8 9h8M8 12h5"/>',
    megaphone:'<path d="M3 11v2a1 1 0 0 0 1 1h2l5 4V6L6 10H4a1 1 0 0 0-1 1z"/><path d="M15 9a4 4 0 0 1 0 6M18 6a8 8 0 0 1 0 12"/>',
    keyboard:'<rect x="2" y="6" width="20" height="12" rx="2"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M6 14h.01M18 14h.01M9 14h6"/>',
    tasks:'<path d="M9 6h11M9 12h11M9 18h11"/><path d="M3.5 6l1.5 1.5L7.5 5M3.5 12l1.5 1.5 2.5-2.5M3.5 18l1.5 1.5 2.5-2.5"/>',
    shield:'<path d="M12 3l8 3v6c0 4.5-3.4 8-8 9-4.6-1-8-4.5-8-9V6z"/><path d="M8.5 12l2.5 2.5 4.5-4.5"/>',
    lock:'<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>'
  };
  const svg=(name)=>'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">'+(ICON[name]||ICON.box)+'</svg>';

  // Same role lists as the dashboard cards and each page's own role check.
  // Side menu (Mohit, 16 Nov 2026): Dashboard, Approvals, Tasks and Complaint Box stay on top; every other
  // group is one row that opens and closes (one open at a time, the open page's group opens by itself).
  const GROUP_ICON={"Sales":"chart","Purchase":"inbox","Stock & Dispatch":"truck","Accounts":"cash","Masters":"users","Admin":"gear","View only":"note"};
  const MENU=[
    {group:"",items:[{t:"Dashboard",h:"dashboard.html",i:"home",r:"*"},
      // Approvals (Mohit, 7 Nov 2026): everything waiting for Admin / Sales Head OK, one card each (approvals.js).
      {t:"Approvals",h:"approvals.html",i:"shield",top:1,r:"admin manager",k:"approval approve permission pending verify check bank payment trip rent rate market order po change stock"},
      {t:"Tasks",h:"tasks.html",i:"tasks",r:"*",top:1},
      // Dial Book (Mohit, 27 Nov 2026): parties, team, purchase truck drivers with a Call button + call log (dial-book.js).
      // Always a 📞 button in the top bar (phone too), so not drawn in the side menu.
      {t:"Dial Book",h:"dial-book.html",i:"phone",r:"admin manager accounts sales warehouse cashier transport",k:"dial book phone call contact contacts number mobile driver truck gaadi party team staff call log record whatsapp location",nm:"admin manager accounts sales warehouse cashier transport"},
      {t:"Complaint Box",h:"complaint-box.html",i:"megaphone",r:"*",top:1},
      // Keyboard Shortcuts (Mohit, 5 Nov 2026): every role sees the keys of the pages it can open.
      {t:"Keyboard Shortcuts",h:"keyboard-shortcuts.html",i:"keyboard",r:"*",k:"keyboard shortcut keys help hotkey",
       // Not in the side menu (Mohit, 7 Nov 2026): the keyboard button in the top bar opens it; still in Module Search.
       nm:"admin manager sales warehouse transport accounts driver"}]},
    {group:"Sales",items:[
      // One "PO / Sales" item (Mohit, 4 Nov 2026): the list, with "+ New PO" on top of it. New PO itself
      // (order-entry.html) is not drawn in the side menu (nm) but stays in search, Manage Users and the
      // phone bottom bar; while it is open its list item is lit (par).
      // (Sales Head / Admin: the approval + driver list; Godown Manager / Accounts: same list, view only;
      // Salesman: his own orders with PO given > Approved > Dispatched > Delivered).
      {t:"New PO / Sales Order",h:"order-entry.html",i:"cart",r:"admin manager sales",k:"new order entry po",pt:"PO / Sales Order (new PO)",nm:"admin manager sales",par:"warehouse-orders.html my-sales.html#orders"},
      {t:"PO / Sales",h:"warehouse-orders.html",i:"note",r:"admin manager accounts",k:"po approval driver warehouse orders",pt:"PO / Sales List (all POs; approve for Admin / Sales Head)"},
      // Direct Vehicle (Mohit, 23 Nov 2026): company truck straight to the party; party advance, final +/- qty, balance.
      {t:"Direct Vehicle",h:"direct-vehicle.html",i:"truck",r:"admin manager accounts",k:"direct vehicle company truck party advance balance baki final qty plus minus ecrs"},
      {t:"PO / Sales",h:"my-sales.html#orders",i:"note",r:"sales",k:"my orders modify",pt:"PO / Sales List (Salesman's own orders)"},
      // Rajnigandha (Mohit, 4 Nov 2026): no own menu items. A Rajnigandha PO prints its slip from PO / Sales
      // (Print), its waiting POs show on top of that list; the rate list is the Rajnigandha tab of Rate List.
      {t:"Rajnigandha Slips",h:"quick-slip.html",i:"note",r:"admin manager accounts sales",k:"rajnigandha slip parchi thermal print kachcha",vo:"accounts",nm:"admin manager accounts sales",par:"warehouse-orders.html my-sales.html#orders"},
      {t:"Rajnigandha Rate List",h:"rajni-rates.html",i:"bill",r:"admin",k:"rajnigandha rate landing min max profit margin approval",nm:"admin",par:"rates.html"},
      {t:"My Sales",h:"my-sales.html",i:"chart",r:"sales"},
      // Party Rate Offer (Mohit, 16 Nov 2026): rate per case given to one party, category-wise, with (i) past rates.
      {t:"Party Rate Offer",h:"party-rates.html",i:"tag",r:"admin manager",k:"party rate offer quotation category pack per case given history whatsapp"},
      // Outstanding (Mohit, 20 Nov 2026): Sales Head sees unpaid / part-paid bills, party-wise dues, ledger; tells Accounts.
      // Outstanding & Ledger for Sales Head (20 Nov 2026) is now the same Ledger & Outstanding page, view only (27 Nov 2026).
      {t:"Outstanding (old)",h:"sales-outstanding.html",i:"cash",r:"admin manager",hide:1},
      {t:"Party Call List",h:"party-calls.html",i:"phone",r:"admin manager sales"},
      // Party Mobile Pending (Mohit, 21 Nov 2026): parties without a mobile number; fill here, task closes by itself.
      {t:"Party Mobile Pending",h:"party-mobile.html",i:"phone",r:"admin manager sales",k:"mobile number missing phone party contact fill pending task"},
      {t:"Outside Market Stock",h:"market-report.html",i:"pin",r:"admin manager sales"},
      {t:"Sales Tracking",h:"sales-tracking.html",i:"chart",r:"admin manager"},
      // Party Buying (Mohit, 17 Nov 2026): party / SKU / category-wise buying, never bought, not in N days, stopped. Tab of Sales Tracking.
      {t:"Party Buying",h:"party-buying.html",i:"chart",r:"admin manager",k:"party sku item category wise sale not buying never bought non selling stopped days since last",nm:"admin manager",par:"sales-tracking.html"},
      {t:"Sales Team Setup",h:"sales-team.html",i:"users",r:"admin manager"},
      // One "Returns" item (Mohit, 4 Nov 2026): Sales Return and Credit Note are tabs on top of it (PAGE_TABS);
      // they leave the side menu only for roles that also have Driver Returns (Salesman keeps Sales Return).
      {t:"Returns",h:"driver-returns.html",i:"undo",r:"admin accounts manager warehouse",pt:"Driver Returns Approval"},
      {t:"Sales Return",h:"sales-return.html",i:"undo",r:"admin sales",nm:"admin",par:"driver-returns.html"},
      {t:"Credit Note Preview",h:"credit-note.html",i:"note",r:"admin accounts",nm:"admin accounts",par:"driver-returns.html"}]},
    // Purchase in one place (Mohit, 2 Nov 2026): entry, the list of every purchase bill (like the PO list),
    // ECRS and damage claims. (The scanned sales bill PDFs moved to Accounts, 16 Nov 2026.)
    {group:"Purchase",items:[
      // One "Purchase" item (Mohit, 4 Nov 2026): the list, with "+ New Purchase" on top. Purchase Entry is
      // not drawn in the side menu (nm) but stays in search and Manage Users; its list item is lit (par).
      {t:"New Purchase (Goods Inward)",h:"goods-inward.html",i:"inbox",r:"admin manager",k:"goods inward purchase bill new entry",pt:"Purchase Entry (Goods Inward)",nm:"admin manager",par:"purchase-register.html"},
      {t:"Purchase",h:"purchase-register.html",i:"note",r:"admin manager warehouse accounts",k:"purchase register bills verify damage photo",pt:"Purchase List / Register"},
      // ECRS (Mohit, 16 Nov 2026): company's daily allowed quantity, our truck orders (Order 1, 2, 3), payment.
      {t:"ECRS Order",h:"ecrs.html",i:"note",r:"admin manager",k:"ecrs acrs company order truck pallet gr discount rtgs coca cola"},
      {t:"Purchase Claims",h:"purchase-claims.html",i:"inbox",r:"admin manager",k:"damage leakage shortage claim"}]},
    // Collapsible groups (Mohit, 16 Nov 2026): Inventory, Dispatch and Delivery in one group.
    {group:"Stock & Dispatch",items:[
      // One "Inventory" item (Mohit, 4 Nov 2026): the other stock pages are tabs on top of it (PAGE_TABS),
      // still found by Module Search and ticked in Manage Users.
      {t:"Inventory",h:"inventory.html",i:"stock",r:"admin manager warehouse accounts",vo:"accounts",pt:"Inventory / Stock Report"},
      {t:"Goods in Transit",h:"stock-transit.html",i:"truck",r:"admin manager warehouse",nm:"admin manager warehouse",par:"inventory.html"},
      {t:"Stock Transfer / Damage",h:"stock-transfer.html",i:"undo",r:"admin manager warehouse accounts",vo:"accounts",nm:"admin manager warehouse accounts",par:"inventory.html"},
      {t:"Night Stock Audit",h:"stock-audit.html",i:"stock",r:"admin manager warehouse accounts",vo:"accounts",nm:"admin manager warehouse accounts",par:"inventory.html"},
      {t:"Opening Stock",h:"opening-stock.html",i:"box",r:"admin",nm:"admin",par:"inventory.html"},
      {t:"Godown Report",h:"godown-report.html",i:"note",r:"admin manager warehouse"},
      // Daily Labour (Mohit, 26 Nov 2026): Godown Manager's one-day market labour (name, mobile, wage), morning plan, night cash.
      {t:"Daily Labour",h:"labour.html",i:"users",r:"admin manager warehouse accounts cashier",k:"daily labour dihadi dihari dahadi majdoor mazdoor majduri hamal market labour one day casual wage hajri attendance chhutak bahar se labour",vo:"accounts"},
      {t:"Loading & Dispatch",h:"loading-dispatch.html",i:"box",r:"admin manager warehouse"},
      {t:"Transport Assignment",h:"transport-allocation.html",i:"truck",r:"admin manager transport"},
      // Vehicle Report (Mohit, 23 Nov 2026): per vehicle / driver for the day: tons loaded, cases delivered, parties, fixed driver.
      {t:"Vehicle Report",h:"vehicle-report.html",i:"truck",r:"admin manager transport accounts",k:"vehicle report driver dashboard ton tons cases delivered trip today gadi truck fixed driver",vo:"accounts"},
      {t:"Driver Delivery / POD",h:"driver-delivery.html",i:"pin",r:"admin manager driver accounts",nm:"accounts"},
      {t:"Live Tracking",h:"live-tracking.html",i:"pin",r:"admin"}]},
    {group:"Accounts",items:[
      // Finance home (Mohit, 20 Nov 2026): one money page for Admin / Accounts / Cashier: money now, work waiting,
      // brand-wise and party-wise split, money in / out, rough P&L, expenses; every number opens what makes it.
      {t:"Finance Home",h:"finance.html",i:"chart",r:"admin accounts cashier",k:"finance home money position cash flow cash in hand bank balance profit loss p&l expenses brand wise party wise to collect to pay company payable work waiting notifications alerts control centre center hisab",pt:"Finance Home (money, brand-wise, P&L)"},
      // Accounts in one place (Mohit, 19 Nov 2026): Billing & Outstanding + Accounts Dashboard = one "Accounts" page
      // (one header, one tab row, acc-hub.js). Billing tabs are party-billing.html, Cash & Bank tabs accounts-dashboard.html.
      // Split by work (Mohit, 20 Nov 2026), same two files, view in the hash (acc-hub.js):
      // Accounts · Tally (Yogesh bhai: Tally bills, bank check, GST + cash), Cashier (cash only), Party & Collections (Admin).
      {t:"Accounts · Tally",h:"party-billing.html",i:"bill",r:"admin accounts",k:"accounts tally bills to make bills made party ledger statement khata tally bill merge sales bill gst gstr gstr-1 gstr-3b gst paid filed bank check verify bank entry cheque po change credit note return cash in cash out bank deposit close day day book",pt:"Accounts · Tally (Bills, Ledger, Bank check, GST)"},
      {t:"Cashier",h:"accounts-dashboard.html#cash",i:"cash",r:"admin cashier",k:"cashier cash in cash out bank deposit close day day book cash book cash ledger cash in hand cheque handover staff advance upad salary vehicle expense party payment received",pt:"Cashier (Cash In / Out, Day book)"},
      {t:"Party & Collections",h:"party-billing.html#party",i:"users",r:"admin",k:"party payment received pending outstanding to collect collection party ledger statement khata advance returns party groups acrs ecrs",pt:"Party & Collections (To collect, Ledger, ACRS)"},
      // Ledger & Outstanding (Mohit, 20 Nov 2026): Tally "Display" books in one page, Ctrl+Alt+L from anywhere.
      {t:"Ledger & Outstanding",h:"accounts-books.html",i:"book",r:"admin accounts manager",k:"ledger outstanding receivable receivables bill wise party wise ageing overdue 30 60 90 days receipt register receipts payment received party payment summary day book voucher khata statement tally ctrl alt l kasar party ledger hisab khatabook baki udhar",a:"ledger outstanding khata hisab baki udhar",pt:"Ledger & Outstanding (Ctrl+Alt+L)"},
      {t:"Accounts",h:"accounts-dashboard.html",i:"cash",r:"admin accounts",hide:1,par:"party-billing.html"},
      {t:"Bank Statement",h:"bank-statement.html",i:"book",r:"admin accounts"},
      // STTS Ledger (Mohit, 13 Nov 2026): company Sales Register + STTS Ledger checked bill by bill against the Rate List scheme.
      {t:"STTS Ledger",h:"stts-ledger.html",i:"note",r:"admin accounts manager",k:"stts ledger scheme claim free bottle oms sales register dms hccb mer company claim short"},
      // Tax invoice in the Tally layout (Mohit, 11 Nov 2026): off until Admin turns it on (today only / till off)
      // for the ticked roles; others find it in search, Accounts also from Bills to make.
      // Company documents (Mohit, 11 Nov 2026): GST / PAN / Aadhaar / licences, renewal reminders, share to a party.
      {t:"Documents",h:"documents.html",i:"note",r:"admin accounts",k:"documents company kyc gst certificate pan aadhaar licence license renewal expiry reminder gstr-1 gstr-3b fssai gumasta share whatsapp party"},
      {t:"Tax Invoice Print",h:"tax-invoice.html",i:"bill",r:"admin accounts manager",k:"tax invoice gst bill print tally format cgst sgst hsn accounts absent",nm:"accounts manager"},
      // Every accounts page in one group (Mohit, 16 Nov 2026).
      {t:"Driver Collections",h:"driver-collections.html",i:"cash",r:"admin manager accounts",nm:"accounts"},
      {t:"Sheet & Pallet Ledger",h:"sheet-pallet.html",i:"layers",r:"admin manager accounts warehouse",vo:"accounts"},
      {t:"Sales Bill PDFs",h:"sales-bill-scans.html",i:"bill",r:"admin accounts manager",k:"scan pdf sales bill invoice register upload",vo:"accounts"},
      {t:"Daily Summary",h:"daily-report.html",i:"stock",r:"admin manager accounts",nm:"accounts"},
      {t:"WhatsApp Reports",h:"whatsapp-reports.html",i:"note",r:"admin",nm:"accounts"},
      {t:"Money Overview",h:"money-overview.html",i:"cash",r:"admin accounts",hide:1},
      {t:"Tally Bill & Invoice No.",h:"accounts-invoice.html",i:"bill",r:"admin accounts",hide:1},
      {t:"Tally Bill Check",h:"tally-check.html",i:"bill",r:"admin accounts",hide:1},
      {t:"Tally Party Mapping",h:"party-mapping.html",i:"users",r:"admin accounts",hide:1},
      {t:"Cashbook",h:"cashbook.html",i:"cash",r:"admin",hide:1}]},
    {group:"Masters",items:[
      {t:"Customer / Party Master",h:"customer-master.html",i:"users",r:"admin manager"},
      {t:"SKU Master",h:"sku-master.html",i:"tag",r:"admin manager"},
      {t:"Rate List",h:"rates.html",i:"tag",r:"admin manager",k:"rate scheme mepd landing slab rajnigandha coca-cola brand",pt:"Rate List (Coca-Cola Rate & Scheme)"},
      {t:"Company / Brand",h:"companies.html",i:"factory",r:"admin manager accounts",vo:"accounts"},
      {t:"Supplier Master",h:"supplier-master.html",i:"factory",r:"admin manager"},
      {t:"Vehicle Master",h:"fleet-master.html#vehicles",i:"truck",r:"admin manager transport"},
      {t:"Drivers",h:"fleet-master.html#drivers",i:"users",r:"transport"},
      {t:"Employee Master",h:"fleet-master.html#employees",i:"users",r:"admin manager"},
      {t:"Fixed Assets",h:"fixed-assets.html",i:"box",r:"admin manager accounts",vo:"accounts"}]},
    {group:"Admin",items:[
      {t:"Settings",h:"settings.html",i:"gear",r:"admin manager"},
      {t:"Manage Users",h:"users.html",i:"lock",r:"admin"},
      {t:"Team Work Report",h:"team-report.html",i:"users",r:"admin manager"},
      // Change History (Mohit, 5 Nov 2026): who added / edited / deleted what. Admin only.
      {t:"Change History",h:"change-history.html",i:"undo",r:"admin",k:"history audit log who edited changed deleted added employee activity"},
      // Brand Data Reset (Mohit, 4 Nov 2026): Admin removes one brand's data till today for a fresh start.
      // Not in the side menu (nm); opens from the Settings card and Module Search.
      {t:"Brand Data Reset",h:"brand-reset.html",i:"lock",r:"admin",k:"reset delete clear brand rajnigandha fresh start opening data",nm:"admin",par:"settings.html"},
      // Order History Days (Mohit, 13 Nov 2026): per role, days after delivery an order stays in its lists.
      {t:"Order History Days",h:"order-history-days.html",i:"note",r:"admin",k:"order history days delivered visible hide old orders salesman driver sales head accounts role",nm:"admin",par:"settings.html"},
      {t:"Accounts Fresh Start",h:"accounts-reset.html",i:"lock",r:"admin",k:"reset delete clear accounts cash book entries opening cash bank balance fresh start",nm:"admin",par:"settings.html"}]},
    // Reports (Mohit, 24 Nov 2026): every report in one place; Admin only, last in the side menu.
    {group:"",items:[{t:"Reports",h:"reports.html",i:"chart",r:"admin",k:"report reports register sales report purchase report date wise party wise sku wise item wise salesman wise supplier wise expense report cash in out register excel export mis summary"}]}
  ];


  // ERP popups. window.alert / confirm / prompt are replaced by styled popups
  // that return Promises, so callers use: await alert(..), if(!await confirm(..)).
  const nativeAlert=window.alert.bind(window),nativeConfirm=window.confirm.bind(window),nativePrompt=window.prompt.bind(window);
  let queue=Promise.resolve();
  function kindOf(text){
    const t=String(text||"").toLowerCase();
    if(/(fail|error|could not|cannot|can't|not saved|not completed|invalid|required|only for|access only|not found|inactive|must |exceeds|unable|maximum|please select|please enter|enter a valid|\benter |at least one)/.test(t))return "error";
    if(/(success|saved|submitted|approved|posted|created|updated|completed|done|cleared|assigned)/.test(t))return "success";
    return "info";
  }
  const TITLE={success:"Done",error:"Please check",info:"Message",confirm:"Please confirm",danger:"Please confirm",prompt:"Enter details"};
  const MARK={success:'<path d="M5 12.5l4.5 4.5L19 7.5"/>',error:'<path d="M12 7v6"/><path d="M12 17h.01"/>',info:'<path d="M12 11v6"/><path d="M12 7h.01"/>',
    confirm:'<path d="M9.5 9a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.6v.6"/><path d="M12 17h.01"/>',prompt:'<path d="M4 20h4L19 9l-4-4L4 16z"/>'};
  MARK.danger=MARK.error;
  function open(kind,text,opts){
    opts=opts||{};
    return new Promise(done=>{
      const back=document.createElement("div");back.className="erp-dlg-back";
      const box=document.createElement("div");box.className="erp-dlg "+kind;box.setAttribute("role",kind==="confirm"||kind==="danger"||kind==="prompt"?"alertdialog":"dialog");box.setAttribute("aria-modal","true");
      const ic=document.createElement("div");ic.className="erp-dlg-ic";ic.innerHTML='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">'+MARK[kind]+'</svg>';
      const h=document.createElement("h3");h.textContent=opts.title||TITLE[kind];
      const lines=String(text==null?"":text).split("\n");
      const first=document.createElement("p");first.className="erp-dlg-lead";
      const rest=document.createElement("p");rest.className="erp-dlg-text";
      // First paragraph is the headline; details below in a softer box.
      const cut=lines.findIndex(l=>!l.trim());
      first.textContent=(cut>0?lines.slice(0,cut):lines).join("\n");
      const detail=cut>0?lines.slice(cut).join("\n").trim():"";
      rest.textContent=detail;
      box.append(ic,h,first);if(detail)box.append(rest);
      let input=null;
      if(kind==="prompt"){input=document.createElement("textarea");input.rows=2;input.className="erp-dlg-input";input.placeholder=opts.placeholder||"Type here";input.value=opts.value||"";box.append(input)}
      const row=document.createElement("div");row.className="erp-dlg-actions";
      const ok=document.createElement("button");ok.type="button";ok.className="erp-dlg-ok";
      ok.textContent=opts.ok||(kind==="danger"?"Yes, continue":kind==="confirm"?"Yes, continue":kind==="prompt"?"Submit":"OK");
      const asks=kind==="confirm"||kind==="danger"||kind==="prompt";
      let no=null;
      if(asks){no=document.createElement("button");no.type="button";no.className="erp-dlg-no";no.textContent=opts.cancel||"Cancel";row.append(no)}
      row.append(ok);box.append(row);back.append(box);
      const last=document.activeElement;
      document.body.append(back);
      requestAnimationFrame(()=>back.classList.add("show"));
      (input||ok).focus();
      function close(v){
        back.classList.remove("show");document.removeEventListener("keydown",key,true);
        setTimeout(()=>back.remove(),160);
        try{last&&last.focus&&last.focus()}catch(e){}
        done(v);
      }
      function key(e){
        if(e.key==="Escape"){e.preventDefault();close(kind==="prompt"?null:asks?false:undefined)}
        else if(e.key==="Enter"&&!(input&&e.shiftKey)){e.preventDefault();ok.click()}
        else if(e.key==="Tab"){const f=[input,no,ok].filter(Boolean),i=f.indexOf(document.activeElement);e.preventDefault();f[(i+(e.shiftKey?f.length-1:1))%f.length].focus()}
      }
      document.addEventListener("keydown",key,true);
      ok.onclick=()=>close(kind==="prompt"?input.value:asks?true:undefined);
      if(no)no.onclick=()=>close(kind==="prompt"?null:false);
      if(!asks)back.addEventListener("click",e=>{if(e.target===back)close()});
    });
  }
  function show(kind,text,opts){
    if(!document.body)return Promise.resolve(kind==="prompt"?nativePrompt(text):kind==="confirm"||kind==="danger"?nativeConfirm(text):nativeAlert(text));
    const run=queue.then(()=>open(kind,text,opts));
    queue=run.then(()=>{},()=>{});
    return run;
  }
  // A clear "it is done" popup with a green tick and OK (Mohit, 17 Nov 2026: after Approve there was no sign).
  function erpDone(text,opts){return show("success",text,Object.assign({ok:"OK"},opts||{}))}
  const DANGER=/(cancel|reject|remove|delete|clear)/i;
  function erpAlert(text,opts){
    const kind=(opts&&opts.kind)||kindOf(text);
    // A successful save needs a short acknowledgement, not a blocking dialog.
    if(kind==="success"&&document.body){
      const root=document.querySelector(".erp-main main, main.erp-main, .erp-main")||document.body;
      let line=root.querySelector(".erp-save-feedback");
      if(!line){line=document.createElement("div");line.className="erp-save-feedback";line.setAttribute("role","status");root.prepend(line)}
      clearTimeout(line._hide);line.hidden=false;line.textContent=String(text||"");
      line._hide=setTimeout(()=>{line.hidden=true},4500);
      return Promise.resolve();
    }
    return show(kind,text,opts);
  }
  function erpConfirm(text,opts){return show((opts&&opts.danger)||(!opts&&DANGER.test(String(text).split("\n")[0]))?"danger":"confirm",text,opts)}
  function erpPrompt(text,value,opts){return show("prompt",text,Object.assign({value:typeof value==="string"?value:""},opts||{}))}
  window.alert=erpAlert;window.confirm=erpConfirm;window.prompt=erpPrompt;

  // Explicit action feedback (save / validation) stays available to each page.
  function toast(text,kind){
    let wrap=document.querySelector(".erp-toasts");
    if(!wrap){wrap=document.createElement("div");wrap.className="erp-toasts";wrap.setAttribute("aria-live","polite");document.body.append(wrap)}
    const t=document.createElement("div");t.className="erp-toast "+(kind||"success");
    t.innerHTML='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round">'+MARK[kind||"success"]+'</svg>';
    const span=document.createElement("span");span.textContent=text;t.append(span);
    wrap.append(t);requestAnimationFrame(()=>t.classList.add("show"));
    setTimeout(()=>{t.classList.remove("show");setTimeout(()=>t.remove(),250)},4200);
  }
  function allowed(item,role){return item.r==="*"||item.r.split(" ").includes(role)}
  // menuFor(role) = the role's default pages; menuFor(role,hidden) also drops
  // the pages Admin unticked for one user (Manage Users > Pages).
  // extra = pages of OTHER roles Admin ticked for this user.
  // vo = roles that only look at the page (no entry / edit there). Accounts (Mohit, 4 Nov 2026): its menu keeps
  // cash, bank, orders and returns (5 Nov 2026: PO / Sales List and Billing & Outstanding with Bills to make are
  // back in the Accounts side menu, Sales Bill PDFs under View only); the other pages it may still open sit at the bottom under "View only".
  const viewOnlyItem=(i,role)=>!!i.vo&&i.vo.split(" ").includes(role);
  // nm = not in the side menu for these roles, but still allowed and found by Module Search / Dashboard search.
  const noMenuItem=(i,role)=>!!i.nm&&i.nm.split(" ").includes(role);
  function menuFor(role,hidden,extra){
    const off=new Set(hidden||[]),plus=new Set(extra||[]),vo=[],nm=[];
    const out=MENU.map(g=>({group:g.group,items:g.items.filter(i=>{
      if(role!=="admin"&&i.h==="live-tracking.html")return false;
      const ok=(allowed(i,role)&&!off.has(i.h))||plus.has(i.h);
      if(ok&&noMenuItem(i,role)){nm.push({...i,g:g.group});return false}
      if(ok&&viewOnlyItem(i,role)){vo.push(i);return false}
      return ok})})).filter(g=>g.items.length);
    if(vo.length)out.push({group:"View only",items:vo});
    if(nm.length)out.push({group:"More",items:nm,so:1});   // search only, not drawn in the side menu
    return out;
  }
  // true when this role may only look at this page (pages hide their entry / edit buttons).
  function viewOnly(role,page){
    page=String(page||location.pathname.split("/").pop()||"").split(/[?#]/)[0];role=String(role||"").toLowerCase();
    return MENU.some(g=>g.items.some(i=>i.h.split("#")[0]===page&&viewOnlyItem(i,role)));
  }
  // Module Search (Mohit, 27 Nov 2026): "ledger" must open Ledger & Outstanding first. Hindi / Hinglish
  // spellings become the menu's English word; a = words that put this page on top of the results.
  const SEARCH_ALIAS={"लेजर":"ledger","लेज़र":"ledger","लेजर्स":"ledger","ledgar":"ledger","lejar":"ledger","leger":"ledger","ledjer":"ledger","legder":"ledger","ledeger":"ledger",
    "खाता":"khata","खाते":"khata","khaata":"khata","khatabook":"khata","hisaab":"hisab","हिसाब":"hisab",
    "आउटस्टैंडिंग":"outstanding","outstandig":"outstanding","outstading":"outstanding","outstnding":"outstanding","बकाया":"baki","बाकी":"baki","baaki":"baki","उधार":"udhar","udhaar":"udhar"};
  const searchWords=q=>String(q||"").toLowerCase().trim().split(/\s+/).filter(Boolean).map(w=>SEARCH_ALIAS[w]||w);
  function findModules(list,q){
    const words=searchWords(q);if(!words.length)return [];
    return list.map((i,n)=>{
      const t=String(i.t||"").toLowerCase(),a=String(i.a||"").toLowerCase().split(" ").filter(Boolean),
        all=(t+" "+(i.g||"")+" "+(i.pt||"")+" "+(i.k||"")+" "+a.join(" ")).toLowerCase();
      if(!words.every(w=>all.includes(w)))return null;
      const inT=words.every(w=>t.includes(w)),s=(words.every(w=>a.some(x=>x.startsWith(w)))?0:t.startsWith(words[0])?2:inT?4:6)+(inT?0:1)-(t.startsWith(words[0])?.5:0);
      return {i,s,n};
    }).filter(Boolean).sort((x,y)=>x.s-y.s||x.n-y.n).map(x=>x.i);
  }
  // Ledger button in the top bar was taken out again (Mohit, 27 Nov 2026): Ledger & Outstanding opens from the
  // menu, Module Search ("ledger" / "khata" / "लेजर") or Ctrl+Alt+L.
  const allPages=()=>MENU.map(g=>({group:g.group,items:g.items.map(i=>({t:i.pt||i.t,h:i.h}))}));

  // Pages hidden from the logged-in user. Cached so the menu is right at once,
  // then re-read from lwb_user_page_access on every page.
  const ACCESS_KEY="lwbHiddenPages";
  function sessionUid(){
    try{const t=JSON.parse(localStorage.getItem("sb-qstgwhbgbznxemajtave-auth-token")||"null");return(t&&t.user&&t.user.id)||""}catch(e){return""}
  }
  function access(){
    try{const c=JSON.parse(localStorage.getItem(ACCESS_KEY)||"null");const sid=sessionUid();if(c&&Array.isArray(c.hidden)&&(!sid||c.uid===sid))return c}catch(e){}
    return null;
  }
  function hiddenPages(){const c=access();return c?c.hidden:[]}
  // Today's cashier (Mohit, 26 Nov 2026): the Sales Head who holds the cash box now (Cash handover, Received ✓)
  // gets the Cashier page as if Admin had ticked it (lwb_acc_duty_cashier_setup.sql, lwb_acc_on_duty()).
  // It goes away by itself when he hands the box on and the next person presses Received ✓.
  const DUTY_KEY="lwbDutyCash",DUTY_PAGES=["accounts-dashboard.html#cash"];
  function dutyInfo(){
    try{const c=JSON.parse(localStorage.getItem(DUTY_KEY)||"null");const sid=sessionUid();if(c&&c.on&&(!sid||c.uid===sid))return c}catch(e){}
    return null;
  }
  const onDuty=()=>!!dutyInfo();
  function extraPages(){const c=access();const x=c&&Array.isArray(c.extra)?c.extra:[];return onDuty()?x.concat(DUTY_PAGES.filter(h=>!x.includes(h))):x}
  // hide:1 pages (Cashbook) are never listed in the menu, search or dashboard; they open only
  // from their own private link. menuFor still has them, so Manage Users can tick them.
  function menuForMe(role){return menuFor(role,hiddenPages(),extraPages()).map(g=>({group:g.group,so:g.so,items:g.items.filter(i=>!i.hide)})).filter(g=>g.items.length)}
  const herePage=()=>(location.pathname.split("/").pop()||"dashboard.html").replace(/^$/,"dashboard.html");
  const withHtml=p=>/\.html$/.test(p)?p:p+".html";
  // Role a page should treat this user as. His own role when the page is his;
  // when Admin ticked this page of another role for him, that page's role.
  function pageRole(role,page){
    page=withHtml(page||herePage());
    if(role!=="admin"&&page==="live-tracking.html")return role;
    const items=MENU.flatMap(g=>g.items).filter(i=>i.h.split("#")[0]===page);
    if(!items.length||items.some(i=>allowed(i,role)))return role;
    if(!extraPages().some(h=>h.split("#")[0]===page))return role;
    const rs=items[0].r.split(" ");return rs.find(r=>r!=="admin")||rs[0];
  }
  // Same, but re-reads the ticks first when the cached ones do not open this page.
  async function pageRoleFresh(role,page){
    if(String(role||"").toLowerCase()==="manager"){await refreshAccess(role);return pageRole(role,page)}  // cash box may have moved
    const r=pageRole(role,page);if(r!==role)return r;
    await refreshAccess();return pageRole(role,page);
  }
  function esc(v){return String(v==null?"":v).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]))}

  // Phone: "Add to Home screen" opens the ERP like an app.
  function appMeta(){
    // Service worker: needed for "Install app" and the Android app; it caches nothing.
    if("serviceWorker" in navigator)navigator.serviceWorker.register("/sw.js").catch(()=>{});
    if(document.querySelector('link[rel="manifest"]'))return;
    const add=(tag,attrs)=>{const n=document.createElement(tag);for(const k in attrs)n.setAttribute(k,attrs[k]);document.head.appendChild(n)};
    add("link",{rel:"manifest",href:"manifest.webmanifest"});
    add("meta",{name:"theme-color",content:"#002f37"});
    add("link",{rel:"apple-touch-icon",href:"app-icon-192.png"});
    add("meta",{name:"apple-mobile-web-app-capable",content:"yes"});
  }

  const DIAL_ROLES=["admin","manager","accounts","sales","warehouse","cashier","transport"];
  const GM_OFF=["goods-inward.html","warehouse-orders.html","quick-slip.html","sales-return.html","tax-invoice.html","fleet-master.html","fixed-assets.html"];
  // Older pages (data-auto) stay on "Loading…" (erp-shell.css) until the top bar and menu are in place,
  // so the plain old-looking page never flashes first after a refresh (Mohit, 24 Nov 2026).
  const READY=()=>document.documentElement.classList.add("erp-ready");
  setTimeout(READY,8000);
  function mount(opts){try{return mountPage(opts)}finally{READY()}}
  function mountPage(opts){
    appMeta();
    const role=String(opts.role||"").toLowerCase();
    const page=(location.pathname.split("/").pop()||"dashboard.html").replace(/^$/,"dashboard.html");
    if(blocked(role,page,hiddenPages()))return {menu:[]};
    // Godown Manager: loading, stock, returns and purchase photos only (Mohit, 18 Nov 2026). Sales pages
    // (PO / Sales list, slips, sales return, tax invoice) and Masters do not open, unless Admin ticked the page.
    // Godown Manager works only on what is assigned: no brand (company) chips, no brand filter.
    if(role==="warehouse"){try{localStorage.removeItem("lwbBrand")}catch(e){}if(!document.getElementById("gmNoBrand")){const st=document.createElement("style");st.id="gmNoBrand";st.textContent=".lwb-brands{display:none!important}";document.head.appendChild(st)}}
    if(role==="warehouse"&&GM_OFF.includes(page)&&!extraPages().some(h=>h.split("#")[0]===page)){location.replace("dashboard.html");return {menu:[]}}
    let groups=menuForMe(role);
    let current=null,currentGroup="";
    // Exact link (with #tab) first, so my-sales.html and my-sales.html#orders each light their own item.
    const here=page+(location.hash||"");
    MENU.forEach(g=>g.items.forEach(i=>{if(!current&&allowed(i,role)&&i.h===here){current=i;currentGroup=g.group}}));
    MENU.forEach(g=>g.items.forEach(i=>{if(!current&&allowed(i,role)&&i.h.split("#")[0]===page&&!i.h.includes("#")){current=i;currentGroup=g.group}}));
    MENU.forEach(g=>g.items.forEach(i=>{if(!current&&allowed(i,role)&&i.h.split("#")[0]===page){current=i;currentGroup=g.group}}));
    const title=opts.title||(current&&current.t)||document.title.split("|")[0].trim();
    const group=opts.group!=null?opts.group:currentGroup;

    document.body.classList.add("erp", "erp-compact");
    document.body.dataset.erpPage = page.replace(/\.html$/, "");
    const top=document.createElement("div");
    top.className="erp-top";
    top.innerHTML=
      '<button class="erp-burger" type="button" aria-label="Menu"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M4 6h16M4 12h16M4 18h16"/></svg></button>'+
      '<div class="erp-crumb" aria-label="Breadcrumb">'+(group?'<a class="mid" href="dashboard.html" style="text-decoration:none">'+esc(group)+'</a><span>/</span>':'')+'<b>'+esc(title)+'</b></div>'+
      '<div class="erp-search"><input type="search" placeholder="Module Search" aria-label="Module Search">'+
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg><div class="erp-results"></div></div>'+
      '<div class="erp-user"><button class="erp-keys-btn" type="button" aria-label="Keyboard shortcuts" title="Keyboard shortcuts (?)">'+svg("keyboard")+'</button><div class="who"><b>'+esc(opts.name||"User")+'</b><small>'+esc(role.toUpperCase())+'</small></div>'+
      '<div class="erp-avatar">'+esc((opts.name||"U").trim().charAt(0).toUpperCase())+'</div>'+
      '<button class="erp-logout" type="button" title="Logout" aria-label="Logout"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/></svg><span>Logout</span></button></div>';

    const side=document.createElement("aside");
    side.className="erp-side";
    const OPEN_KEY="erpSideGroup";
    const isActive=i=>!!current&&(i.h===current.h||String(current.par||"").split(" ").includes(i.h));
    function drawSide(){
      let html='<div class="erp-brand"><span class="erp-mark" aria-hidden="true">lwb</span><div><b>LUXURY WRIST BRAND</b><small>BUSINESS ERP</small></div></div>'+
        '<div class="erp-menu-find"><input type="search" aria-label="Find a page" placeholder="Find a page…"></div><p class="erp-menu-empty" hidden>No page found</p>';
      const link=(i,g)=>'<a class="erp-link'+(i.top?' erp-side-top':'')+(isActive(i)?' active':'')+'" href="'+esc(i.h)+'" data-k="'+esc((i.t+" "+g.group+" "+(i.pt||"")+" "+(i.k||"")+" "+(i.a||"")).toLowerCase())+'">'+svg(i.i)+'<span>'+esc(i.t)+'</span></a>';
      const secs=groups.filter(g=>!g.so&&g.group);
      // Which group is open: the open page's group, else the one opened last, else the first.
      let open=(secs.find(g=>g.items.some(isActive))||{}).group;
      if(!open){try{open=localStorage.getItem(OPEN_KEY)||""}catch(e){}}
      if(!secs.some(g=>g.group===open))open=secs.length===1?secs[0].group:"";
      groups.forEach(g=>{
        if(g.so)return;
        if(!g.group){html+=g.items.map(i=>link(i,g)).join("");return}
        const on=g.group===open,id="erp-sec-"+g.group.toLowerCase().replace(/[^a-z]+/g,"-");
        html+='<div class="erp-sec'+(on?' open':'')+'" data-g="'+esc(g.group)+'">'+
          '<button type="button" class="erp-group" aria-expanded="'+on+'" aria-controls="'+id+'">'+svg(GROUP_ICON[g.group]||"note")+
          '<span>'+esc(g.group)+'</span><svg class="erp-chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/></svg></button>'+
          '<div class="erp-sec-body" id="'+id+'">'+g.items.map(i=>link(i,g)).join("")+'</div></div>';
      });
      // Phone: Logout sits at the end of the side menu, the top bar keeps only the daily icons (Mohit, 27 Nov 2026).
      html+='<button type="button" class="erp-side-logout"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/></svg><span>Logout</span></button>';
      side.innerHTML=html;
    }
    drawSide();
    side.setAttribute("aria-label", "Main menu");
    // Approvals, Tasks, Complaint Box (Mohit, 16 Nov 2026): small icons in the top bar on a computer; on a phone
    // the top bar has no room, so they stay at the top of the side menu.
    function drawQuick(){
      const user=top.querySelector(".erp-user");let q=user.querySelector(".erp-quick");
      if(!q){q=document.createElement("div");q.className="erp-quick";user.prepend(q)}
      q.innerHTML=groups.filter(g=>!g.so).flatMap(g=>g.items).filter(i=>i.top).map(i=>
        '<a class="erp-quick-btn'+(isActive(i)?' active':'')+'" href="'+esc(i.h)+'" title="'+esc(i.t)+'" aria-label="'+esc(i.t)+'">'+svg(i.i)+'</a>').join("");
      // 📞 Dial Book button (Mohit, 27 Nov 2026): on every page, computer and phone.
      let db=user.querySelector(".erp-dial-btn");
      if(DIAL_ROLES.includes(role)){
        if(!db){db=document.createElement("a");db.className="erp-dial-btn";db.href="dial-book.html";db.title="Dial Book";db.setAttribute("aria-label","Dial Book");
          db.innerHTML=svg("phone")+"<span>Dial</span>";user.prepend(db)}
        db.classList.toggle("active",page==="dial-book.html");
      }else db?.remove();
    }
    side.addEventListener("click", e => {
      const b=e.target.closest(".erp-group");if(!b)return;
      const sec=b.parentElement,on=!sec.classList.contains("open");
      side.querySelectorAll(".erp-sec.open").forEach(x=>{x.classList.remove("open");x.querySelector(".erp-group").setAttribute("aria-expanded","false")});
      sec.classList.toggle("open",on);b.setAttribute("aria-expanded",String(on));
      try{localStorage.setItem(OPEN_KEY,on?sec.dataset.g:"")}catch(err){}
      if(on)requestAnimationFrame(()=>sec.scrollIntoView({block:"nearest"}));
    });
    side.addEventListener("input", e => {
      if(!e.target.matches(".erp-menu-find input")) return;
      const q=e.target.value.trim().toLowerCase(),words=searchWords(q);
      const links=[...side.querySelectorAll(".erp-link")];
      links.forEach(a => {const k=a.dataset.k||a.textContent.toLowerCase();a.hidden=!!q&&!words.every(w=>k.includes(w));a.classList.remove("kb")});
      // While finding, every group with a match is shown open; clearing the box brings back the open / closed groups.
      side.classList.toggle("finding",!!q);
      side.querySelectorAll(".erp-sec").forEach(sec => {sec.hidden=!!q&&![...sec.querySelectorAll(".erp-link")].some(a=>!a.hidden)});
      // Like Module Search: the first match is picked, ↑ / ↓ move, Enter opens (Mohit, 7 Nov 2026).
      const best=q&&findModules(flat,q)[0],first=q&&(links.find(a=>!a.hidden&&best&&a.getAttribute("href")===best.h)||links.find(a=>!a.hidden));if(first)first.classList.add("kb");
      side.querySelector(".erp-menu-empty").hidden=links.some(a => !a.hidden);
    });
    side.addEventListener("keydown", e => {
      if(!e.target.matches(".erp-menu-find input")) return;
      const vis=[...side.querySelectorAll(".erp-link")].filter(a=>!a.hidden&&a.offsetParent);
      let i=vis.findIndex(a=>a.classList.contains("kb"));
      if(e.key==="ArrowDown"||e.key==="ArrowUp"){
        if(!vis.length)return;e.preventDefault();
        i=i<0?(e.key==="ArrowDown"?0:vis.length-1):(i+(e.key==="ArrowDown"?1:vis.length-1))%vis.length;
        vis.forEach((a,n)=>a.classList.toggle("kb",n===i));vis[i].scrollIntoView({block:"nearest"});
      }else if(e.key==="Enter"&&e.target.value.trim()&&vis.length){e.preventDefault();location.href=(vis[i<0?0:i]).getAttribute("href")}
      else if(e.key==="Escape"&&e.target.value){e.preventDefault();e.stopPropagation();e.target.value="";e.target.dispatchEvent(new Event("input",{bubbles:true}))}
    });
    const shade=document.createElement("div");shade.className="erp-shade";
    document.body.prepend(top,side,shade);
    drawQuick();

    const narrow=()=>window.matchMedia("(max-width:980px)").matches;
    let closed=false;
    try{closed=localStorage.getItem("erpSideClosed")==="1"}catch(e){}
    if(closed&&!narrow())document.body.classList.add("side-closed");
    top.querySelector(".erp-burger").onclick=()=>{
      if(narrow()){const on=document.body.classList.toggle("side-open");top.querySelector(".erp-burger").setAttribute("aria-expanded",String(on));if(on)side.querySelector("input").focus();return}
      const c=document.body.classList.toggle("side-closed");
      try{localStorage.setItem("erpSideClosed",c?"1":"0")}catch(e){}
    };
    function closeSide(){document.body.classList.remove("side-open");top.querySelector(".erp-burger").setAttribute("aria-expanded","false")}
    top.querySelector(".erp-burger").setAttribute("aria-expanded","false");
    shade.onclick=closeSide;
    document.addEventListener("keydown",e=>{if(e.key==="Escape" && document.body.classList.contains("side-open")){closeSide();top.querySelector(".erp-burger").focus()}});
    side.addEventListener("click",e=>{if(e.target.closest("a"))closeSide()});
    // Auto hide (Mohit, 16 Nov 2026): an open side menu hides by itself 12 seconds after it was opened,
    // counted again from when the mouse leaves it / you stop typing in it. ☰ opens it again.
    const AUTO_HIDE_MS=12000;let hideT=0;
    const sideOpen=()=>narrow()?document.body.classList.contains("side-open"):!document.body.classList.contains("side-closed");
    const inSide=()=>side.matches(":hover")||side.contains(document.activeElement);
    const armHide=()=>{clearTimeout(hideT);if(!sideOpen())return;hideT=setTimeout(()=>{
      if(!sideOpen())return;if(inSide()){armHide();return}
      if(narrow())closeSide();else{document.body.classList.add("side-closed");try{localStorage.setItem("erpSideClosed","1")}catch(e){}}
    },AUTO_HIDE_MS)};
    top.querySelector(".erp-burger").addEventListener("click",armHide);
    side.addEventListener("mouseleave",armHide);side.addEventListener("focusout",armHide);side.addEventListener("input",armHide);
    armHide();
    top.querySelector(".erp-keys-btn").onclick=()=>{if(window.LWBKeys&&LWBKeys.help)LWBKeys.help();else location.href="keyboard-shortcuts.html"};
    top.querySelector(".erp-logout").onclick=opts.onLogout||(()=>{location.href="login.html"});
    side.addEventListener("click",e=>{if(e.target.closest(".erp-side-logout"))top.querySelector(".erp-logout").click()});
    mountedRole=role||"";
    if(role)unlockSetting(top.querySelector(".erp-avatar"),role);

    // Module search: type, then click or press Enter.
    const input=top.querySelector(".erp-search input"),box=top.querySelector(".erp-results");
    let flat=groups.flatMap(g=>g.items.map(i=>({...i,g:g.group})));
    let hits=[],pos=0;
    function show(){
      const q=input.value.toLowerCase().trim();
      hits=q?findModules(flat,q):[];
      pos=0;
      box.innerHTML=hits.map((i,n)=>'<a href="'+esc(i.h)+'"'+(n===0?' class="active"':'')+'>'+esc(i.t)+'<small>'+esc(i.g||"Home")+'</small></a>').join("")||(q?'<a>No module found</a>':"");
      box.classList.toggle("open",!!q);
    }
    input.addEventListener("input",show);
    input.addEventListener("keydown",e=>{
      if(e.key==="Enter"&&hits[pos]){location.href=hits[pos].h}
      // Cashbook code word (e.g. 401): no module has that name, so it opens the Cashbook with the code;
      // the database checks the code (lwb_cashbook_ok), a wrong one shows nothing
      else if(e.key==="Enter"&&/^[A-Za-z0-9_-]{3,64}$/.test(input.value.trim())){location.href="cashbook.html#k="+input.value.trim()}
      if(e.key==="Escape"){input.value="";show()}
      if((e.key==="ArrowDown"||e.key==="ArrowUp")&&hits.length){
        e.preventDefault();pos=(pos+(e.key==="ArrowDown"?1:hits.length-1))%hits.length;
        [...box.children].forEach((a,n)=>a.classList.toggle("active",n===pos));
      }
    });
    document.addEventListener("click",e=>{if(!e.target.closest(".erp-search"))box.classList.remove("open")});
    if(role!=="driver")bottomNav(page,role);
    pageTabs(page,role);
    // Driver keeps its own bottom menu. Keyboard handling applies to every role.
    watchKeyboard();
    // Inline success messages already confirm saves; avoid a second toast for the same event.
    compactTables();
    if(role){if(!stayLoggedIn(role))idleLogout();otpGuard();}
    bell(top,role);
    brandTop(top,role);
    dateTop(top,role);
    refreshAccess(role).then(changed=>{
      if(!changed)return;
      if(blocked(role,page,hiddenPages()))return;
      groups=menuForMe(role);flat=groups.flatMap(g=>g.items.map(i=>({...i,g:g.group})));drawSide();drawQuick();
      if(role!=="driver")bottomNav(page,role);
      pageTabs(page,role);
      document.dispatchEvent(new CustomEvent("erp:access"));
    });
    return {menu:groups};
  }

  // Page tabs (Mohit, 4 Nov 2026): pages merged into one menu item show a tab row on top,
  // only with the pages this login may open.
  const PAGE_TABS=[
    [["Driver Returns","driver-returns.html"],["Sales Return","sales-return.html"],["Credit Note","credit-note.html"]],
    [["Coca-Cola","rates.html"],["Rajnigandha","rajni-rates.html"]],
    [["Sales Tracking","sales-tracking.html"],["Party Buying","party-buying.html"]],
    [["Stock","inventory.html"],["Transit","stock-transit.html"],["Transfer","stock-transfer.html"],["Audit","stock-audit.html"],["Opening","opening-stock.html"]]
  ];
  function pageTabs(page,role){
    document.querySelector(".erp-ptabs")?.remove();
    const set=PAGE_TABS.find(t=>t.some(x=>x[1]===page));if(!set)return;
    const permitted=new Set(menuFor(role,hiddenPages(),extraPages()).flatMap(g=>g.items.map(i=>i.h.split("#")[0])));
    const tabs=set.filter(x=>permitted.has(x[1])||x[1]===page);if(tabs.length<2)return;
    const root=document.querySelector(".erp-main");if(!root)return;
    const nav=document.createElement("nav");nav.className="erp-ptabs";nav.setAttribute("aria-label","Pages");
    nav.innerHTML=tabs.map(([t,h])=>'<a href="'+h+'"'+(h===page?' class="on" aria-current="page"':"")+">"+esc(t)+"</a>").join("");
    root.prepend(nav);
  }

  // Small role-specific shortcuts; actual permission checks remain on each page / RPC.
  function bottomNav(page,role){
    document.querySelector(".erp-bnav")?.remove();
    document.body.classList.remove("has-bnav");
    if(page==="dashboard.html")return; // Dashboard uses its menu and search, without a fixed shortcut bar.
    const presets={
      sales:[["Home","dashboard.html","home"],["New Order","order-entry.html","cart"],["PO List","my-sales.html#orders","note"],["My Sales","my-sales.html","chart"]],
      admin:[["Home","dashboard.html","home"],["New Order","order-entry.html","cart"],["PO List","warehouse-orders.html","note"],["Stock","inventory.html","stock"]],
      manager:[["Home","dashboard.html","home"],["New Order","order-entry.html","cart"],["PO List","warehouse-orders.html","note"],["Dispatch","loading-dispatch.html","truck"]],
      accounts:[["Home","dashboard.html","home"],["Finance","finance.html","chart"],["Accounts","party-billing.html","bill"],["Ledger","accounts-books.html","book"]],
      cashier:[["Home","dashboard.html","home"],["Finance","finance.html","chart"],["Cashier","accounts-dashboard.html#cash","cash"]],
      warehouse:[["Home","dashboard.html","home"],["Loading","loading-dispatch.html","truck"],["Purchase","purchase-register.html","note"],["Stock","inventory.html","stock"]],
      transport:[["Home","dashboard.html","home"],["Assign","transport-allocation.html","truck"],["Vehicles","fleet-master.html#vehicles","box"],["Drivers","fleet-master.html#drivers","users"]]
    };
    const permitted=new Set(menuForMe(role).flatMap(g=>g.items.map(i=>i.h.split("#")[0])));
    let list=presets[role]||[];
    if(role==="manager"&&onDuty())list=list.slice(0,3).concat([["Cashier","accounts-dashboard.html#cash","cash"]],list.slice(3));   // today's cashier
    const items=list.filter(i=>permitted.has(i[1].split("#")[0]));
    if(items.length<2)return;
    const active=h=>(page==="accounts-dashboard.html"&&h==="party-billing.html")||h===(page+(location.hash||"")) || (!h.includes("#") && h===page && !items.some(i=>i[1]===(page+(location.hash||""))));
    const nav=document.createElement("nav");nav.className="erp-bnav";nav.setAttribute("aria-label","Quick menu");
    nav.innerHTML=items.map(([t,h,i])=>'<a href="'+h+'" class="'+(h==="order-entry.html"?"new":"")+(active(h)?" active":"")+'"'+(active(h)?' aria-current="page"':'')+'>'+svg(i)+"<span>"+esc(t)+"</span></a>").join("");
    document.body.appendChild(nav);document.body.classList.add("has-bnav");
    nav.dataset.page=page;
    if(!window.__lwbNavHash){window.__lwbNavHash=true;window.addEventListener("hashchange",()=>bottomNav(page,role))}
  }

  // Keep large reports scrollable inside their panel, rather than widening the phone page.
  function compactTables(){
    const root=document.querySelector(".erp-main");if(!root)return;
    const scan=()=>root.querySelectorAll("table").forEach(t=>{
      if(t.closest(".erp-data-scroll, .modal, .overlay, dialog") || t.id==="itemsTable")return;
      const p=t.parentElement;if(!p)return;
      if(/scroll|wrap|table/i.test(p.className)){p.classList.add("erp-data-scroll");return}
      const wrap=document.createElement("div");wrap.className="erp-data-scroll";
      t.before(wrap);wrap.append(t);
    });
    scan();
    let pending=false;
    new MutationObserver(()=>{if(pending)return;pending=true;requestAnimationFrame(()=>{pending=false;scan()})}).observe(root,{childList:true,subtree:true});
  }

  // While typing, the phone keyboard pushes fixed bars up over the page; hide them until typing ends.
  let keyboardWatching=false;
  function watchKeyboard(){
    if(keyboardWatching)return;keyboardWatching=true;
    const typing=el=>el&&(el.tagName==="TEXTAREA"||el.tagName==="SELECT"||el.isContentEditable||(el.tagName==="INPUT"&&!/^(button|submit|reset|checkbox|radio|file|range|color|image|hidden)$/i.test(el.type)));
    // Keyboard open = a text box has focus AND the visible screen is clearly shorter than
    // the full screen. A box that keeps focus after the keyboard is closed (iPhone Chrome)
    // no longer hides the bars.
    let fullH=0,fullW=0;
    const keyboardUp=()=>{
      const vv=window.visualViewport;if(!vv)return true;
      if(window.innerWidth!==fullW){fullW=window.innerWidth;fullH=0}
      fullH=Math.max(fullH,window.innerHeight,vv.height*vv.scale);
      return vv.height*vv.scale<fullH-150;
    };
    const sync=()=>document.body.classList.toggle("kb-open",typing(document.activeElement)&&keyboardUp());
    document.addEventListener("focusin",()=>{sync();setTimeout(sync,400)});
    document.addEventListener("focusout",()=>setTimeout(sync,60));
    if(window.visualViewport){window.visualViewport.addEventListener("resize",sync);window.visualViewport.addEventListener("scroll",sync)}
    window.addEventListener("scroll",sync,{passive:true});
  }

  // An ERP page whose menu entries are all unticked for this user: go to the
  // first page still open to them.
  function blocked(role,page,hidden){
    const mine=MENU.flatMap(g=>g.items).filter(i=>allowed(i,role)&&i.h.split("#")[0]===page);
    if(!mine.length||!mine.every(i=>hidden.includes(i.h)))return false;
    const first=menuFor(role,hidden,extraPages()).flatMap(g=>g.items)[0];
    if(first){location.replace(first.h);return true}
    document.body.innerHTML='<div style="font:16px system-ui;padding:40px 16px;text-align:center"><b>No ERP page is open for your login.</b><br>Please ask Admin to tick your pages in Manage Users.<br><br><a href="login.html">Back to Login</a></div>';
    return true;
  }

  async function refreshAccess(role){
    try{
      if(!window.supabase)return false;
      const c=window.__lwbBellClient||(window.__lwbBellClient=window.supabase.createClient(URL_,KEY_));
      const {data}=await c.auth.getSession();const user=data&&data.session&&data.session.user;if(!user)return false;
      let r=await c.from("lwb_user_page_access").select("hidden,extra").eq("user_id",user.id).maybeSingle();
      if(r.error)r=await c.from("lwb_user_page_access").select("hidden").eq("user_id",user.id).maybeSingle();
      if(r.error)return false; // setup SQL not run yet: role defaults only
      const before=JSON.stringify([hiddenPages(),extraPages()]),hidden=(r.data&&r.data.hidden)||[],extra=(r.data&&r.data.extra)||[];
      try{localStorage.setItem(ACCESS_KEY,JSON.stringify({uid:user.id,hidden,extra}))}catch(e){}
      // Sales Head: is he today's cashier (holds the cash box)? No SQL yet / error = no.
      if(String(role||mountedRole||"").toLowerCase()==="manager"){
        let d=null;try{const x=await c.rpc("lwb_acc_on_duty");d=!x.error&&x.data&&x.data.on_duty?x.data:null}catch(e){}
        try{localStorage.setItem(DUTY_KEY,JSON.stringify({uid:user.id,on:!!d,since:d&&d.since,amount:d&&d.amount}))}catch(e){}
      }else{try{localStorage.removeItem(DUTY_KEY)}catch(e){}}
      return JSON.stringify([hiddenPages(),extraPages()])!==before;
    }catch(e){return false}
  }

  // Driver, Salesman and Godown Manager (Mohit, 18 Nov 2026): these roles see no profit or sales reports,
  // so they stay logged in until they tap Logout themselves. Every other role keeps the 15-minute rule.
  // login.html uses the same role list (NO_IDLE_ROLES there).
  const NO_IDLE_ROLES=["driver","sales","warehouse"];
  function stayLoggedIn(role){return NO_IDLE_ROLES.includes(String(role||"").trim().toLowerCase())}
  // Auto logout after 1 hour (Mohit, 27 Nov 2026; was 15 minutes) with no tap, key or scroll. The time is shared by every ERP tab of
  // this browser, and is checked again when a phone comes back to the app. login.html sets it on login.
  const IDLE_MS=60*60e3,IDLE_KEY="lwbLastActive";
  let idleOn=false;
  function idleLogout(){
    if(idleOn)return;idleOn=true;
    const read=()=>{try{return Number(localStorage.getItem(IDLE_KEY))||0}catch(e){return 0}};
    let last=0,out=false;
    const mark=()=>{const now=Date.now();if(out||now-last<10e3)return;last=now;try{localStorage.setItem(IDLE_KEY,String(now))}catch(e){}};
    async function check(){
      const t=read();
      if(out||!t||Date.now()-t<IDLE_MS)return false;
      out=true;
      const c=window.__lwbBellClient||(window.__lwbBellClient=window.supabase.createClient(URL_,KEY_));
      try{localStorage.removeItem(IDLE_KEY)}catch(e){}
      // Fingerprint or MPIN on for this login on this phone: lock (session kept) instead of logout.
      let uid="";try{const {data}=await c.auth.getSession();uid=(data&&data.session&&data.session.user&&data.session.user.id)||""}catch(e){}
      if(lockOn(uid)){lockNow(uid,"idle");return true}
      try{await c.auth.signOut({scope:"local"})}catch(e){}
      location.replace("login.html?idle=1");
      return true;
    }
    check().then(gone=>{if(!gone)mark()});
    // Only real input counts: the browser also fires mousemove / scroll when the page itself changes.
    const real=e=>{if(e.isTrusted&&(e.type!=="mousemove"||e.movementX||e.movementY))mark()};
    ["pointerdown","keydown","touchstart","mousemove","wheel"].forEach(ev=>document.addEventListener(ev,real,{passive:true,capture:true}));
    document.addEventListener("visibilitychange",()=>{if(!document.hidden)check().then(gone=>{if(!gone)mark()})});
    setInterval(check,30e3);
  }

  // Profile > Login & Security (tap the round initial in the top bar, or Settings > Login & Security):
  // set / change / turn off the MPIN and turn fingerprint unlock on / off for this phone (quick-unlock.js,
  // lwb_mpin_setup.sql). Every role can open it.
  const mpinWho=u=>u&&u.email&&!/@staff\.lwb-erp\.in$/i.test(u.email)?u.email:"";
  function loadUnlock(){
    if(window.LWBUnlock)return Promise.resolve(window.LWBUnlock);
    return new Promise((ok,bad)=>{const s=document.createElement("script");s.src="quick-unlock.js?v=20261121b";s.onload=()=>ok(window.LWBUnlock);s.onerror=bad;document.head.appendChild(s)});
  }
  function unlockSetting(av,role){
    // Admin (27 Nov 2026): password only, no MPIN / fingerprint.
    if(!av||!appMode()||String(role||"").toLowerCase()==="admin")return;
    av.setAttribute("role","button");av.tabIndex=0;av.title="Login & Security (MPIN, fingerprint)";av.style.cursor="pointer";
    av.addEventListener("click",()=>openSecurity(role));
    av.addEventListener("keydown",e=>{if(e.key==="Enter"||e.key===" "){e.preventDefault();openSecurity(role)}});
  }
  let secOpen=false,mountedRole="";
  async function openSecurity(role){
    role=typeof role==="string"?role:mountedRole;
    if(secOpen||!window.supabase||!appMode()||String(role||"").toLowerCase()==="admin")return;secOpen=true;
    let U,user,c;
    try{
      U=await loadUnlock();
      c=window.__lwbBellClient||(window.__lwbBellClient=window.supabase.createClient(URL_,KEY_));
      const {data}=await c.auth.getSession();user=data&&data.session&&data.session.user;
    }catch(e){}
    if(!U||!user){secOpen=false;return}
    const back=document.createElement("div");back.className="erp-dlg-back";
    const box=document.createElement("div");box.className="erp-dlg erp-lsec";box.setAttribute("role","dialog");box.setAttribute("aria-modal","true");
    back.append(box);document.body.append(back);requestAnimationFrame(()=>back.classList.add("show"));
    const close=()=>{back.classList.remove("show");document.removeEventListener("keydown",esc_,true);setTimeout(()=>back.remove(),160);secOpen=false};
    const esc_=e=>{if(e.key==="Escape"){e.preventDefault();close()}};
    document.addEventListener("keydown",esc_,true);
    back.addEventListener("click",e=>{if(e.target===back)close()});
    const fpOk=await U.supported();
    let pinOn=null,busy=false;
    async function readPin(){
      try{const r=await c.rpc("lwb_mpin_status",{p_device:U.device()});
        if(r.error){pinOn=null;return}
        pinOn=r.data===true;
        try{if(!pinOn)localStorage.removeItem("lwbMpin");else{const o=JSON.parse(localStorage.getItem("lwbMpin")||"null");localStorage.setItem("lwbMpin",JSON.stringify({uid:user.id,at:Date.now(),who:o&&o.uid===user.id&&o.who||mpinWho(user)}))}}catch(e){}
      }catch(e){pinOn=null}
    }
    const badge=on=>'<span class="erp-sec-badge '+(on?"on":"off")+'">'+(on?"ON":"OFF")+'</span>';
    function main(){
      const fpOn=U.isOn(user.id);
      box.innerHTML='<h3>Login &amp; Security</h3><p class="erp-sec-sub">This phone · '+esc(user.email&&!/@staff\.lwb-erp\.in$/i.test(user.email)?user.email:"your login")+'</p>'+
        '<div class="erp-sec-row"><div><b>MPIN</b>'+(pinOn===null?'<small>Not set up yet. Ask Admin.</small>':badge(pinOn)+'<small>4 digits instead of password + OTP</small>')+'</div>'+
        '<div class="erp-sec-btns">'+(pinOn===null?"":pinOn?'<button type="button" data-a="pin" class="erp-sec-main">Change</button><button type="button" data-a="pinoff">Turn off</button>':'<button type="button" data-a="pin" class="erp-sec-main">Set MPIN</button>')+'</div></div>'+
        '<div class="erp-sec-row"><div><b>Fingerprint</b>'+(fpOk?badge(fpOn)+'<small>Fingerprint, face or phone lock</small>':'<small>Not available on this device</small>')+'</div>'+
        '<div class="erp-sec-btns">'+(fpOk?(fpOn?'<button type="button" data-a="fpoff">Turn off</button>':'<button type="button" data-a="fpon" class="erp-sec-main">Turn on</button>'):"")+'</div></div>'+
        (stayLoggedIn(role)?'<p class="erp-sec-note">You stay logged in until you tap Logout. With MPIN or fingerprint ON, Logout only <b>locks</b> the ERP. Open it again without password and OTP.</p>'
          :'<p class="erp-sec-note">With MPIN or fingerprint ON, Logout or 1 hour without work only <b>locks</b> the ERP. Open it again without password and OTP.</p>')+
        '<div class="erp-dlg-actions"><button type="button" class="erp-dlg-no" data-a="close">Close</button></div>';
      box.querySelectorAll("button[data-a]").forEach(b=>b.onclick=()=>act(b.dataset.a,b));
    }
    async function act(a,b){
      if(busy)return;
      if(a==="close")return close();
      if(a==="pin")return pinView();
      busy=true;b.disabled=true;
      try{
        if(a==="pinoff"){await U.mpinOff(c);pinOn=false;toast("MPIN turned off on this phone.")}
        if(a==="fpoff"){U.disable();toast("Fingerprint unlock turned off on this phone.")}
        if(a==="fpon"){try{await U.enable(user);if(pinOn)await U.mpinOff(c),pinOn=false;toast("Fingerprint unlock is on for this phone. MPIN is off.")}catch(e){if(e&&e.name!=="NotAllowedError")toast("Fingerprint could not be turned on: "+(e&&e.message||e),"error")}}
      }finally{busy=false;main()}
    }
    function pinView(){
      let first="";
      box.innerHTML='<h3 class="erp-sec-h"></h3><p class="erp-sec-sub erp-sec-msg"></p><div class="erp-sec-pin"></div>'+
        '<div class="erp-dlg-actions"><button type="button" class="erp-dlg-no" data-a="back">Back</button></div>';
      const h=box.querySelector(".erp-sec-h"),msg=box.querySelector(".erp-sec-msg");
      const say=(t,bad)=>{msg.textContent=t;msg.classList.toggle("bad",!!bad)};
      const step=n=>{h.textContent=n===1?(pinOn?"Enter new MPIN":"Set a 4-digit MPIN"):"Enter the same MPIN again";if(n===1)say("Avoid easy MPINs like 1111 or 1234.");else say("To confirm.")};
      const P=U.pad(box.querySelector(".erp-sec-pin"),{busy:()=>busy,onDone:async pin=>{
        if(!first){
          if(U.mpinWeak(pin)){P.clear(true);say("This MPIN is too easy (like 1111 or 1234). Choose another.",true);return}
          first=pin;P.clear();step(2);return;
        }
        if(pin!==first){first="";P.clear(true);step(1);say("Both MPINs did not match. Set it again.",true);return}
        busy=true;say("Saving...");
        try{await U.mpinSet(c,user.id,pin);pinOn=true;U.disable();busy=false;toast("MPIN is set for this phone. Fingerprint is off.");main()}
        catch(e){busy=false;first="";P.clear(true);step(1);say(e.message||String(e),true)}
      }});
      P.fingerprint(null);step(1);
      box.querySelector('[data-a="back"]').onclick=()=>{if(!busy)main()};
    }
    box.innerHTML='<h3>Login &amp; Security</h3><p class="erp-sec-sub">Loading...</p>';
    await readPin();main();
  }

  // A login that passed the password but no OTP (Authenticator aal2, or WhatsApp OTP saved
  // by lwb_whatsapp_otp_setup.sql) is sent back to Login.
  async function otpGuard(){
    try{
      const c=window.__lwbBellClient||(window.__lwbBellClient=window.supabase.createClient(URL_,KEY_));
      const {data,error}=await c.auth.mfa.getAuthenticatorAssuranceLevel();
      if(error||!data||data.currentLevel==="aal2")return;
      const {data:s}=await c.auth.getSession();if(!s||!s.session)return;
      const ok=await c.rpc("lwb_login_otp_ok");if(!ok.error&&ok.data===true)return;
      location.replace("login.html?otp=1");
    }catch(e){}
  }

  // 🔔 ERP notifications on every page, for every logged-in role (Driver too).
  async function bell(top,role){
    try{
      if(!window.supabase)return;
      const c=window.__lwbBellClient||(window.__lwbBellClient=window.supabase.createClient(URL_,KEY_));
      const {data}=await c.auth.getSession();const user=data&&data.session&&data.session.user;if(!user)return;
      // Login page "type your email, MPIN pad opens" needs the login name next to this phone's MPIN flag.
      try{const o=JSON.parse(localStorage.getItem("lwbMpin")||"null");if(o&&o.uid===user.id&&!o.who&&mpinWho(user)){o.who=mpinWho(user);localStorage.setItem("lwbMpin",JSON.stringify(o))}}catch(e){}
      if(!window.LWBOperationsNotifications)await new Promise((ok,bad)=>{const s=document.createElement("script");s.src="erp-operations-notifications.js";s.onload=ok;s.onerror=bad;document.head.appendChild(s)});
      window.LWBOperationsNotifications.init({db:c,user,role,mount:top.querySelector(".erp-user"),pages:menuForMe(role).flatMap(g=>g.items.map(i=>i.h.split("#")[0]))});
    }catch(e){}
    profitSwitch(top,role);
    // liveLocation();  // 📍 Switched OFF by the owner 23 Nov 2026: no location is asked or sent. Remove // to bring back.
    cashierChip(top,role);
    tripRent(role);
    eveningReport(role);
    teamChat(role);
    taskSiren(role);
  }

  // 💼 Today's cashier (Mohit, 26 Nov 2026): small chip in the top bar, only for Admin / Accounts / Sales Head
  // (and the Cashier role): "💼 Vishal" = who holds the cash box now (lwb_acc_shift_list holders).
  const CHIP_ROLES=["admin","accounts","manager","cashier"];
  async function cashierChip(top,role){
    try{
      if(!CHIP_ROLES.includes(role))return;
      const c=window.__lwbBellClient;if(!c)return;
      const draw=async()=>{
        // Cashier = latest receiver who is not Admin (Admin only keeps the cash at night, lwb_acc_cashier_admin_safe_setup.sql).
        let S=null,CS=[],HS=[];
        const r=await c.rpc("lwb_acc_today_cashier");
        if(!r.error&&r.data){S=r.data;CS=S.cashiers||[];HS=S.holders||[]}
        else{const o=await c.rpc("lwb_acc_shift_list",{p_from:null,p_to:null});S=!o.error&&o.data;HS=S&&S.holders&&S.holders.length?S.holders:S&&S.holder?[S.holder]:[];CS=HS;
          if(S&&S.pending)S.pending=S.pending.to_name;
          // both failed: show the reason in the chip instead of hiding it (Mohit 26 Nov 2026, Vishal saw nothing)
          if(!S){const e=(r.error&&r.error.message)||(o.error&&o.error.message)||"no data";let x=top.querySelector(".erp-cashier");
            if(!x){x=document.createElement("a");x.className="erp-cashier";const u=top.querySelector(".erp-user");if(!u)return;u.prepend(x)}
            x.textContent="💼 ⚠ "+String(e).slice(0,70);x.title="Cashier info did not load: "+e;x.removeAttribute("href");return}}
        let el=top.querySelector(".erp-cashier");
        if(!CS.length&&!HS.length){if(el)el.remove();return}
        if(!el){el=document.createElement("a");el.className="erp-cashier";const u=top.querySelector(".erp-user");if(!u)return;u.prepend(el)}
        const first=a=>a.map(h=>String(h.name||"").split(/\s+/)[0]).join(" + "),ids=a=>a.map(h=>h.id).sort().join();
        const me=CS.some(h=>h.id===S.me),t=v=>v?new Date(v).toLocaleTimeString("en-IN",{hour:"2-digit",minute:"2-digit",hour12:true,timeZone:"Asia/Kolkata"}):"";
        const apart=HS.length&&ids(HS)!==ids(CS);   // cash kept by someone else (Admin at night)
        el.classList.toggle("me",me);
        el.replaceChildren(document.createTextNode("💼 "));const lb=document.createElement("small");lb.textContent="Cashier:";const nm=document.createElement("b");
        nm.textContent=CS.length?(me?"You":first(CS)):"—";el.append(lb,nm);
        if(apart){const w=document.createElement("small");w.className="cw";w.textContent=" · cash with "+(HS.some(h=>h.id===S.me)?"you":first(HS));el.appendChild(w)}
        el.title="Today's cashier: "+(CS.length?CS.map(h=>h.name).join(" + ")+" · since "+t(CS[0].since):"not set")+
          (apart?"\nCash box with "+HS.map(h=>h.name).join(" + ")+" since "+t(HS[0].since):"")+(S.pending?"\nHanding to "+S.pending+" · waiting":"");
        el.setAttribute("aria-label",el.title);
        if(me||["admin","accounts","cashier"].includes(role))el.href="accounts-dashboard.html#cash";else el.removeAttribute("href");
        if(S.pending)cashAsk(c,role,draw);
      };
      await draw().catch(e=>{const x=document.createElement("a");x.className="erp-cashier";x.textContent="💼 ⚠ "+String(e&&e.message||e).slice(0,70);const u=top.querySelector(".erp-user");if(u)u.prepend(x)});setInterval(()=>{if(!document.hidden)draw().catch(()=>{})},60000);
      document.addEventListener("visibilitychange",()=>{if(!document.hidden)draw().catch(()=>{})});
    }catch(e){}
  }

  // 💼 Cash handed to me (Mohit, 26 Nov 2026): Vishal on the PO page got no sign, the Received ✓ bar was only on the
  // Dashboard. Now a popup comes on any page: Received ✓ or Later (asks again after 10 minutes).
  let cashAsking=false;
  async function cashAsk(c,role,redraw){
    if(cashAsking)return;cashAsking=true;
    try{
      const o=await c.rpc("lwb_acc_shift_list",{p_from:null,p_to:null});if(o.error||!o.data)return;
      const S=o.data,P=S.pending,mine=P&&(P.parts||[]).find(x=>x.to===S.me&&x.status==="PENDING");if(!mine)return;
      const k="lwbCashLater:"+mine.id;let t=0;try{t=Number(sessionStorage.getItem(k))||0}catch(e){}
      if(Date.now()-t<600000)return;
      const rs=v=>"₹"+Math.round(Number(v)||0).toLocaleString("en-IN");
      const split=(P.parts||[]).length>1?"\nCash split: "+P.parts.map(x=>String(x.to_name||"").split(/\s+/)[0]+" "+rs(x.amount)).join(" · "):"";
      const ok=await erpConfirm((P.by_name||"Someone")+" is handing you "+rs(mine.amount)+" cash."+"\n\nCount the cash first, then press Received ✓. If it is different, ask Accounts / Admin."+split,
        {title:"💼 Cash for you",ok:"Received ✓",cancel:"Later"});
      if(!ok){try{sessionStorage.setItem(k,String(Date.now()))}catch(e){}return}
      const x=await c.rpc("lwb_acc_shift_receive",{p_id:Number(mine.id),p_amount:null,p_note:null});
      if(x.error){await erpAlert(x.error.message);return}
      toast("Cash received "+rs(mine.amount));
      if(role==="manager"){setTimeout(()=>location.reload(),700);return}   // today's cashier: Cashier page comes into the menu
      redraw().catch(()=>{});
    }catch(e){}finally{cashAsking=false}
  }

  // 🚨 Urgent task siren: full-screen alarm + siren sound on any page when an urgent task rings
  // (task-siren.js, lwb_task_siren_setup.sql). Until the SQL is run nothing shows.
  async function taskSiren(role){
    try{
      const c=window.__lwbBellClient;if(!c||!role)return;
      const {data}=await c.auth.getSession();const user=data&&data.session&&data.session.user;if(!user)return;
      if(!window.LWBSiren)await new Promise((ok,bad)=>{const s=document.createElement("script");s.src="task-siren.js";s.onload=ok;s.onerror=bad;document.head.appendChild(s)});
      window.LWBSiren.init({db:c,user,role});
    }catch(e){}
  }

  // 🏷 ONE brand picker for the whole site, next to the page name (Mohit, 19 Nov 2026):
  // All brands / Coca-Cola / Rajnigandha / any company added later in Companies (lwb_companies).
  // The choice is kept on this device and every page (dashboard, Accounts, stock, PO list ...) shows
  // only that brand; All = every brand together. A Sales Head / Salesman tied to brands in Companies >
  // Team brands gets only those (the database already returns only his SKUs / POs), so one brand = a
  // fixed label, nothing to change. Godown Manager and Driver work on what is assigned: no picker.
  // Page brand chips / drop-downs are hidden and follow this one (brand-filter.js LWBBrand.pick).
  async function brandTop(top,role){
    try{
      if(!window.supabase||!role||role==="warehouse"||role==="driver"||top.querySelector(".erp-brandpick"))return;
      const c=window.__lwbBellClient||(window.__lwbBellClient=window.supabase.createClient(URL_,KEY_));
      const {data}=await c.auth.getSession();if(!data||!data.session)return;
      if(!window.LWBBrand)await new Promise((ok,bad)=>{const s=document.createElement("script");s.src="brand-filter.js";s.onload=ok;s.onerror=bad;document.head.appendChild(s)});
      const info=await window.LWBBrand.load(c);
      const list=(info.companies||[]).filter(x=>!info.mine||info.mine.includes(x.id));
      if(!list.length)return;
      const box=document.createElement("div");box.className="erp-brandpick";box.setAttribute("data-nosearch","");
      const crumb=top.querySelector(".erp-crumb");crumb.after(box);top.classList.add("has-brand");
      // Phone: the top bar has no room for a full name, so a short word shows (All / COCA / RAJNI);
      // tapping opens the normal list with the full names.
      const short=n=>String(n||"").trim().split(/[\s\-_/.]+/)[0].slice(0,5)||String(n||"").slice(0,5);
      const paint=id=>{const b=list.find(x=>x.id===id);box.style.setProperty("--bc",b?b.color||"#c9b26a":"#c9b26a");box.classList.toggle("on",!!b);
        const l=box.querySelector(".bp-l");if(l)l.textContent=b?short(b.name):"All"};
      if(list.length===1){
        box.classList.add("one");box.title="Your brand";box.innerHTML='<i></i><span class="bp-l">'+esc(short(list[0].name))+'</span><b>'+esc(list[0].name)+'</b>';box.querySelector(".bp-l").className="bp-s";paint(list[0].id);return;
      }
      const v=window.LWBBrand.get(list);
      const sel=document.createElement("select");sel.setAttribute("aria-label","Brand (whole site)");sel.title="Brand for every page";
      sel.innerHTML='<option value="">All brands</option>'+list.map(x=>'<option value="'+esc(x.id)+'">'+esc(x.name)+'</option>').join("");
      sel.value=v;box.innerHTML='<i></i><span class="bp-l"></span>';box.appendChild(sel);paint(v);
      sel.onchange=()=>{paint(sel.value);window.LWBBrand.pick(sel.value)};
      document.addEventListener("lwb:brand",e=>{const id=e.detail.id;if(sel.value!==id&&[...sel.options].some(o=>o.value===id)){sel.value=id;paint(id)}});
    }catch(e){}
  }

  // 📅 ONE date filter for the whole site, next to the brand picker (Mohit, 20 Nov 2026): Today / Yesterday /
  // 7 Days / 30 Days / This Month / Custom. Pages with dates load erp-period.js and follow it; their own date
  // filters are gone. Pages without dates (no erp-period.js) show no picker.
  function dateTop(top,role){try{if(window.LWBPeriod)window.LWBPeriod.mountTop(top,role)}catch(e){}}

  // 💬 Team Chat: round chat button in the corner of every page, popups for new messages (team-chat.js,
  // lwb_team_chat_setup.sql). Until the SQL is run the button does not show.
  async function teamChat(role){
    try{
      const c=window.__lwbBellClient;if(!c||!role)return;
      const {data}=await c.auth.getSession();const user=data&&data.session&&data.session.user;if(!user)return;
      if(!window.LWBChat)await new Promise((ok,bad)=>{const s=document.createElement("script");s.src="team-chat.js";s.onload=ok;s.onerror=bad;document.head.appendChild(s)});
      await window.LWBChat.init({db:c,user,role});
    }catch(e){}
  }

  // ⏳ Porter rent left empty at transport assignment: popup after 2 hours / at day close (trip-rent.js).
  async function tripRent(role){
    try{
      const c=window.__lwbBellClient;if(!c||!["admin","manager","transport"].includes(String(role||"").toLowerCase()))return;
      if(!window.LWBTrip)await new Promise((ok,bad)=>{const s=document.createElement("script");s.src="trip-rent.js";s.onload=ok;s.onerror=bad;document.head.appendChild(s)});
      window.LWBTrip.remind(c);
    }catch(e){}
  }

  // 🌙 Evening report: after today's cash handover, Admin gets "Download evening report" (PDF) on any page,
  // again every 5 minutes until it is downloaded (evening-report.js, lwb_evening_report_setup.sql).
  async function eveningReport(role){
    try{
      const c=window.__lwbBellClient;if(!c||String(role||"").toLowerCase()!=="admin")return;
      if(!window.LWBEvening)await new Promise((ok,bad)=>{const s=document.createElement("script");s.src="evening-report.js?v=20261126b";s.onload=ok;s.onerror=bad;document.head.appendChild(s)});
      window.LWBEvening.init({db:c,role});
    }catch(e){}
  }

  // 💜 "Profit ON/OFF" in the top bar: Admin always, others only when Admin allowed them (profit-view.js).
  async function profitSwitch(top,role){
    try{
      const c=window.__lwbBellClient;if(!c||role==="driver")return;
      if(!window.LWBProfit)await new Promise((ok,bad)=>{const s=document.createElement("script");s.src="profit-view.js";s.onload=ok;s.onerror=bad;document.head.appendChild(s)});
      await window.LWBProfit.init({client:c,mount:top.querySelector(".erp-user")});
    }catch(e){}
  }

  // 📍 Live Tracking: the phone shares its location while the ERP is open
  // (only roles + hours set on the Live Tracking page; see live-location.js).
  async function liveLocation(){
    try{
      const c=window.__lwbBellClient;if(!c)return;
      if(!window.LWBLocation)await new Promise((ok,bad)=>{const s=document.createElement("script");s.src="live-location.js?v=20261123c";s.onload=ok;s.onerror=bad;document.head.appendChild(s)});
      window.LWBLocation.start(c);
    }catch(e){}
  }

  // Older pages: <script src="erp-shell.js" data-auto defer>. Hides the page's
  // own header, wraps the page in the shell and reads the logged-in profile.
  const URL_="https://qstgwhbgbznxemajtave.supabase.co",KEY_="sb_publishable_YA2Pow327REqgrWPzVCZiA_nw1F32_o";
  async function auto(){
    const old=document.querySelector("body > header, body > .header");
    if(old)old.classList.add("erp-old-header");
    const wrap=document.createElement("div");wrap.className="erp-main";
    [...document.body.childNodes].forEach(n=>{if(!(n.nodeType===1&&n.tagName==="SCRIPT"))wrap.appendChild(n)});
    document.body.prepend(wrap);
    let role="",name="",client=null;
    try{
      client=window.supabase.createClient(URL_,KEY_);
      const {data}=await client.auth.getSession();
      const user=data&&data.session&&data.session.user;
      // Not logged in on this site (e.g. a new preview link): go to Login instead of showing page errors.
      if(!user){location.replace("login.html");return}
      if(user){
        const p=await client.from("user_profiles").select("role,full_name").eq("id",user.id).single();
        role=String((p.data&&p.data.role)||"").toLowerCase().trim();
        name=(p.data&&p.data.full_name)||user.email||"";
      }
    }catch(e){}
    mount({role,name,onLogout:async()=>{try{await client.auth.signOut()}catch(e){}location.replace("login.html")}});
  }
  // Esc closes the popup on top, on every ERP page (esc-close.js).
  if(!window.LWBEsc&&!document.querySelector('script[src*="esc-close.js"]')){const s=document.createElement("script");s.src="esc-close.js";document.head.appendChild(s)}
  // Every list row opens its detail (PO → items, party → bills): erp-list.js has the popup + LWBDrill.
  if(!window.ERPList&&!document.querySelector('script[src*="erp-list.js"]')){const s=document.createElement("script");s.src="erp-list.js";document.head.appendChild(s)}
  // Keyboard first: Enter = next field, arrows in lists, shortcuts (erp-keys.js).
  if(!window.LWBKeys&&!document.querySelector('script[src*="erp-keys.js"]')){const s=document.createElement("script");s.src="erp-keys.js";document.head.appendChild(s)}
  // Every drop-down searches like the SKU box in New PO (erp-select.js).
  if(!window.LWBSelect&&!document.querySelector('script[src*="erp-select.js"]')){const s=document.createElement("script");s.src="erp-select.js";document.head.appendChild(s)}
  window.ERPShell={mount,findModules,onDuty,dutyInfo,security:openSecurity,isApp:appMode,menuFor,viewOnly,menuForMe,hiddenPages,extraPages,pageRole,pageRoleFresh,allPages,icon:svg,alert:erpAlert,confirm:erpConfirm,prompt:erpPrompt,toast,done:erpDone};
  const me=document.currentScript;
  if(me&&me.hasAttribute("data-auto")){
    if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",auto);else auto();
  }
})();

/* Auto refresh on every ERP page (Mohit, 17 Nov 2026): after anything is saved / approved, the open page
   shows the new data by itself, without the browser Refresh, keeping filters, tab, scroll and popups.
   - This tab: a save that the page did not follow with its own reload -> the page's Refresh runs ~1 s later.
   - Other tabs, phones and users: the save sends a small "changed" note (Supabase Realtime broadcast, plus
     BroadcastChannel for tabs of this browser); every open ERP page gets it and refreshes within ~2-5 s.
   - Tab in the background: refreshes when it comes back. Waits while you type, scroll, select text or
     have a popup open, and runs at most once in 6 s (own save) / once in 20 s (other users' saves, so a
     busy office does not keep every open page reloading its whole list: speed fix, 17 Nov 2026).
   The page's own Refresh is used: window.ERPLiveRefresh(), [data-live-refresh], #refresh, #reload or
   #refreshBtn. A page without any of these is left as it is. ERPLive.quiet is true during an auto refresh
   so a page can skip its "Loading..." placeholder. Only the table / function name is sent, no data. */
(function(){
  if(window.ERPLive||!window.fetch)return;
  const PAGE=(location.pathname.split("/").pop()||"index.html");
  // Pages with a form being filled, or no list to refresh.
  const OFF=/^(login|index|order-entry|po-maker|sales-invoice-test|keyboard-shortcuts|offline|privacy|terms|share|404)(\.html)?$/;
  // Writes that are not business data (bells read, chat, GPS, phone alerts, PO drafts while typing, page access).
  const QUIET=/^(erp_notifications|lwb_po_drafts|lwb_sales_invoice_test_drafts|lwb_user_page_access)$|(^|_)(chat|track|tracking_ping|push|login|otp|location|ping|password|draft|drafts|recent)(_|$)/;
  const WRITE_RPC=/(^|_)(save\d*|set|add|approve|request|decide|delete|remove|cancel|create|mark|submit|send|post|receive|review|update|merge|run|start|step|resolve|assign|dispatch|printed|verify|fill|link|import|fix|unadjust|revoke|reply|close|sync|entry\d*|pay|arrived|upsert|edit|reset|returned|deposit|undeposit|reopen|unverify|undo|restore|modify|book)(_|$)/;
  const READ_END=/_(preview|list|queue|get|status|options|info)$/;
  const tabId=Math.random().toString(36).slice(2);
  const live={quiet:false,on:!OFF.test(PAGE),last:0,refreshing:false};
  const SELF_GAP=6000,OTHER_GAP=20000;
  let gesture=0,touch=0,inflight=0,lastRead=0,pending=false,pendingSelf=false,timer=0,seenIds=new Set();
  const gap=()=>pendingSelf?SELF_GAP:OTHER_GAP;

  // A write counts only right after a real tap / key (so an automatic reload never starts a refresh chain).
  ["pointerdown","keydown","touchstart"].forEach(ev=>document.addEventListener(ev,e=>{if(e.isTrusted){gesture=touch=Date.now()}},{capture:true,passive:true}));
  ["wheel","touchmove","scroll"].forEach(ev=>document.addEventListener(ev,()=>{touch=Date.now()},{capture:true,passive:true}));

  function classify(url,method){
    const m=/\/rest\/v1\/(rpc\/)?([a-z0-9_]+)/i.exec(url);if(!m)return null;
    const name=m[2].toLowerCase(),rpc=!!m[1];
    if(rpc?(method==="GET"||!WRITE_RPC.test(name.replace(/^lwb_/,""))||READ_END.test(name)):(method==="GET"||method==="HEAD"))return {read:true,name};
    return {write:true,name,quiet:QUIET.test(name)};
  }
  const nativeFetch=window.fetch.bind(window);
  window.fetch=function(input,init){
    let info=null;
    try{
      const url=typeof input==="string"?input:(input&&input.url)||"";
      const method=String((init&&init.method)||(input&&input.method)||"GET").toUpperCase();
      if(url.indexOf("/rest/v1/")>0)info=classify(url,method);
    }catch(e){}
    if(!info)return nativeFetch(input,init);
    inflight++;
    if(info.read)lastRead=Date.now();
    const userWrite=info.write&&!live.refreshing&&Date.now()-gesture<60e3;
    return nativeFetch(input,init).then(res=>{
      inflight--;
      if(userWrite&&res&&res.ok)wrote(info);
      return res;
    },err=>{inflight--;throw err});
  };

  // ---- after a save ----
  let sendTimer=0,sendNames=new Set();
  function wrote(info){
    const at=Date.now();
    // This tab: if the page itself reads again within 1.2 s it has reloaded; otherwise run its Refresh.
    setTimeout(()=>{if(lastRead<at)want("self")},1200);
    if(info.quiet)return;
    sendNames.add(info.name);
    clearTimeout(sendTimer);sendTimer=setTimeout(()=>{const t=[...sendNames];sendNames.clear();announce(t)},400);
  }
  let bc=null;try{bc=new BroadcastChannel("lwb-live")}catch(e){}
  let chan=null,chanReady=false;
  function announce(tables){
    const msg={id:tabId+"-"+Date.now(),from:tabId,page:PAGE,t:tables.slice(0,8),at:Date.now()};
    try{bc&&bc.postMessage(msg)}catch(e){}
    try{if(chan&&chanReady)chan.send({type:"broadcast",event:"changed",payload:msg})}catch(e){}
  }
  function heard(msg){
    if(!msg||msg.from===tabId||!msg.id||seenIds.has(msg.id))return;
    seenIds.add(msg.id);if(seenIds.size>200)seenIds=new Set([...seenIds].slice(-100));
    want("other");
  }
  if(bc)bc.onmessage=e=>heard(e.data);
  function connect(){
    if(chan||!live.on||!window.supabase)return;
    try{
      const c=window.__lwbBellClient||(window.__lwbBellClient=window.supabase.createClient("https://qstgwhbgbznxemajtave.supabase.co","sb_publishable_YA2Pow327REqgrWPzVCZiA_nw1F32_o"));
      chan=c.channel("lwb-live",{config:{broadcast:{self:false}}});
      chan.on("broadcast",{event:"changed"},p=>heard(p&&p.payload));
      chan.subscribe(s=>{chanReady=s==="SUBSCRIBED";dot()});
    }catch(e){chan=null}
  }

  // ---- refresh the page when it is free ----
  function refresher(){
    if(typeof window.ERPLiveRefresh==="function")return window.ERPLiveRefresh;
    const b=document.querySelector("[data-live-refresh],#refresh,#reload,#refreshBtn");
    if(!b||b.disabled||b.offsetParent===null)return null;
    return ()=>b.click();
  }
  function popupOpen(){
    if(document.querySelector(".erp-dlg-back,.cv-back,.erp-ls-back,dialog[open],body.cv-open"))return true;
    // Any other popup: whatever is in the middle of the screen sits in a fixed layer (not the top bar).
    const x=innerWidth/2,y=innerHeight/2;let n=document.elementFromPoint(x,y);
    for(;n&&n!==document.body;n=n.parentElement){
      const cs=getComputedStyle(n);
      if(cs.position==="fixed"&&!n.classList.contains("erp-top"))return n.offsetWidth>innerWidth*.5||n.offsetHeight>innerHeight*.5;
    }
    return false;
  }
  function busyNow(){
    if(document.hidden)return "hidden";
    const a=document.activeElement;
    if(a&&(a.isContentEditable||a.tagName==="TEXTAREA"||(a.tagName==="INPUT"&&!/^(button|submit|checkbox|radio|range|color|file|reset)$/i.test(a.type))))return "typing";
    if(Date.now()-touch<4000)return "using";
    try{if(String(getSelection()||"").trim())return "selecting"}catch(e){}
    if(popupOpen())return "popup";
    if(inflight>0)return "loading";
    if(Date.now()-live.last<gap())return "soon";
    return "";
  }
  function want(why){
    if(!live.on)return;
    pending=true;if(why!=="other")pendingSelf=true;clearTimeout(timer);timer=setTimeout(tryRun,why==="self"?0:800+Math.random()*1200);
  }
  function tryRun(){
    clearTimeout(timer);
    if(!pending)return;
    const b=busyNow();
    if(b==="hidden")return; // visibilitychange runs it
    if(b){timer=setTimeout(tryRun,b==="soon"?gap()-(Date.now()-live.last)+50:1500);return}
    const fn=refresher();if(!fn){pending=pendingSelf=false;return}
    pending=pendingSelf=false;run(fn);
  }
  async function run(fn){
    const keep=[[window,scrollX,scrollY]];
    document.querySelectorAll("[id]").forEach(el=>{if(el.scrollTop>0||el.scrollLeft>0)keep.push([el.id,el.scrollLeft,el.scrollTop])});
    live.refreshing=live.quiet=true;live.last=Date.now();dot("busy");
    try{const r=fn();if(r&&typeof r.then==="function")await r}catch(e){}
    // Wait until the page's reads are done (max 15 s), then put the scroll back.
    const t0=Date.now();while(inflight>0&&Date.now()-t0<15e3)await new Promise(ok=>setTimeout(ok,120));
    await new Promise(ok=>requestAnimationFrame(()=>setTimeout(ok,30)));
    keep.forEach(([el,x,y])=>{
      if(el===window){if(Math.abs(scrollY-y)>2&&Date.now()-touch>1500)scrollTo(x,y);return}
      const n=document.getElementById(el);if(n&&Math.abs(n.scrollTop-y)>2){n.scrollLeft=x;n.scrollTop=y}
    });
    live.refreshing=live.quiet=false;live.last=Date.now();dot("done");
  }
  document.addEventListener("visibilitychange",()=>{if(!document.hidden&&pending)timer=setTimeout(tryRun,600)});

  // ---- small "Live" dot in the top bar ----
  let dotEl=null,dotT=0;
  function dot(state){
    if(!live.on)return;
    if(!dotEl){
      const u=document.querySelector(".erp-top .erp-user");if(!u)return;
      dotEl=document.createElement("span");dotEl.className="erp-live";dotEl.setAttribute("role","status");
      dotEl.innerHTML='<i aria-hidden="true"></i><span>Live</span>';u.prepend(dotEl);
    }
    const at=live.last?new Date(live.last).toLocaleTimeString("en-IN",{hour:"2-digit",minute:"2-digit",hour12:false,timeZone:"Asia/Kolkata"}):"";
    dotEl.classList.toggle("off",!chanReady&&!bc);
    dotEl.title="Auto refresh is on: changes saved by anyone show here by themselves."+(at?"\nLast auto update: "+at:"");
    if(state==="busy"){dotEl.classList.add("busy");dotEl.lastChild.textContent="Updating"}
    if(state==="done"){clearTimeout(dotT);dotEl.classList.remove("busy");dotEl.classList.add("done");dotEl.lastChild.textContent="Updated";
      dotT=setTimeout(()=>{dotEl.classList.remove("done");dotEl.lastChild.textContent="Live"},2500)}
  }
  function boot(){connect();dot();if(!dotEl){let n=0;const iv=setInterval(()=>{dot();if(dotEl||++n>20)clearInterval(iv)},500)}}
  if(live.on){if(document.readyState==="complete")setTimeout(boot,800);else addEventListener("load",()=>setTimeout(boot,800))}

  window.ERPLive={get quiet(){return live.quiet},get on(){return live.on},set on(v){live.on=!!v;if(!v&&dotEl)dotEl.remove()},
    refresh:()=>want("api"),changed:t=>announce([].concat(t||"manual")),_classify:classify};
})();
