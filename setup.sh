#!/bin/bash
# Run once inside this folder (Flutter SDK installed)
flutter create --org com.sellone --project-name sellone_ai --platforms android .
M=android/app/src/main/AndroidManifest.xml
grep -q CAMERA $M || sed -i '0,/<manifest[^>]*>/s//&\n    <uses-permission android:name="android.permission.INTERNET"\/>\n    <uses-permission android:name="android.permission.CAMERA"\/>/' $M
flutter pub get
echo "Done. Test: flutter run   |  APK: flutter build apk --release   |  Play Store: flutter build appbundle --release"
