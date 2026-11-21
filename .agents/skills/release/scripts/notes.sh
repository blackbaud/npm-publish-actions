#!/usr/bin/env bash
# Prints the full release notes: the change summary, a changelog link, and the consumer
# workflow template read from the release commit with every `uses:` pinned to that commit.
#
# Usage: bash notes.sh <preflight-output> <summary.md>
#   <preflight-output>  the key=value lines preflight.sh printed (repo, tag, sha, previous)
#   <summary.md>        the change summary, written for this release
# Runs on macOS and Linux, so it sticks to POSIX tool flags.
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

template_path=.agents/skills/release/npm-publish.yml
action_ref=blackbaud/npm-publish-actions/

[[ $# -eq 2 ]] || fail "usage: notes.sh <preflight-output> <summary.md>"
[[ -s $2 ]] || fail "summary file $2 is missing or empty"
# The work directory outlives a release, so a summary older than this preflight run is stale.
[[ $2 -nt $1 ]] || fail "summary file $2 is older than $1. Write the summary for this release."

repo='' tag='' sha='' previous=''
while IFS='=' read -r key value; do
  case $key in
    repo) repo=$value ;;
    tag) tag=$value ;;
    sha) sha=$value ;;
    previous) previous=$value ;;
  esac
done <"$1"
[[ -n $repo && -n $tag ]] || fail "$1 has no repo or tag line"
[[ $sha =~ ^[0-9a-f]{40}$ ]] || fail "$1 has no full commit SHA"
[[ $(git rev-parse --verify --quiet "$sha^{commit}") == "$sha" ]] || fail "$sha isn't a commit in this clone"

# Command substitution drops the template's trailing newlines, so the code block ends cleanly.
workflow=$(git show "$sha:$template_path")
workflow=${workflow//RELEASE_SHA/$sha}
workflow=${workflow//RELEASE_TAG/$tag}

grep -q 'RELEASE_' <<<"$workflow" && fail "$template_path has a placeholder other than RELEASE_SHA and RELEASE_TAG"
uses=$(grep -c "uses: $action_ref" <<<"$workflow" || true)
pinned=$(grep -c "uses: ${action_ref}[a-z-]*@$sha # $tag\$" <<<"$workflow" || true)
[[ $uses -gt 0 && $uses == "$pinned" ]] ||
  fail "$pinned of $uses uses: lines in $template_path are pinned to $sha # $tag"

if [[ -n $previous ]]; then
  changelog="https://github.com/$repo/compare/$previous...$tag"
else
  changelog="https://github.com/$repo/commits/$tag"
fi

cat "$2"
cat <<EOF

**Full changelog**: $changelog

## Using this release

Copy the workflow below to \`.github/workflows/npm-publish.yml\` in your repo. Keep the file name and every \`uses:\` line exactly as shown: npm trusted publishing matches the file name, and each \`uses:\` pins this release's commit. The [README](https://github.com/$repo#setting-up-a-consumer-repo) has the rest of the setup.

<details>
<summary><code>.github/workflows/npm-publish.yml</code> for $tag</summary>

\`\`\`yaml
$workflow
\`\`\`

</details>
EOF
