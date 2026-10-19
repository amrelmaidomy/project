# Android host for معاك

Use Flutter 3.35.7 (Dart 3.9), a Java 17 compatible JDK, and Android SDK platform 36 with build tools 36.0.0 and Flutter's NDK 27.0.12077973. `scripts/install_android_sdk.sh` installs these SDK prerequisites from verified official downloads. The host pins Gradle 8.12, Android Gradle Plugin 8.9.1 and Kotlin 2.1.0. Minimum Android version is 8.0/API 26; target API is 36. AGP 8.9.1 may warn about API 36 because its validated maximum is API 35; the warning has not been suppressed.

From `mobile/`, run `flutter pub get`, `flutter analyze`, `flutter test`, then `flutter run`. Flutter writes the ignored `android/local.properties` with local SDK paths. When using Gradle directly, supply `flutter.sdk` there or set `FLUTTER_ROOT`, and supply `sdk.dir` or `ANDROID_HOME` for the Android SDK. No SDK binaries or local machine paths belong in Git.

The checked-in wrapper comes from the official Gradle `v8.12.0` tag. Its JAR SHA-256 is `2db75c40782f5e8ba1fc278a5574bab070adccb2d21ca5a6e5ed840888448046`, verified against `https://services.gradle.org/distributions/gradle-8.12-wrapper.jar.sha256`. The distribution checksum is pinned in `gradle-wrapper.properties`.

Debug builds allow HTTP only to Android emulator host `10.0.2.2`, loopback `127.0.0.1`, and `localhost`; other connections require HTTPS. For a USB connected device use `adb reverse tcp:8000 tcp:8000` and configure the app backend URL to `http://127.0.0.1:8000`. Profile and release builds require HTTPS.

Release builds are unsigned until an owner supplies an ignored `android/key.properties`:

```properties
storeFile=/absolute/path/to/private-release-key.jks
storePassword=YOUR_PRIVATE_PASSWORD
keyAlias=YOUR_PRIVATE_KEY_ALIAS
keyPassword=YOUR_PRIVATE_PASSWORD
```

Do not commit this file or a keystore. Release never uses the generated debug signing key. Install debug artifacts for local testing; sign production artifacts with the owner controlled production key.

Microphone, notification and exact alarm declarations do not grant access. The Flutter application must request runtime permissions in context. `SCHEDULE_EXACT_ALARM` uses user granted special access on Android 12+; no broad `USE_EXACT_ALARM` entitlement is declared. Boot/package replacement receivers allow the notifications plugin to restore scheduled notifications.

The optional native wake-word bridge uses ONNX Runtime Android 1.22.0. Its microphone foreground service must be started explicitly by the user, after permissions and model validation. No trained Arabic classifier is bundled. An English Hey Jarvis demo is available through the documented optional model download. Missing models disable their wake profile and do not block normal voice reminders. Custom Arabic wake-word accuracy, battery behavior and background microphone lifecycle require trained models and physical Android validation before enabling it for production.

Android build and on-device behavior require a full Flutter SDK, Android SDK, and emulator/device. XML parsing and wrapper integrity checks alone do not establish runtime correctness.
