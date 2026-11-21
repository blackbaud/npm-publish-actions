#!/usr/bin/env bash
# Template "Prepare Package": copy the root package.json into dist (module -> index.js when set),
# plus README.md and CHANGELOG.md.
set -euo pipefail
fail() { echo "::error::$*"; exit 1; }
[[ -d dist ]] || fail "dist directory not found."
jq 'if (.module // "") != "" then .module = "index.js" else . end' package.json > dist/package.json
cp README.md CHANGELOG.md dist/
