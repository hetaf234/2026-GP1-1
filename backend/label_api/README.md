# Label API, profiles and allergy services

## Purpose

Define authenticated profile/allergy operations and packaged-label scanning.

## Contents

`app/` holds auth, models, safe logging/errors and services. `main.py` defines routes. `test_*.py` are mocked regressions. `allergen_matching_dataset_reviewed_rtl.csv` stays at its original relative path. `check_quality.py`, `download_model.py` and `user_metadata_migration.py` are historical/test helpers; they are not added to the runtime overlay unless explicitly mapped.

## Important Files

`app/services/label_progress_service.py` tracks actual label milestones. `app/services/ingredient_service.py` loads the pinned local label model. `app/services/ocr_service.py` performs OCR when an authorized real request is made. `app/services/user_metadata_service.py` preserves valid existing role/language values.

## How It Works

The existing main app is included by deployment/gateway.py so both scan families share token verification and authoritative saved allergies.

## When to Modify

Edit the relevant service plus unit tests. Update the CSV only through a separately reviewed data change. The two approved JSON files live under data and concern dish ingredients/display names, not this CSV.

## Dependencies

FastAPI, Firebase Admin, Vision, transformers and provider dependencies from the deployment lockfile.

## Important Notes

Do not rerun user migrations, modify auth settings or invent role values in clients. Tests must use fixtures, never production accounts or paid image analysis.
