"""Validate Claude ingredient extraction and merge source evidence."""
from __future__ import annotations

from collections import defaultdict
import math

from .claude_client import StageError


NAME_NORMALIZATION_METHOD = "case_whitespace_v1"


def validate_extraction(obj, dish, categories):
    if set(obj) != {"dinov2_predicted_dish", "ingredients"} or obj["dinov2_predicted_dish"] != dish or not isinstance(obj["ingredients"], list):
        raise StageError("invalid_response", "The ingredient result did not preserve the accepted dish or the required format.")
    for item in obj["ingredients"]:
        if (not isinstance(item, dict) or set(item) != {"name", "confidence", "allergens"}
            or not isinstance(item["name"], str) or not item["name"].strip()
            or isinstance(item["confidence"], bool) or not isinstance(item["confidence"], (int, float))
            or not math.isfinite(item["confidence"]) or not 0 <= item["confidence"] <= 100
            or not isinstance(item["allergens"], list)
            or any(not isinstance(a, str) or a not in categories for a in item["allergens"])):
            raise StageError("invalid_response", "The ingredient analysis contained an invalid ingredient, confidence or allergen category.")
    return obj


def merge_sources(dataset_items, claude_items):
    """Group case/whitespace variants; preserve raw evidence and semantic differences."""
    merged = {}
    for source, items in (("Dataset", dataset_items), ("Claude", claude_items)):
        for index, item in enumerate(items):
            name = item["name"]
            if not isinstance(name, str) or not name.strip():
                raise StageError("invalid_ingredient_name", "An ingredient name is missing or invalid. Merging stopped.")
            display_name = " ".join(name.split())
            # Dataset is visited first, so its spelling wins when both sources match.
            # Do not remove punctuation, preparation words, plurals or qualifiers.
            key = display_name.casefold()
            entry = merged.setdefault(key, {"name": display_name, "sources": [], "allergens": [], "evidence": []})
            if source not in entry["sources"]:
                entry["sources"].append(source)
            entry["allergens"] = sorted(set(entry["allergens"]) | set(item["allergens"]))
            entry["evidence"].append({"source": source, "source_index": index, "original_name": name,
                                      "confidence": item.get("confidence"), "allergens": list(item["allergens"]),
                                      "mapping_evidence": item.get("mapping_evidence", [])})
    causes = defaultdict(list)
    disagreements = []
    for item in merged.values():
        per_source = {s: sorted({a for e in item["evidence"] if e["source"] == s for a in e["allergens"]})
                      for s in item["sources"]}
        if len(per_source) > 1 and len({tuple(a) for a in per_source.values()}) > 1:
            disagreements.append({"ingredient": item["name"], "source_allergens": per_source})
        for allergen in item["allergens"]:
            evidence = [e for e in item["evidence"] if allergen in e["allergens"]]
            causes[allergen].append({"ingredient": item["name"], "sources": sorted({e["source"] for e in evidence}), "evidence": evidence})
    return {"ingredients": list(merged.values()), "allergens": sorted(causes),
            "allergen_causing_ingredients": dict(sorted(causes.items())), "mapping_disagreements": disagreements,
            "available_sources": ["Dataset", "Claude"], "normalization_applied": True,
            "normalization_method": NAME_NORMALIZATION_METHOD, "semantic_normalization_applied": False,
            "merge_rule": "Compare names using casefold and trimmed/collapsed whitespace; prefer the first Dataset spelling, otherwise the first Claude spelling. Retain all raw names, confidences, allergens and source evidence. No semantic normalization."}
