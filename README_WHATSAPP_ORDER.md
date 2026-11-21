# LWB — Customer orders on WhatsApp (number 99926 99905)

Customer writes "Hi" / "Order" (or taps **Order करें** on our template) → picks brand → products → cases →
**ऑर्डर भेजो** → gets "ऑर्डर मिल गया W-25". The order goes to the same place as website orders
(`lwb_web_order_intake`, channel WHATSAPP): number on one party = pending PO at once, else **Sales > Website Orders**.

Code: `supabase/functions/lwb-wa-order` (logic.js = chat steps, tested in `tests/whatsapp-order`),
`functions/api/whatsapp.js` (our domain → Edge Function), `lwb_whatsapp_order_setup.sql`. All deploy / run on merge.

## One-time setup (Admin)

1. **App Secret** → Supabase → Edge Functions → Secrets → add `WA_APP_SECRET` = Meta App Dashboard → App settings → Basic → App secret.
   (`WA_ACCESS_TOKEN`, `WA_PHONE_NUMBER_ID` are already there.) Never paste it in chat.
2. **Webhook** → Meta App Dashboard → WhatsApp → Configuration → Webhook → Edit:
   - Callback URL: `https://luxurywristbrand.com/api/whatsapp`
   - Verify token: `lwb-wa-order` (or set your own in secret `WA_VERIFY_TOKEN`)
   - Verify and save, then under Webhook fields **Subscribe** to `messages`.
3. Test: send "Hi" to 99926 99905 from any phone.

## Template to invite customers (Marketing, name `lwb_order_invite`, Hindi)
- Header: image (logo / products)
- Body: `नमस्ते {{1}} 🙏 Luxury Wrist Brand से आज का ऑर्डर दीजिए। Coca-Cola, Rajnigandha और बाकी सभी प्रोडक्ट। नीचे Order करें दबाइए, 1 मिनट में ऑर्डर बुक।`
- Footer: `Luxury Wrist Brand, Surat`
- Button: Quick reply `Order करें`

Cost (approx., Meta changes it): replies within 24 h of the customer's message are free; each template
message ~₹0.80–0.90 (marketing) / ~₹0.12–0.15 (utility).
