"""Check the immutable build input, including the mandatory human authority."""
import hashlib
import json
from pathlib import Path

V5_CAPABILITIES = {
    "frozen_pipeline": {"user_allergy_matching_enabled": False},
    "dish_endpoint": {"personalization": "verified_uid_firestore", "json": True,
                      "sse": True, "sse_protocol": "progress_outcome_v1"},
}
V5_REQUIRED_FILES = (
    "dish/configs/pipeline.json",
    "deployment/dish_api.py",
    "labels/app/services/dish_allergen_service.py",
    "labels/app/services/dish_progress_service.py",
)


def verify_capabilities(manifest):
    # Legacy v4 snapshots remain valid provenance inputs. New snapshots declare
    # endpoint features separately from the frozen pipeline's disabled matcher.
    schema = manifest.get("schema_version", 1)
    if schema not in (1, 2):
        raise ValueError("Unsupported deployment manifest schema.")
    if schema == 2 or "capabilities" in manifest:
        if manifest.get("capabilities") != V5_CAPABILITIES or manifest.get("user_allergy_matching_enabled") is not False:
            raise ValueError("Deployment capability metadata is inconsistent.")
        for name in V5_REQUIRED_FILES:
            if name not in manifest["files"]:
                raise ValueError("Required Dish deployment asset is missing: " + name)


def verify(root):
    root = Path(root).resolve()
    manifest = json.loads((root / "bundle_manifest.json").read_bytes())
    verify_capabilities(manifest)
    for name, expected in manifest["files"].items():
        path = (root / name).resolve()
        if not path.is_relative_to(root) or not path.is_file():
            raise ValueError("A deployment asset is missing: " + name)
        if path.stat().st_size != expected["bytes"]:
            raise ValueError("A deployment asset size changed: " + name)
        with path.open("rb") as stream:
            actual = hashlib.file_digest(stream, "sha256").hexdigest()
        if actual != expected["sha256"]:
            raise ValueError("A deployment asset hash changed: " + name)
    if manifest.get("schema_version") == 2:
        config = json.loads((root / "dish/configs/pipeline.json").read_bytes())
        if config.get("allergy_matching_enabled") is not False:
            raise ValueError("Frozen pipeline allergy matching must remain disabled.")
    registry = root / "dish/data_governance/human_label_registry.json"
    active = json.loads((root / "dish/data_governance/active_references.json").read_bytes())
    digest = hashlib.sha256(registry.read_bytes()).hexdigest()
    if active.get("status") != "ready" or active.get("registry_sha256") != digest or manifest["registry_sha256"] != digest:
        raise ValueError("Human-review authority is missing or stale.")
    return manifest


if __name__ == "__main__":
    verify(Path(__file__).resolve().parents[1])
    print("Deployment source hashes and human authority verified.")
