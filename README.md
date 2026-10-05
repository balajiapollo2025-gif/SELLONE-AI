# SELLONE AI (Flutter Android)
1. Install Flutter SDK (flutter.dev) + Android Studio
2. `./setup.sh`  (creates android/ folder, adds INTERNET+CAMERA permissions)
3. If build error about minSdk: set `minSdk = 23` in android/app/build.gradle(.kts)
4. `flutter run`  (phone connected, USB debugging ON)
5. APK: `flutter build apk --release` -> build/app/outputs/flutter-apk/app-release.apk
6. Play Store: create signing key, then `flutter build appbundle --release` (.aab upload)
App open chesi Settings -> API key pettandi. Publishing = demo adapters until real marketplace credentials.
