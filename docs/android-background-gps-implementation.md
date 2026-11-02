# Android Background GPS — Luxury Wrist Brand ERP (implementation handoff)

Status: **Architecture audited, implementation pending**. This feature branch is isolated from production.

## Verified current architecture

- GitHub repo: `MOHIT8449/luxury-wrist-brand`, main branch.
- Android app: `android/` is a **Trusted Web Activity** built with `com.google.androidbrowserhelper:androidbrowserhelper:2.5.0` (target SDK 36), launching the Cloudflare Pages website. It is **not** a native WebView app; the current Java/Kotlin source tree does not contain an app-specific Activity or native location service.
- Existing browser GPS: `live-location.js` sends the signed-in browser's position through Supabase RPC `lwb_track_ping` while active; it cannot reliably track with screen off.
- Existing admin UI: `live-tracking.html` displays the tracking map (Leaflet).
- Existing database objects (verified in linked Supabase project `luxury-wrist-erp`):
  - `lwb_tracking_settings` (roles and work hours)
  - `lwb_staff_location` (latest user position)
  - `lwb_location_history` (time series)
  - `lwb_trip_events` (order route milestones)
  - `lwb_order_pickup`, `dispatch_assignments`, `lwb_delivery_reports`
- Existing access pattern: `lwb_track_me`, `lwb_track_ping` are SECURITY DEFINER RPCs and use `auth.uid()` for driver identity. Never send the service-role key from an APK.

## Important issues to resolve before enabling native tracking

1. **TWA authentication boundary**: the Chrome/TWA Supabase session is not automatically accessible to a native foreground service. Do **not** pull browser cookies or persist a service-role/anon privileged token in Java code. Design an explicit user-consented, short-lived, device-bound pairing/authorization flow mediated by authenticated ERP web UI and an authenticated backend; use revocable scoped credentials and refresh handling. Confirm device/user binding server-side on every batch.
2. **Location permission and disclosure**: an Android location foreground service needs foreground location permission, service type `location`, Android 14+ `FOREGROUND_SERVICE_LOCATION`, a persistent visible notification, a manual Start Duty / End Duty action and transparent explanation. Request `ACCESS_BACKGROUND_LOCATION` only if a documented use case requires it (not by default). Do not use silent staff tracking for this feature.
3. **Work shift and assignment checks**: keep tracking within an explicitly started driver shift/active delivery; ensure server enforces active role, assignment/shift, hours and revocation. Stop on End Duty/logout and show last-seen when offline. Do not auto-restart into tracking after device boot without new explicit user action.
4. **No duplicate tracking tables**: reuse the existing lwb_* tables and RPC flow where possible; add a new migration only for session/device pairing, consent and idempotency if needed. Audit `lwb_track_ping` authorizations, rate limits and stale-location behavior before invoking it from native code.
5. **Data retention**: existing SQL states 30 days route history. Make sure deletion is deterministic and scheduled, not only opportunistic, and match the actual staff privacy notice and applicable requirements.
6. **No production migration/deploy**: this branch contains only design until implementation and tests pass.

## Proposed safe implementation sequence

**A — Backend authorization and opt-in**
- Add a per-driver GPS tracking session tied to `user_profiles.id`, with `started_at`, `ended_at`, consent timestamp, device reference, last heartbeat and state.
- Implement server-issued, narrow-scoped native session credentials, short expiration, revocation and replay/idempotency checks; never ship backend secrets in the APK.
- Add authenticated endpoint to accept GPS batches, verify authenticated driver and active tracking session, validate coordinates/accuracy/timestamp, enforce rate limits and apply existing `lwb_track_ping` updates in the correct user security context.
- Ensure active driver assignment is verified using existing profile-mobile mapping. Avoid exposing all drivers to arbitrary signed-in clients.

**B — Native Android**
- Introduce `DriverLocationService` (Java/Kotlin) using Fused Location Provider in a foreground service, visible notification, 30-second desired interval, movement/battery trade-offs, last fix accuracy, and bounded offline queue.
- Implement a secure pairing UI and a user-facing Start/Stop Duty Activity; because TWA doesn't automatically grant native JS-to-app access, explicitly design, implement and test a trusted app↔web handoff rather than assuming it exists.
- Add runtime foreground-location request. Handle Android 13+ notifications and Android 14+/15/16 service-start restrictions. Don't launch the location FGS from background without required platform exemptions.
- Stop native service on logout/End Duty; forbid sending location when no valid authorized session exists.

**C — Web UI**
- In `live-tracking.html`, display online/stale/offline based on server timestamp, driver, last fix, current assignment, vehicle and arrival milestones; reuse Leaflet map rather than adding a paid Maps dependency without consent.
- In the driver portal, add clear duty/tracking consent and service status, and a session revocation action.

**D — Validation**
- Inspect authorization policies for current RPCs and expose only the minimum.
- Run Android build with existing signing pipeline on a **test branch**, not main release workflow.
- Verify screen-locked 10–30 min, network loss and replay, logout, revoked shift, app forced-stop, reboot, battery saver, unauthorized driver, manager view, user privacy notification, GPS disabled.
- Confirm no effect to PO, dispatch, payment, POD, returns, stock and Tally modules.

## Current audit conclusion

The website already has usable live location tables and map. The principal missing work is **native Android background tracking plus a secure identity bridge between the TWA website login and native service**. Adding only Android Manifest permissions is insufficient and unsafe. This branch is the starting point for that scoped integration.
