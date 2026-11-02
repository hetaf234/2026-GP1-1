"""Attack the actual rules in the local Firestore emulator; never production."""
import base64
import json
import os
import time
import unittest

import requests

PROJECT = "demo-misbar-metadata"
HOST = "127.0.0.1:8810"
ROOT = f"http://{HOST}/v1/projects/{PROJECT}/databases/(default)/documents"


def token(uid, **claims):
    now = int(time.time())
    payload = {"iss": "https://securetoken.google.com/" + PROJECT, "aud": PROJECT,
               "iat": now, "exp": now + 3600, "sub": uid, "user_id": uid,
               "firebase": {"identities": {}, "sign_in_provider": "password"}, **claims}
    encode = lambda value: base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")
    return encode({"alg": "none", "typ": "JWT"}) + "." + encode(payload) + "."


class FirestoreRulesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.environ.get("FIRESTORE_EMULATOR_HOST") != HOST:
            raise RuntimeError("Only the explicit local demo Firestore emulator is allowed.")
        cls.member = {"Authorization": "Bearer " + token("member")}
        cls.admin = {"Authorization": "Bearer " + token("admin", role="admin", admin=True)}
        cls.owner = {"Authorization": "Bearer owner"}
        cls.fields = {"name": {"stringValue": "Local Fixture"},
                      "language": {"stringValue": "en"}, "role": {"stringValue": "member"},
                      "allergies": {"arrayValue": {"values": [{"stringValue": "Milk"}]}}}

    def setUp(self):
        for uid in ("member", "admin"):
            fields = {**self.fields, "role": {"stringValue": uid}}
            response = requests.patch(ROOT + "/users/" + uid, headers=self.owner,
                                      json={"fields": fields}, timeout=10)
            self.assertEqual(response.status_code, 200)

    def denied(self, method, path, *, headers=None, **kwargs):
        response = requests.request(method, ROOT + path, headers=headers or self.member,
                                    timeout=10, **kwargs)
        self.assertEqual(response.status_code, 403, response.text)

    def test_owner_can_read_own_complete_legacy_or_extended_profile(self):
        response = requests.get(ROOT + "/users/member", headers=self.member, timeout=10)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["fields"]["allergies"], self.fields["allergies"])

    def test_unauthenticated_read_is_denied(self):
        self.assertEqual(requests.get(ROOT + "/users/member", timeout=10).status_code, 403)

    def test_other_user_and_admin_claim_cannot_read_private_profile(self):
        self.denied("GET", "/users/admin")
        self.denied("GET", "/users/member", headers=self.admin)

    def test_collection_listing_and_public_query_are_denied(self):
        self.denied("GET", "/users")
        self.denied("POST", ":runQuery", json={"structuredQuery": {"from": [{"collectionId": "users"}]}})

    def test_client_creation_is_denied_for_member_admin_and_omitted_role(self):
        self.assertEqual(requests.delete(ROOT + "/users/member", headers=self.owner, timeout=10).status_code, 200)
        for role in ("member", "admin", None):
            with self.subTest(role=role):
                fields = {**self.fields}
                if role is None:
                    fields.pop("role")
                else:
                    fields["role"] = {"stringValue": role}
                self.denied("POST", "/users", params={"documentId": "member"}, json={"fields": fields})

    def test_own_role_cannot_be_promoted_changed_or_deleted(self):
        for fields in ({"role": {"stringValue": "admin"}}, {"role": {"stringValue": "owner"}}, {}):
            with self.subTest(fields=fields):
                self.denied("PATCH", "/users/member", params={"updateMask.fieldPaths": "role"}, json={"fields": fields})

    def test_language_is_system_owned(self):
        self.denied("PATCH", "/users/member", params={"updateMask.fieldPaths": "language"},
                    json={"fields": {"language": {"stringValue": "ar"}}})

    def test_direct_allergy_and_profile_updates_are_denied(self):
        for field, value in (("name", {"stringValue": "Changed"}), ("allergies", {"arrayValue": {}})):
            with self.subTest(field=field):
                self.denied("PATCH", "/users/member", params={"updateMask.fieldPaths": field}, json={"fields": {field: value}})

    def test_delete_and_recreate_escape_is_denied(self):
        self.denied("DELETE", "/users/member")
        self.denied("PATCH", "/users/member", json={"fields": {"role": {"stringValue": "admin"}}})

    def test_forged_admin_claim_does_not_grant_write_access(self):
        self.denied("PATCH", "/users/admin", headers=self.admin,
                    json={"fields": {"role": {"stringValue": "admin"}}})

    def test_schema_pollution_types_size_and_timestamp_attacks_are_denied(self):
        for fields in ({"isAdmin": {"booleanValue": True}}, {"role": {"integerValue": "1"}},
                       {"name": {"stringValue": "x" * 20000}}, {"createdAt": {"timestampValue": "2000-01-01T00:00:00Z"}},
                       {"uid": {"stringValue": "other"}}, {"role": {"mapValue": {"fields": {"admin": {"booleanValue": True}}}}}):
            with self.subTest(keys=list(fields)):
                self.denied("PATCH", "/users/member", json={"fields": fields})

    def test_nested_permission_documents_and_other_collections_are_denied(self):
        self.denied("PATCH", "/users/member/permissions/admin", json={"fields": {"enabled": {"booleanValue": True}}})
        self.denied("GET", "/other/private")

    def test_batch_writes_cannot_bypass_role_protection(self):
        self.denied("POST", ":commit", json={"writes": [{"update": {"name": ROOT.split('/v1/')[1] + "/users/member",
                     "fields": {"role": {"stringValue": "admin"}}}}]})

    def test_trusted_admin_backend_write_remains_available(self):
        response = requests.patch(ROOT + "/users/member", headers=self.owner,
                                  params={"updateMask.fieldPaths": "language"},
                                  json={"fields": {"language": {"stringValue": "ar"}}}, timeout=10)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["fields"]["role"], {"stringValue": "member"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
