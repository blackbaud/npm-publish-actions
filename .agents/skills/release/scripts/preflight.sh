#!/usr/bin/env bash
# Checks that a version can be released from the tip of the default branch and prints
# the facts the release notes need, as key=value lines: repo, tag, sha, previous.
# `previous` is empty for the first release.
#
# Usage: bash preflight.sh <version>      (1.2.0 or v1.2.0)
# Reads: the `origin` git remote, and the GitHub repo that `gh` resolves from it.
# Runs on macOS and Linux, so it sticks to POSIX tool flags.
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

template_path=.agents/skills/release/npm-publish.yml

[[ $# -eq 1 ]] || fail "usage: preflight.sh <version>"
version=${1#v}
semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ $version =~ $semver ]] ||
  fail "'$1' isn't a release version. Use MAJOR.MINOR.PATCH, such as 1.2.0, with no prerelease or build suffix."
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
tag=v$version

repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
branch=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)

# The release commit is the default branch's tip on origin, never the local checkout.
git fetch --quiet --no-tags origin "+refs/heads/$branch:refs/remotes/origin/$branch"
sha=$(git rev-parse --verify "refs/remotes/origin/$branch^{commit}")

remote_tags=$(git ls-remote --tags --refs origin)
if grep -q "[[:space:]]refs/tags/$tag\$" <<<"$remote_tags"; then
  fail "tag $tag already exists on origin"
fi
if gh release view "$tag" >/dev/null 2>&1; then
  fail "a release named $tag already exists"
fi
drafts=$(gh release list --limit 100 --json tagName,isDraft --jq '.[] | select(.isDraft) | .tagName')
if [[ -n $drafts ]]; then
  fail "unpublished draft releases exist (${drafts//$'\n'/, }). Publish or delete them first, so the previous release is unambiguous."
fi

# The previous release is the highest vMAJOR.MINOR.PATCH tag on origin.
previous=$(sed -n 's#.*[[:space:]]refs/tags/v\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\)$#\1 \2 \3#p' <<<"$remote_tags" |
  sort -n -k1,1 -k2,2 -k3,3 | tail -n 1)

if [[ -n $previous ]]; then
  read -r pmajor pminor ppatch <<<"$previous"
  previous=v$pmajor.$pminor.$ppatch
  next_patch=$pmajor.$pminor.$((ppatch + 1))
  next_minor=$pmajor.$((pminor + 1)).0
  next_major=$((pmajor + 1)).0.0
  case $version in
    "$next_patch" | "$next_minor" | "$next_major") ;;
    *) fail "$tag doesn't follow $previous. The next version is $next_patch (patch), $next_minor (minor) or $next_major (major)." ;;
  esac
  git fetch --quiet --no-tags origin "refs/tags/$previous:refs/tags/$previous"
  git merge-base --is-ancestor "$previous^{commit}" "$sha" ||
    fail "$previous isn't an ancestor of $branch ($sha). The release would drop commits that $previous shipped."
elif [[ $patch != 0 || ($major == 0 && $minor == 0) ]]; then
  fail "the first release must be MAJOR.MINOR.0 with a non-zero MAJOR or MINOR, such as 1.0.0"
fi

package_version=$(git show "$sha:package.json" | jq -r .version)
[[ $package_version == "$version" ]] ||
  fail "package.json on $branch ($sha) has version $package_version, not $version. Merge a PR that sets it to $version first."

git cat-file -e "$sha:$template_path" 2>/dev/null ||
  fail "$branch ($sha) has no $template_path, so the release notes can't include the consumer workflow"

printf 'repo=%s\ntag=%s\nsha=%s\nprevious=%s\n' "$repo" "$tag" "$sha" "$previous"
