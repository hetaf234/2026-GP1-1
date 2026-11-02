# Local preparation status

## Prepared

- Independent local integration branch from the existing hetaf234/2026-GP1-1 initial history; original worktree/other remote untouched.
- Approved Flutter Android source and header fix, unchanged application/signing identity.
- Backend source extracted and hash-verified against the approved deployed image.
- Latest two JSON files with approved hashes and original runtime paths preserved by explicit source mapping.
- Folder READMEs, student collaboration/setup, CI/CD, signing/distribution, and wireless design documents.
- Pinned private model base, model/data integrity checks, local mock tests, emulator security tests and AMD64 model-loading smoke.
- Three inactive workflow templates, keyless WIF/IAM plans, fail-closed upload/deploy gates and separate tester-delivery approval.
- Candidate secret/artifact scan, unchanged public client Firebase build config, and excluded private keys/models/user data.

## Not performed

No commit, push, Git merge/tag, remote branch/PR/release, author-identity change, repository visibility/protection change, collaborator/tester invitation, IAM grant, WIF/service-account/bucket provisioning, Cloud Build submission, Cloud Run deployment, Firebase APK upload, signing-key change or Firestore/Auth/rules change. No real image/paid analysis was requested.

## Open owner decisions (separate approvals)

1. Review local files and control initial commits/pushes yourself.
2. Keep the repository Public for committee review, review the public publication candidates, and separately apply main protection. Adapt the currently disabled private-only deployment guards/WIF plan in a future approved implementation before activation. Collaborator enumeration/detailed protection administration requires additional authorized read access or owner console review; do not infer the team list.
3. Provide/approve team GitHub usernames and separately approve collaborator permissions.
4. Review proposed dedicated build/orchestrator/distributor identities, WIF numeric conditions, staging bucket/API needs and each scoped IAM grant.
5. Separately approve backend workflow activation and the first testing-service deployment.
6. Review App Distribution Get started state (groups read returned 404), approve the private group/tester emails and signing-key secret handling.
7. Separately approve a wireless security design and verify it end to end before enabling APK upload.
8. Separately approve upload and later tester release access/invitations.

This preparation does not claim a live CI/CD or USB-free App Distribution rollout. The current approved Cloud Run revisions remain the reference. All publication stays under the owner's direct control.

## Verified access limits

The repository was Public and main reported unprotected during the earlier preparation inspection. The owner explicitly requires it to remain Public. The connected owner had administrative permission, but the GitHub integration could not enumerate collaborators or read detailed branch protection. The browser's access-settings page required owner reconfirmation; no verification message was sent and no settings were changed. The account's paid plan is unverified. Check protected-environment reviewer availability and apply public-repository branch protection separately before activation. If the necessary approval controls are unavailable, keep automated publishing disabled and decide the manual release process separately. The final public review is local only and does not refresh remote settings.

Creating a signing-key secret may require enabling Secret Manager and appropriate billing in the Firebase project. Secret storage/access, Cloud Build, Artifact Registry storage, runner usage and a future wireless relay may incur charges. No such resource, API activation or paid build was created by this preparation.
