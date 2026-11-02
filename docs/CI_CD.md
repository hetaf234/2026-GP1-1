# Backend CI/CD plan — inactive

## Current state and design

No workflow/trigger, WIF pool, CI account, IAM grant, source bucket or new Cloud Run revision was created. The hosting-project WIF pool list was empty during the earlier preparation inspection. Both live services remain unchanged by this work. Templates are `.yml.disabled`; publication/renaming alone is insufficient because explicit flags default false. The owner now explicitly requires a Public repository. The current guards/WIF proposal still require Private and therefore are not activation-ready for that requirement; see PUBLIC_REPOSITORY_REVIEW.md. Do not change repository visibility.

One GitHub Actions orchestration submits a build to Google Cloud Build. There is no independent Cloud Build repository trigger. CI tests PRs and main, with path detection and a stable aggregate Misbar CI check. Backend deployment only reacts to backend/data/deployment changes; documentation-only changes do not deploy it. Android distribution is separate.

## Reproducible model strategy

policy.json pins the approved private AMD64 runtime base by digest, not a moving public alternative. It contains the model binaries, required human-label registry and active references. These private assets are not copied into Git. approved-runtime.json records the asset hashes; source-map.json maps reviewed source and current data into the unchanged /opt/misbar runtime paths. prepare_runtime.py updates the bundle integrity manifest and generates a small Docker overlay under .local. Current prepared sources reproduce the approved runtime manifest bytes exactly.

Cloud Build's steps prepare temporary writable output, run credential-free unit/contract checks, create the explicit overlay, build AMD64 without networking during Docker RUN, and load both models in a no-network container. Only a successful build pushes its declared image. GitHub reads that build's immutable digest and invokes the testing-service image updater. Model/registry/configuration hashes are verified. Keep the private base digest and its identifying registry tag retained; do not enable cleanup that removes the required base or rollback image. No model retraining/download is part of this pipeline.

## Authentication and narrow permissions

Use separate backend orchestrator, Cloud Build builder and Android distributor identities. iam-plan.json is a reviewable proposal, not a provisioning script. WIF conditions bind numeric owner ID 184541228 and repository ID 1441817440, private visibility, main push and the exact corresponding workflow ref. No stored service-account JSON key is used. [Google WIF deployment pipeline guidance](https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines).

The builder can read/write only the model Artifact Registry repository, read its dedicated staging bucket and write build logs. It does not receive runtime provider secrets or Firestore privileges. The orchestrator can submit builds using the chosen builder identity, upload/read its dedicated source bucket, update only the existing testing service and act as only the existing runtime identity. Source bucket metadata read is needed for the explicit existence check. Never grant Owner/Editor, project-wide secret access or stable-service write privileges. Dedicated identity provisioning, API activation, bucket creation and each scoped IAM binding require separate owner approval; do not run a bulk setup without review.

## Required non-secret GitHub settings after approval

- MISBAR_BACKEND_DEPLOY_ENABLED, initially absent/false.
- MISBAR_BACKEND_WIF_PROVIDER: the approved provider resource name.
- MISBAR_BACKEND_ORCHESTRATOR: dedicated orchestrator SA email.
- MISBAR_CLOUD_BUILD_ACCOUNT: dedicated builder SA email.
- MISBAR_BUILD_SOURCE_BUCKET: an explicitly approved existing bucket name.
- Protected environment `misbar-test`, with a reviewer distinct from the author.

The policy file also requires allow_backend_deployment=true through a reviewed owner-approved change. Do not add provider secret values to GitHub variables. The source archive uses .gcloudignore, excludes credential files, and includes only two frontend contract inputs required by backend regressions. The Docker build context is an explicit source allowlist and never includes GitHub ADC credentials.

## Branch and failure controls

As currently implemented, a publishing run must be main in the intended private repository, main must report protected, and the commit must correspond to a merged same-repository PR with a current-head approval. The private check conflicts with the owner's Public requirement and deliberately remains unchanged in this documentation-only review. A future approved implementation must retain numeric repository/owner identity, exact workflow/main/event conditions, current-head review and protected environment controls while safely supporting Public. Unreviewed direct pushes and feature branches must continue to fail before cloud identity is requested. Branch protection must independently enforce required reviews/checks; the guard is additional protection, not a replacement for administration settings.

The deployer uses services update with image only. It checks target identity, private IAM, 4 vCPU/8 GiB, concurrency 1, min 0/max 1, timeout 600 and /ready startup probe. It compares resources/environment/volumes/service account and IAM afterwards and retains the previous revision/rollback receipt. It never creates a service, changes IAM/secrets, deploys rules or targets the stable service. A build/test/guard failure stops publication. A failed post-check stops and requires review; no additional automatic deployment or paid scan is attempted. Do not retry image-analysis calls as a deployment check.

## Activation and rollback

After reviewing all local files, the owner controls publication into this Public repository. Separately review the public-repository guard changes, protection settings, infrastructure/IAM, backend activation and the first test deployment. Only after those approvals and tests may the backend template be renamed, the reviewed variables/flags set, and environment review enforced. No part of these steps was activated here.

For a later authorized rollback, use the exact previous revision saved by deploy_backend.py in .local/deployment-receipt/rollback.txt. The command changes traffic on the testing service only. The initial reference remains misbar-consolidated-test-20261101-json-e933-ce5b-105802. Stable service misbar-models-dataset-candidate is never a deployment target.

## Costs

Local preparation creates no recurring cloud resources. Future Cloud Build uses E2_HIGHCPU_8, Artifact Registry stores images, a dedicated source bucket stores build inputs, and Cloud Run revisions run under existing test limits. These have usage-based costs and need an approved budget. Review GitHub runner limits and environment protection support for the owner's Public repository before activation. No build submission or billable provider analysis was performed by this preparation.
