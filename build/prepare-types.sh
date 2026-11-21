#!/usr/bin/env bash
# Template "Prepare Types Package": dist-types becomes <name>-types at the same version.
# Environment: NAME, VERSION.
set -euo pipefail
fail() { echo "::error::$*"; exit 1; }
[[ -d dist-types ]] || fail "dist-types directory not found."
[[ -f dist-types/package.json ]] || echo '{}' > dist-types/package.json
npm -C dist-types pkg set "name=$NAME-types" "description=Type definitions for $NAME" "version=$VERSION"
if [[ $(npm -C dist-types pkg get types) == '{}' ]]; then
  [[ -f dist-types/index.d.ts ]] || fail "Unable to find index.d.ts in dist-types."
  npm -C dist-types pkg set types=index.d.ts
fi
