# Transformer Survey (offline, sky blue)

Fully local: SQLite on the phone, photos converted to WebP before storage, no backend.

## Build the APK
A) GitHub: push this folder to a repo -> Actions -> "Build APK" -> download artifact `survey-apk`.
   (The workflow runs `flutter create`, adds permissions, installs `native/MainActivity.kt` and builds.)
B) Local: `flutter create --platforms=android --project-name survey_app --org com.example .`
   - add permissions to AndroidManifest.xml: INTERNET, ACCESS_NETWORK_STATE, ACCESS_FINE_LOCATION,
     ACCESS_COARSE_LOCATION, CAMERA, READ_PHONE_STATE
   - replace android/app/src/main/kotlin/com/example/survey_app/MainActivity.kt with native/MainActivity.kt
   - `flutter pub get && flutter build apk --release`

## Feeder reference data (replaces the server download)
Home menu -> Import feeder data. CSV (header row) or JSON list with:
`subdivision_code, subdivision_name, app_id, feeder_code, feeder_name`
Without it, Subdivision / APP ID / Feeder fields are typed by hand.

## Easy-to-change constants (lib/main.dart)
kMinPhotos=1, kMaxPhotos=20, kMinChecks=2 (operator checks needed to save), `opts` (dropdown lists), `quality()` (speed -> signal).
