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
