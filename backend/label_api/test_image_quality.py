import os
import sys
import unittest
from unittest.mock import patch, MagicMock

SERVER_DIR = os.path.dirname(os.path.abspath(__file__))
if SERVER_DIR not in sys.path:
    sys.path.insert(0, SERVER_DIR)

from fastapi.testclient import TestClient
from main import app
from app.auth import get_current_user

# Test client
client = TestClient(app)

def override_auth_user():
    return {"uid": "quality_test_user", "email": "test@example.com"}


class TestImageQuality(unittest.TestCase):
    def setUp(self):
        app.dependency_overrides[get_current_user] = override_auth_user
        self.addCleanup(app.dependency_overrides.clear)


    @patch("main.check_image_quality")
    def test_scan_image_rejected_when_quality_below_threshold(self, mock_quality):
        """When Sightengine quality score is below threshold (0.5), image must be rejected as low_quality."""
        mock_quality.return_value = {
            "score": 0.35,
            "threshold": 0.5,
            "accepted": False
        }

        fake_image = b"\xff\xd8\xff\xe0\x00\x10JFIF" + b"\x00" * 100
        resp = client.post(
            "/scan/image",
            files={"file": ("blurry_label.jpg", fake_image, "image/jpeg")}
        )

        self.assertEqual(resp.status_code, 200)
        data = resp.json()

        self.assertFalse(data["success"])
        self.assertEqual(data["status"], "low_quality")
        self.assertIn("Image Not Clear", data["error_title"])
        self.assertEqual(data["allergens_detected"], [])
        self.assertEqual(data["ocr_engine"], "not_run")
        self.assertEqual(data["extracted_ocr_text"], "")

    @patch("main.fetch_user_allergens_from_db")
    @patch("main.detect_allergens")
    @patch("main.extract_ingredients")
    @patch("main.perform_ocr")
    @patch("main.check_image_quality")
    def test_scan_image_proceeds_when_quality_meets_threshold(
        self, mock_quality, mock_ocr, mock_extract, mock_detect, mock_fetch_db
    ):
        """When Sightengine quality score is >= 0.5, scan proceeds to OCR and allergen analysis."""
        mock_quality.return_value = {
            "score": 0.85,
            "threshold": 0.5,
            "accepted": True
        }
        mock_ocr.return_value = ("Ingredients: Milk, Sugar", "mock_ocr")
        mock_extract.return_value = "Milk, Sugar"
        mock_fetch_db.return_value = ["Milk"]
        mock_detect.return_value = ([], True)

        fake_image = b"\xff\xd8\xff\xe0\x00\x10JFIF" + b"\x00" * 100
        resp = client.post(
            "/scan/image",
            files={"file": ("clear_label.jpg", fake_image, "image/jpeg")}
        )

        self.assertEqual(resp.status_code, 200)
        data = resp.json()

        self.assertTrue(data["success"])
        self.assertEqual(data["status"], "completed")
        mock_ocr.assert_called_once()
        mock_extract.assert_called_once()

if __name__ == "__main__":
    unittest.main()
