// WhatsApp order webhook on our own domain (Mohit, 21 Nov 2026): Meta calls
// https://luxurywristbrand.com/api/whatsapp ; this passes the call unchanged to the Supabase
// Edge Function lwb-wa-order, which checks Meta's signature and answers the customer.
const TARGET = "https://qstgwhbgbznxemajtave.supabase.co/functions/v1/lwb-wa-order";

export async function onRequest({ request }) {
  if (request.method !== "GET" && request.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const url = new URL(request.url);
  const headers = { "content-type": request.headers.get("content-type") || "application/json" };
  const sig = request.headers.get("x-hub-signature-256");
  if (sig) headers["x-hub-signature-256"] = sig;
  const r = await fetch(TARGET + url.search, {
    method: request.method, headers,
    body: request.method === "POST" ? await request.text() : undefined,
  });
  return new Response(await r.text(), { status: r.status, headers: { "content-type": "text/plain; charset=utf-8" } });
}
