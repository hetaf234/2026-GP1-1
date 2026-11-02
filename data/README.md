# Approved lightweight data

## Purpose

Store the two latest approved JSON runtime inputs in one editable location.

## Contents

`Misbar_Normlized_IngredientsXAllergen.json` contains schema 2.0 dish ingredient/allergen records. `misbar_dish_name_mapping.json` maps exact classifier keys to display labels. `approved-hashes.json` records the approved bytes. The label matching CSV stays in backend/label_api to preserve its existing reader path.

## Important Files

`approved-hashes.json` must match both files. `deployment/validate_data.py` reuses the production readers to reject malformed/duplicate JSON, missing or conflicting allergen lists, and mismatched model dish keys.

## How It Works

prepare_runtime.py places these files at their original dish-root paths and updates only their required entries in bundle_manifest.json. Current approved data contains 121 dishes; display poutine is Loaded Fries. Classifier keys remain unchanged. English display_name_en is used by the current backend; Arabic labels are retained as supplied.

## When to Modify

Review JSON changes, preserve source evidence/allergen causes, run the data validator and update approved hashes only for reviewed content. Never restore an old experimental copy merely because it exists in history.

## Dependencies

Production IngredientData and DishDisplayNames readers plus the fixed class mapping and ingredient category schema.

## Important Notes

These inputs are recipe possibilities, not proof of ingredients in a particular image. Empty recorded allergen lists must stay empty. Do not infer new links or normalize user data during a build. dataVersion is retained exactly as supplied; SHA-256 identifies content.

## Approved hashes

```text
Ingredients: e93333fd351837902a476891df262634641a5733eae4f680e894525b963c32f5
Display map: ce5b003edf76403d17494d5dfa3811c7bce3c93fa5ca47445136ed449a1c7606
```

Run `python deployment/validate_data.py` from the root. A mismatch stops preparation. Model weights, user documents and experimental dataset copies do not belong in this folder.
