// Send everyone to our own domain.
// - luxury-wrist-brand.pages.dev (old production address) -> https://luxurywristbrand.com
// - www.luxurywristbrand.com -> https://luxurywristbrand.com
// Same path, query and #hash are kept, so open links, password-reset links
// and notification links still land on the right page.
// Branch previews (xxx.luxury-wrist-brand.pages.dev) are NOT redirected.
const OWN = "luxurywristbrand.com";
const MOVE = new Set(["luxury-wrist-brand.pages.dev", "www.luxurywristbrand.com"]);

// Android app download on our own domain (Mohit, 22 Nov 2026): /app.apk -> latest signed APK.
const APK = "https://github.com/MOHIT8449/luxury-wrist-brand/releases/download/android-app/lwb-erp.apk";

export async function onRequest({ request, next }) {
  const url = new URL(request.url);
  if (url.hostname === OWN && (url.pathname === "/app.apk" || url.pathname === "/app")) {
    return Response.redirect(APK, 302);
  }
  if (MOVE.has(url.hostname)) {
    url.protocol = "https:";
    url.hostname = OWN;
    url.port = "";
    return Response.redirect(url.toString(), 301);
  }
  return next();
}
