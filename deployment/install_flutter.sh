#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
destination="${RUNNER_TEMP:?RUNNER_TEMP is required}/flutter"
revision="$(python3 -c 'import json; print(json.load(open("deployment/policy.json"))["flutter_commit"])')"
[[ "$revision" =~ ^[a-f0-9]{40}$ ]]
git init --quiet "$destination"
git -C "$destination" remote add origin https://github.com/flutter/flutter.git
git -C "$destination" fetch --quiet --depth=1 origin "$revision"
git -C "$destination" checkout --quiet --detach FETCH_HEAD
test "$(git -C "$destination" rev-parse HEAD)" = "$revision"
echo "$destination/bin" >> "${GITHUB_PATH:?GITHUB_PATH is required}"
