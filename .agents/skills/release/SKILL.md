---
name: release
description: Use when creating a new release of spm-publish-actions, such as when asked to release, cut or tag version X.Y.Z, or to draft its GitHub release notes.
argument-hint: <version>
disable-model-invocation: true
---

# Release spm-publish-actions

A release is a **draft** GitHub release `vX.Y.Z` targeting the commit at the tip of the default branch. Its notes are the only place consumers get the workflow. The notes carry `npm-publish.yml` with every `uses:` pinned to that commit's full SHA. No floating `v1` tag exists. The user reviews the draft and publishes it, and publishing creates the tag.

The version to release is `$ARGUMENTS`. If it's empty, ask the user for it.

## Steps

Run everything from the repo root. Call the scripts through `bash`. Work files live in the directory that `git rev-parse --git-path release` prints. Git ignores that directory, and it lasts between shells, so each command below finds it again.

1. **Preflight.** It checks the version and finds the release commit and the previous release:

   ```bash
   out=$(git rev-parse --git-path release) && mkdir -p "$out" &&
     bash .agents/skills/release/scripts/preflight.sh "<version>" > "$out/release.env" &&
     cat "$out/release.env"
   ```

   If it exits non-zero, stop and show the user the error. The fix belongs to the user, usually a merged PR or a different version, so don't work around it.

2. **Read what changed** between `previous` and `sha` from `release.env`. When `previous` is empty this is the first release: run only `git log --format='%h %s' <sha>`, read the actions as they are at `sha`, and skip step 3.

   ```bash
   git log --format='%h %s%n%n%b' <previous>..<sha>
   git diff --stat <previous> <sha>
   git diff <previous> <sha> -- '*/action.yml' .agents/skills/release/npm-publish.yml
   ```

   Read the diffs of the scripts behind each changed behavior. Commit subjects alone are not enough to describe the change.

3. **Check the version against the changes.** The template is the consumer contract. A change is breaking when either of these holds:
   - the template diff changes anything other than the `uses:` refs
   - an `action.yml` removes or renames an input or output that the template uses, or adds a required input

   If a change is breaking and the version isn't a major bump, stop and tell the user what breaks. Report every other change in the summary.

4. **Write the summary** to `summary.md` in the work directory. It contains exactly these parts, in order:
   1. `## What's changed`
   2. Only when consumers must edit their workflow beyond the SHA: a `> [!IMPORTANT]` callout naming each edit.
   3. One bullet per change a consumer could notice, led by the action in bold (`**verify:**`, `**build:**`, `**publish:**`) or `**repo:**` for CI and docs. Each bullet says what changed and what the consumer will see, for example a publish that used to pass and now fails. For the first release, the bullets describe what each action does.

   The script adds the changelog link and the workflow, so the summary ends after the bullets.

5. **Assemble the notes.** Don't edit the generated workflow by hand. If it's wrong, fix the template in a PR.

   ```bash
   out=$(git rev-parse --git-path release) &&
     bash .agents/skills/release/scripts/notes.sh "$out/release.env" "$out/summary.md" > "$out/notes.md"
   ```

6. **Create the draft:**

   ```bash
   out=$(git rev-parse --git-path release) &&
     gh release create <tag> --draft --target <sha> --title <tag> --notes-file "$out/notes.md"
   ```

   Give the user the draft's URL. It contains `untagged-` until the user publishes it. Tell the user to review the draft and publish it on GitHub.

## Boundaries

| Never | Because |
|---|---|
| `git tag` or `git push` a tag | Publishing the draft creates the tag at `--target`. A pushed tag goes public before anyone has reviewed it. |
| Omit `--draft`, or publish or edit the draft yourself | The user reviews and publishes. |
| Create or move a `v1`-style tag | Consumers pin full SHAs from the notes. A movable tag would undo that. |
| Copy the workflow from README.md or the working tree | The notes must show the template as it exists at the release commit, and `notes.sh` reads it from there. |
| Edit `package.json`, delete drafts or pick another version to get past preflight | Those are the user's decisions. Report the error. |

These rules hold even when the user has said to "handle whatever comes up". That instruction doesn't authorize tags, publishing or version changes.

## Maintaining the template

`npm-publish.yml` in this directory is the consumer workflow. `RELEASE_SHA` and `RELEASE_TAG` mark the version on each `uses:` line of this repo's actions. A change to an action's inputs, outputs or required job permissions must update the template in the same PR.
