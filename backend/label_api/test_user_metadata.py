"""Trusted profile initialization against transactional in-memory Firestore."""
import copy
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

import main
from app.auth import get_current_user
from app.services import user_allergen_service as service
from app.services.user_metadata_service import missing_metadata


class MemoryFirestore:
    def __init__(self, data=None):
        self.data = copy.deepcopy(data)
        self.version = 0
        self.writes = []
        self.race = None
        self.fail = False

    def collection(self, name):
        assert name == "users"
        return self

    def document(self, uid):
        assert uid == "verified-user"
        return self

    def get(self, transaction=None):
        if transaction is not None:
            transaction.version = self.version
        data = copy.deepcopy(self.data)
        return SimpleNamespace(exists=data is not None, to_dict=lambda: data)

    def transaction(self):
        return SimpleNamespace(db=self, version=None, pending=None,
                               set=lambda ref, data, merge: self._stage(ref, data, merge))

    def _stage(self, ref, data, merge):
        assert ref is self and merge is True
        self.pending = copy.deepcopy(data)

    @staticmethod
    def transactional(fn):
        def run(transaction):
            db = transaction.db
            for _ in range(3):
                fn(transaction)
                if db.race:
                    race, db.race = db.race, None
                    race(db)
                    db.version += 1
                if db.version != transaction.version:
                    continue
                if db.fail:
                    raise RuntimeError("PRIVATE_DATABASE_FAILURE")
                db.data = {**(db.data or {}), **db.pending}
                db.writes.append(db.pending)
                db.version += 1
                return
            raise RuntimeError("Transaction conflict")
        return run


class UserMetadataTests(unittest.TestCase):
    def setUp(self):
        self.db = MemoryFirestore()
        self.enterContext(patch.object(service, "get_firestore_client", return_value=self.db))
        self.enterContext(patch("firebase_admin.firestore.transactional", MemoryFirestore.transactional))
        main.app.dependency_overrides[get_current_user] = lambda: {"uid": "verified-user", "email": "fixture@example.invalid"}
        self.addCleanup(main.app.dependency_overrides.clear)
        self.client = TestClient(main.app)
        self.addCleanup(self.client.close)

    def test_new_profile_gets_top_level_defaults_without_fake_allergy_selection(self):
        response = self.client.post("/users/profile", json={"name": "Fixture", "email": "fixture@example.invalid"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.db.data["role"], "member")
        self.assertEqual(self.db.data["language"], "en")
        self.assertEqual(self.db.data["name"], "Fixture")
        self.assertIn("createdAt", self.db.data)
        self.assertNotIn("allergies", self.db.data)
        self.assertFalse(response.json()["allergy_selection_saved"])
        self.assertEqual(response.json()["allergies"], [])

    def test_missing_only_defaults_preserve_every_existing_value(self):
        for data, expected in [({}, {"role": "member", "language": "en"}),
                               ({"role": "admin"}, {"language": "en"}),
                               ({"language": "ar-SA"}, {"role": "member"}),
                               ({"language": "fr", "role": "admin"}, {}),
                               ({"role": None}, {"language": "en"})]:
            with self.subTest(data=data):
                self.assertEqual(missing_metadata(data), expected)

    def test_existing_admin_language_and_unrelated_fields_are_preserved(self):
        self.db.data = {"role": "admin", "language": "ar-SA", "allergies": ["Milk"],
                        "createdAt": "old", "custom": {"kept": True}}
        response = self.client.post("/users/profile", json={"name": "Changed"})
        self.assertEqual(response.status_code, 200)
        for key, expected in (("role", "admin"), ("language", "ar-SA"), ("allergies", ["Milk"]),
                              ("createdAt", "old"), ("custom", {"kept": True})):
            self.assertEqual(self.db.data[key], expected)
        self.assertNotIn("role", self.db.writes[0])
        self.assertNotIn("language", self.db.writes[0])

    def test_client_role_language_uid_and_privilege_flags_are_ignored(self):
        response = self.client.post("/users/profile", json={"name": "Fixture", "role": "admin",
                                   "language": "ar", "uid": "other", "isAdmin": True})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["uid"], "verified-user")
        self.assertEqual(self.db.data["role"], "member")
        self.assertEqual(self.db.data["language"], "en")
        self.assertNotIn("uid", self.db.data)
        self.assertNotIn("isAdmin", self.db.data)

    def test_client_cannot_downgrade_or_replace_admin_role(self):
        self.db.data = {"role": "admin", "language": "fr"}
        self.client.post("/users/profile", json={"role": "member", "language": "en"})
        self.assertEqual(self.db.data["role"], "admin")
        self.assertEqual(self.db.data["language"], "fr")

    def test_allergy_save_can_initialize_a_deferred_profile_with_defaults(self):
        response = self.client.put("/users/me/allergies", json={"allergies": ["Milk"], "role": "admin"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.db.data["role"], "member")
        self.assertEqual(self.db.data["language"], "en")
        self.assertEqual(self.db.data["allergies"], ["Milk"])

    def test_my_allergies_save_preserves_existing_metadata(self):
        self.db.data = {"allergies": ["Milk"], "role": "admin", "language": "ar", "custom": 12}
        response = self.client.put("/users/me/allergies", json={"allergies": ["Egg"]})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.db.data["role"], "admin")
        self.assertEqual(self.db.data["language"], "ar")
        self.assertEqual(self.db.data["custom"], 12)
        self.assertEqual(self.db.data["allergies"], ["Egg"])

    def test_repeated_profile_initialization_never_resets_admin_or_language(self):
        self.client.post("/users/profile", json={"name": "Fixture"})
        self.db.data.update(role="admin", language="ar")
        self.client.post("/users/profile", json={"name": "Fixture"})
        self.assertEqual(self.db.data["role"], "admin")
        self.assertEqual(self.db.data["language"], "ar")
        self.assertNotIn("createdAt", self.db.writes[-1])

    def test_concurrent_admin_assignment_is_preserved_after_transaction_retry(self):
        self.db.data = {"allergies": ["Milk"]}
        self.db.race = lambda db: db.data.update(role="admin")
        self.client.post("/users/profile", json={"name": "Fixture"})
        self.assertEqual(self.db.data["role"], "admin")
        self.assertEqual(self.db.data["language"], "en")
        self.assertEqual(self.db.data["allergies"], ["Milk"])
        self.assertNotIn("role", self.db.writes[-1])

    def test_concurrent_language_change_is_preserved_after_transaction_retry(self):
        self.db.data = {"allergies": ["Milk"]}
        self.db.race = lambda db: db.data.update(language="fr")
        self.client.put("/users/me/allergies", json={"allergies": ["Milk"]})
        self.assertEqual(self.db.data["language"], "fr")
        self.assertEqual(self.db.data["role"], "member")

    def test_legacy_profile_reads_have_defaults_without_writing_or_changing_allergies(self):
        self.db.data = {"name": "Fixture", "allergies": ["Milk"]}
        response = self.client.get("/users/me")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["language"], "en")
        self.assertEqual(response.json()["role"], "member")
        self.assertEqual(response.json()["allergies"], ["Milk"])
        self.assertEqual(self.db.writes, [])
        self.assertNotIn("role", self.db.data)

    def test_admin_and_language_are_returned_without_granting_any_authorization(self):
        self.db.data = {"role": "admin", "language": "ar", "allergies": ["Milk"]}
        response = self.client.get("/users/me")
        self.assertEqual(response.json()["role"], "admin")
        self.assertEqual(response.json()["language"], "ar")
        self.assertEqual(self.db.writes, [])

    def test_unauthenticated_profile_creation_does_not_access_database(self):
        main.app.dependency_overrides.clear()
        response = self.client.post("/users/profile", json={"name": "Fixture", "role": "admin"})
        self.assertEqual(response.status_code, 401)
        self.assertIsNone(self.db.data)
        self.assertEqual(self.db.writes, [])

    def test_profile_transaction_failure_is_safe_and_does_not_succeed(self):
        self.db.fail = True
        response = self.client.post("/users/profile", json={"name": "Fixture"})
        self.assertEqual(response.status_code, 503)
        self.assertNotIn("PRIVATE_DATABASE_FAILURE", response.text)
        self.assertEqual(self.db.writes, [])

    def test_allergy_transaction_failure_keeps_previous_allergies(self):
        self.db.data = {"allergies": ["Milk"], "role": "admin"}
        self.db.fail = True
        response = self.client.put("/users/me/allergies", json={"allergies": ["Egg"]})
        self.assertEqual(response.status_code, 503)
        self.assertEqual(self.db.data, {"allergies": ["Milk"], "role": "admin"})


if __name__ == "__main__":
    unittest.main()
