"""Missing-only users migration. Explicit target, complete private backup, CAS updates.

Run without --apply first. Never logs document IDs, document values or credentials.
Backups retain Firestore's typed REST values, createTime and updateTime so no
timestamp/bytes/reference precision is lost. No rules, IAM or Auth configuration
is changed. This operator tool is not imported by the application.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

from app.services.user_metadata_service import missing_metadata

PROJECT = "misbar-ebea2"
PROJECT_NUMBER = "237433634785"
DATABASE = "(default)"
DATABASE_UID = "be680a5b-82de-49d1-9113-3b7fd11de576"
DATABASE_NAME = f"projects/{PROJECT}/databases/{DATABASE}"
DOCUMENT_ROOT = DATABASE_NAME + "/documents"
FIRESTORE = "https://firestore.googleapis.com/v1/"


class MigrationStopped(Exception):
    """Safe machine-readable reason only; never attach provider exceptions."""


class HttpFailure(MigrationStopped):
    def __init__(self, status):
        self.status = status
        super().__init__("http_" + str(status))


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()


def private_json(path, value):
    """Exclusive file creation, fsync and reread; refuse incomplete backups."""
    raw = canonical(value) + b"\n"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(raw)
        output.flush()
        os.fsync(output.fileno())
    if Path(path).read_bytes() != raw:
        raise MigrationStopped("backup_verification_failed")
    return hashlib.sha256(raw).hexdigest()


class FirestoreRest:
    """Uses the operator's existing gcloud session; token stays only in memory."""
    def __init__(self):
        import requests
        process = subprocess.run(["gcloud", "auth", "print-access-token"],
                                 capture_output=True, text=True, timeout=60)
        if process.returncode or not process.stdout.strip():
            raise MigrationStopped("credential_unavailable")
        self.session = requests.Session()
        self.session.headers["Authorization"] = "Bearer " + process.stdout.strip()

    def request(self, method, url, **kwargs):
        try:
            response = self.session.request(method, url, timeout=(10, 60), **kwargs)
            if response.status_code != 200:
                raise HttpFailure(response.status_code)
            return response.json()
        except MigrationStopped:
            raise
        except Exception:
            raise MigrationStopped("request_failed") from None


def verify_target(client, project=PROJECT, database=DATABASE):
    if project != PROJECT or database != DATABASE:
        raise MigrationStopped("target_not_allowlisted")
    identity = client.request("GET", "https://cloudresourcemanager.googleapis.com/v1/projects/" + PROJECT)
    if (identity.get("projectId") != PROJECT or str(identity.get("projectNumber")) != PROJECT_NUMBER
            or identity.get("lifecycleState") != "ACTIVE"):
        raise MigrationStopped("project_identity_mismatch")
    instance = client.request("GET", FIRESTORE + DATABASE_NAME)
    if (instance.get("name") != DATABASE_NAME or instance.get("uid") != DATABASE_UID
            or instance.get("type") != "FIRESTORE_NATIVE" or instance.get("databaseEdition") != "STANDARD"):
        raise MigrationStopped("database_identity_mismatch")
    return {"project_id": PROJECT, "project_number": PROJECT_NUMBER, "database": DATABASE,
            "database_uid": DATABASE_UID, "edition": "STANDARD"}


def snapshot_users(client):
    # Obtain a server read timestamp, then paginate every document at that same
    # snapshot. A listing failure or duplicate/path mismatch aborts all writes.
    anchor = client.request("POST", FIRESTORE + DOCUMENT_ROOT + ":runQuery", json={
        "structuredQuery": {"from": [{"collectionId": "users"}], "limit": 1}})
    if not isinstance(anchor, list) or not anchor or not anchor[-1].get("readTime"):
        raise MigrationStopped("snapshot_time_missing")
    read_time = anchor[-1]["readTime"]
    documents = []
    seen = set()
    tokens = set()
    token = None
    while True:
        params = {"pageSize": 200, "readTime": read_time, "orderBy": "__name__"}
        if token:
            params["pageToken"] = token
        page = client.request("GET", FIRESTORE + DOCUMENT_ROOT + "/users", params=params)
        for document in page.get("documents", []):
            name = document.get("name", "")
            prefix = DOCUMENT_ROOT + "/users/"
            if (not name.startswith(prefix) or not name[len(prefix):] or "/" in name[len(prefix):]
                    or name in seen or not document.get("updateTime") or not document.get("createTime")
                    or not isinstance(document.get("fields", {}), dict)):
                raise MigrationStopped("invalid_snapshot_document")
            seen.add(name)
            documents.append(document)
        token = page.get("nextPageToken")
        if not token:
            break
        if token in tokens:
            raise MigrationStopped("repeated_page_token")
        tokens.add(token)
    return read_time, documents


def make_backup(client, directory, identity):
    directory = Path(directory)
    if directory.resolve().is_relative_to(Path(__file__).resolve().parents[2]):
        raise MigrationStopped("backup_must_be_outside_repository")
    directory.mkdir(mode=0o700, parents=False, exist_ok=False)
    read_time, documents = snapshot_users(client)
    payload = {"format": "misbar-users-firestore-rest-v1", "identity": identity,
               "read_time": read_time, "documents": documents}
    digest = private_json(directory / "users.backup.json", payload)
    manifest = {"complete": True, "identity": identity, "read_time": read_time,
                "documents": len(documents), "sha256": digest}
    private_json(directory / "backup-manifest.json", manifest)
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return load_backup(directory, identity)


def load_backup(directory, identity):
    directory = Path(directory)
    manifest = json.loads((directory / "backup-manifest.json").read_bytes())
    raw = (directory / "users.backup.json").read_bytes()
    payload = json.loads(raw)
    if (manifest.get("complete") is not True or manifest.get("identity") != identity
            or payload.get("identity") != identity or payload.get("format") != "misbar-users-firestore-rest-v1"
            or manifest.get("sha256") != hashlib.sha256(raw).hexdigest()
            or manifest.get("documents") != len(payload["documents"])
            or manifest.get("read_time") != payload.get("read_time")):
        raise MigrationStopped("backup_verification_failed")
    return manifest, payload["documents"]


def run_migration(client, directory, *, apply=False, project=PROJECT, database=DATABASE):
    identity = verify_target(client, project, database)
    manifest, documents = make_backup(client, directory, identity)
    # No write can occur before the complete backup has been flushed, read back,
    # checksum verified, and both target identities verified again.
    if apply:
        if verify_target(client, project, database) != identity:
            raise MigrationStopped("target_changed")
        manifest, documents = load_backup(directory, identity)
    result = {"identity": identity, "apply": apply, "scanned": len(documents),
              "updated": 0, "unchanged": 0, "failed": 0, "would_update": 0,
              "existing_invalid_metadata": 0, "backup_sha256": manifest["sha256"]}
    failures = []
    for ordinal, document in enumerate(documents, 1):
        fields = document.get("fields", {})
        if any(key in fields and (set(fields[key]) != {"stringValue"}
                                  or not fields[key]["stringValue"].strip()) for key in ("role", "language")):
            # This migration is authorized to add absent fields only. Retain
            # invalid existing values too, report them, never silently repair.
            result["existing_invalid_metadata"] += 1
        patch = {key: {"stringValue": value} for key, value in missing_metadata(fields).items()}
        if not patch:
            result["unchanged"] += 1
            continue
        if not apply:
            result["would_update"] += 1
            continue
        expected = {**fields, **patch}
        try:
            current = client.request("GET", FIRESTORE + document["name"])
            if current != document:
                raise MigrationStopped("concurrent_document_change")
            params = [("updateMask.fieldPaths", key) for key in patch]
            params.append(("currentDocument.updateTime", document["updateTime"]))
            # updateTime precondition prevents creation and protects concurrent
            # admin/language/allergy changes; the mask never includes other data.
            try:
                written = client.request("PATCH", FIRESTORE + document["name"],
                                         params=params, json={"fields": patch})
            except HttpFailure:
                raise
            except MigrationStopped:
                # A lost response may follow a committed write. Reconcile once,
                # without resending the update or overwriting any current data.
                written = client.request("GET", FIRESTORE + document["name"])
            if (written.get("fields", {}) != expected or written.get("name") != document["name"]
                    or written.get("createTime") != document["createTime"]):
                raise MigrationStopped("post_update_verification_failed")
            confirmed = client.request("GET", FIRESTORE + document["name"])
            if confirmed != written:
                raise MigrationStopped("post_update_document_changed")
            result["updated"] += 1
        except MigrationStopped as error:
            result["failed"] += 1
            failures.append({"ordinal": ordinal, "reason": str(error)})
    private_json(Path(directory) / "migration-result.json", result)
    private_json(Path(directory) / "migration-failures.json", failures)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--database", required=True)
    parser.add_argument("--backup-dir", required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    try:
        if args.project != PROJECT or args.database != DATABASE:
            raise MigrationStopped("target_not_allowlisted")
        result = run_migration(FirestoreRest(), args.backup_dir, apply=args.apply,
                               project=args.project, database=args.database)
        print(json.dumps(result, sort_keys=True))
        return 1 if result["failed"] else 0
    except MigrationStopped as error:
        print(json.dumps({"status": "stopped", "reason": str(error)}))
        return 1
    except Exception:
        print(json.dumps({"status": "stopped", "reason": "local_backup_or_execution_failed"}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
