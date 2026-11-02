"""Read the user's normalized ingredient file directly from the project."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

from .claude_client import StageError


class IngredientData:
    """Load once, validate schema 2.0, and retrieve exact recorded ingredients."""

    def __init__(self, path, categories):
        self.path = Path(path).resolve()
        raw = self.path.read_bytes()
        try:
            dataset = json.loads(raw)
        except (ValueError, UnicodeDecodeError) as error:
            raise StageError("invalid_recipe_data", "The ingredient file is not valid JSON.") from error
        if not isinstance(dataset, dict):
            raise StageError("invalid_recipe_data", "The ingredient data must be an object.")
        meta = dataset.get("MetaData")
        records = dataset.get("dishes")
        if (not isinstance(meta, dict) or meta.get("schemaVersion") != "2.0"
            or not isinstance(meta.get("dataVersion"), str) or not meta["dataVersion"].strip()
            or not isinstance(records, list) or not records):
            raise StageError("invalid_recipe_data", "The normalized ingredient data has an unsupported or empty structure.")

        self.identity = {"file": self.path.name, "path": str(self.path),
                         "sha256": hashlib.sha256(raw).hexdigest(),
                         "schema_version": meta["schemaVersion"], "data_version": meta["dataVersion"],
                         "ingredient_names_normalized": True, "allergen_source": "embedded_allergens"}
        self.dishes = {}
        supported = set(categories)
        global_links = {}
        for record in records:
            if (not isinstance(record, dict) or not isinstance(record.get("dishName"), str)
                or not record["dishName"].strip()):
                raise StageError("invalid_recipe_data", "A dish name is missing or invalid.")
            dish = record["dishName"]
            if dish in self.dishes:
                raise StageError("invalid_recipe_data", f"Duplicate dish name: {dish}.")
            count = record.get("recipeCount")
            ingredients = record.get("normalizedIngredients")
            if isinstance(count, bool) or not isinstance(count, int) or count < 1:
                raise StageError("invalid_recipe_data", f"The recipe count is missing or invalid for {dish}.")
            if not isinstance(ingredients, list) or not ingredients:
                raise StageError("invalid_recipe_data", f"The ingredient list is missing or invalid for {dish}.")
            names = set()
            for item in ingredients:
                if (not isinstance(item, dict) or not isinstance(item.get("name"), str) or not item["name"].strip()
                    or not isinstance(item.get("allergens"), list)):
                    raise StageError("invalid_recipe_data", f"An ingredient name or allergen list is missing or invalid for {dish}.")
                name, allergens = item["name"], item["allergens"]
                if name in names:
                    raise StageError("invalid_recipe_data", f"Duplicate ingredient name in {dish}: {name}.")
                names.add(name)
                if any(not isinstance(a, str) or a not in supported for a in allergens):
                    raise StageError("invalid_mapping", f"An allergen category is invalid for {dish} / {name}.")
                links = frozenset(allergens)
                if len(links) != len(allergens):
                    raise StageError("invalid_mapping", f"Duplicate allergen category for {dish} / {name}.")
                if name in global_links and global_links[name] != links:
                    raise StageError("invalid_mapping", f"Conflicting allergen lists for {name} across dishes.")
                global_links[name] = links
            self.dishes[dish] = record

    def retrieve(self, dish):
        record = self.dishes.get(dish)
        if record is None:
            raise StageError("missing_recipe", "No ingredient record is available for the accepted dish. Analysis stopped before merging.")
        items = [{"name": item["name"], "confidence": None, "allergens": list(item["allergens"]),
                  "mapping_evidence": item["allergens"], "original_record": item}
                 for item in record["normalizedIngredients"]]
        return {"dish": dish, "ingredients": items,
                "allergens": sorted({a for item in items for a in item["allergens"]}),
                "unmapped_ingredients": [item["name"] for item in items if not item["allergens"]],
                "recipe_metadata": {"dishName": dish, "recipeCount": record["recipeCount"]},
                "allergen_source": "embedded_allergens", "dataset_metadata": self.identity,
                "note": "Recipe possibilities, not confirmation that every ingredient is present in this photo. An unmapped ingredient is not proven allergen-free."}
