#!/usr/bin/env bash
# Gate for npm publishing. Makes GitHub API calls and fetches the tagged commit object to check its
# signature; never checks out or runs repository code. Needs curl, gpg, git, gh and jq.
#
# Environment: GH_TOKEN, DEFAULT_BRANCH, plus the standard GITHUB_* variables.
# Writes name, version, publish and publish-types to GITHUB_OUTPUT, plus node-version when either
# publish flag is true.
set -euo pipefail
fail() { echo "::error::$*"; exit 1; }
repo=$GITHUB_REPOSITORY sha=$GITHUB_SHA tag=$GITHUB_REF_NAME

[[ $GITHUB_EVENT_NAME == push && $GITHUB_REF_TYPE == tag ]] \
  || fail "Run this on a tag push, not a $GITHUB_EVENT_NAME of a $GITHUB_REF_TYPE."

# 1. The tag is exactly the package.json version (template: "Enforce matching versions").
manifest=$(gh api "repos/$repo/contents/package.json?ref=$sha" --jq .content | base64 -d)
name=$(jq -r .name <<<"$manifest")
version=$(jq -r .version <<<"$manifest")
[[ $tag == "$version" ]] || fail "Tag $tag does not match package.json version $version."

# 2. Each pipelineSettings flag publishes its own package, independent of the other.
#    Both default to false (template: "Set global npm publish variables").
flag() { jq -r --arg k "$1" '(.pipelineSettings[$k] // false | tostring | ascii_downcase) == "true"' <<<"$manifest"; }
publish=$(flag publishToNPM)
publish_types=$(flag publishTypesToNPM)
{
  echo "name=$name"
  echo "version=$version"
  echo "publish=$publish"
  echo "publish-types=$publish_types"
} >> "$GITHUB_OUTPUT"
if [[ $publish != true && $publish_types != true ]]; then
  echo "::notice::Neither publishToNPM nor publishTypesToNPM is true for $name. Nothing to do."
  exit 0
fi

# 3. Neither the package nor any dependency (by name or npm: alias) is @blackbaud-internal, since
#    npmjs.org consumers can't install those.
[[ $name != @blackbaud-internal/* ]] || fail "$name is internal; it publishes through ADO to Blackbaud-npm."
internal=$(jq -r '[(.dependencies, .devDependencies, .peerDependencies, .optionalDependencies)
                   // {} | to_entries[]
                   | select((.key | startswith("@blackbaud-internal/"))
                            or (.value | tostring | startswith("npm:@blackbaud-internal/")))
                   | .key] | unique | join(", ")' <<<"$manifest")
[[ -z $internal ]] || fail "$name depends on @blackbaud-internal packages, which npmjs.org consumers can't install: $internal."

# 4. The build's Node version from .nvmrc (template "Setup Node") is 22 or 24, or an exact version
#    that satisfies ^22.23.5 || ^24.22.3. setup-node resolves a bare major to that line's newest
#    release. Aliases such as lts/* are rejected, because what they resolve to changes over time.
#    Without .nvmrc it is 22. The build action sets up the node-version output instead of reading
#    .nvmrc itself, so it runs the version approved here however setup-node would parse the file.
node=22
has_nvmrc=$(gh api "repos/$repo/contents?ref=$sha" --jq 'any(.[]; .name == ".nvmrc" and .type == "file")')
if [[ $has_nvmrc == true ]]; then
  nvmrc=$(gh api "repos/$repo/contents/.nvmrc?ref=$sha" --jq .content | base64 -d | tr -d '\r' | awk 'NF { print $1; exit }')
  node=
  if [[ $nvmrc =~ ^v?(22|24)$ ]]; then
    node=${BASH_REMATCH[1]}
  elif [[ $nvmrc =~ ^v?((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$ ]]; then
    major=${BASH_REMATCH[2]} minor=${BASH_REMATCH[3]} patch=${BASH_REMATCH[4]}
    if (( (major == 22 && (minor > 23 || (minor == 23 && patch >= 5)))
          || (major == 24 && (minor > 22 || (minor == 22 && patch >= 3))) )); then
      node=${BASH_REMATCH[1]}
    fi
  fi
  [[ -n $node ]] || fail ".nvmrc is '$nvmrc'. It must be 22, 24, or a version that satisfies ^22.23.5 || ^24.22.3."
fi
echo "node-version=$node" >> "$GITHUB_OUTPUT"

# gh api --paginate prints one JSON document per page; jq -s gathers them. For list endpoints,
# "add // []" joins the pages into one array.

# 5. Exactly one PR, merged into the default branch or a <major>.x.x maintenance branch,
#    whose merge commit is this tag.
prs=$(gh api --paginate "repos/$repo/commits/$sha/pulls?per_page=100" \
  | jq -s --arg sha "$sha" --arg default "$DEFAULT_BRANCH" '
  [add // [] | .[] | select(.merged_at != null and .merge_commit_sha == $sha
                and (.base.ref == $default or (.base.ref | test("^[0-9]+\\.x\\.x$"))))]')
[[ $(jq length <<<"$prs") == 1 ]] || fail "$tag is not the merge commit of a PR into $DEFAULT_BRANCH or a <major>.x.x branch."
number=$(jq -r '.[0].number' <<<"$prs")
base=$(jq -r '.[0].base.ref' <<<"$prs")
head=$(jq -r '.[0].head.sha' <<<"$prs")
author=$(jq -r '.[0].user.login' <<<"$prs")

# 6. Still on that branch.
status=$(gh api "repos/$repo/compare/$sha...$base" --jq .status)
[[ $status == ahead || $status == identical ]] || fail "$sha is not on $base."

# 7. GitHub's merge or squash button created and signed it (rebase merges are never signed).
signed=$(gh api "repos/$repo/commits/$sha" --jq '.commit.verification.verified and .committer.login == "web-flow"')
[[ $signed == true ]] || fail "$sha was not created and signed by GitHub."
#    The signature is also checked here, not only by the API: a keyring holding only GitHub's
#    published web-flow keys verifies the commit object, fetched without trees or blobs so nothing
#    is checked out. verify-commit also accepts a key that has since expired (EXPKEYSIG), so the
#    gpg status must be GOODSIG. That rejects the web-flow key retired on 2024-01-16, which signs
#    nothing new, along with any merge commit made before then.
GNUPGHOME=$(mktemp -d) gitdir=$(mktemp -d)
export GNUPGHOME
curl -fsSL https://github.com/web-flow.gpg | gpg --batch --quiet --import \
  || fail "Could not import GitHub's web-flow signing key."
git init -q "$gitdir"
git -C "$gitdir" fetch -q --depth=1 --filter=tree:0 --no-tags "$GITHUB_SERVER_URL/$repo" "$sha" \
  || fail "Could not fetch $sha."
sig=$(git -C "$gitdir" verify-commit --raw "$sha" 2>&1) || fail "$sha does not carry a valid web-flow signature."
grep -q '^\[GNUPG:\] GOODSIG ' <<<"$sig" || fail "$sha is not signed with GitHub's current web-flow key."

# 8. Approved by someone other than the author. As on GitHub, each reviewer's latest approving,
#    change-requesting or dismissed review is their verdict; comments don't change it.
approvals=$(gh api --paginate "repos/$repo/pulls/$number/reviews?per_page=100" \
  | jq -s --arg a "$author" '[add // [] | .[]
      | select(.user.login != $a and (.state | IN("APPROVED", "CHANGES_REQUESTED", "DISMISSED")))]
    | group_by(.user.login) | map(max_by(.submitted_at) | select(.state == "APPROVED")) | length')
(( approvals > 0 )) || fail "PR #$number has no approval from anyone but $author."

# Steps 9 and 10 judge the PR head's check runs and commit statuses. As on GitHub, only the
# newest result of each counts, so a re-run that passed replaces an earlier failure. Check run ids
# increase as runs are created, and a queued run has an id before it has any timestamps.
# filter=all lists every run, because the API's default (latest) picks by completed_at and can
# hide a newer run that hasn't finished. The combined status endpoint already returns only the
# newest status of each context. A check run passes when it succeeded, was skipped or was neutral;
# one still running has no conclusion and fails.
runs=$(gh api --paginate "repos/$repo/commits/$head/check-runs?per_page=100&filter=all" \
  | jq -s -c '[.[].check_runs[]
               | {name, app: .app.id, id, pass: (.conclusion | IN("success", "skipped", "neutral"))}]')
statuses=$(gh api --paginate "repos/$repo/commits/$head/status?per_page=100" \
  | jq -s -c '[.[].statuses[] | {name: .context, pass: (.state == "success")}]')

# 9. At least one check run, from any app, ran on the PR head, and the newest run of every check
#    passed, whether or not a ruleset requires it. Each app's checks are judged separately, so one
#    app's passing run can't hide another app's failing run of the same name.
latest=$(jq -c 'group_by([.app, .name]) | map(max_by(.id))' <<<"$runs")
[[ $latest != '[]' ]] || fail "No check runs ran on PR #$number."
failed=$(jq -r '[.[] | select(.pass | not) | .name | @json] | unique | join(", ")' <<<"$latest")
[[ -z $failed ]] || fail "Check runs did not pass on PR #$number: $failed."

# 10. The branch's rulesets require at least one status check, and each one passed on the PR head,
#     judged as GitHub judges a merge. A requirement limited to an app (integration_id) counts
#     only that app's check runs. One without counts check runs from every app and commit
#     statuses of that name. Commit statuses don't say which app set them, so they never satisfy
#     a requirement limited to an app. The newest result from each app, and the newest status,
#     must all pass, and there must be at least one.
required=$(gh api --paginate "repos/$repo/rules/branches/$base?per_page=100" \
  | jq -s -c '[add // [] | .[] | select(.type == "required_status_checks")
               | .parameters.required_status_checks[] | {context, app: .integration_id}] | unique')
[[ $required != '[]' ]] || fail "No ruleset on $base requires a status check."
failed=$(jq -n -r --argjson required "$required" --argjson runs "$runs" --argjson statuses "$statuses" '
  [$required[] | . as $req
   | ([$runs[] | select(.name == $req.context and ($req.app == null or .app == $req.app))]
      | group_by(.app) | map(max_by(.id) | .pass))
     + (if $req.app == null then [$statuses[] | select(.name == $req.context) | .pass] else [] end)
   | select(length == 0 or (all | not))
   | ($req.context | @json) + (if $req.app == null then "" else " from app \($req.app)" end)]
  | join(", ")')
[[ -z $failed ]] || fail "Required checks did not pass on PR #$number: $failed."

echo "PR #$number by $author into $base, merged as $sha: $name@$version (publish=$publish, types=$publish_types)"
