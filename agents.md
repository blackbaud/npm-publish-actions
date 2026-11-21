# AGENT.md

This file provides guidance to agents when working with code in this repository.

## What this repo is

Shared composite GitHub Actions that let repos in the `blackbaud` GitHub org publish public packages to npmjs.org (`~blackbaud`) using [npm trusted publishing](https://docs.npmjs.com/trusted-publishers) (OIDC, no npm tokens). Consumer repos call them from a `.github/workflows/npm-publish.yml` workflow triggered by a `*.*.*` tag push. The consumer workflow template is `.agents/skills/release/npm-publish.yml`. The `release` skill publishes it in each release's notes with every `uses:` pinned to that release's commit SHA, and consumers copy it from there. A change to inputs, outputs or behavior reaches a consumer only when they move to a release that contains it. When a change alters the actions' inputs, outputs or required job permissions, update the template in the same change.

The actions port the npm steps of Blackbaud's ADO `npm-package-oss` pipeline template to GitHub. Comments that say "template:" or "Template ..." name the template step being reproduced. Keep that parity unless a change is deliberate.

## Architecture: three actions, three trust levels

The design separates what each job can see from what each job runs. Most constraints follow from this split:

| Action | Runs repo code? | Has `id-token: write`? | Role |
|---|---|---|---|
| `verify/` | Never. GitHub API calls (`gh api`, `jq`), plus a tree-less fetch of the tagged commit object for `git verify-commit` | No | Gate: decides whether to publish |
| `build/` | Yes (`npm ci`, lint, test, build, pack lifecycle scripts) | **Must not** | Produces the tarballs |
| `publish/` | No. No checkout, no install, `--ignore-scripts` | Yes | Uploads the tarballs to npm |

- **Do not** add a checkout, an install, or anything that runs package scripts to `publish/`. **Do not** give `build/` access to OIDC. `publish.sh` refuses to run without `ACTIONS_ID_TOKEN_REQUEST_URL`.
- Composite actions can't set job `permissions` or `environment`. Those belong in the consumer workflow, and the publish job's environment must be `npm-publish` to match each package's npm trusted publisher. npm also matches the workflow filename (`npm-publish.yml`).
- Data flow: `verify` outputs `name`, `version`, `publish`, `publish-types` and `node-version` → `build` sets up that Node and packs `dist/` (when `publish` is true) and/or `dist-types/` (when `publish-types` is true), then uploads the `npm-packages` artifact → `publish` downloads that artifact, checks the tarballs against verify's outputs, and publishes them.

### verify (`verify/verify.sh`)
Reads `package.json` at the tag's SHA through the contents API. It then checks that the tag equals the version, and, when something will publish, that the package isn't `@blackbaud-internal/*` and that no dependency points at `@blackbaud-internal` by name or `npm:` alias. A `.nvmrc`, when present, must be `22`, `24` or an exact version that satisfies `^22.23.5 || ^24.22.3`. Aliases such as `lts/*` are rejected. The approved version (22 without `.nvmrc`) becomes the `node-version` output. The `pipelineSettings.publishToNPM` and `pipelineSettings.publishTypesToNPM` flags (both default to false) decide what gets published. It also requires the tagged commit to be:
- the merge commit of exactly one PR into the default branch or a `<major>.x.x` branch
- still on that branch
- signed by GitHub (`web-flow`), which rules out rebase merges. The API's verification must say so, and `git verify-commit` must also accept the commit object using a fresh keyring holding only the keys from `https://github.com/web-flow.gpg`. The fetch has `--depth=1 --filter=tree:0`, so nothing is checked out. It authenticates with the `github-token` input so it works on private repos. The token reaches git as an auth header through `GIT_CONFIG_*` environment variables, limited to `GITHUB_SERVER_URL`, so it never appears in a command line or a config file. The encoded header is masked in the logs. git accepts a good signature from a key that has since expired, so gpg's status must also be `GOODSIG`. That rejects the web-flow key retired on 2024-01-16 and any merge commit made before then.
- approved by someone other than the PR author, whose latest verdict is an approval of the PR head commit
- green on every check run: at least one check run from any app ran on the PR head, and the newest run of every check (grouped by app and name) passed, required or not
- green on every required check from the branch's **rulesets**, judged as GitHub judges a merge. Only rulesets count; classic branch protection is ignored. The job fails if the rulesets require no status checks at all. A requirement with an `integration_id` counts only that app's check runs. One without counts check runs from every app and commit statuses of that name. The newest result from each app, and the newest status, must all pass, and there must be at least one.

GitHub API list calls use `gh api --paginate` piped to `jq -s`, because every page comes back as its own JSON document.

When neither flag is true, it exits 0 and downstream jobs skip.

### build (`build/`)
Node is verify's `node-version` output. The build never reads `.nvmrc` itself, so setup-node can't parse it differently from verify. setup-node runs with `check-latest`, so a bare major resolves to its newest release rather than the runner's cached one. A `package-lock.json` is required. Then `npm ci --legacy-peer-deps`, `lint --if-present`, `test:ci` (or `test`), `build`, followed by the helper scripts:
- `prepare-package.sh` copies the root `package.json`, `README.md` and `CHANGELOG.md` into `dist/`.
- `prepare-types.sh` names the `dist-types/` package `<name>-types` at the same version.
- `pack.sh` runs `npm pack` inside each folder and checks that the packed manifest's name and version match and that the package isn't private.

### publish (`publish/`)
Node 24 and the npm it bundles, so nothing is installed. Trusted publishing needs npm ≥ 11.5.1, which Node 24 bundles from 24.5.0 on, and `publish.sh` fails on anything older. It takes verify's `name`, `version`, `publish` and `publish-types` as inputs and trusts nothing the build job wrote except the tarball contents. `read-manifest.js` parses each tarball with npm's bundled tar. Every entry must be a canonical `package/<path>`, and exactly one regular file may land on `package.json`. The package identity comes from that manifest. Each approved package (`<name>@<version>`, `<name>-types@<version>`) needs exactly one tarball, and any other tarball fails the job. Every npm call in `publish.sh` passes `--registry https://registry.npmjs.org/`. Scoped registries can outrank that flag, so the job fails if the npm config names another registry. `npm publish` applies any setting in a tarball's `publishConfig` that the command line doesn't set, including to the OIDC token exchange, so a proxy, CA or `strict-ssl` setting there could leak the publish token. Only `access`, `provenance`, `registry` and `tag` are allowed, because the publish command sets each of them itself. Each manifest's dependencies get the same `@blackbaud-internal` check as verify's, because the build writes `dist-types/package.json`. A top-level `tag` in a manifest replaces `--tag`, so it must equal the chosen dist-tag. All of these checks run for every package before anything publishes. The consumer workflow template serializes publish jobs per repo, so concurrent tags can't race on the versions `dist-tag.js` reads. Re-runs are safe: when a version is already on npm with the same `sha512` integrity, it is skipped, and different contents fail the job. The package must already exist on npm, because trusted publishing can't create it. `dist-tag.js` picks the tag using the semver copy bundled with npm, so nothing extra is installed:
- prerelease → `next`
- `-trust.N` prerelease → `trust-check`
- highest stable version → `latest`
- older stable version that is the highest in its major → `lts-v<major>`
- stable version below the highest already published in its major → fails, so no tag moves backwards

## Conventions

- Logic goes in the per-action `.sh`/`.js` files, which `action.yml` calls as `bash "$GITHUB_ACTION_PATH/<script>"`. The exception is a `run:` block of at most two lines, which can stay inline. Inputs reach scripts as `env:` variables. Never interpolate `${{ }}` into `run:` blocks. Each script lists the environment variables it reads in its header comment.
- Scripts use `set -euo pipefail`, a `fail()` helper that prints `::error::`, and `jq` for all JSON handling.
- Scripts target the `ubuntu-24.04` runner, so GNU tool flags such as `base64 -w0` appear. They won't run unchanged on macOS.
- Every `uses:` pins a full commit SHA followed by a `# vX.Y.Z` comment naming the release it points to. Consumers can't pin the actions these composite actions call, and zizmor fails on tag refs.

## Verification

`.github/workflows/ci.yml` runs on every pull request: `shellcheck` on every `*.sh`, `actionlint` on workflows, `zizmor` on workflows and every `action.yml`, and `node --check` on every `*.js`. The linter images are pinned in that file's `env:`. Run the same tools locally when they're installed. `actionlint` lints workflow files only and reports false errors on `action.yml` metadata, which is why zizmor covers the actions. End-to-end behavior can only be checked by tagging a release in a consumer repo; a `-trust.N` prerelease version publishes under the `trust-check` dist-tag for that kind of validation.
