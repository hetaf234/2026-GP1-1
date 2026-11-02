import os
import sys
import json
import unittest
from unittest.mock import patch, MagicMock

SERVER_DIR = os.path.dirname(os.path.abspath(__file__))
if SERVER_DIR not in sys.path:
    sys.path.insert(0, SERVER_DIR)

from fastapi.testclient import TestClient
from main import app
from app.auth import get_current_user
from app.services.user_allergen_service import (
    UserDocumentNotFoundError,
    DatabaseUnavailableError,
    InvalidAllergyDataError,
    fetch_user_allergens_from_db,
)

client = TestClient(app)

class TestFirestoreAuthoritativeAllergy(unittest.TestCase):
    def setUp(self):
        self.enterContext(patch("main.extract_ingredients", side_effect=lambda text: text.split(":", 1)[-1].strip()))
        self.mock_user = {
            "uid": "user_alice_123",
            "email": "alice@misbar.local",
            "name": "Alice",
        }
        app.dependency_overrides[get_current_user] = lambda: self.mock_user

    def tearDown(self):
        app.dependency_overrides.clear()

    @patch("main.fetch_user_allergens_from_db")
    def test_3_and_9_scans_retrieve_from_firestore_not_payload(self, mock_fetch):
        """
        Verify: Every scan (text and image) retrieves allergies directly from Firestore
        using verified UID, and NEVER uses request payloads.
        """
        mock_fetch.return_value = ["Milk"]

        # Text scan
        resp = client.post("/scan/text", json={"text": "Ingredients: Milk, Sugar"})
        self.assertEqual(resp.status_code, 200)
        mock_fetch.assert_called_with(user_id="user_alice_123")
        data = resp.json()
        self.assertFalse(data["is_safe"])
        user_allergens = [d for d in data["allergens_detected"] if d["is_user_allergen"]]
        self.assertEqual(len(user_allergens), 1)
        self.assertIn("milk", user_allergens[0]["allergen"].lower() + str(user_allergens[0]["matched_ingredients"]).lower())

    @patch("main.fetch_user_allergens_from_db")
    def test_4_forged_user_allergens_field_cannot_affect_text_scan(self, mock_fetch):
        """
        Verify: Supplying a forged 'user_allergens' field in a JSON text scan request
        has ZERO effect. Backend retrieves strictly from Firestore.
        """
        # User in Firestore has 'Milk'
        mock_fetch.return_value = ["Milk"]

        # Attacker / client attempts to forge user_allergens: [] to bypass Dairy detection
        resp = client.post("/scan/text", json={
            "text": "Ingredients: Whole milk, Cream",
            "user_allergens": []  # Forged override attempt!
        })

        self.assertEqual(resp.status_code, 200)
        data = resp.json()
        # Forged list was ignored; Dairy from Firestore was used!
        self.assertFalse(data["is_safe"], "Forged empty user_allergens must NOT bypass Firestore Milk")
        user_allergens = [d for d in data["allergens_detected"] if d["is_user_allergen"]]
        self.assertGreater(len(user_allergens), 0)

    @patch("main.fetch_user_allergens_from_db")
    @patch("main.perform_ocr")
    @patch("main.extract_ingredients")
    @patch("main.check_image_quality")
    def test_4_and_9_forged_user_allergens_field_cannot_affect_image_scan(
        self, mock_quality, mock_extract, mock_ocr, mock_fetch
    ):
        """
        Verify: Supplying a forged 'user_allergens' in multipart form data to /scan/image
        has ZERO effect. Backend retrieves strictly from Firestore.
        """
        mock_quality.return_value = {"accepted": True}
        mock_ocr.return_value = ("Ingredients: Whole milk, Cream", "mock_vision")
        mock_extract.return_value = "Whole milk, Cream"
        mock_fetch.return_value = ["Milk"]

        fake_image = b"\xff\xd8\xff\xe0\x00\x10JFIF" + b"\x00" * 100

        # Attacker sends forged user_allergens in form-data
        resp = client.post(
            "/scan/image",
            files={"file": ("label.jpg", fake_image, "image/jpeg")},
            data={"user_allergens": json.dumps([])}  # Forged override!
        )

        self.assertEqual(resp.status_code, 200)
        data = resp.json()
        self.assertFalse(data["is_safe"], "Forged user_allergens in multipart form must be ignored")
        user_allergens = [d for d in data["allergens_detected"] if d["is_user_allergen"]]
        self.assertGreater(len(user_allergens), 0)
        mock_fetch.assert_called_with(user_id="user_alice_123")

    @patch("main.fetch_user_allergens_from_db")
    def test_5_user_isolation_strictly_derives_uid_from_token(self, mock_fetch):
        """
        Verify: User can only access and scan against their own Firestore record.
        """
        mock_fetch.return_value = ["Cereals containing gluten"]

        # Call endpoint as user_alice_123
        resp = client.post("/scan/text", json={"text": "Ingredients: Wheat flour"})
        self.assertEqual(resp.status_code, 200)
        mock_fetch.assert_called_with(user_id="user_alice_123")

        # Now simulate a different authenticated user Bob
        app.dependency_overrides[get_current_user] = lambda: {
            "uid": "user_bob_456",
            "email": "bob@misbar.local"
        }
        mock_fetch.reset_mock()
        mock_fetch.return_value = ["Peanut"]

        resp2 = client.post("/scan/text", json={"text": "Ingredients: Wheat flour"})
        self.assertEqual(resp2.status_code, 200)
        mock_fetch.assert_called_with(user_id="user_bob_456")
        # For Bob, wheat is safe because Bob only has Peanut
        self.assertTrue(resp2.json()["is_safe"])

    @patch("main.fetch_user_allergens_from_db")
    def test_6_empty_allergy_list_is_invalid_and_distinct_from_firestore_failure(self, mock_fetch):
        """A saved empty list is invalid; missing profiles and DB failures stay distinct."""
        mock_fetch.return_value = []
        resp_empty = client.post("/scan/text", json={"text": "Ingredients: Milk, Peanuts, Wheat"})
        self.assertEqual(resp_empty.status_code, 500)
        self.assertNotIn("is_safe", resp_empty.json())

        # Case B: Missing user document in Firestore -> 404
        mock_fetch.side_effect = UserDocumentNotFoundError("Doc missing")
        resp_missing = client.post("/scan/text", json={"text": "Ingredients: Milk"})
        self.assertEqual(resp_missing.status_code, 404)
        self.assertIn("not found", resp_missing.json()["detail"].lower())

        # Case C: Firestore connection failure -> 503
        mock_fetch.side_effect = DatabaseUnavailableError("Network timeout")
        resp_down = client.post("/scan/text", json={"text": "Ingredients: Milk"})
        self.assertEqual(resp_down.status_code, 503)
        self.assertIn("unavailable", resp_down.json()["detail"].lower())

        # Case D: Corrupted database field -> 500
        mock_fetch.side_effect = InvalidAllergyDataError("Field not a list")
        resp_corrupt = client.post("/scan/text", json={"text": "Ingredients: Milk"})
        self.assertEqual(resp_corrupt.status_code, 500)
        self.assertIn("invalid", resp_corrupt.json()["detail"].lower())

    @patch("main.fetch_user_allergens_from_db")
    def test_8_remaining_allergens_flagged_and_unselected_visible_globally(self, mock_fetch):
        """
        Verify: Remaining selected allergies are flagged as user allergens,
        while unselected allergens remain visible in global detections with is_user_allergen=False.
        """
        # User has only Cereals containing gluten in Firestore
        mock_fetch.return_value = ["Cereals containing gluten"]

        resp = client.post("/scan/text", json={"text": "Ingredients: Wheat flour, Milk, Peanuts"})
        self.assertEqual(resp.status_code, 200)
        data = resp.json()
        self.assertFalse(data["is_safe"], "Product contains Gluten which user is allergic to")

        # Gluten must have is_user_allergen=True
        gluten = next((d for d in data["allergens_detected"] if "gluten" in d["allergen"].lower() or "cereals" in d["allergen"].lower()), None)
        self.assertIsNotNone(gluten)
        self.assertTrue(gluten["is_user_allergen"])

        # Milk and Peanuts must be present globally with is_user_allergen=False
        milk = next((d for d in data["allergens_detected"] if "milk" in d["allergen"].lower() or "dairy" in d["allergen"].lower()), None)
        self.assertIsNotNone(milk)
        self.assertFalse(milk["is_user_allergen"])

        peanut = next((d for d in data["allergens_detected"] if "peanut" in d["allergen"].lower()), None)
        self.assertIsNotNone(peanut)
        self.assertFalse(peanut["is_user_allergen"])

class TestCanonicalAllergyStorageAndMatching(unittest.TestCase):
    """Real existing service paths against an in-memory Firestore double."""
    def setUp(self):
        from app.services import allergen_service, user_allergen_service
        self.matcher = allergen_service
        self.service = user_allergen_service
        self.db = MagicMock()
        self.ref = self.db.collection.return_value.document.return_value
        self.doc = self.ref.get.return_value
        self.doc.exists = True
        self.doc.to_dict.return_value = {"allergies": ["Milk"]}
        self.enterContext(patch("firebase_admin.firestore.transactional", side_effect=lambda fn: fn))
        self.enterContext(patch.object(self.service, "get_firestore_client", return_value=self.db))
        self.enterContext(patch("main.extract_ingredients", side_effect=lambda text: text))
        app.dependency_overrides[get_current_user] = lambda: {"uid": "verified-only"}
        self.addCleanup(app.dependency_overrides.clear)
        self.client = TestClient(app)
        self.addCleanup(self.client.close)

    def invalid_lists(self):
        return [None, [], "Milk", {"Milk": True}, [None], [12], [True], [""], [" "],
                ["Dairy"], ["Egg allergy"], ["Soy"], ["Peanuts"], ["Shellfish"],
                ["Nuts"], ["Gluten"], ["sulfites"], ["حساسية Milk"], ["Milkshake"],
                ["nut"], ["ish"], ["milk"], [" Milk"], ["Milk "], ["Milk", "Milk"],
                ["Milk", "not supported"]]

    def test_all_fourteen_categories_are_exact_and_agree_with_flutter(self):
        expected = ["Celery", "Cereals containing gluten", "Crustaceans", "Egg", "Fish",
                    "Lupin", "Milk", "Molluscs", "Mustard", "Peanut", "Sesame", "Soybean",
                    "Sulphur dioxide and sulphites", "Tree nuts"]
        self.assertEqual(self.matcher.get_available_categories(), expected)
        from pathlib import Path
        import re
        flutter = Path(SERVER_DIR).parents[1] / "frontend/lib/models/scan_result.dart"
        names = re.findall(r"name: '([^']+)'", flutter.read_text())
        self.assertEqual(sorted(names), expected)
        self.assertEqual(len(names), 14)

    def test_all_fourteen_categories_save_and_read_without_conversion(self):
        values = self.matcher.get_available_categories()
        self.doc.to_dict.return_value = {"allergies": values}
        self.assertEqual(self.service.fetch_user_allergens_from_db("verified-only"), values)
        self.assertTrue(self.service.save_user_allergens_in_db("verified-only", values))
        payload = self.db.transaction.return_value.set.call_args.args[1]
        self.assertEqual(payload["allergies"], values)
        self.assertEqual(self.db.transaction.return_value.set.call_args.kwargs, {"merge": True})
        self.assertEqual(self.service.get_user_profile_from_db("verified-only")["allergies"], values)
        self.assertEqual(self.client.get("/users/me/allergies").json(),
                         {"allergies": values, "allergy_selection_saved": True})

    def test_invalid_saves_are_rejected_before_any_database_access(self):
        for values in self.invalid_lists():
            with self.subTest(values=values):
                self.db.reset_mock()
                with self.assertRaises(InvalidAllergyDataError):
                    self.service.save_user_allergens_in_db("verified-only", values)
                self.db.collection.assert_not_called()

    def test_invalid_saved_values_fail_in_both_read_paths(self):
        for values in self.invalid_lists():
            self.doc.to_dict.return_value = {"allergies": values}
            with self.subTest(values=values):
                for read in [self.service.fetch_user_allergens_from_db, self.service.get_user_profile_from_db]:
                    with self.assertRaises(InvalidAllergyDataError):
                        read("verified-only")

    def test_invalid_http_save_never_writes_or_echoes_supplied_values(self):
        for body in [{}] + [{"allergies": values} for values in self.invalid_lists()]:
            with self.subTest(body=body):
                self.db.reset_mock()
                response = self.client.put("/users/me/allergies", json=body)
                self.assertEqual(response.status_code, 422)
                self.db.collection.assert_not_called()
                self.assertNotIn("not supported", response.text)

    def test_canonical_http_save_is_confirmed_only_after_write(self):
        values = ["Sulphur dioxide and sulphites", "Peanut", "Tree nuts"]
        response = self.client.put("/users/me/allergies", json={"allergies": values, "uid": "forged"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"allergies": values, "allergy_selection_saved": True})
        self.db.collection.assert_called_once_with("users")
        self.db.collection.return_value.document.assert_called_once_with("verified-only")
        self.assertEqual(self.db.transaction.return_value.set.call_args.args[1]["allergies"], values)

    def test_failed_write_never_returns_success(self):
        self.db.transaction.return_value.set.side_effect = RuntimeError("PRIVATE_WRITE_FAILURE")
        response = self.client.put("/users/me/allergies", json={"allergies": ["Milk"]})
        self.assertEqual(response.status_code, 503)
        self.assertNotIn("PRIVATE_WRITE_FAILURE", response.text)

    def test_new_user_has_explicit_unsaved_state_and_cannot_scan(self):
        for exists, data in [(False, None), (True, {"name": "New user"})]:
            with self.subTest(exists=exists):
                self.doc.exists = exists
                self.doc.to_dict.return_value = data
                response = self.client.get("/users/me/allergies")
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.json(), {"allergies": [], "allergy_selection_saved": False})
                profile = self.client.get("/users/me")
                self.assertEqual(profile.status_code, 200)
                self.assertFalse(profile.json()["allergy_selection_saved"])
                self.assertEqual(profile.json()["allergies"], [])
                scan = self.client.post("/scan/text", json={"text": "Milk"})
                self.assertEqual(scan.status_code, 404)
                self.assertNotIn("is_safe", scan.json())

    def test_profile_creation_does_not_save_an_empty_selection(self):
        self.doc.exists = False
        response = self.client.post("/users/profile", json={"name": "New user"})
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json()["allergy_selection_saved"])
        self.assertNotIn("allergies", self.db.transaction.return_value.set.call_args.args[1])
        self.assertIn("createdAt", self.db.transaction.return_value.set.call_args.args[1])

    def test_profile_update_does_not_replace_saved_selections(self):
        self.doc.to_dict.return_value = {"name": "Existing", "allergies": ["Milk"]}
        response = self.client.post("/users/profile", json={"name": "Changed"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["allergies"], ["Milk"])
        self.assertNotIn("allergies", self.db.transaction.return_value.set.call_args.args[1])

    def test_failed_retrieval_never_becomes_an_empty_success(self):
        self.ref.get.side_effect = RuntimeError("PRIVATE_READ_FAILURE")
        for route in ["/users/me", "/users/me/allergies"]:
            with self.subTest(route=route):
                response = self.client.get(route)
                self.assertEqual(response.status_code, 503)
                self.assertNotIn("allergies", response.json())
                self.assertNotIn("PRIVATE_READ_FAILURE", response.text)
        response = self.client.post("/scan/text", json={"text": "Milk"})
        self.assertEqual(response.status_code, 503)

    def test_corrupt_profile_never_becomes_a_valid_empty_response(self):
        for values in [[], ["Dairy"], ["Milk", None], ["Milk", "Milk"]]:
            self.doc.to_dict.return_value = {"allergies": values}
            for route in ["/users/me", "/users/me/allergies"]:
                with self.subTest(values=values, route=route):
                    response = self.client.get(route)
                    self.assertEqual(response.status_code, 500)
                    self.assertNotIn("allergies", response.json())

    def test_label_text_and_image_reject_invalid_stored_selections(self):
        with patch("main.check_image_quality", return_value={"accepted": True}), \
             patch("main.perform_ocr", return_value=("Milk", "mock_ocr")):
            for values in [[], ["Dairy"], ["Milk", "unknown"], ["Milk", "Milk"]]:
                self.doc.to_dict.return_value = {"allergies": values}
                for image in [False, True]:
                    with self.subTest(values=values, image=image):
                        response = (self.client.post("/scan/image", files={"file": ("label.png", b"synthetic", "image/png")})
                                    if image else self.client.post("/scan/text", json={"text": "Milk"}))
                        self.assertEqual(response.status_code, 500)
                        self.assertNotIn("is_safe", response.json())

    def test_label_matching_retains_triggering_keywords_for_all_fourteen(self):
        self.matcher.load_allergen_dataset()
        for category in self.matcher.get_available_categories():
            keyword = next(k for c, k, _ in self.matcher._allergen_rules if c == category)
            with self.subTest(category=category):
                detections, is_safe = self.matcher.detect_allergens(keyword, [category])
                selected = [d for d in detections if d.is_user_allergen]
                self.assertFalse(is_safe)
                self.assertEqual([d.allergen for d in selected], [category])
                self.assertIn(keyword, selected[0].matched_ingredients)

    def test_label_and_dish_json_and_sse_read_the_same_canonical_saved_selections(self):
        from test_dish_sse import frames, ProgressPipeline
        from deployment.dish_api import dish_router
        from fastapi import FastAPI
        from copy import deepcopy
        values = ["Egg", "Milk", "Soybean"]
        self.matcher.load_allergen_dataset()
        self.doc.to_dict.return_value = {"allergies": values}
        keywords = [next(k for c, k, _ in self.matcher._allergen_rules if c == value) for value in values]
        label = self.client.post("/scan/text", json={"text": ", ".join(keywords)})
        self.assertEqual(label.status_code, 200)
        self.assertEqual({d["allergen"] for d in label.json()["allergens_detected"] if d["is_user_allergen"]}, set(values))
        pipeline = ProgressPipeline()
        before = deepcopy(pipeline.result)
        dish_app = FastAPI()
        dish_app.include_router(dish_router(pipeline, lambda: {"uid": "verified-only"}))
        with TestClient(dish_app) as client:
            for streaming in [False, True]:
                with self.subTest(streaming=streaming):
                    response = client.post("/scan/dish", files={"file": ("dish.png", b"synthetic", "image/png")},
                                           headers={"Accept": "text/event-stream" if streaming else "application/json"})
                    self.assertEqual(response.status_code, 200)
                    outcome = frames(response.text)[-1][1] if streaming else None
                    if outcome is not None:
                        self.assertEqual(outcome["http_status"], 200)
                    result = outcome["result"] if streaming else response.json()
                    self.assertEqual(result["personalization"]["selected_allergies"], values)
                    self.assertEqual({m["allergen"] for m in result["personalization"]["matches"]}, set(values))
                    for match in result["personalization"]["matches"]:
                        self.assertEqual(match["causes"], before["stages"][-1]["data"]["allergen_causing_ingredients"][match["allergen"]])
        self.assertEqual(pipeline.result, before)
        self.assertTrue(all(call.args == ("verified-only",) for call in self.db.collection.return_value.document.call_args_list))
        self.assertEqual(self.ref.get.call_count, 3)
        self.ref.set.assert_not_called()

    def test_label_detector_never_accepts_invalid_preferences_even_without_text(self):
        for values in self.invalid_lists():
            for text in ["Milk, Peanut", ""]:
                with self.subTest(values=values, text=text), self.assertRaises(InvalidAllergyDataError):
                    self.matcher.detect_allergens(text, values)

    def test_missing_or_incomplete_keyword_dataset_fails_closed(self):
        from io import StringIO
        for source in [None, "Allergen,Keyword,Language\nMilk,milk,en\n"]:
            with self.subTest(source=source), patch.object(self.matcher, "_dataset_loaded", False):
                if source is None:
                    with patch.object(self.matcher, "ALLERGEN_DATASET_FILE", None), self.assertRaises(RuntimeError):
                        self.matcher.detect_allergens("Milk", ["Milk"])
                else:
                    with patch("builtins.open", return_value=StringIO(source)), self.assertRaises(RuntimeError):
                        self.matcher.detect_allergens("Milk", ["Milk"])


if __name__ == "__main__":
    unittest.main()
