import os
import sys
import unittest
from unittest.mock import patch, MagicMock

# Add server directory to path
SERVER_DIR = os.path.dirname(os.path.abspath(__file__))
if SERVER_DIR not in sys.path:
    sys.path.insert(0, SERVER_DIR)

from fastapi.testclient import TestClient
from main import app
from app.auth import get_current_user

client = TestClient(app)

class TestArchitectureSecurity(unittest.TestCase):
    def setUp(self):
        self.enterContext(patch("main.extract_ingredients", side_effect=lambda text: text))
        self.enterContext(patch("main.get_vision_client", return_value=None))
        self.enterContext(patch("app.auth.init_firebase_admin"))
        from app.auth import auth
        self.enterContext(patch("app.auth.auth.verify_id_token", side_effect=auth.InvalidIdTokenError("Invented invalid token")))
        app.dependency_overrides.clear()
        self.addCleanup(app.dependency_overrides.clear)


    def test_public_endpoints(self):
        """Public endpoints should succeed without authentication."""
        resp = client.get("/")
        self.assertEqual(resp.status_code, 200)

        resp = client.get("/health")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json()["status"], "healthy")

        resp = client.get("/allergens")
        self.assertEqual(resp.status_code, 200)
        self.assertIn("categories", resp.json())

    def test_protected_endpoints_reject_missing_token(self):
        """Protected endpoints must reject requests with 401 when Authorization header is absent."""
        endpoints = [
            ("GET", "/users/me", {}),
            ("POST", "/users/profile", {"json": {"name": "Test"}}),
            ("GET", "/users/me/allergies", {}),
            ("PUT", "/users/me/allergies", {"json": {"allergies": ["Milk"]}}),
            ("POST", "/scan/text", {"json": {"text": "Water, Sugar"}}),
        ]

        for method, path, kwargs in endpoints:
            with self.subTest(method=method, path=path):
                if method == "GET":
                    resp = client.get(path, **kwargs)
                elif method == "POST":
                    resp = client.post(path, **kwargs)
                elif method == "PUT":
                    resp = client.put(path, **kwargs)
                self.assertEqual(
                    resp.status_code,
                    401,
                    f"Expected 401 for {method} {path}, got {resp.status_code}"
                )
                self.assertIn("WWW-Authenticate", resp.headers)

    def test_protected_endpoints_reject_invalid_token(self):
        """Protected endpoints must reject invalid or forged Bearer tokens with 401."""
        headers = {"Authorization": "Bearer totally_invalid_token_12345"}
        resp = client.get("/users/me", headers=headers)
        self.assertEqual(resp.status_code, 401)

        resp = client.get("/users/me/allergies", headers=headers)
        self.assertEqual(resp.status_code, 401)

        resp = client.post("/scan/text", json={"text": "Sugar"}, headers=headers)
        self.assertEqual(resp.status_code, 401)

    def test_authenticated_user_isolation(self):
        """
        Verifies that when a valid token is provided:
        1. UID is derived strictly from the verified token.
        2. User operations are isolated to that UID.
        """
        mock_user = {
            "uid": "test_user_uid_999",
            "email": "testuser@misbar.local",
            "name": "Test User",
        }

        # Override dependency with verified token mock
        app.dependency_overrides[get_current_user] = lambda: mock_user

        try:
            # Mock the user_allergen_service functions
            with patch("main.get_user_profile_from_db") as mock_get_profile, \
                 patch("main.save_user_profile_in_db") as mock_save_profile, \
                 patch("main.fetch_user_allergens_from_db") as mock_fetch_allergies, \
                 patch("main.save_user_allergens_in_db") as mock_save_allergies:

                mock_get_profile.return_value = {
                    "uid": "test_user_uid_999",
                    "name": "Test User",
                    "email": "testuser@misbar.local",
                    "allergies": ["Milk"]
                }
                mock_fetch_allergies.return_value = ["Milk"]

                # 1. Test GET /users/me
                resp = client.get("/users/me")
                self.assertEqual(resp.status_code, 200)
                data = resp.json()
                self.assertEqual(data["uid"], "test_user_uid_999")
                self.assertEqual(data["email"], "testuser@misbar.local")

                # 2. Test POST /users/profile
                resp = client.post("/users/profile", json={"name": "Updated Name"})
                self.assertEqual(resp.status_code, 200)
                mock_save_profile.assert_called_once_with(
                    user_id="test_user_uid_999",
                    name="Updated Name",
                    email="testuser@misbar.local"
                )

                # 3. Test GET /users/me/allergies
                resp = client.get("/users/me/allergies")
                self.assertEqual(resp.status_code, 200)
                self.assertEqual(resp.json()["allergies"], ["Milk"])
                mock_fetch_allergies.assert_called_with(user_id="test_user_uid_999")

                # 4. Test PUT /users/me/allergies
                resp = client.put("/users/me/allergies", json={"allergies": ["Peanut", "Cereals containing gluten"]})
                self.assertEqual(resp.status_code, 200)
                mock_save_allergies.assert_called_once_with(
                    user_id="test_user_uid_999",
                    allergies=["Peanut", "Cereals containing gluten"]
                )

                # 5. Test Scan Text uses authenticated user UID from token
                resp = client.post("/scan/text", json={"text": "Ingredients: Wheat flour, Milk, Sugar"})
                self.assertEqual(resp.status_code, 200)
                mock_fetch_allergies.assert_called_with(user_id="test_user_uid_999")

        finally:
            app.dependency_overrides.clear()

if __name__ == "__main__":
    unittest.main()
