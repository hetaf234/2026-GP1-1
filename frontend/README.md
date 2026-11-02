# Flutter Android application

## Purpose

Provide Misbar Android screens, authentication and HTTP/SSE clients.

## Contents

`lib/screens/` holds account, allergy and label screens. `lib/features/dish_scan/` holds dish capture, progress, results and fixtures. `lib/services/` holds authentication, allergy state, endpoint validation and SSE transports. `lib/widgets/` contains shared UI. `test/` includes mock-based tests. `assets/images/` contains the unchanged logo. `android/` contains the Android platform code and Firebase client configuration.

## Important Files

`lib/widgets/app_header.dart` is the header design source, including the appearance contract sent to native Android capture. `android/app/src/main/java/com/example/flutter_application_1/ImageCaptureActivity.java` uses that contract. `lib/services/label_scan_http_client.dart` uses a 660-second total deadline. `android/app/src/misbar2/google-services.json` registers the existing second-copy package.

## How It Works

The auth gate retrieves saved allergies before choosing Home or initial selection. Home offers Dish and Label Scan. Firebase tokens authenticate backend requests. Both scan clients show backend-confirmed progress, not timers pretending to be progress. Native label capture returns an image path through the existing MethodChannel. Back/Logout remain screen-owned; public screens show no signed-in name or Logout.

## When to Modify

Change UI in screens/widgets; change API transport in services; update tests with each behavior change. Do not change package name, signing identity, logo artwork or auth flow as part of deployment setup.

## Dependencies

The exact Flutter revision is recorded in deployment/policy.json. JDK 21 and Android SDK are required. The two google-services.json files are public Firebase client configuration, not service-account credentials. Firebase email/password sign-in is existing behavior.

## Important Notes

The deployed package is `com.example.flutter_application_1.misbar2`. Use the `misbar2` flavor and `MISBAR_SECOND_COPY=true` together. The approved second-copy build is debug-only; do not remove its release guard or introduce a new signing key. Preview builds use a separate package and memory-only identity/network blockers.

## Run on Android Emulator

Install Android Studio, create a fresh Android virtual device with internet access, and accept Android SDK licenses with `flutter doctor --android-licenses`. Run `flutter doctor`, `flutter devices`, then:

```sh
# On the development computer, after authorized gcloud login:
gcloud run services proxy misbar-consolidated-test-20261101 --project=project-51f11627-cb56-4c1e-978 --region=us-central1 --port=8080
# In this frontend directory:
flutter pub get
flutter run --flavor misbar2 --dart-define=MISBAR_SECOND_COPY=true --dart-define=MISBAR_API_BASE_URL=http://10.0.2.2:8080
```

Use an authorized testing account and the team's approved cloud access; never put cloud credentials in the app. Do not use a developer's independently generated emulator signing key to update the owner's physical-phone installation. Keep developer emulator data separate from distribution testing.

## Offline UI preview

```sh
flutter run --target lib/main_dish_preview.dart --dart-define=MISBAR_DISH_PREVIEW=true --dart-define=MISBAR_API_BASE_URL=https://misbar-ui.invalid
```

This existing preview blocks real networking. Never describe its results as live provider/SSE verification.
