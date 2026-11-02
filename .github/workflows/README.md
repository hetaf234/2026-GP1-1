# Inactive GitHub Actions templates

## Purpose

Keep all automation inactive during preparation.

## Contents

CI tests pull requests and main changes, with path-based skips and a consistent aggregate check. Backend publishing only considers backend/data/deployment paths. Android building, signing/upload with short-lived cloud authentication, and separately approved tester delivery use distinct jobs. APK signing itself still requires the existing approved private key.

## Important Files

ci.yml.disabled, backend-deploy.yml.disabled, android-distribution.yml.disabled. No active .yml or .yaml workflow exists in this preparation.

## How It Works

Activation requires owner action: select a template, review its pinned actions and permissions, satisfy policy.json and environment gates, then rename it. Publishing source alone must not activate deployments.

## When to Modify

Update paths if real source layout changes. Never use pull_request_target for untrusted code or grant contents: write to release jobs.

## Dependencies

Official GitHub Actions pins, WIF, protected main, protected environments and the local deployment helper scripts.

## Important Notes

The current disabled templates reject publishing from a feature branch and require protected main and a merged same-repository PR with a current-head approval. Their guards and WIF proposal also retain an earlier private-repository condition. This repository must remain Public; that condition is a known blocker to future deployment/distribution activation, not a reason to change visibility. See docs/PUBLIC_REPOSITORY_REVIEW.md. Initial group access/invitations are a distinct approval.
