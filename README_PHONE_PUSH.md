# Phone notifications — LWB ERP

Push updates are generated from **new** `erp_notifications` rows. The existing order / assignment / delivery workflow still decides each recipient. Old notifications are not replayed. Sales Head CC copies stay in the bell to avoid duplicate phone alerts.

## Staff: enable once on each phone

1. Update the Android app using the signed `android-app` release APK when installing the notification-permission update. Keep the existing app / login; install the update over it.
2. Open the ERP app, sign in, tap **🔔**, then **Enable phone alerts** and **Allow**.
3. Tap **Test**. Check the phone's notification panel, then tap the notification. Provider acceptance alone is not proof that the phone displayed it.

Each staff member enables alerts with their own ERP login. **Turn off** disconnects the current device. Explicit sign-out clears the device identity and unsubscribes it; the server also removes expired provider endpoints. On iPhone/iPad use the ERP installed on the Home Screen, then grant permission inside it. Browser / OS support, connection, battery restrictions, notification-channel settings and Do Not Disturb can affect timing, sound and banners. No app can guarantee a sound or heads-up banner against OS settings.

## Deployment

- Apply `lwb_web_push_setup.sql` using a privileged migration connection. It creates private, RLS-protected config / subscription / job / delivery tables, narrow authenticated registration RPCs, an insert trigger and a one-minute retry job. It does not alter business records or user roles.
- Deploy `supabase/functions/lwb-web-push` with `verify_jwt=false` as declared in `supabase/config.toml`. Dispatch/bootstrap authenticate with the dedicated server-only webhook secret; setup/test authenticate the user's JWT and active database profile. Only Admin can activate keys; test sends only to the caller's registered endpoint.
- Run the server bootstrap (no secret values leave the database / function):

```sql
select net.http_post(
 url:=c.project_url||'/functions/v1/lwb-web-push',
 headers:=jsonb_build_object('Content-Type','application/json','x-lwb-push-secret',c.webhook_secret),
 body:='{"action":"bootstrap"}'::jsonb, timeout_milliseconds:=10000)
from public.lwb_push_config c where id=1;
```

Verify with:

```sql
select enabled, vapid_public is not null as public_key_ready,
 vapid_private is not null as server_key_ready
from public.lwb_push_config where id=1;
```

VAPID private keys and the dedicated webhook secret are stored only in the locked server config table; the browser RPC returns only the public VAPID key. Do not print, copy or commit private keys. Supabase injects its server credentials into the Edge Function runtime. Do not rotate the VAPID pair casually: existing devices would need to re-subscribe.

`erp-push.js` adds opt-in/test/off controls inside the bell. `sw.js` displays encrypted pushes only for the stored active user and opens a same-origin route. PO Approval supports `?order=` to open the specific authorized order, including older orders outside the initial 300-row list. Private notification text is suppressed on shared devices if the active user differs.

## Delivery behavior and recovery

Immediate pg_net requests wake the Edge Function. A durable job plus a lease and per-device delivery records handle concurrent webhooks / bounded retries. The one-minute cron retries recent failed work up to six claims / fifteen minutes; provider TTL is five minutes. Each delivery has a stable notification tag; rare retries after provider acceptance plus a DB-write failure can replace the same banner. HTTP 404/410 removes an expired endpoint. Recipient active status and device ownership are checked at send time.

To pause outgoing pushes while keeping the bell: `update public.lwb_push_config set enabled=false where id=1;`. The cron retains no sensitive payload, and completed job history is cleaned after seven days. Do not test using fake production orders or payments; the **Test** button sends a device-only notification.

## Validation

Run `npm ci --prefix tests/push --ignore-scripts` and `npm test --prefix tests/push`.

Tests cover SSRF endpoint rejection, encrypted Web Push round-trip with generated browser keys, role/order deep links, shared-phone suppression, safe click navigation, permission opt-in, subscription rebinding and logout cleanup. Live verification checks table ACLs/RLS, anonymous endpoint rejection, authenticated registration validation, retry-job health and successful server bootstrap. End-to-end display/sound still requires a real phone to opt in and receive Test.

Supabase advisor notes: private push tables intentionally have no client RLS policies (direct access is revoked). The three authenticated SECURITY DEFINER RPCs are intentional narrow entry points: config returns only public data after an active-user check, subscribe binds only auth.uid(), and unsubscribe removes only that user's endpoint. Every internal function is revoked from clients and uses an empty search_path.

References: [Supabase database webhooks](https://supabase.com/docs/guides/database/webhooks), [function authentication](https://supabase.com/docs/guides/functions/auth-headers), [Web Push library](https://github.com/web-push-libs/web-push), [Chrome TWA notification delegation](https://chromium.googlesource.com/chromium/src/+/HEAD/chrome/android/java/src/org/chromium/chrome/browser/browserservices/permissiondelegation/README.md).
