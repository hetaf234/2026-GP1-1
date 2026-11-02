# Firestore security emulator regressions

## Purpose

Test the already deployed policy without writing to production.

## Contents

firestore_rules_test.py attacks owner reads, cross-user access, role/language writes, deletes, batches and forged admin claims using synthetic local users.

## Important Files

Root firestore.rules is the existing rule snapshot. Root firebase.json selects local emulator ports only. No deployment command or live user credentials are required.

## How It Works

The test refuses to run unless FIRESTORE_EMULATOR_HOST is 127.0.0.1:8810. All documents belong to demo-misbar-metadata, a local demo project.

## When to Modify

Add a regression when a rule is intentionally changed through a separately approved task. Never change production rules or rerun a user migration to satisfy these tests.

## Dependencies

JDK 21, the pinned Firebase CLI under deployment/tools, Python requests and the local Firestore emulator.

## Important Notes

Emulator fixture writes are temporary. They must never be redirected to misbar-ebea2 or any real project.

```sh
npm ci --prefix deployment/tools --ignore-scripts --no-audit --no-fund
deployment/tools/node_modules/.bin/firebase emulators:exec --only firestore --project demo-misbar-metadata 'python -m unittest discover -s security_tests -p "*_test.py"'
```
