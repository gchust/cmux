# Fork maintenance

This fork keeps two long-lived branches:

- `main`: upstream mirror branch
- `custom/main`: fork default branch for local work and releases

## Why `main` stays a mirror

`main` is reserved for upstream sync. It should stay as close as possible to `manaflow-ai/cmux:main` so upstream updates remain easy to reason about and easy to merge.

Do not put fork-only feature work on `main`.

## Why `custom/main` is the default branch

All fork-only changes live on `custom/main` or short-lived branches cut from it.

That keeps upstream sync separate from local customizations and makes release automation predictable:

- upstream sync lands in `main`
- a sync PR flows from `main` into `custom/main`
- merge commits into `custom/main` are the fork release points

## How upstream sync works

Fork automation uses `.github/workflows/upstream-release-sync.yml`.

The workflow:

1. fetches `manaflow-ai/cmux:main`
2. fast-forwards fork `main`
3. mirrors the latest upstream stable release tag into the fork
4. creates or updates a PR from `main` to `custom/main`
5. merges that PR automatically when GitHub reports a clean merge state

If GitHub reports conflicts or a blocked merge state, the PR is left open for manual resolution.

## How fork releases work

Fork automation uses `.github/workflows/release-on-custom-merge.yml`.

The workflow runs after pushes to `custom/main` and on manual `workflow_dispatch`.

Default behavior:

- push to `custom/main`: publish a fork release
- manual dispatch: build a dry-run artifact unless `publish=true`

Each fork release:

- resolves the latest upstream stable tag as the base version
- computes the next fork tag as `vX.Y.Z-fork.N`
- rebuilds from `custom/main`
- publishes a GitHub release from the fork tag

Release metadata always records both:

- upstream base tag
- fork tag

## Default platform matrix

This fork follows the resource-saving default:

- build `macOS`
- do not build Windows or Linux GUI artifacts
- do not add Android unless the upstream repo clearly supports Android

For `cmux`, upstream release assets and repository structure currently indicate a macOS-only desktop app, so the fork release workflow also stays macOS-only.

Remote daemon assets remain aligned with upstream naming:

- `cmuxd-remote-darwin-arm64`
- `cmuxd-remote-darwin-amd64`
- `cmuxd-remote-linux-arm64`
- `cmuxd-remote-linux-amd64`

## Signing and fallback behavior

If the fork has Apple signing and notarization secrets, releases are signed and notarized.

If those secrets are missing, the workflow degrades cleanly:

- the app still builds
- an unsigned `cmux-macos.dmg` is produced
- GitHub release publishing still works

If a Sparkle private key exists, the workflow also generates `appcast.xml`.

## Contributor workflow

When changing fork-specific behavior:

1. branch from `custom/main`
2. open a PR into `custom/main`
3. merge the PR
4. let `release-on-custom-merge.yml` publish the next fork release

When resolving upstream conflicts:

1. inspect the sync PR from `main` to `custom/main`
2. fix conflicts on a temporary branch off `custom/main`
3. merge back into `custom/main`
