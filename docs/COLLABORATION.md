# Four-student collaboration

## Current verified repository

The owner confirmed hetaf234/2026-GP1-1. At initial inspection it was public, with one initial commit, only README.md, a single main branch and no protection. The connected owner has admin permission. The integration connector cannot enumerate collaborators or read detailed branch-protection administration; those are not assumed verified. The account's subscription plan was not available through that connection.

This preparation is on a separate local prepare/misbar2-local-integration branch. Existing main history and author identities are retained. No commits, pushes, PRs, invitations or remote settings changes were performed. The original working copy and its unrelated remote are outside this integration.

## Owner decisions before publication

Keep this repository Public for the graduation-project committee, as explicitly required by the owner. Review all publication candidates before the first push; do not include private artifacts simply because they exist locally. GitHub documents branch protection for public repositories on Free. Confirm the exact environment-review features and settings before relying on them; no settings were changed by this preparation. [GitHub protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).

The owner supplies and approves the other three GitHub usernames. Do not guess them. Give only the necessary write access for feature branches; students do not need admin/IAM access. Require one approving review by someone other than the author, dismiss stale approvals, require conversation resolution and the Misbar CI check, apply protections to administrators, disallow force pushes/deletions, and prevent direct main pushes. Add code owners only after the actual reviewers are approved. No protection has been applied by this preparation.

All workflow templates are currently disabled, so Misbar CI is not yet an active required check. The owner can publish the reviewed integration branch first for human review. Activation of test-only CI and the later required-check setting need separate review; a missing check must not be represented as passing. Cloud/mobile publishing remains disabled until the public-repository incompatibility described in PUBLIC_REPOSITORY_REVIEW.md is resolved.

## Human-owned Git workflow

Each student makes a small feature branch, describes the user-visible result, tests the change, and personally commits/pushes using their own account. The following are human instructions, not commands executed by the agent:

```sh
git switch main
git pull --ff-only
git switch -c feature/short-description
# Edit and run relevant tests.
git status
git diff
# Review every staged path; never add credentials or generated outputs.
git add <reviewed-source-files>
git commit -m "Describe the resulting behavior"
git push -u origin feature/short-description
```

Open the PR manually in GitHub against main. Include the test evidence, data/artifact changes and rollback notes. Another student reviews it. The owner or an authorized reviewer performs the merge only after required checks/reviews pass. Never enable a bot to author commits or auto-push fixes. No workflow here has contents: write permission.

## Receiving changes and conflicts

Use `git fetch origin` to inspect reviewed remote changes. Keep local work on its feature branch and do not reset or overwrite uncommitted work. If main can fast-forward safely, use `git pull --ff-only`. For a conflict, keep a backup, coordinate with the file owner, inspect both versions in the editor, resolve the actual behavior, rerun affected tests and have a human make the reviewed resolution commit. Do not discard a teammate's changes, force-push main, rewrite authors/history, or auto-resolve data/model conflicts. Approved hashes must be reconciled deliberately, not chosen just because one side is newer.

## Initial integration review

The existing remote contains only README.md. All new project paths are additions; the root README is the only existing file being expanded. A copy of the initial repository history and the approved source backup are retained outside Git. If remote main changes before the owner publishes, inspect the fresh diff and integrate manually; do not replace main blindly.
