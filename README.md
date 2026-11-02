# 2026-GP1-1 — Misbar 2

## Purpose

Misbar helps signed-in users review potential allergens in a dish or a packaged-food label. Results describe possible allergens and require user judgement before eating.

## Contents

`frontend/` is the Flutter Android app. `backend/` contains the label API and frozen dish pipeline. `data/` contains the approved JSON files. `deployment/` contains reproducible container preparation and inactive release plans. `docs/` contains team guides. `.github/` contains inactive workflow templates. `security_tests/` tests the existing Firestore rules only against a local demo emulator.

## Important Files

`frontend/lib/main.dart` starts the app. `backend/label_api/main.py` defines the label/profile API. `deployment/gateway.py` adds the dish endpoint and readiness lifecycle. `deployment/policy.json` records approved identities and disabled release gates. `data/approved-hashes.json` prevents stale data from silently entering a build.

## How It Works

The Android app signs in with Firebase Authentication and sends a Firebase ID token to FastAPI. The backend reads saved allergies through Firebase Admin SDK. Dish and label processing support SSE; legacy JSON remains supported. The backend is currently IAM-private, so development uses a local Cloud Run Proxy. Model weights and the mandatory human-review registry stay in the digest-pinned private base image, outside Git.

## When to Modify

Edit screens/services under frontend for UI or client behavior, label API modules for API changes, and approved JSON with its hash file for reviewed data updates. Frozen model configuration and artifacts require separate approval. Follow docs/COLLABORATION.md; humans own commits, pushes, PRs and merges.

## Dependencies

Flutter 3.47.5 / Dart 3.13.4, Android SDK/JDK 21, Python 3.14, Firebase project `misbar-ebea2`, and Cloud Run project `project-51f11627-cb56-4c1e-978`. Full image builds also require access to the pinned private Artifact Registry base.

## Important Notes

**Preparation only.** This repository must remain **Public** for the graduation-project committee. No workflow is active: template names end in `.yml.disabled`, and cloud release flags are false. The disabled publishing guards and IAM proposal still contain an earlier private-repository requirement; they must be reviewed for this public repository before any future activation. Do not change visibility to satisfy those guards. No credentials, signing key, user backup or model weights belong in Git. App Distribution does not establish USB-free API connectivity. See [the public publication review](docs/PUBLIC_REPOSITORY_REVIEW.md).

## Local setup and tests

Read [the student setup guide](docs/STUDENT_SETUP.md) first. Clone only `https://github.com/hetaf234/2026-GP1-1.git`.

```sh
python3.14 -m venv .venv
. .venv/bin/activate
python -m pip install --extra-index-url https://download.pytorch.org/whl/cpu -r deployment/test-requirements.txt -c deployment/requirements.lock.txt
python deployment/run_checks.py --backend
python deployment/secret_scan.py
cd frontend
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```

For Android Emulator, start the authorized local proxy on the development computer and run the app with `--flavor misbar2 --dart-define=MISBAR_SECOND_COPY=true --dart-define=MISBAR_API_BASE_URL=http://10.0.2.2:8080`. This is an emulator-to-host connection, not a production mobile API address. See frontend/README.md for the full command.

## Architecture and release process

`Flutter → Firebase ID token → FastAPI → saved user allergies + dish/label pipeline`.

The intended backend path is reviewed feature PR → protected main → GitHub orchestration → Cloud Build tests/build/model checks → private Artifact Registry → testing service image update. There is no second automatic Cloud Build trigger. Android tests/build, signing/upload, and tester delivery are separate jobs and approvals. Both workflows are currently disabled. See [CI/CD](docs/CI_CD.md), [signing/distribution](docs/APP_DISTRIBUTION.md), and [wireless connectivity](docs/BACKEND_CONNECTIVITY.md).
