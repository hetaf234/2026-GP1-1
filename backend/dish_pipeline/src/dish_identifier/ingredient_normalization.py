"""Experimental name grouping; allergen links come only from original evidence."""
from __future__ import annotations

from collections import Counter, defaultdict
from copy import deepcopy
import json

from .claude_client import StageError

METHOD = "claude_ingredient_names_v1"


def normalization_records(merged):
    """Bind ids to this exact pre-normalization snapshot; send only names/sources."""
    return [{"id": f"ingredient_{index:03d}", "name": item["name"], "sources": list(item["sources"])}
            for index, item in enumerate(merged["ingredients"], 1)]


def render_prompt(template, dish, records):
    # Replace the ingredient placeholder first: input text is never a template.
    prefix, marker, suffix = template.partition("{ingredients_json}")
    if not marker or "{ingredients_json}" in suffix or "{dish_name}" not in prefix:
        raise ValueError("Invalid ingredient-normalization prompt template")
    return prefix.replace("{dish_name}", dish) + json.dumps(records, ensure_ascii=False) + suffix


def apply_normalization(merged, proposal):
    """Validate a total partition, then rebuild groups and causes without model links."""
    def invalid(message):
        raise StageError("invalid_normalization", message)

    records = normalization_records(merged)
    originals = {record["id"]: item for record, item in zip(records, merged["ingredients"])}
    if not isinstance(proposal, dict) or set(proposal) != {"groups"} or not isinstance(proposal["groups"], list):
        invalid("Normalization must contain only a groups array.")
    seen_ids, seen_names, groups = set(), set(), []
    for proposed in proposal["groups"]:
        if not isinstance(proposed, dict) or set(proposed) != {"canonical_name", "member_ids", "reason"}:
            invalid("A normalization group has missing or unexpected fields.")
        name, ids, reason = proposed["canonical_name"], proposed["member_ids"], proposed["reason"]
        if not isinstance(name, str) or not name.strip() or not isinstance(reason, str) or not reason.strip():
            invalid("A normalization group has an empty name or reason.")
        name = " ".join(name.split())
        if name.casefold() in seen_names:
            invalid("Separate normalization groups must not have the same canonical name.")
        if not isinstance(ids, list) or not ids:
            invalid("Every normalization group needs at least one original id.")
        for member_id in ids:
            if not isinstance(member_id, str) or member_id not in originals or member_id in seen_ids:
                invalid("Normalization contains an unknown or repeated original id.")
            seen_ids.add(member_id)
        seen_names.add(name.casefold())
        members = [{"id": member_id, **deepcopy(originals[member_id])} for member_id in ids]
        evidence = [deepcopy(e) for member in members for e in member["evidence"]]
        allergens = sorted({a for e in evidence for a in e["allergens"]})
        expected = sorted({a for member in members for a in member["allergens"]})
        if allergens != expected:
            invalid("Original ingredient links disagree with their source evidence.")
        sources = [s for s in ("Dataset", "Claude") if any(e["source"] == s for e in evidence)]
        groups.append({"name": name, "member_ids": list(ids), "members": members,
                       "reason": reason, "sources": sources, "allergens": allergens, "evidence": evidence,
                       "allergen_coverage": {
                           a: {"member_ids": [m["id"] for m in members if a in m["allergens"]],
                               "applies_to_all_members": all(a in m["allergens"] for m in members)}
                           for a in allergens}})
    if seen_ids != set(originals):
        invalid("Normalization omitted original ingredient ids.")

    causes, disagreements = defaultdict(list), []
    for group in groups:
        per_source = {s: sorted({a for e in group["evidence"] if e["source"] == s for a in e["allergens"]})
                      for s in group["sources"]}
        if len(per_source) > 1 and len({tuple(a) for a in per_source.values()}) > 1:
            disagreements.append({"ingredient": group["name"], "source_allergens": per_source})
        for allergen in group["allergens"]:
            evidence = [deepcopy(e) for e in group["evidence"] if allergen in e["allergens"]]
            causes[allergen].append({"ingredient": group["name"],
                "sources": sorted({e["source"] for e in evidence}), "evidence": evidence,
                "original_members": [{"id": m["id"], "name": m["name"],
                    "evidence": [deepcopy(e) for e in m["evidence"] if allergen in e["allergens"]]}
                    for m in group["members"] if allergen in m["allergens"]]})

    def fingerprint(items):
        return Counter(json.dumps(e, sort_keys=True, ensure_ascii=False) for item in items for e in item["evidence"])

    preserved = (fingerprint(groups) == fingerprint(merged["ingredients"]) and sorted(causes) == merged["allergens"])
    if not preserved:
        invalid("Normalization did not preserve all original evidence and allergen categories.")
    return {"ingredients": groups, "allergens": sorted(causes),
            "allergen_causing_ingredients": dict(sorted(causes.items())), "mapping_disagreements": disagreements,
            "normalization_applied": True, "normalization_method": METHOD, "semantic_normalization_applied": True,
            "review_status": "experimental_pending_human_review", "original_ingredient_count": len(originals),
            "normalized_ingredient_count": len(groups), "all_evidence_preserved": True,
            "available_sources": list(merged["available_sources"])}
