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
with `nix flake check`, and commits only when the generated package inputs
changed.
