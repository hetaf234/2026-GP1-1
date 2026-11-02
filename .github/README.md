# GitHub collaboration metadata

## Purpose

Prepare review guidance and inactive workflow templates for this repository only.

## Contents

`workflows/` contains ci.yml.disabled, backend-deploy.yml.disabled and android-distribution.yml.disabled. PULL_REQUEST_TEMPLATE.md requests test evidence and scope/rollback notes.

## Important Files

The CI result job is named Misbar CI. Cloud and mobile templates use dedicated protected environments and short-lived WIF credentials after separate activation.

## How It Works

Files ending in .yml.disabled are not GitHub workflows. The owner must explicitly review and rename selected templates only after all corresponding gates are satisfied.

## When to Modify

Edit templates and PR guidance in reviewed changes. Do not add remote collaborators, activate workflows or create PRs on the owner’s behalf.

## Dependencies

The existing hetaf234/2026-GP1-1 repository, future branch protection and approvals, and action versions pinned in deployment/action-pins.json.

## Important Notes

No bot-authored commits, automatic pushes or Git author configuration are used. Backend and Android delivery are separate. Unknown team usernames must not be guessed.
