// Pure helpers: identical endpoint checks at registration and delivery prevent SSRF.
export const PUSH_HOSTS = new Set(['fcm.googleapis.com','updates.push.services.mozilla.com','web.push.apple.com']);
export function validEndpoint(raw) {
 try {const u=new URL(String(raw));return u.protocol==='https:' && !u.username && !u.password && !u.port && !u.hash && u.pathname!=='/' && PUSH_HOSTS.has(u.hostname);} catch {return false;}
}
export function safeRoute(type, order, role) {
 const id=order ? '?order='+encodeURIComponent(String(order)) : '';
 if(type==='ORDER_NEW')return '/warehouse-orders.html'+id;
 if(type.startsWith('LOADING_ASSIGNMENT_DRIVER'))return '/driver-delivery.html'+id;
 if(type.startsWith('LOADING_ASSIGNMENT'))return '/loading-dispatch.html'+id;
 if(type==='TALLY_BILL_PENDING')return '/accounts-invoice.html'+id;
 if(type.startsWith('DELIVERY_RETURN'))return (role==='driver'?'/driver-delivery.html':'/driver-returns.html')+id;
 if(type.startsWith('DELIVERY_COLLECTION'))return (role==='driver'?'/driver-delivery.html':'/driver-collections.html')+id;
 if(type==='SALES_RETURN_NEW')return '/sales-return.html';
 if(type.startsWith('COMPLAINT'))return '/complaint-box.html';
 if(type.startsWith('GODOWN'))return '/godown-report.html';
 if(type.startsWith('MARKET'))return '/market-report.html';
 return '/dashboard.html';
}
export function messageFor(n,role) {
 const type=String(n.notification_type||'').replace(/^CC_/,'');
 return {title:'Luxury Wrist Brand · '+String(n.title||'ERP update').slice(0,80),
 body:String(n.message||'Open the app to view this update.').replace(/[\r\n]+/g,' ').slice(0,240),
 url:safeRoute(type,n.order_id,role),tag:'lwb-'+String(n.id),user_id:n.user_id};
}
