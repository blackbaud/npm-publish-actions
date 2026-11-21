#!/usr/bin/env bash
# Publishes the tarballs in PACKAGES_DIR to registry.npmjs.org with npm trusted publishing (OIDC).
# The build job runs dependency code, so its tarballs are checked against what verify approved:
# NAME@VERSION when PUBLISH is true and NAME-types@VERSION when PUBLISH_TYPES is true. Each
# approved package needs exactly one tarball, any other tarball fails the job, and nothing
# publishes until every package passes every check. A re-run skips versions already on npm with
# identical contents.
# Environment: NAME, VERSION, PUBLISH, PUBLISH_TYPES, PACKAGES_DIR, ACTIONS_ID_TOKEN_REQUEST_URL,
# GITHUB_ACTION_PATH.
set -euo pipefail
fail() { echo "::error::$*"; exit 1; }

[[ -n ${ACTIONS_ID_TOKEN_REQUEST_URL:-} ]] || fail "The publish job needs permissions: id-token: write."
unset NODE_AUTH_TOKEN

# Trusted publishing needs npm 11.5.1 or later, which Node 24 bundles from 24.5.0 on.
npm_version=$(npm --version)
[[ $(printf '%s\n' 11.5.1 "$npm_version" | sort -V | head -n1) == 11.5.1 ]] \
  || fail "Trusted publishing needs npm 11.5.1 or later, but Node $(node --version) bundles npm $npm_version."

NPM_ROOT=$(npm root --global)
export NPM_ROOT

# Every npm call reads from and publishes to npmjs.org. --registry outranks npmrc files and the
# environment, but a scoped registry outranks --registry, so no npm config may name another one.
registry=https://registry.npmjs.org/
elsewhere='[to_entries[] | select((.key | test("registry$"; "i"))
            and ((.value | tostring | rtrimstr("/")) != "https://registry.npmjs.org")) | .key]
           | join(", ")'
other=$(npm config list --json --registry "$registry" | jq -r "$elsewhere") \
  || fail "Could not read the npm config."
[[ -z $other ]] || fail "npm config points $other at a registry other than $registry."

expected=()
if [[ $PUBLISH == true ]]; then expected+=("$NAME@$VERSION"); fi
if [[ $PUBLISH_TYPES == true ]]; then expected+=("$NAME-types@$VERSION"); fi
(( ${#expected[@]} > 0 )) || fail "Neither publish nor publish-types is true."
declare -A approved=() tarball=() manifest=() dist_tag=()
for id in "${expected[@]}"; do approved[$id]=1; done

shopt -s nullglob
for tgz in "$PACKAGES_DIR"/*.tgz; do
  file=$(basename "$tgz")
  json=$(TARBALL="$tgz" node "$GITHUB_ACTION_PATH/read-manifest.js") || fail "$file: $json."
  id=$(jq -r '"\(.name)@\(.version)"' <<<"$json") || fail "$file: package.json is not an object."
  [[ -n ${approved[$id]:-} ]] || fail "$file holds $id, which verify did not approve."
  [[ -z ${tarball[$id]:-} ]] || fail "More than one tarball holds $id."
  # npm publish applies any npm setting in publishConfig that the command line doesn't set,
  # including to the OIDC token exchange. A proxy, CA or strict-ssl setting there could hand the
  # publish token to someone else, and a scoped registry could redirect the upload. Only the
  # settings the publish command below sets itself, which its flags outrank, are allowed.
  other=$(jq -r '.publishConfig // {} | keys - ["access", "provenance", "registry", "tag"]
                 | join(", ")' <<<"$json") \
    || fail "$id: publishConfig in package.json is not an object."
  [[ -z $other ]] || fail "$id sets $other in publishConfig. Only access, provenance, registry and tag are allowed."
  # verify checks the root package.json, but the build writes dist-types/package.json and can
  # change dist/package.json, so each published manifest is checked for internal dependencies too.
  internal=$(jq -r '[(.dependencies, .devDependencies, .peerDependencies, .optionalDependencies)
                     // {} | to_entries[]
                     | select((.key | startswith("@blackbaud-internal/"))
                              or (.value | tostring | startswith("npm:@blackbaud-internal/")))
                     | .key] | unique | join(", ")' <<<"$json") \
    || fail "$id: a dependency list in package.json is not an object."
  [[ -z $internal ]] || fail "$id depends on @blackbaud-internal packages, which npmjs.org consumers can't install: $internal."
  tarball[$id]=$tgz manifest[$id]=$json
done
for id in "${expected[@]}"; do
  [[ -n ${tarball[$id]:-} ]] || fail "No tarball holds $id."
done

to_publish=()
for id in "${expected[@]}"; do
  tgz=${tarball[$id]}
  pkg=${id%@*}

  integrity="sha512-$(openssl dgst -sha512 -binary "$tgz" | base64 -w0)"
  existing=$(npm view "$id" dist.integrity --registry "$registry" 2>/dev/null || true)
  if [[ -n $existing ]]; then
    [[ $existing == "$integrity" ]] || fail "$id is already on npm with different contents."
    echo "::notice::$id is already published with the same contents."
    continue
  fi

  versions=$(npm view "$pkg" versions --json --registry "$registry") \
    || fail "Could not read $pkg from npm. It must already exist there before trusted publishing."
  tag=$(VERSIONS="$versions" VERSION="$VERSION" node "$GITHUB_ACTION_PATH/dist-tag.js") \
    || fail "$id: $tag."
  # npm publishes under a top-level "tag" in package.json in place of --tag.
  jq -e --arg t "$tag" '(.tag // $t) == $t' <<<"${manifest[$id]}" >/dev/null \
    || fail "$id sets \"tag\" in package.json, which would replace its dist-tag $tag."
  dist_tag[$id]=$tag
  to_publish+=("$id")
done

for id in "${to_publish[@]}"; do
  echo "Publishing $id with dist-tag ${dist_tag[$id]}"
  npm publish "${tarball[$id]}" --registry "$registry" --tag "${dist_tag[$id]}" \
    --access public --ignore-scripts --provenance=false
done
