# codex-flake

Nix flake packaging the latest released OpenAI Codex CLI from
<https://github.com/openai/codex>, built from the release source tag.

The `nixpkgs` input is pinned directly to the same revision used by
`github:conroy-cheers/system-config`, without adding system-config as a flake
input.

## Usage

```sh
nix build
nix run
```

## Updating

```sh
./scripts/update.sh
```

The updater reads GitHub's latest Codex release, rewrites `versions.json` with
the source and Cargo hashes, and refreshes the direct `nixpkgs` pin to match
`github:conroy-cheers/system-config`.

## Automation

The GitHub Actions workflow in `.github/workflows/update.yml` runs every 10
minutes and on manual dispatch. It runs the updater, validates changed inputs
with `nix flake check --no-build`, builds and checks the installed Codex version,
and commits only when the generated package inputs changed.

The workflow limits Nix to one build at a time and one Cargo job, adds 8 GiB of
swap, and logs memory usage during validation. Its source build overrides the
release profile to disable LTO and debug information. These overrides apply
only to the workflow build; normal flake builds retain the upstream release
profile. CI evaluates the normal checks but runs the version check against
the overridden binary.

Hydra builds the explicit `hydraJobs.<system>.codex` jobs for each supported
platform. These point directly to the normal Codex packages; the version checks
remain available through `nix flake check`.
