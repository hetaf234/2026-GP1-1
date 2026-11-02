"""Dish-only personalization of validated, structured normalization evidence.

Never calls Label Scan's keyword detector, infers links from ingredient names,
or changes a pipeline stage. All causes remain potential ingredient evidence.
"""
from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timezone

from app.services import user_allergen_service
from app.services.allergen_service import get_available_categories


METHOD = "dish_structured_allergen_matching_v1"
SAFETY_NOTICE = (
    "This analysis may miss ingredients or allergens. No match does not confirm "
    "that a dish is safe or allergen-free. Ingredient presence and cross-contact "
    "are not established by this analysis."
)


class DishEvidenceError(ValueError):
    """The completed normalization evidence is missing or inconsistent."""


def _validate_evidence(normalized, categories):
    """Check the internal structured contract; never generate new allergen links."""
    def invalid():
        raise DishEvidenceError("Dish normalization evidence is missing or inconsistent.")

    if (not isinstance(categories, (list, tuple)) or not categories
            or any(not isinstance(c, str) or not c.strip() for c in categories)
            or len(set(categories)) != len(categories)):
        invalid()
    supported = set(categories)
    if supported != set(get_available_categories()):
        invalid()
    if (not isinstance(normalized, dict)
            or normalized.get("semantic_normalization_applied") is not True
            or normalized.get("all_evidence_preserved") is not True
            or not isinstance(normalized.get("ingredients"), list)
            or not normalized["ingredients"]
            or not isinstance(normalized.get("allergens"), list)
            or not isinstance(normalized.get("allergen_causing_ingredients"), dict)
            or not isinstance(normalized.get("mapping_disagreements"), list)):
        invalid()
    allergens = normalized["allergens"]
    if (any(not isinstance(a, str) or a not in supported for a in allergens)
            or len(set(allergens)) != len(allergens)):
        invalid()
    causes = normalized["allergen_causing_ingredients"]
    if set(causes) != set(allergens):
        invalid()
    groups = {}
    for group in normalized["ingredients"]:
        if (not isinstance(group, dict) or not isinstance(group.get("name"), str)
                or not group["name"].strip() or group["name"] in groups
                or not isinstance(group.get("allergens"), list)
                or any(not isinstance(a, str) or a not in supported for a in group["allergens"])
                or not isinstance(group.get("evidence"), list) or not group["evidence"]
                or not isinstance(group.get("members"), list) or not group["members"]):
            invalid()
        for evidence in group["evidence"]:
            if (not isinstance(evidence, dict) or not isinstance(evidence.get("allergens"), list)
                    or any(not isinstance(a, str) or a not in supported for a in evidence["allergens"])):
                invalid()
        if {a for e in group["evidence"] for a in e["allergens"]} != set(group["allergens"]):
            invalid()
        groups[group["name"]] = group
    if {a for g in groups.values() for a in g["allergens"]} != set(allergens):
        invalid()
    for allergen, records in causes.items():
        if not isinstance(records, list) or not records:
            invalid()
        expected_names = {g["name"] for g in groups.values() if allergen in g["allergens"]}
        names = []
        for cause in records:
            if not isinstance(cause, dict) or not isinstance(cause.get("ingredient"), str):
                invalid()
            group = groups.get(cause["ingredient"])
            if (group is None or allergen not in group["allergens"]
                    or not isinstance(cause.get("sources"), list) or not cause["sources"]
                    or not isinstance(cause.get("evidence"), list) or not cause["evidence"]
                    or not isinstance(cause.get("original_members"), list) or not cause["original_members"]):
                invalid()
            for evidence in cause["evidence"]:
                if (not isinstance(evidence, dict) or evidence not in group["evidence"]
                        or not isinstance(evidence.get("allergens"), list)
                        or allergen not in evidence["allergens"]):
                    invalid()
            if cause["evidence"] != [e for e in group["evidence"] if allergen in e["allergens"]]:
                invalid()
            if sorted(cause["sources"]) != sorted({e.get("source") for e in cause["evidence"]}):
                invalid()
            originals = []
            for member in group["members"]:
                if (not isinstance(member, dict) or not isinstance(member.get("allergens"), list)
                        or not isinstance(member.get("evidence"), list)
                        or not isinstance(member.get("id"), str) or not isinstance(member.get("name"), str)):
                    invalid()
                if allergen in member["allergens"]:
                    originals.append({"id": member["id"], "name": member["name"],
                                      "evidence": [e for e in member["evidence"]
                                                   if isinstance(e, dict) and allergen in e.get("allergens", [])]})
            if cause["original_members"] != originals:
                invalid()
            names.append(cause["ingredient"])
        if set(names) != expected_names or len(names) != len(expected_names):
            invalid()


def match_structured_allergens(normalized, user_allergens, *, categories):
    """Compare canonical categories and copy original cause records unchanged."""
    _validate_evidence(normalized, categories)
    user_allergen_service.validate_user_allergens(user_allergens)
    selected = set(user_allergens)

    matches = [{"allergen": a, "causes": deepcopy(normalized["allergen_causing_ingredients"][a])}
               for a in normalized["allergens"] if a in selected]
    return {
        "status": "completed",
        "method": METHOD,
        "profile_source": "firestore",
        "selected_allergies": list(user_allergens),
        "resolved_categories": sorted(selected),
        # Retain the existing response fields; each selected name is already canonical.
        "profile_category_resolutions": [{"profile_term": value, "categories": [value]}
                                         for value in user_allergens],
        "unresolved_profile_terms": [],
        "match_status": "potential_matches_found" if matches else "no_known_matches",
        "matches": matches,
        # Include unmapped members even when a different member in the same
        # display group supplies allergen links. Empty links never prove safety.
        "ingredients_without_identified_allergens": [
            {"name": g["name"], "members": [deepcopy(m) for m in g["members"] if not m["allergens"]]}
            for g in normalized["ingredients"] if any(not m["allergens"] for m in g["members"])],
        "mapping_disagreements": deepcopy(normalized["mapping_disagreements"]),
        "safety_assessment": "not_established",
        "notice": SAFETY_NOTICE,
        "category_scope_note": (
            "Canonical allergen categories are compared exactly. Cereals containing gluten "
            "does not confirm wheat specifically."
        ),
    }


def personalize_dish_result(result, verified_uid, *, categories):
    """Called only by the authenticated Dish endpoint, after normalization."""
    if not isinstance(verified_uid, str) or not verified_uid.strip():
        raise ValueError("A verified Firebase UID is required.")
    stages = result.get("stages", [])
    normalized_stages = [s for s in stages if s.get("id") == "normalization"]
    if (result.get("decision") != "accepted"
            or result.get("semantic_normalization_performed") is not True
            or len(normalized_stages) != 1
            or normalized_stages[0].get("status") != "complete"):
        raise DishEvidenceError("Successful Claude normalization is required.")
    normalized = normalized_stages[0].get("data")
    _validate_evidence(normalized, categories)
    allergies = user_allergen_service.fetch_user_allergens_from_db(user_id=verified_uid)
    personalization = match_structured_allergens(normalized, allergies, categories=categories)
    personalization["profile_read_at"] = datetime.now(timezone.utc).isoformat()
    output = deepcopy(result)
    output.update(
        personalization=personalization,
        user_allergy_matching_performed=True,
        stopped_at="after_user_allergy_matching",
        message="Dish analysis and personalized allergen comparison completed. " + SAFETY_NOTICE,
    )
    return output
