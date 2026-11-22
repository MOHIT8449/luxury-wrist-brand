// Pure helpers: identical endpoint checks at registration and delivery prevent SSRF.
export const PUSH_HOSTS = new Set(['fcm.googleapis.com','updates.push.services.mozilla.com','web.push.apple.com']);
export function validEndpoint(raw) {
 try {const u=new URL(String(raw));return u.protocol==='https:' && !u.username && !u.password && !u.port && !u.hash && u.pathname!=='/' && PUSH_HOSTS.has(u.hostname);} catch {return false;}
}
export function safeRoute(type, order, role) {
 const id=order ? '?order='+encodeURIComponent(String(order)) : '';
 if(type==='ORDER_NEW')return '/warehouse-orders.html'+id;
 const o=order ? encodeURIComponent(String(order)) : '';
 if(type==='PO_RATE_APPROVAL')return '/warehouse-orders.html'+(o?'?rate='+o:'');
 if(type==='RATE_APPROVAL')return '/quick-slip.html'+(o?'?review='+o:'');
 if(type==='PO_RATE_APPROVED'||type==='ORDER_RATE_CHECK')return '/warehouse-orders.html'+id;
 if(type.startsWith('LOADING_ASSIGNMENT_DRIVER'))return '/driver-delivery.html'+id;
 if(type.startsWith('LOADING_ASSIGNMENT'))return '/loading-dispatch.html'+id;
 if(type==='TALLY_BILL_PENDING')return '/accounts-invoice.html'+id;
 if(type.startsWith('DELIVERY_RETURN'))return (role==='driver'?'/driver-delivery.html':'/driver-returns.html')+id;
 if(type.startsWith('DELIVERY_COLLECTION'))return (role==='driver'?'/driver-delivery.html':'/driver-collections.html')+id;
 if(type==='SALES_RETURN_NEW')return '/sales-return.html';
 if(type.startsWith('COMPLAINT'))return '/complaint-box.html';
 if(type.startsWith('TASK_'))return '/tasks.html';
 if(type==='CHAT_MSG')return '/dashboard.html#chat';
 if(type.startsWith('GODOWN'))return '/godown-report.html';
 if(type.startsWith('MARKET'))return '/market-report.html';
 if(type==='ACC_CHEQUE_REMINDER'&&(role==='admin'||role==='accounts'))return '/accounts-dashboard.html#cheques';
 if(type.startsWith('ACC_')&&(role==='admin'||role==='accounts'))return '/accounts-dashboard.html';
 if(type==='LOCATION_OFF'&&role==='admin')return '/live-tracking.html?show=off';
 if(type.startsWith('DOC_')&&(role==='admin'||role==='accounts'))return '/documents.html';
 return '/dashboard.html';
}
export function messageFor(n,role) {
 const type=String(n.notification_type||'').replace(/^CC_/,'');
 const msg={title:'Luxury Wrist Brand · '+String(n.title||'ERP update').slice(0,80),
 body:String(n.message||'Open the app to view this update.').replace(/[\r\n]+/g,' ').slice(0,240),
 url:safeRoute(type,n.order_id,role),tag:'lwb-'+String(n.id),user_id:n.user_id};
 // 🚨 Urgent task siren (lwb_task_siren_setup.sql): stays on screen, long vibration, one banner per task,
 // opens the full-screen alarm in the app (task-siren.js).
 if(type==='TASK_SIREN'){
  const id=(/^TSK-(\d+|DEMO) /.exec(String(n.message||''))||[])[1]||'';
  return {...msg,title:String(n.title||'🚨 URGENT task').slice(0,90),url:'/tasks.html'+(id?'?siren='+id.toLowerCase():''),
   tag:'lwb-siren-'+(id||n.id),siren:true};
 }
 return msg;
}

// Salesmen get their order updates (approved, out for delivery, bill, delivered, payment) since 17 Nov 2026;
// live GPS / tracking and vehicle-loading assignment alerts stay off for them (lwb_order_updates_everyone_setup.sql).
export function suppressSalesOrderAlert(n, role) {
 return ['sales','salesman'].includes(String(role||'').trim().toLowerCase()) &&
  /^(CC_)?(LIVE_|GPS_|TRACK|LOADING_ASSIGNMENT)/i.test(String(n.notification_type||''));
}
