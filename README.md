# NPM Publish Actions

Shared GitHub Actions for publishing npm packages to https://www.npmjs.com/~blackbaud. These actions are used by the `npm-publish` workflow in consumer repos.

## Setting up a consumer repo

You'll need to work with the SKY UX team to set up the `npm-publish` workflow in your repo.

1. Open the [latest release](https://github.com/blackbaud/npm-publish-actions/releases/latest). Every release is listed on the [releases page](https://github.com/blackbaud/npm-publish-actions/releases).
2. Expand **`.github/workflows/npm-publish.yml`** in the release notes and copy the workflow into your repo at that exact path. npm trusted publishing matches the filename, so don't rename it.
3. Keep each `uses:` line exactly as copied. It pins the release's full commit SHA, so the code it runs can't change after review. Don't replace the SHA with a tag or branch name.
4. Add the workflow to `.github/CODEOWNERS` so every change to it needs approval from the SKY UX services team:

```text
# Shared npm publish actions. Every change needs approval from this team.
.github/workflows/npm-publish.yml @blackbaud/skyux-maintainers
```

## Package requirements

The workflow fails unless all of these are true.

- `package.json` sets at least one of these flags. Both default to `false`.
  - `pipelineSettings.publishToNPM: true` publishes `dist/` as `<name>`.
  - `pipelineSettings.publishTypesToNPM: true` publishes `dist-types/` as `<name>-types`.
- The package name isn't `@blackbaud-internal/*`, and no dependency points at `@blackbaud-internal`, by name or through an `npm:` alias.
- `repository.url` in `package.json` names the repo on GitHub. npm requires an exact match.
- `publishConfig`, if present, contains only `access`, `provenance`, `registry` or `tag`.
- `package-lock.json`, `README.md` and `CHANGELOG.md` are committed at the repo root.
- `package.json` has a `build` script and either a `test:ci` or a `test` script. A `lint` script is optional.
- `.nvmrc` is absent, which builds with Node 22, or contains `22`, `24` or an exact version that satisfies `^22.23.5 || ^24.22.3`. Aliases such as `lts/*` fail.
- Azure Pipelines runs on the repo's PRs. Publishing requires at least one Azure Pipelines check on the PR, and all of them must pass.
- The repo's Azure pipeline uses version 1.33 or later of the `npm-package-oss` template. Those versions skip their npm publish steps when `.github/workflows/npm-publish.yml` exists.

## Troubleshooting

| Error mentions | Fix |
|---|---|
| Tag does not match the `package.json` version | Tag the version exactly as `package.json` spells it, without a `v` prefix. |
| Not the merge commit of a PR | Tag the commit that GitHub created when it merged the version PR, not a later commit. |
| Not created and signed by GitHub | The PR was rebase-merged. Merge or squash a new version PR. |
| No approval of its head commit from anyone but the author | Someone other than the PR author must approve the PR's last commit. An approval of an earlier commit doesn't count. |
| No ruleset requires a status check | Ask SKY UX to fix the ruleset. |
| `publish` job waits and never starts | A release approver other than the person who pushed the tag must approve the deployment to `npm-publish`. |
| `ENEEDAUTH` or another npm authentication error | The trusted publisher configuration is missing, wrong, expired or doesn't allow `npm publish`. Ask SKY UX to fix it. |
| Can't take `latest` or `lts-v<major>` | A higher version in the same major is already on npm. Release a version above it instead. |
| Must already exist there before trusted publishing | The package isn't on npm yet. Ask SKY UX to create it. |

To retry a failed publish, re-run the failed jobs. A version that's already on npm with the same contents is skipped.

## Upgrading

To move to a newer release, replace your `.github/workflows/npm-publish.yml` with the workflow from that release's notes. Don't just swap the SHA, because a release can also change job permissions, inputs or outputs. The release notes summarize what changed.
