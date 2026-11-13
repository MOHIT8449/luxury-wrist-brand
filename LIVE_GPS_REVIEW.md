# Live GPS tracking review

Prepared 13 November 2026 against `MOHIT8449/luxury-wrist-brand`, main commit
`98b0875f3505f058a9bca3a624bf6e9b06dde53f`. The user authorized GitHub publication and rollout on 13 November 2026.
Deployment status is reported separately from this implementation review.

## Result

The existing Android TWA remains responsible for the ERP. A native driver GPS
screen starts a location foreground service from a visible activity. It sends
fresh locations approximately every 30 seconds while allowed by server work
hours, including while Chrome is backgrounded. Notification controls expose
status and Stop. Native tokens use AndroidKeyStore-backed AES-GCM encryption;
passwords are never persisted. Session refresh, inactive/changed-role rejection,
permission loss, offline retry, old-fix rejection and work-hour pauses are handled.
The native RPC accepts only the authenticated active driver's identity.

| Role | Tracking access | Settings and party pins |
|---|---|---|
| Driver | Sends own GPS; existing assigned deliveries and reporting | No |
| Admin | Live map, routes, delivery/trip progress | Yes |
| Sales Head (`manager`) | Live map, routes, delivery/trip progress | Yes |
| Godown Manager (`warehouse`) | Live map, routes, delivery/trip progress | Read only |
| Accounts | Live map, routes, delivery/trip progress | Read only |
| Salesman (`sales` / `salesman`) | No map, route, dispatch/delivery feed, order-follow-up tab or order-related bell/push alerts | No, even with page overrides |

Salesman order entry and existing party/SKU sales analytics remain available.
The order-follow-up list, including its edit/cancel buttons, is intentionally
removed from the salesman screen to satisfy the no-order-updates requirement.
Existing general order/sales analytics permissions are retained; this patch does
not hide all order records or redesign the ERP's analytics APIs. Dispatch and
delivery feed tables, tracking RPCs and the follow-up RPC are separately guarded.
Other roles' ordering, loading, invoicing, POD, returns, collections, inventory and
Tally workflows are retained. The database regression test runs the delivery/trip
sequence through delivery reports, first-party pin capture and return to godown.

## Validation

- Tracking/permissions: 19 PostgreSQL tests using isolated PGlite fixtures, including
  repeatable upgrade SQL, actual authenticated-role calls, permissive page override
  attempts, denied direct table access, read-only Accounts/Godown actions, historical
  alert filtering, inactive profiles and immediate native role-change rejection.
- Screens: 6 DOM interaction tests covering Admin, Sales Head, Godown, Accounts,
  salesman, navigation menu overrides, settings, party pins, refresh and stale GPS.
- Browser GPS: 1 regression test prevents a failed fix from re-sending old coordinates
  as fresh.
- Push: 12 tests pass, including salesman suppression of queued order/tracking alerts
  and existing ownership, encryption, permission and logout behavior.
- Existing regressions: 5 salesman-scope and 4 order-visibility tests pass.
- Modified inline JavaScript and Android manifest XML parse; `git diff --check` passes.

Run locally:

```sh
npm ci --prefix tests/live-tracking
npm test --prefix tests/live-tracking
npm ci --prefix tests/push
npm test --prefix tests/push
npm ci --prefix tests/salesman-scope
npm test --prefix tests/salesman-scope
npm ci --prefix tests/order-visibility
npm test --prefix tests/order-visibility
bash android/gradlew -p android :app:assembleDebug
```

**Not verified:** Android compilation could not start because the Gradle distribution
could not be downloaded (`Network is unreachable`); no configured Android SDK or
physical phone is available here. Real Chromium rendering also failed to launch
because this environment disallows Chromium's process socket. DOM checks use
mocked map/RPC data and do not establish rendered layout or real GPS behavior.
Production Supabase and signed-in staff screens have not been exercised or changed.
These are release gates, not passing checks.

## Device release gates

Before rollout, build a signed APK on Android Studio/CI and install over the existing
app. Test Android 10/11 and 13–16, plus the drivers' actual phone/OEM models:

1. Active driver signs in on **Open driver GPS setup**, grants precise location and
   notifications, starts GPS, then returns to ERP. Confirm that map timestamps keep
   advancing after app switch, screen lock and a 15–30 minute stationary period.
2. Check moving GPS, denied/approximate permission, location switched off, revoked
   permission while running, offline/reconnection and expired refresh token. Old
   points must never appear as fresh uploads; stale GPS must never look live.
3. Test work-hour boundary pause and next-work-period resume, Stop in both activity
   and notification, force-stop/reboot, battery saver and OEM battery restrictions.
   Force-stop/reboot requires the driver to reopen setup and start again.
4. Test two drivers switching on one phone; Stop the previous shift first. Verify
   profile deactivation and driver-to-other-role changes stop native uploads.
5. Confirm Admin/Sales Head edit controls, read-only Godown/Accounts, and denied
   salesman direct URLs/RPCs, old/new alerts and page-permission overrides.
6. Complete approve → allocate → load → invoice → deliver/POD → collect/return flow;
   compare stock, collections and reports with the existing ERP behavior.

The native login is separate from Chrome's ERP session. **Stop shift GPS before ERP
logout or driver changes.** Website logout does not end the independent native
session. This is visible on the driver setup screen and explained in the Android
README. No credentials are transferred through URLs or JavaScript bridges.

## Apply only after approval

1. Review/apply the patch to a branch at the recorded base commit.
2. On an ERP with existing live-tracking and sales-follow-up setup installed, review
   and apply `lwb_driver_background_tracking_setup.sql`. For a fresh environment,
   install the ERP's existing prerequisites and live tracking/follow-up setup first.
   The existing Supabase apply workflow automatically applies the reviewed upgrade
   and deploys the push function after merge to main. Historical setup files are
   marked no-auto-run; the upgrade includes its idempotent tracking foundation.
3. Update reviewed web assets and the `lwb-web-push` function together with the SQL.
   The push guard also suppresses already queued order alerts for sales recipients.
4. Build/sign the new APK, complete the release gates above, then request rollout
   approval. A web merge alone does not install native GPS on drivers' phones.

No production readiness claim is made before these release gates pass.
