# Misbar team documentation

## Purpose

Provide implementation-matched setup, collaboration and release guidance.

## Contents

`STUDENT_SETUP.md` covers local dependencies and Android Emulator. `COLLABORATION.md` covers branches/reviews and safe conflict resolution. `CI_CD.md` covers build/deploy identities and activation gates. `APP_DISTRIBUTION.md` covers signing, upload, tester access and Android rollback. `BACKEND_CONNECTIVITY.md` explains the current USB/proxy dependency and a separate security proposal. `PREPARATION_STATUS.md` lists what is prepared and what remains unapproved. `PUBLIC_REPOSITORY_REVIEW.md` records the Public requirement, publication boundaries and remaining private-only automation incompatibility.

## Important Files

Read PREPARATION_STATUS.md before publishing, BACKEND_CONNECTIVITY.md before claiming USB-free operation, and CI_CD.md before enabling any cloud automation.

## How It Works

Folder READMEs describe actual checked-in code. Release documents distinguish local preparation from remote activation.

## When to Modify

Update documentation in the same reviewed change as implementation. Do not document proposed endpoints, groups or IAM as existing resources.

## Dependencies

Current source/configuration and the linked official vendor references.

## Important Notes

No private user emails, account backups, service-account keys, local machine files or sensitive logs belong in documentation.
