# LWB — Automatic Driver WhatsApp Loading Notifications

This module automatically *attempts* to send an approved Meta WhatsApp
message when a Sales Head or Transport Team user saves a Driver + Vehicle
assignment **and confirms driver WhatsApp opt-in**.

**Important deployment difference**:
- GitHub -> Cloudflare Pages deploys `warehouse-orders.html`,
  `transport-allocation.html`, and `driver-whatsapp.js`.
- A Supabase Edge Function is **NOT** deployed by Cloudflare Pages. You must
  deploy it separately to Supabase and configure Meta Cloud API secrets.
- Until the Edge Function is deployed and the approved Meta template is
  configured, ERP assignments still save, but WhatsApp delivery does NOT work.

## 1. Database SQL — run once

Open Supabase SQL Editor for project `txkbhadzdbxpieunfvox`.

Copy and run the full script:
[`lwb_driver_whatsapp_setup.sql`](./lwb_driver_whatsapp_setup.sql)

Expect `public.lwb_driver_whatsapp_log` in the SQL Results. This audit table:
- records Meta-accepted, failed, in-progress and uncertain attempts;
- deduplicates assignment + message fingerprint + SKU part;
- provides SELECT permission only to authorized active ERP managers/transport;
- cannot be written by browser users;
- does **not** change existing PO/Invoice/Stock/Outstanding data.

## 2. Create an approved Meta WhatsApp Message Template

In Meta Business Manager -> WhatsApp Manager -> Message Templates, create:

- **Name**: `lwb_driver_loading_assignment`
- **Category**: Utility (subject to Meta approval/classification)
- **Language**: English (US), template code `en_US`
- **Header**: None
- **Buttons**: None
- **Body**: Copy exactly as below (eight placeholders in numerical order).

```text
LWB Loading Assignment
PO: {{1}}
Party: {{2}}
Driver: {{3}}
Vehicle: {{4}}
Dispatch Team: {{5}}
SKU / CS (Part {{6}}):
{{7}}
Total Approved: {{8}} CS

Please check all SKUs and cases before vehicle loading.
```

Provide Meta with representative samples for ALL EIGHT placeholders:
1. `LXY-00004`
2. `SHREE JAGDISH TRADERS`
3. `MOHIT`
4. `GJ05FW9821`
5. `DHRUV`
6. `1/1`
7. `300ML THUMSUP: 351 CS` (or a representative multiline SKU list)
8. `406`

Wait until Meta marks the template **Approved**. The template name,
language code, body and number of placeholders must match the function.
Meta may require edits to approve the category or formatting; update both
template and function consistently if that happens.

**Opt-in**: Obtain each driver's explicit consent to WhatsApp notifications
from Luxury Wrist Brand before checking the confirmation checkbox. Respect
driver opt-out requests. Never send unsolicited WhatsApp messages.

## 3. Configure secure Meta Cloud API access

Your business needs:
- an active WhatsApp Business Platform / Cloud API sender number;
- its **Phone Number ID** (a numeric identifier; NOT your visible phone number);
- an access token with the correct WhatsApp messaging permission;
- the Approved message template from Step 2.

Never paste or publish the Meta token in GitHub, HTML, JavaScript, or a chat.

Open Supabase project -> **Edge Functions -> Secrets**:
https://supabase.com/dashboard/project/txkbhadzdbxpieunfvox/functions/secrets

Set:

| Secret name | Value |
|---|---|
| `WA_ACCESS_TOKEN` | Private permanent/system-user Meta access token |
| `WA_PHONE_NUMBER_ID` | Meta WhatsApp Phone Number ID |

Optional settings (normally leave defaults):

| Name | Default |
|---|---|
| `WA_GRAPH_VERSION` | `v26.0` |
| `WA_TEMPLATE_NAME` | `lwb_driver_loading_assignment` |
| `WA_TEMPLATE_LANG` | `en_US` |

The Edge Function uses an **injected Supabase server secret key** to read
saved assignment and PO rows, with independent JWT + role validation.
If your hosted project has no injected server secret, create a separate
`LWB_DB_SECRET_KEY` only in **Supabase Edge Function Secrets** (never client code).

## 4. Deploy the Edge Function in Supabase

Open:
https://supabase.com/dashboard/project/txkbhadzdbxpieunfvox/functions

Create/deploy a new Edge Function **named exactly**
`driver-assignment-whatsapp`.

Paste the full source from:
[`supabase/functions/driver-assignment-whatsapp/index.ts`](./supabase/functions/driver-assignment-whatsapp/index.ts)

Click **Deploy Function**. Leave **Verify JWT / require authentication ON**.
Our code additionally verifies the active ERP user role server-side.

If deploying via Supabase CLI instead:
```bash
supabase login
supabase link --project-ref txkbhadzdbxpieunfvox
supabase functions deploy driver-assignment-whatsapp
```

Do not deploy with `--no-verify-jwt` for this authenticated-user function.

## 5. Test on a REAL, authorized approved PO

Cloudflare Pages frontend URL:
- Sales Head: https://luxury-wrist-brand.pages.dev/warehouse-orders.html
- Transport Allocation: https://luxury-wrist-brand.pages.dev/transport-allocation.html

After Cloudflare deploy, use Ctrl+Shift+R.

1. Open an approved, not-yet-loaded PO.
2. Assign a valid Driver Name, Indian 10-digit Driver WhatsApp Mobile,
   Vehicle Number and Dispatch Team / Loading Person.
3. Verify **real driver opt-in** and check the opt-in box.
4. Click **Save Driver & Vehicle** or **Save Allocation**.
5. ERP saves the assignment first, then automatically invokes the
   secured Edge Function. **No separate Send button needed.**
6. Sales Head UI shows whether Meta accepted all SKU parts.
   A **Send / Retry WhatsApp** control exists for an already saved PO.
   Accepted messages are not sent again for unchanged content.

Approved SKUs/CS are read from the saved `order_items` rows on the backend,
not from browser-supplied text. All positive-quantity approved SKU lines
are included. Large SKU lists are partitioned into multiple approved
template messages (each part explicitly numbered).

The function recognizes **only Indian +91 / 10-digit mobile numbers**.
If a driver is missing a valid number or opt-in, ERP assignment can still
save but WhatsApp will not send.

## 6. Check message status

```sql
SELECT created_at,order_id,part_no,part_count,
       right(recipient_mobile,4) AS mobile_last4,
       status,meta_message_id,error_message
FROM public.lwb_driver_whatsapp_log
ORDER BY created_at DESC
LIMIT 30;
```

- `accepted`: Meta Cloud API returned a message ID; this does NOT prove the
  driver's handset received or read it.
- `failed`: definite Meta API rejection; can retry.
- `sending`: another request is in progress; do not duplicate.
- `unknown`: network result uncertain; verify in Meta Manager before retry.
- Multiple SKU chunks can incur multiple Meta template-message charges.
- For definitive **delivered/read** status, a separate signed Meta webhook is
  required and is NOT yet implemented.

## What this feature does NOT do

- Does not send messages to WhatsApp Groups automatically.
- Does not send from the personal WhatsApp app.
- Does not create Tally Invoices, change stock or post accounts entries.
- Does not notify on Approved PO alone; driver + vehicle must actually be saved.
- Does not guarantee delivery if the browser closes before the post-save
  function invocation; a future durable background outbox/worker can add that
  guarantee if needed.

Meta template sending API:
https://developers.facebook.com/docs/whatsapp/cloud-api/
Supabase dashboard Edge Functions:
https://supabase.com/docs/guides/functions/quickstart-dashboard
