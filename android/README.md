# LWB ERP Android app

A Trusted Web Activity: the app opens https://luxury-wrist-brand.pages.dev
full screen in Chrome. Everything (login + OTP, camera photos, call buttons,
WhatsApp, popups) is the live website, so a merged PR reaches the app at once.
A new APK is only needed when this `android/` folder changes.

## Get the APK
- Latest signed app: https://github.com/MOHIT8449/luxury-wrist-brand/releases/download/android-app/lwb-erp.apk
- Built by `.github/workflows/android-apk.yml` on every push to `main` that changes `android/`
  (needs the `LWB_KEYSTORE_BASE64` and `LWB_KEYSTORE_PASSWORD` repository secrets).

## Build in Android Studio
1. File > Open > this `android` folder. Let Gradle sync.
2. Build > Build App Bundle(s) / APK(s) > Build APK(s). This debug APK shows a
   small address bar, because it is not signed with the release key.
3. For the full-screen release APK, set `LWB_KEYSTORE_FILE` (path to the .jks)
   and `LWB_KEYSTORE_PASSWORD`, then run `./gradlew assembleRelease`.

## Signing key
The SHA-256 of the release key is in `/.well-known/assetlinks.json` on the
website. That file is what lets the app hide the address bar. Keep the .jks
safe: every later APK must be signed with the same key to update the app.

## Google Play
- Upload `lwb-erp.aab` from the `android-app` release (same link as above, ending in `.aab`).
- Play re-signs the app with its own key ("Play App Signing"). Copy that SHA-256
  from Play Console > Test and release > App integrity and add it to
  `/.well-known/assetlinks.json` next to the upload key, or the Play version shows an address bar.

## Phone notifications

This app declares Android POST_NOTIFICATIONS, the `NotificationPermissionRequestActivity` (needed on Android 13+ so Chrome can show the Allow dialog inside the app; added 2 Nov 2026 after Enable did nothing) and a status-bar bell icon (`SMALL_ICON`) for Chrome notification delegation. Install the newest signed APK over the existing app, then sign in → 🔔 → Enable phone alerts → Allow → Test. Server setup and safeguards are in ../README_PHONE_PUSH.md. User/OS permission must be granted on each device; no notification permission is requested just by opening an order page.

## Fingerprint unlock
After 15 minutes idle the ERP locks and opens with the phone's fingerprint / face / PIN
(`quick-unlock.js`, WebAuthn in Chrome). It is part of the website, so no new APK is needed.

## Driver shift GPS (new APK required)

The TWA still handles the ERP, uploads, calls, payments and login. A separate native
`DriverTrackingActivity` and non-exported location foreground service handle GPS.
On the Android Driver Delivery page choose **Open driver GPS setup**, sign in with
an active, tracking-enabled driver's email/password, grant precise location and
notification permissions, then **Start shift GPS** while the activity is visible.
Return to ERP; the location foreground service remains active when Chrome is
backgrounded or the screen is locked. A persistent notification shows the last
successful upload and has a Stop action. This follows Android's requirement to
start a location foreground service from a visible activity:
https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start

The native login is intentionally separate from Chrome's cookie/localStorage
session. **Stop GPS before switching drivers or signing out of the ERP.** Website
logout alone does not revoke this separate native session. Stop clears the native
session. No password is saved; tokens are AES-GCM encrypted with an AndroidKeyStore
key, and Android backup is disabled. No service-role key or token-bearing deep link
is used. Only the native driver session's `auth.uid()` supplies location.

The service samples GPS/network location and attempts fresh uploads about every
30 seconds. No fix older than 90 seconds is resent; offline points are not queued
or later presented as live. Supabase validates driver activation, tracked roles and
work hours; the service checks work hours periodically and pauses provider
subscriptions outside them. Expired tokens refresh using Supabase Auth, and invalid
sessions stop tracking. Permission/provider/network failures are visible in the
notification. OS force-stop, reboot and OEM battery restrictions can stop GPS:
reopen GPS setup and start again. No background/reboot auto-start is attempted.
Browser-only GPS retains its foreground limitation.

After approval, apply `lwb_driver_background_tracking_setup.sql` to an ERP that
already has live tracking and sales order follow-up installed, update the web
assets and `lwb-web-push` function, build/install a newly signed APK, and perform
the device validation in `LIVE_GPS_REVIEW.md`. Merging source alone is not an APK
installation or database migration.
