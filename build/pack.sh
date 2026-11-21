#!/usr/bin/env bash
# Packs dist and/or dist-types and checks each tarball's package.json before upload.
# Packs from inside each folder, as the template's "npm publish" did, so the package's prepack,
# prepare and postpack scripts run here. That's acceptable: this job has no id-token.
# Environment: NAME, VERSION, PUBLISH, PUBLISH_TYPES, OUT_DIR.
set -euo pipefail
fail() { echo "::error::$*"; exit 1; }
mkdir -p "$OUT_DIR"

pack() { # pack DIR EXPECTED_NAME
  local dest tgz manifest
  dest=$(mktemp -d)
  (cd "$1" && npm pack --pack-destination "$dest" 1>&2)
  tgz=$(ls "$dest"/*.tgz)
  manifest=$(tar -xzOf "$tgz" package/package.json)
  jq -e --arg n "$2" --arg v "$VERSION" \
    '.name == $n and .version == $v and (.private // false) != true' <<<"$manifest" >/dev/null \
    || fail "$1/package.json is not a public $2@$VERSION."
  mv "$tgz" "$OUT_DIR/"
  echo "Packed $2@$VERSION as $(basename "$tgz")"
}

if [[ $PUBLISH == true ]]; then pack dist "$NAME"; fi
if [[ $PUBLISH_TYPES == true ]]; then pack dist-types "$NAME-types"; fi
