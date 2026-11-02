# Approved dish inference source

## Purpose

Keep the frozen classifier/OOD and approved ingredient workflow reproducible.

## Contents

`src/dish_identifier/` contains the runtime, prompts and data readers. `configs/` contains approved pipeline/image-quality settings. `nonlinear/` contains lightweight frozen configuration and class metadata. `scripts/` and `manual_testing/` contain inference helper modules imported by the frozen runtime; their names do not make them CI evaluation suites.

## Important Files

`ingredient_data.py` reads schema 2.0 recorded allergens without re-mapping names. `dish_display.py` changes English presentation names only. `human_labels.py` requires the central human-review registry. `frozen_runtime.py` retains model loading and classification behavior.

## How It Works

The container receives the original directory structure. Required weights, DINO assets, human_label_registry.json and active_references.json remain in the digest-pinned private base. Missing authority must fail; it must never fall back to folder labels. No real image is needed for model-loading smoke checks.

## When to Modify

Routine frontend or profile work should not modify this folder. Frozen model/configuration changes require a separate reviewed artifact and approval. Data changes belong in data, not duplicated runtime copies.

## Dependencies

Pinned private base model artifacts, torch/torchvision, NumPy/SciPy and the existing Claude/quality integrations.

## Important Notes

Do not open reserved OOD Final Test, retrain models or compute accuracy from folder names. Human reviews are permanent authority for offline evaluation and never overwrite model predictions. Keep dataset and approach versions separate. Model binaries and private review records must not be committed.
