"""Saved selections remain authoritative across saves and successive scans.

All extraction and database operations are local doubles; no providers are used.
"""
import json
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
from main import app
from app.auth import get_current_user


class TestAllergyRaceConditionBackend(unittest.TestCase):
    def setUp(self):
        app.dependency_overrides[get_current_user] = lambda: {"uid": "race_condition_test_user"}
        self.addCleanup(app.dependency_overrides.clear)
        self.client = TestClient(app)
        self.addCleanup(self.client.close)
        self.enterContext(patch("main.extract_ingredients", side_effect=lambda text: text))

    def test_text_payload_cannot_override_saved_selections(self):
        with patch("main.fetch_user_allergens_from_db", return_value=["Milk"]) as fetch:
            response = self.client.post("/scan/text", json={
                "text": "Milk, Sugar", "user_allergens": ["Cereals containing gluten"]})
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json()["is_safe"])
        self.assertTrue(next(d for d in response.json()["allergens_detected"] if d["allergen"] == "Milk")["is_user_allergen"])
        fetch.assert_called_once_with(user_id="race_condition_test_user")

    def test_image_payload_cannot_override_saved_selections(self):
        with patch("main.check_image_quality", return_value={"accepted": True}), \
             patch("main.perform_ocr", return_value=("Milk, Cream", "mock")), \
             patch("main.fetch_user_allergens_from_db", return_value=["Milk"]) as fetch:
            response = self.client.post("/scan/image", files={"file": ("label.jpg", b"synthetic", "image/jpeg")},
                                        data={"user_allergens": json.dumps(["Fish"])})
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json()["is_safe"])
        fetch.assert_called_once_with(user_id="race_condition_test_user")

    def test_remaining_selected_allergens_are_still_detected(self):
        with patch("main.fetch_user_allergens_from_db", return_value=["Cereals containing gluten", "Egg"]):
            response = self.client.post("/scan/text", json={"text": "Wheat flour, Eggs, Sugar"})
        self.assertEqual(response.status_code, 200)
        flagged = {d["allergen"] for d in response.json()["allergens_detected"] if d["is_user_allergen"]}
        self.assertEqual(flagged, {"Cereals containing gluten", "Egg"})
        self.assertFalse(response.json()["is_safe"])

    def test_unselected_allergens_remain_visible(self):
        with patch("main.fetch_user_allergens_from_db", return_value=["Cereals containing gluten"]):
            response = self.client.post("/scan/text", json={"text": "Roasted Peanuts, Salt"})
        self.assertEqual(response.status_code, 200)
        peanut = next(d for d in response.json()["allergens_detected"] if d["allergen"] == "Peanut")
        self.assertFalse(peanut["is_user_allergen"])
        self.assertTrue(response.json()["is_safe"])

    def test_empty_payload_cannot_disable_saved_allergies(self):
        with patch("main.fetch_user_allergens_from_db", return_value=["Milk", "Tree nuts"]) as fetch:
            response = self.client.post("/scan/text", json={"text": "Milk, Cashews, Almonds", "user_allergens": []})
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json()["is_safe"])
        fetch.assert_called_once_with(user_id="race_condition_test_user")

    def test_next_scan_reads_the_confirmed_saved_selection_without_caching(self):
        stored = ["Milk"]
        def save(*, user_id, allergies):
            self.assertEqual(user_id, "race_condition_test_user")
            stored[:] = allergies
            return True
        with patch("main.save_user_allergens_in_db", side_effect=save), \
             patch("main.fetch_user_allergens_from_db", side_effect=lambda **_: list(stored)) as fetch:
            first = self.client.post("/scan/text", json={"text": "Milk"})
            saved = self.client.put("/users/me/allergies", json={"allergies": ["Fish"]})
            second = self.client.post("/scan/text", json={"text": "Milk"})
        self.assertEqual(saved.status_code, 200)
        self.assertEqual(saved.json()["allergies"], ["Fish"])
        self.assertFalse(first.json()["is_safe"])
        self.assertTrue(second.json()["is_safe"])
        self.assertEqual(fetch.call_count, 2)


if __name__ == "__main__":
    unittest.main()
