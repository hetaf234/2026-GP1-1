# Container preparation and controlled release plans

## Purpose

Reproduce the approved backend layout and prepare guarded cloud/mobile automation.

## Contents

Approved runtime Python modules remain here for unchanged imports. source-map.json defines explicit runtime overlays; approved-runtime.json preserves file identities. policy.json holds disabled activation flags and target identities. cloudbuild.build-only.yaml builds/tests/pushes only; it never deploys. iam-plan.json and distribution-plan.json are plans, not applied resources. tools contains the pinned emulator CLI dependency lock.

## Important Files

prepare_runtime.py generates .local/runtime-context. runtime_smoke.py verifies bundle integrity and loads both real local CPU models without an image or provider request. build_cloud.py submits a build only after approval. deploy_backend.py updates only the existing testing service. check_apk.py/sign_apk.py verify and preserve the existing Android identity. firebase_distribution.py separates upload from tester assignment.

## How It Works

The Docker overlay uses the approved private base by digest, including model weights and required human authority. It never installs packages or downloads weights during a cloud build. GitHub orchestrates Cloud Build; there is no duplicate Cloud Build trigger. Runtime service secrets/IAM/resources are preserved and compared around an image update.

## When to Modify

Change source-map only when runtime files genuinely change. Review policy, base digest, runtime manifests, IAM and workflow templates as security-sensitive changes. Do not activate, submit builds, upload APKs or grant permissions during this preparation phase.

## Dependencies

Docker with AMD64 support; the private Artifact Registry base; Python 3.14; Google Cloud SDK for future approved submission; an existing approved source bucket and dedicated build/orchestrator identities. Android publication additionally needs the existing key, verified wireless connectivity and a configured App Distribution app/group.

## Important Notes

allow_backend_deployment, allow_android_distribution, mobile_connectivity_verified and allow_tester_delivery are false. Scripts fail closed before cloud writes. Stable service targeting is rejected. Never put runtime credentials or the signing keystore in Git. Read docs/CI_CD.md and docs/APP_DISTRIBUTION.md before activation.

## Local container verification

```sh
python deployment/prepare_runtime.py
docker build --platform=linux/amd64 --network=none -t misbar-local:review .local/runtime-context
cat deployment/runtime_smoke.py | docker run --rm -i --network=none --read-only --cpus=4 --memory=8g --tmpfs /tmp --entrypoint python misbar-local:review -B -
```

Base identity and model dependencies are in policy.json and approved-runtime.json. This local workflow requires existing private-base read access, but no provider credentials. No command above pushes or deploys.

## Runtime configuration

The existing testing service uses 4 vCPU, 8 GiB, one worker, concurrency 1, min 0/max 1, a 600-second request timeout and /ready startup probe. Secret Manager supplies Firebase, Vision, Sightengine and Claude secrets through existing mounts/references. The CI builder must not receive those runtime secrets. For backend rollback, keep the previous revision and use the reviewed image-update receipt's rollback command only after owner approval.
