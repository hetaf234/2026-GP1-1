# FastAPI backend and dish pipeline

## Purpose

Keep the approved API and inference code together without changing runtime imports or model behavior.

## Contents

`label_api/` contains main.py, app modules, the label matching CSV, unit tests and tested migration helpers. `dish_pipeline/` contains dish Python source, immutable model configuration, class mapping, inference helpers and prompts. Model binaries and private human-review records are inherited from the approved private base image.

## Important Files

`label_api/app/auth.py` verifies Firebase tokens. `user_metadata_service.py` supplies missing en/member metadata through trusted backend operations. `user_allergen_service.py` loads saved allergies. `label_progress_service.py` and `dish_progress_service.py` supply progress facts. `dish_pipeline/src/dish_identifier/pipeline.py` preserves the approved dish stages.

## How It Works

deployment/prepare_runtime.py copies explicit approved source paths into the original `/opt/misbar/labels`, `/opt/misbar/dish` and `/opt/misbar/deployment` layout. deployment/serve.py runs one worker. gateway.py loads models and exposes /ready. Firebase Admin SDK is server-only; direct client writes remain denied by the existing Firestore rules.

## When to Modify

Edit API/service code and tests for backend changes. Changing model weights, thresholds, class identities, normalization approach or human-review authority needs separate approval. Existing-user migration has already completed; do not run the migration helper against production during CI or routine startup.

## Dependencies

Pinned Python packages in deployment/requirements.lock.txt; frozen dish/label models in the pinned private image; Vision OCR, Sightengine, Claude, Firebase Authentication and Firestore. Runtime secrets remain mounted/injected by the existing Cloud Run service.

## Important Notes

The local unit runner denies external networking. Tests use synthetic users, fixture responses and temporary files. Do not call paid providers or live Firestore to make a test pass. Two test paths were adapted for the new monorepo layout; application behavior was preserved.

## Existing routes

The checked-in `label_api/main.py` defines `/health`, `GET /users/me`, `POST /users/profile`, `GET/PUT /users/me/allergies`, `POST /scan/image`, `POST /scan/text`, and `GET /allergens` with their existing methods. deployment/gateway.py adds `/scan/dish` and `/ready`. Inspect the actual decorators or generated OpenAPI before changing contracts. `/scan/image` and `/scan/dish` support existing JSON and requested SSE responses. Label stages are Image Received, Extracting Text, Identifying Ingredients, and Checking Allergens.

```sh
python deployment/run_checks.py --backend
python deployment/validate_data.py
python deployment/prepare_runtime.py
```

These commands run from the repository root. They do not initialize a live service, provision resources or submit images.
