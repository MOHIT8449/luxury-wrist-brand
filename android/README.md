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

## Staff location sharing (new APK required)

Every active ERP login except Admin shares location with Admin. Only Admin sees
Live Tracking. The app icon now opens `DriverTrackingActivity` (the location gate)
before the ERP:

1. First open: the person reads the notice, ticks **I agree**, and signs in with
   their ERP email/password. The agreement time is saved (`lwb_gps_agree`) and
   shown to Admin on Live Tracking. Admin logins skip all of this.
2. Every open: the app checks precise location, **Allow all the time**
   (background location), notifications and phone location (GPS) switch. Anything
   missing shows a popup with one button and no Skip. Back closes the app; the
   popup comes again on the next open.
3. When everything is fine the location foreground service starts and the ERP opens.

Staff have no Stop button. The service stops only when the server says the login is
not tracked (Admin, inactive or deleted user). It is sticky and starts again after a
phone restart or app update (`BootReceiver`). If location is turned off or permission
is removed, the server gets `OFF`/`DENIED` (Admin sees **Location off**) and a
reminder notification opens the popup. Android always lets a person force-stop the
app or revoke permission in phone settings; that cannot be blocked, but it shows on
the Admin map and the popup returns on the next open.

Location is sent about every 30 seconds in the work hours set by Admin. No fix older
than 90 seconds is sent. Tokens are AES-GCM encrypted with an AndroidKeyStore key; no
password is saved. **Change login** on the gate screen switches tracking to another
staff login on a shared phone.

Google Play: background location needs the Play Console location declaration and a
short video of the notice screen before review. Direct APK installs are not affected.
