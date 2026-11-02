"""Synthetic Dish evidence and authenticated endpoint tests; no external calls.

Run from the repository root with:
python -m unittest discover -s Packaged-Food-Recognition/Server -p test_dish_allergen_matching.py -v
"""
import asyncio
from copy import deepcopy
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import patch

SERVER = Path(__file__).resolve().parent
REPOSITORY = SERVER.parents[1]
sys.path.insert(0, str(REPOSITORY))
sys.path.insert(0, str(SERVER))

from fastapi import FastAPI, Header, HTTPException
from fastapi.testclient import TestClient
import httpx

from app.services import allergen_service, user_allergen_service
from app.services.dish_allergen_service import (
    DishEvidenceError, match_structured_allergens, personalize_dish_result,
)
from deployment.dish_api import dish_router


CATEGORIES = allergen_service.get_available_categories()
AUTH = {"Authorization": "Bearer alice-token"}


def normalized_fixture():
    """Explicit fictional category links, never inferred from these names."""
    def group(name, members):
        evidence = [deepcopy(e) for m in members for e in m["evidence"]]
        allergens = sorted({a for e in evidence for a in e["allergens"]})
        return {"name": name, "member_ids": [m["id"] for m in members], "members": members,
                "allergens": allergens, "evidence": evidence,
                "sources": sorted({e["source"] for e in evidence}), "reason": "Synthetic grouping.",
                "allergen_coverage": {a: {
                    "member_ids": [m["id"] for m in members if a in m["allergens"]],
                    "applies_to_all_members": all(a in m["allergens"] for m in members)} for a in allergens}}

    def member(index, name, source, allergens, confidence):
        evidence = {"source": source, "original_name": name, "confidence": confidence,
                    "allergens": allergens, "source_index": index,
                    "mapping_evidence": [{"note": "Synthetic retained evidence"}]}
        return {"id": f"ingredient_{index:03d}", "name": name, "allergens": allergens,
                "sources": [source], "evidence": [evidence]}

    groups = [group("Sauce", [member(1, "Sauce", "Dataset", ["Milk", "Soybean"], None),
                               member(2, "special sauce", "Claude", ["Egg"], 5)]),
              group("Bread", [member(3, "Bread", "Dataset", ["Cereals containing gluten"], None),
                               member(4, "sesame bun", "Claude", ["Sesame"], 90)]),
              group("Unknown garnish", [member(5, "Unknown garnish", "Claude", [], 1)])]
    causes = {}
    for g in groups:
        for allergen in g["allergens"]:
            evidence = [deepcopy(e) for e in g["evidence"] if allergen in e["allergens"]]
            causes.setdefault(allergen, []).append({"ingredient": g["name"],
                "sources": sorted({e["source"] for e in evidence}), "evidence": evidence,
                "original_members": [{"id": m["id"], "name": m["name"],
                    "evidence": [deepcopy(e) for e in m["evidence"] if allergen in e["allergens"]]}
                    for m in g["members"] if allergen in m["allergens"]]})
    return {"ingredients": groups, "allergens": sorted(causes), "allergen_causing_ingredients": causes,
            "mapping_disagreements": [{"ingredient": "Sauce", "source_allergens": {
                "Dataset": ["Milk", "Soybean"], "Claude": ["Egg"]}}],
            "semantic_normalization_applied": True, "all_evidence_preserved": True,
            "normalization_applied": True, "review_status": "live_output_not_individually_human_reviewed"}


def pipeline_result():
    return {"decision": "accepted", "final_dish": "synthetic_dish",
            "semantic_normalization_performed": True, "user_allergy_matching_performed": False,
            "stopped_at": "before_user_allergy_matching", "message": "Original pipeline message",
            "protocol": {"assets": {"prompt": "unchanged-hash"}}, "registry_sha256": "synthetic-reference",
            "stages": [{"id": "classification", "status": "complete", "data": {
                "top1": {"dish": "synthetic_dish", "confidence": .8}}},
                {"id": "normalization", "status": "complete", "data": normalized_fixture()}]}


class MatchingTests(unittest.TestCase):
    def setUp(self):
        self.normalized = normalized_fixture()
        self.before = deepcopy(self.normalized)
        self.detector = patch.object(allergen_service, "detect_allergens", side_effect=AssertionError("No keyword detection"))
        self.detector.start()
        self.addCleanup(self.detector.stop)

    def match(self, profile):
        result = match_structured_allergens(self.normalized, profile, categories=CATEGORIES)
        self.assertEqual(self.normalized, self.before)
        self.assertNotIn("is_safe", result)
        self.assertEqual(result["safety_assessment"], "not_established")
        return result

    def test_sauce_retains_three_distinct_allergens_and_original_causes(self):
        result = self.match(["Egg", "Milk", "Soybean"])
        self.assertEqual([m["allergen"] for m in result["matches"]], ["Egg", "Milk", "Soybean"])
        for match in result["matches"]:
            self.assertEqual(match["causes"], self.normalized["allergen_causing_ingredients"][match["allergen"]])
            self.assertEqual(match["causes"][0]["ingredient"], "Sauce")
        egg = result["matches"][0]["causes"][0]
        self.assertEqual(egg["sources"], ["Claude"])
        self.assertEqual(egg["evidence"][0]["confidence"], 5)
        self.assertEqual(egg["original_members"][0]["name"], "special sauce")
        self.assertEqual(result["mapping_disagreements"], self.normalized["mapping_disagreements"])

    def test_all_fourteen_structured_categories_retain_original_low_confidence_evidence(self):
        evidence = {"source": "Claude", "original_name": "Fictional trigger", "confidence": 3,
                    "allergens": list(CATEGORIES), "mapping_evidence": [{"note": "Fictional links only"}]}
        member = {"id": "fictional_1", "name": "Fictional trigger", "allergens": list(CATEGORIES),
                  "sources": ["Claude"], "evidence": [evidence]}
        group = {"name": "Fictional group", "allergens": list(CATEGORIES),
                 "members": [member], "evidence": [evidence]}
        causes = {a: [{"ingredient": group["name"], "sources": ["Claude"], "evidence": [evidence],
                       "original_members": [{"id": member["id"], "name": member["name"], "evidence": [evidence]}]}]
                  for a in CATEGORIES}
        self.normalized.update(ingredients=[group], allergens=list(CATEGORIES),
                               allergen_causing_ingredients=causes, mapping_disagreements=[])
        self.before = deepcopy(self.normalized)
        result = self.match(list(CATEGORIES))
        self.assertEqual([m["allergen"] for m in result["matches"]], CATEGORIES)
        for match in result["matches"]:
            self.assertEqual(match["causes"], causes[match["allergen"]])
            self.assertEqual(match["causes"][0]["evidence"][0]["confidence"], 3)

    def test_generalized_names_do_not_create_or_transfer_links(self):
        result = self.match(["Sesame", "Cereals containing gluten"])
        causes = {m["allergen"]: m["causes"] for m in result["matches"]}
        self.assertEqual(causes["Sesame"][0]["original_members"][0]["name"], "sesame bun")
        self.assertEqual(causes["Cereals containing gluten"][0]["sources"], ["Dataset"])
        self.assertNotIn("Milk", causes)

    def test_all_supported_categories_are_compared_without_conversion(self):
        for category in CATEGORIES:
            with self.subTest(profile=category):
                result = self.match([category])
                self.assertEqual(result["selected_allergies"], [category])
                self.assertEqual(result["resolved_categories"], [category])
                self.assertEqual(result["profile_category_resolutions"],
                                 [{"profile_term": category, "categories": [category]}])
                self.assertEqual(result["unresolved_profile_terms"], [])

    def test_peanut_tree_nuts_and_fish_shellfish_remain_distinct(self):
        for category in ["Peanut", "Tree nuts", "Fish", "Crustaceans", "Molluscs"]:
            with self.subTest(profile=category):
                self.assertEqual(self.match([category])["resolved_categories"], [category])

    def test_duplicate_preferences_are_rejected(self):
        with self.assertRaises(user_allergen_service.InvalidAllergyDataError):
            self.match(["Egg", "Egg"])

    def test_one_allergen_retains_multiple_separate_causes(self):
        other = deepcopy(self.normalized["ingredients"][0])
        other["name"] = "Dressing"
        self.normalized["ingredients"].append(other)
        for records in self.normalized["allergen_causing_ingredients"].values():
            if records[0]["ingredient"] == "Sauce":
                cause = deepcopy(records[0])
                cause["ingredient"] = "Dressing"
                records.append(cause)
        self.before = deepcopy(self.normalized)
        result = self.match(["Egg"])
        self.assertEqual([c["ingredient"] for c in result["matches"][0]["causes"]], ["Sauce", "Dressing"])

    def test_unmapped_member_within_linked_group_remains_unresolved(self):
        unmapped = deepcopy(self.normalized["ingredients"][2]["members"][0])
        self.normalized["ingredients"][0]["members"].append(unmapped)
        self.normalized["ingredients"][0]["evidence"].extend(deepcopy(unmapped["evidence"]))
        self.before = deepcopy(self.normalized)
        result = self.match(["Egg"])
        self.assertEqual(result["ingredients_without_identified_allergens"][0]["name"], "Sauce")
        self.assertEqual(result["ingredients_without_identified_allergens"][0]["members"], [unmapped])

    def test_no_match_preserves_uncertainty_and_unmapped_ingredients(self):
        result = self.match(["Fish"])
        self.assertEqual((result["match_status"], result["status"]), ("no_known_matches", "completed"))
        self.assertEqual(result["matches"], [])
        self.assertIn("No match does not confirm", result["notice"])
        self.assertEqual(result["ingredients_without_identified_allergens"][0]["name"], "Unknown garnish")

    def test_invalid_profile_is_rejected_even_when_some_entries_are_valid(self):
        with self.assertRaises(user_allergen_service.InvalidAllergyDataError):
            self.match(["Egg", "unknown food allergy", "None"])

    def test_no_detected_allergens_still_does_not_establish_safety(self):
        self.normalized.update(ingredients=[self.normalized["ingredients"][-1]], allergens=[],
                               allergen_causing_ingredients={}, mapping_disagreements=[])
        self.before = deepcopy(self.normalized)
        result = self.match(["Egg"])
        self.assertEqual(result["matches"], [])
        self.assertEqual(result["match_status"], "no_known_matches")
        self.assertEqual(result["safety_assessment"], "not_established")

    def test_aliases_substrings_case_and_whitespace_are_rejected(self):
        for value in ["nut", "ish", "Milkshake", "Dairy", "Soy", "Shellfish", "Nuts",
                      "Egg allergy", "حساسية Milk", "milk", " Milk", "Milk "]:
            with self.subTest(value=value), self.assertRaises(user_allergen_service.InvalidAllergyDataError):
                self.match([value])

    def test_malformed_returned_profile_is_an_explicit_error(self):
        for profile in [None, "Milk", [], [None], [123], [True], [""], ["Milk", "Milk"]]:
            with self.subTest(profile=profile), self.assertRaises(user_allergen_service.InvalidAllergyDataError):
                match_structured_allergens(self.normalized, profile, categories=CATEGORIES)

    def test_missing_or_inconsistent_evidence_fails_before_profile_lookup(self):
        for mutate in [lambda n: n.pop("allergen_causing_ingredients"),
                       lambda n: n.update(all_evidence_preserved=False),
                       lambda n: n["allergens"].append("Invented"),
                       lambda n: n["allergen_causing_ingredients"].update(Egg=[]),
                       lambda n: n["allergen_causing_ingredients"]["Egg"][0].update(ingredient="Unknown garnish"),
                       lambda n: n["allergen_causing_ingredients"]["Egg"][0]["evidence"][0].update(allergens=[]),
                       lambda n: n["allergen_causing_ingredients"]["Egg"][0].update(original_members=[]),
                       lambda n: n["allergen_causing_ingredients"]["Egg"][0].update(sources=["Dataset"]),
                       lambda n: n["allergen_causing_ingredients"]["Egg"].append(deepcopy(n["allergen_causing_ingredients"]["Egg"][0]))]:
            result = pipeline_result()
            mutate(result["stages"][1]["data"])
            with patch.object(user_allergen_service, "fetch_user_allergens_from_db") as fetch:
                with self.assertRaises(DishEvidenceError):
                    personalize_dish_result(result, "verified-uid", categories=CATEGORIES)
                fetch.assert_not_called()

    def test_result_and_nested_evidence_are_independent_copies(self):
        result = self.match(["Egg"])
        result["matches"][0]["causes"][0]["evidence"][0]["confidence"] = 100
        self.assertEqual(self.normalized, self.before)


def authenticate(authorization: str | None = Header(None)):
    users = {"Bearer alice-token": "alice-verified", "Bearer bob-token": "bob-verified"}
    if authorization not in users:
        raise HTTPException(401, "Authentication required")
    return {"uid": users[authorization]}


class FakePipeline:
    categories = CATEGORIES

    def __init__(self):
        self.result = pipeline_result()
        self.paths = []
        self.block = False
        self.entered = threading.Event()
        self.release = threading.Event()

    def run(self, path, *, filename):
        self.paths.append(Path(path))
        if self.block:
            self.entered.set()
            if not self.release.wait(5):
                raise RuntimeError("Synthetic worker timed out")
        return self.result


def make_app(pipeline):
    app = FastAPI()
    app.include_router(dish_router(pipeline, authenticate))
    return app


class EndpointTests(unittest.TestCase):
    def setUp(self):
        self.pipeline = FakePipeline()
        self.before = deepcopy(self.pipeline.result)
        self.client = TestClient(make_app(self.pipeline))
        self.addCleanup(self.client.close)
        self.fetch_patch = patch.object(user_allergen_service, "fetch_user_allergens_from_db", return_value=["Egg", "Milk", "Soybean"])
        self.fetch = self.fetch_patch.start()
        self.addCleanup(self.fetch_patch.stop)
        detector = patch.object(allergen_service, "detect_allergens", side_effect=AssertionError("Keyword detector called"))
        detector.start()
        self.addCleanup(detector.stop)

    def scan(self, headers=AUTH, data=None):
        return self.client.post("/scan/dish", headers=headers, data=data,
                                files={"file": ("../../private.png", b"synthetic", "image/png")})

    def test_verified_uid_overrides_forged_client_fields_and_preserves_all_stages(self):
        def fetch_after_normalization(**kwargs):
            self.assertTrue(self.pipeline.paths)
            self.assertEqual(self.pipeline.result["stages"][-1]["status"], "complete")
            return ["Egg", "Milk", "Soybean"]
        self.fetch.side_effect = fetch_after_normalization
        response = self.scan(data={"uid": "bob", "user_id": "bob", "user_allergens": "[]"})
        self.assertEqual(response.status_code, 200)
        result = response.json()
        self.fetch.assert_called_once_with(user_id="alice-verified")
        self.assertEqual(result["stages"], self.before["stages"])
        self.assertEqual(result["protocol"], self.before["protocol"])
        self.assertEqual(result["registry_sha256"], self.before["registry_sha256"])
        self.assertTrue(result["user_allergy_matching_performed"])
        self.assertEqual(len(result["personalization"]["matches"]), 3)
        self.assertNotIn("is_safe", result)
        self.assertEqual(self.pipeline.result, self.before)
        self.assertFalse(self.pipeline.paths[0].exists())

    def test_requests_retrieve_fresh_profiles_without_cross_user_state(self):
        self.fetch.side_effect = [["Egg"], ["Sesame"], ["Fish"]]
        a = self.scan().json()
        b = self.scan(headers={"Authorization": "Bearer bob-token"}).json()
        c = self.scan().json()
        self.assertEqual(a["personalization"]["matches"][0]["allergen"], "Egg")
        self.assertEqual(b["personalization"]["matches"][0]["allergen"], "Sesame")
        self.assertEqual(c["personalization"]["match_status"], "no_known_matches")
        self.assertEqual([c.kwargs["user_id"] for c in self.fetch.call_args_list], ["alice-verified", "bob-verified", "alice-verified"])
        self.assertEqual(self.pipeline.result, self.before)

    def test_missing_invalid_or_expired_auth_cannot_run_pipeline_or_lookup(self):
        for headers in [{}, {"Authorization": "Bearer invalid"}, {"Authorization": "Bearer expired"}]:
            with self.subTest(headers=headers):
                self.assertEqual(self.scan(headers=headers).status_code, 401)
        self.assertEqual(self.pipeline.paths, [])
        self.fetch.assert_not_called()

    def test_missing_or_malformed_verified_uid_is_rejected(self):
        for uid in [None, "", "  ", 123]:
            with self.subTest(uid=uid):
                app = FastAPI()
                app.include_router(dish_router(self.pipeline, lambda: {"uid": uid}))
                with TestClient(app) as client:
                    response = client.post("/scan/dish", files={"file": ("x.png", b"synthetic")})
                self.assertEqual(response.status_code, 401)
        self.assertEqual(self.pipeline.paths, [])
        self.fetch.assert_not_called()

    def test_each_early_pipeline_stop_skips_personalization(self):
        for stage in ["upload", "quality", "food_gate", "ood", "extraction", "fusion", "normalization"]:
            for decision, status in [("rejected", 200), ("error", 503)]:
                with self.subTest(stage=stage, decision=decision):
                    self.pipeline.result = {"decision": decision, "stopped_at": stage, "stages": [],
                                            "user_allergy_matching_performed": False}
                    response = self.scan()
                    self.assertEqual(response.status_code, status)
                    self.assertEqual(response.json(), self.pipeline.result)
        self.fetch.assert_not_called()

    def test_normalization_must_be_successful_and_present(self):
        for mutate in [lambda r: r.update(semantic_normalization_performed=False),
                       lambda r: r["stages"].pop(),
                       lambda r: r["stages"][-1].update(status="error")]:
            self.pipeline.result = pipeline_result()
            mutate(self.pipeline.result)
            response = self.scan()
            self.assertEqual(response.status_code, 503)
            self.assertEqual(response.json()["personalization"]["error_code"], "invalid_dish_evidence")
        self.fetch.assert_not_called()

    def test_profile_failures_preserve_evidence_and_do_not_leak_details(self):
        for exception, status in [(user_allergen_service.UserDocumentNotFoundError, 404),
                                  (user_allergen_service.DatabaseUnavailableError, 503),
                                  (user_allergen_service.InvalidAllergyDataError, 500)]:
            with self.subTest(exception=exception):
                self.fetch.side_effect = exception("PRIVATE_DATABASE_DETAILS")
                response = self.scan()
                self.assertEqual(response.status_code, status)
                self.assertNotIn("PRIVATE_DATABASE_DETAILS", response.text)
                self.assertEqual(response.json()["decision"], "error")
                self.assertEqual(response.json()["stages"], self.before["stages"])
                self.assertFalse(response.json()["user_allergy_matching_performed"])
                self.assertEqual(response.json()["personalization"]["safety_assessment"], "not_established")

    def test_invalid_selections_fail_closed_and_preserve_all_pipeline_evidence(self):
        for profile in [[], ["Egg", "unrecognized allergy"], ["Dairy"], ["Egg", "Egg"]]:
            with self.subTest(profile=profile):
                self.fetch.return_value = profile
                response = self.scan()
                self.assertEqual(response.status_code, 500)
                result = response.json()
                self.assertEqual(result["decision"], "error")
                self.assertEqual(result["personalization"]["error_code"], "invalid_allergy_profile")
                self.assertEqual(result["stages"], self.before["stages"])
                self.assertFalse(result["user_allergy_matching_performed"])
                self.assertEqual(result["personalization"]["safety_assessment"], "not_established")

    def test_invalid_upload_limits_precede_pipeline_and_profile(self):
        for data, expected in [(b"", 400), (b"x" * (4 * 1024 * 1024 + 1), 413)]:
            response = self.client.post("/scan/dish", headers=AUTH, files={"file": ("x.png", data)})
            self.assertEqual(response.status_code, expected)
        self.assertEqual(self.pipeline.paths, [])
        self.fetch.assert_not_called()


class CancellationTests(unittest.IsolatedAsyncioTestCase):
    async def test_cancelled_request_retains_lock_until_worker_and_matching_finish(self):
        pipeline = FakePipeline()
        pipeline.block = True
        with patch.object(user_allergen_service, "fetch_user_allergens_from_db", return_value=["Egg"]) as fetch:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=make_app(pipeline)), base_url="http://test") as client:
                async def scan():
                    return await client.post("/scan/dish", headers=AUTH, files={"file": ("x.png", b"synthetic")})
                first = asyncio.create_task(scan())
                self.assertTrue(await asyncio.to_thread(pipeline.entered.wait, 2))
                try:
                    first.cancel()
                    with self.assertRaises(asyncio.CancelledError):
                        await first
                    self.assertEqual((await scan()).status_code, 429)
                    fetch.assert_not_called()
                finally:
                    pipeline.release.set()
                for _ in range(100):
                    await asyncio.sleep(.01)
                    response = await scan()
                    if response.status_code != 429:
                        break
                self.assertEqual(response.status_code, 200)
                self.assertEqual(fetch.call_count, 2)
                self.assertTrue(all(not p.exists() for p in pipeline.paths))


if __name__ == "__main__":
    unittest.main()
