"""Migration safety tests use only typed synthetic Firestore documents."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import user_metadata_migration as migration


def fixture(uid="fixture", **fields):
    return {"name": migration.DOCUMENT_ROOT + "/users/" + uid,
            "createTime": "2026-01-01T00:00:00Z", "updateTime": "2026-10-01T00:00:00Z",
            "fields": {"allergies": {"arrayValue": {"values": [{"stringValue": "Milk"}]}},
                       "nested": {"mapValue": {"fields": {"preserved": {"bytesValue": "AQID"}}}},
                       **fields}}


class MemoryRest:
    def __init__(self, documents):
        self.documents = {d["name"]: copy.deepcopy(d) for d in documents}
        self.calls = []
        self.patches = []
        self.before_patch = None
        self.lost_response = False
        self.page_fail = False
        self.bad_project = False
        self.bad_database = False
        self.result_corrupt = False
        self.snapshot = None
        self.backup_dir = None

    def request(self, method, url, **kwargs):
        self.calls.append((method, url, copy.deepcopy(kwargs)))
        if "cloudresourcemanager" in url:
            return {"projectId": "wrong" if self.bad_project else migration.PROJECT,
                    "projectNumber": migration.PROJECT_NUMBER, "lifecycleState": "ACTIVE"}
        if url == migration.FIRESTORE + migration.DATABASE_NAME:
            return {"name": migration.DATABASE_NAME, "uid": "wrong" if self.bad_database else migration.DATABASE_UID,
                    "databaseEdition": "STANDARD", "type": "FIRESTORE_NATIVE"}
        if url.endswith(":runQuery"):
            self.snapshot = copy.deepcopy(list(self.documents.values()))
            return [{"readTime": "2026-11-01T00:00:00Z"}]
        if url.endswith("/users"):
            params = kwargs["params"]
            assert params["readTime"] == "2026-11-01T00:00:00Z"
            start = int(params.get("pageToken", 0))
            if self.page_fail and start:
                raise migration.HttpFailure(503)
            response = {"documents": self.snapshot[start:start + 2]}
            if len(self.snapshot) > start + 2:
                response["nextPageToken"] = str(start + 2)
            return copy.deepcopy(response)
        name = url.removeprefix(migration.FIRESTORE)
        if method == "GET":
            if name not in self.documents:
                raise migration.HttpFailure(404)
            return copy.deepcopy(self.documents[name])
        if method == "PATCH":
            assert self.backup_dir and (self.backup_dir / "backup-manifest.json").exists()
            if self.before_patch:
                self.before_patch(self.documents[name])
            params = kwargs["params"]
            precondition = dict(params)["currentDocument.updateTime"]
            if name not in self.documents or self.documents[name]["updateTime"] != precondition:
                raise migration.HttpFailure(412)
            values = kwargs["json"]["fields"]
            mask = [value for key, value in params if key == "updateMask.fieldPaths"]
            assert set(mask) == set(values) <= {"language", "role"}
            self.patches.append(copy.deepcopy(values))
            self.documents[name]["fields"].update(copy.deepcopy(values))
            self.documents[name]["updateTime"] = "2026-11-01T00:01:00Z"
            if self.lost_response:
                raise migration.MigrationStopped("request_failed")
            result = copy.deepcopy(self.documents[name])
            if self.result_corrupt:
                result["fields"]["allergies"] = {"arrayValue": {}}
            return result
        raise AssertionError("Unexpected synthetic request")


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(self.enterContext(tempfile.TemporaryDirectory()))

    def run_case(self, documents, apply=True, *, client=None, name="backup"):
        client = client or MemoryRest(documents)
        client.backup_dir = self.directory / name
        result = migration.run_migration(client, client.backup_dir, apply=apply)
        return client, result

    def test_both_missing_added_with_partial_mask_and_no_other_data_changes(self):
        original = fixture()
        client, result = self.run_case([original])
        self.assertEqual((result["scanned"], result["updated"], result["unchanged"], result["failed"]), (1, 1, 0, 0))
        self.assertEqual(client.patches, [{"language": {"stringValue": "en"}, "role": {"stringValue": "member"}}])
        after = client.documents[original["name"]]
        for key, value in original["fields"].items():
            self.assertEqual(after["fields"][key], value)
        self.assertEqual(after["createTime"], original["createTime"])

    def test_only_missing_language_is_added_and_admin_preserved(self):
        client, result = self.run_case([fixture(role={"stringValue": "admin"})])
        self.assertEqual(client.patches, [{"language": {"stringValue": "en"}}])
        self.assertEqual(result["updated"], 1)
        self.assertEqual(next(iter(client.documents.values()))["fields"]["role"], {"stringValue": "admin"})

    def test_only_missing_role_is_added_and_language_preserved(self):
        client, _ = self.run_case([fixture(language={"stringValue": "zh-Hant-TW"})])
        self.assertEqual(client.patches, [{"role": {"stringValue": "member"}}])

    def test_existing_fields_are_unchanged_including_admin_and_language(self):
        original = fixture(role={"stringValue": "admin"}, language={"stringValue": "ar-SA"})
        client, result = self.run_case([original])
        self.assertEqual(client.patches, [])
        self.assertEqual(client.documents[original["name"]], original)
        self.assertEqual(result["unchanged"], 1)

    def test_second_run_has_no_writes_or_timestamp_changes(self):
        client, first = self.run_case([fixture()])
        before = copy.deepcopy(client.documents)
        client.patches.clear()
        _, second = self.run_case([], client=client, name="second-backup")
        self.assertEqual(first["updated"], 1)
        self.assertEqual(second["updated"], 0)
        self.assertEqual(second["unchanged"], 1)
        self.assertEqual(client.patches, [])
        self.assertEqual(client.documents, before)

    def test_dry_run_creates_recoverable_backup_without_writes(self):
        original = fixture()
        client, result = self.run_case([original], apply=False)
        self.assertEqual(result["would_update"], 1)
        self.assertEqual(result["updated"], 0)
        self.assertEqual(client.patches, [])
        manifest, documents = migration.load_backup(client.backup_dir, result["identity"])
        self.assertTrue(manifest["complete"])
        self.assertEqual(documents, [original])

    def test_private_backup_permissions_and_typed_values_are_preserved(self):
        original = fixture(reference={"referenceValue": migration.DOCUMENT_ROOT + "/other/a"},
                           timestamp={"timestampValue": "2026-01-01T00:00:00.123456789Z"})
        client, result = self.run_case([original], apply=False)
        self.assertEqual(client.backup_dir.stat().st_mode & 0o777, 0o700)
        for f in client.backup_dir.iterdir():
            self.assertEqual(f.stat().st_mode & 0o777, 0o600)
        self.assertEqual(migration.load_backup(client.backup_dir, result["identity"])[1], [original])

    def test_explicit_wrong_project_is_rejected_before_access_or_backup(self):
        client = MemoryRest([])
        with self.assertRaisesRegex(migration.MigrationStopped, "target_not_allowlisted"):
            migration.run_migration(client, self.directory / "bad", apply=True, project="project-51f11627-cb56-4c1e-978")
        self.assertEqual(client.calls, [])

    def test_named_database_is_rejected_before_access(self):
        client = MemoryRest([])
        with self.assertRaisesRegex(migration.MigrationStopped, "target_not_allowlisted"):
            migration.run_migration(client, self.directory / "bad", apply=True, database="other")
        self.assertEqual(client.calls, [])

    def test_project_number_or_id_mismatch_prevents_any_write(self):
        client = MemoryRest([fixture()]); client.bad_project = True
        with self.assertRaisesRegex(migration.MigrationStopped, "project_identity_mismatch"):
            self.run_case([], client=client)
        self.assertEqual(client.patches, [])

    def test_database_uid_mismatch_prevents_any_write(self):
        client = MemoryRest([fixture()]); client.bad_database = True
        with self.assertRaisesRegex(migration.MigrationStopped, "database_identity_mismatch"):
            self.run_case([], client=client)
        self.assertEqual(client.patches, [])

    def test_all_pages_must_be_backed_up_before_first_update(self):
        client, result = self.run_case([fixture(str(i)) for i in range(5)])
        self.assertEqual(result["scanned"], 5)
        first_patch = next(i for i, call in enumerate(client.calls) if call[0] == "PATCH")
        pages = [call for call in client.calls[:first_patch] if call[1].endswith("/users")]
        self.assertEqual(len(pages), 3)
        self.assertEqual(len({p[2]["params"]["readTime"] for p in pages}), 1)

    def test_pagination_failure_prevents_all_writes(self):
        client = MemoryRest([fixture(str(i)) for i in range(3)]); client.page_fail = True
        with self.assertRaises(migration.HttpFailure):
            self.run_case([], client=client)
        self.assertEqual(client.patches, [])
        self.assertFalse((client.backup_dir / "backup-manifest.json").exists())

    def test_backup_write_failure_prevents_all_updates(self):
        client = MemoryRest([fixture()])
        with patch.object(migration, "private_json", side_effect=OSError("private disk failure")):
            with self.assertRaises(OSError):
                self.run_case([], client=client)
        self.assertEqual(client.patches, [])

    def test_private_user_backup_cannot_be_written_inside_source_repository(self):
        client = MemoryRest([fixture()])
        directory = Path(migration.__file__).resolve().parents[2] / "unsafe-user-backup"
        with self.assertRaisesRegex(migration.MigrationStopped, "backup_must_be_outside_repository"):
            migration.run_migration(client, directory, apply=True)
        self.assertFalse(directory.exists())
        self.assertEqual(client.patches, [])

    def test_corrupted_backup_is_rejected(self):
        client, result = self.run_case([fixture()], apply=False)
        (client.backup_dir / "users.backup.json").write_text("{}")
        with self.assertRaises(migration.MigrationStopped):
            migration.load_backup(client.backup_dir, result["identity"])

    def test_concurrent_admin_update_cannot_be_overwritten_by_member_default(self):
        client = MemoryRest([fixture()])
        def promote(document):
            document["fields"]["role"] = {"stringValue": "admin"}
            document["updateTime"] = "2026-11-01T00:00:01Z"
        client.before_patch = promote
        client, result = self.run_case([], client=client)
        self.assertEqual(result["failed"], 1)
        self.assertEqual(client.patches, [])
        self.assertEqual(next(iter(client.documents.values()))["fields"]["role"], {"stringValue": "admin"})

    def test_concurrent_allergy_update_is_preserved_by_precondition(self):
        client = MemoryRest([fixture()])
        def edit(document):
            document["fields"]["allergies"] = {"arrayValue": {"values": [{"stringValue": "Egg"}]}}
            document["updateTime"] = "2026-11-01T00:00:01Z"
        client.before_patch = edit
        client, result = self.run_case([], client=client)
        self.assertEqual(result["failed"], 1)
        self.assertEqual(client.patches, [])
        self.assertEqual(next(iter(client.documents.values()))["fields"]["allergies"]["arrayValue"]["values"], [{"stringValue": "Egg"}])

    def test_lost_success_response_is_reconciled_without_repeating_write(self):
        client = MemoryRest([fixture()]); client.lost_response = True
        client, result = self.run_case([], client=client)
        self.assertEqual(result["updated"], 1)
        self.assertEqual(len(client.patches), 1)

    def test_invalid_existing_values_are_reported_and_never_rewritten(self):
        original = fixture(role={"integerValue": "7"}, language={"stringValue": ""})
        client, result = self.run_case([original])
        self.assertEqual(result["existing_invalid_metadata"], 1)
        self.assertEqual(client.patches, [])
        self.assertEqual(client.documents[original["name"]], original)

    def test_post_write_disagreement_is_a_failure_not_false_success(self):
        client = MemoryRest([fixture()]); client.result_corrupt = True
        _, result = self.run_case([], client=client)
        self.assertEqual(result["updated"], 0)
        self.assertEqual(result["failed"], 1)

    def test_result_and_failure_logs_contain_counts_not_personal_fields(self):
        client, result = self.run_case([fixture("PRIVATE_UID", email={"stringValue": "PRIVATE_EMAIL"})])
        text = json.dumps(result) + (client.backup_dir / "migration-failures.json").read_text()
        self.assertNotIn("PRIVATE_UID", text)
        self.assertNotIn("PRIVATE_EMAIL", text)
        self.assertNotIn("Milk", text)

    def test_no_documents_is_safe(self):
        client, result = self.run_case([])
        self.assertEqual((result["scanned"], result["updated"], result["unchanged"], result["failed"]), (0, 0, 0, 0))
        self.assertEqual(client.patches, [])


if __name__ == "__main__":
    unittest.main()
