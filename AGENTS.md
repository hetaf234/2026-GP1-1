# Misbar repository instructions

Use only the owner-confirmed hetaf234/2026-GP1-1 repository. Do not connect to or modify any unrelated repository or original working copy.

Agents must not create commits, push, merge, tag, create PRs/releases/remote branches, alter Git author identity, change repository visibility, invite collaborators, grant IAM, deploy Cloud Run, upload/distribute APKs or modify Firebase data/settings without the owner's separate explicit instructions. This preparation is local only; the owner controls Git publication.

Preserve approved dataset hashes in data/approved-hashes.json, existing package/signing identity, token verification, allergies and model behavior. No paid scan calls in automated tests. Never deploy to the stable service.

Human label reviews permanently outrank folder labels, model suggestions and historical manifests. Use backend/dish_pipeline/src/dish_identifier/human_labels.py and the required central registry before deriving ground truth or metrics. The registry and active references are retained in the pinned private base under /opt/misbar/dish/data_governance; they are intentionally not exposed in Git. Missing/stale authority must fail, not fall back. Match images by exact SHA-256. RELABEL affects only reference targets, never predictions; KEEP overrides automated proposals; UNSURE is unresolved; EXCLUDE_UNUSABLE is not eligible. Keep source evidence and history. Do not open reserved OOD Final Test without separate authorization.

Normalization/data versions are separate from approach/model versions. Keep sources and causes, never invent allergen mappings, and preserve immutable historical evidence. Frozen model/configuration and human-review changes need a separately reviewed artifact. Model smoke checks load local weights without real images; they are not accuracy evaluations.
