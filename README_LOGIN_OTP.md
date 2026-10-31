# LWB — Login OTP (WhatsApp + Authenticator app)

After the password, every ERP login needs a 6-digit OTP:

- **WhatsApp OTP** to the user's Login Mobile (Manage Users), when WhatsApp is set up.
- **Authenticator app** (Google Authenticator) for users with no Login Mobile,
  while WhatsApp is not set up, or by choice ("Verify with Authenticator app").

Until steps 1-4 are done, login keeps using the Authenticator app. Nothing breaks.

## 1. SQL — run once

Supabase SQL Editor: run [`lwb_whatsapp_otp_setup.sql`](./lwb_whatsapp_otp_setup.sql).
(`lwb_login_otp_setup.sql` for the Authenticator "Reset OTP" button should already be run.)

## 2. Meta WhatsApp template

Meta Business Manager -> WhatsApp Manager -> Message Templates -> Create template:

- **Category**: Authentication
- **Name**: `lwb_login_otp`
- **Language**: English (US) (`en_US`)
- **Code delivery**: Copy code
- Optional: tick "Add security recommendation" and set expiry **5 minutes**.

Submit and wait until it shows **Approved** (usually minutes).

## 3. Secrets

Uses the same Edge Function secrets as the driver WhatsApp message
(Supabase -> Edge Functions -> Secrets):
`WA_ACCESS_TOKEN`, `WA_PHONE_NUMBER_ID`. Optional: `WA_OTP_TEMPLATE_NAME`
(default `lwb_login_otp`), `WA_OTP_TEMPLATE_LANG` (default `en_US`).

## 4. Deploy the Edge Function

Supabase -> Edge Functions -> Deploy a new function -> Via Editor.
Name exactly **`login-whatsapp-otp`**, paste
[`supabase/functions/login-whatsapp-otp/index.ts`](./supabase/functions/login-whatsapp-otp/index.ts),
keep **Verify JWT ON**, Deploy.

CLI instead: `supabase functions deploy login-whatsapp-otp`.

## 5. Test

Log out, log in with a user that has a Login Mobile: a WhatsApp message with the
code should arrive. Wrong code shows an error; after 5 wrong tries or 5 minutes
use **Resend OTP** (max 6 per hour).

## Notes

- Cost: Meta charges per authentication message (India approx ₹0.12-0.15).
- The code is kept only as a hash; the verified login is tied to that one login
  session, so a new device or a logout needs a new OTP.
- OTP is checked by the login page and every ERP page. Database rules (RLS) do
  not yet require it.
