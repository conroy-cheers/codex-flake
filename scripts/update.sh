#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

for cmd in awk curl jq nix; do
  require "$cmd"
done

tmpdir="$(mktemp -d)"
for file in versions.json flake.nix flake.lock; do
  if [ -f "$file" ]; then
    cp "$file" "$tmpdir/$file.backup"
  fi
done

cleanup() {
  local status=$?

  if [ "$status" -ne 0 ]; then
    for file in versions.json flake.nix flake.lock; do
      if [ -f "$tmpdir/$file.backup" ]; then
        cp "$tmpdir/$file.backup" "$file"
      else
        rm -f "$file"
      fi
    done
  fi

  rm -rf "$tmpdir"
  exit "$status"
}

trap cleanup EXIT

release_json="$tmpdir/codex-release.json"
versions_json="$tmpdir/versions.json"
flake_nix="$tmpdir/flake.nix"
rusty_v8_json="$tmpdir/rusty-v8.json"

curl -fsSL "https://api.github.com/repos/openai/codex/releases/latest" > "$release_json"

tag_name="$(jq -r '.tag_name' "$release_json")"
version="${tag_name#rust-v}"
published_at="$(jq -r '.published_at' "$release_json")"

if [ "$(jq -r '.draft' "$release_json")" != "false" ]; then
  echo "latest Codex release is still a draft: $tag_name" >&2
  exit 1
fi

if [ "$(jq -r '.prerelease' "$release_json")" != "false" ]; then
  echo "latest Codex release is a prerelease: $tag_name" >&2
  exit 1
fi

ref_json="$tmpdir/tag-ref.json"
curl -fsSL "https://api.github.com/repos/openai/codex/git/ref/tags/$tag_name" > "$ref_json"
rev="$(jq -r '.object.sha' "$ref_json")"
if [ "$(jq -r '.object.type' "$ref_json")" = "tag" ]; then
  tag_json="$tmpdir/tag-object.json"
  curl -fsSL "$(jq -r '.object.url' "$ref_json")" > "$tag_json"
  rev="$(jq -r '.object.sha' "$tag_json")"
fi

source_prefetch="$(
  nix store prefetch-file --json --unpack \
    "https://github.com/openai/codex/archive/$tag_name.tar.gz"
)"
source_hash="$(jq -r '.hash' <<< "$source_prefetch")"
source_path="$(jq -r '.storePath' <<< "$source_prefetch")"
v8_version="$(
  awk '
    $0 == "name = \"v8\"" { in_v8 = 1; next }
    in_v8 && $1 == "version" {
      gsub(/"/, "", $3)
      print $3
      exit
    }
  ' "$source_path/codex-rs/Cargo.lock"
)"

if [ -z "$v8_version" ]; then
  echo "could not determine rusty_v8 version from Cargo.lock" >&2
  exit 1
fi

printf '{}\n' > "$rusty_v8_json"

add_rusty_v8_platform() {
  local system="$1"
  local triple="$2"
  local url hash next_json

  url="https://github.com/denoland/rusty_v8/releases/download/v$v8_version/librusty_v8_release_$triple.a.gz"
  hash="$(nix store prefetch-file --json "$url" | jq -r '.hash')"
  next_json="$tmpdir/rusty-v8-$system.json"

  jq \
    --arg system "$system" \
    --arg url "$url" \
    --arg hash "$hash" \
    '. + {($system): {url: $url, hash: $hash}}' \
    "$rusty_v8_json" > "$next_json"
  mv "$next_json" "$rusty_v8_json"
}

add_rusty_v8_platform "x86_64-linux" "x86_64-unknown-linux-gnu"
add_rusty_v8_platform "aarch64-linux" "aarch64-unknown-linux-gnu"
add_rusty_v8_platform "x86_64-darwin" "x86_64-apple-darwin"
add_rusty_v8_platform "aarch64-darwin" "aarch64-apple-darwin"

jq -n \
  --arg version "$version" \
  --arg tagName "$tag_name" \
  --arg publishedAt "$published_at" \
  --arg rev "$rev" \
  --arg sourceHash "$source_hash" \
  --arg v8Version "$v8_version" \
  --slurpfile rustyV8Platforms "$rusty_v8_json" \
  --arg cargoHash "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" \
  '{
    version: $version,
    tagName: $tagName,
    publishedAt: $publishedAt,
    rev: $rev,
    source: {
      hash: $sourceHash
    },
    rustyV8: {
      version: $v8Version,
      platforms: $rustyV8Platforms[0]
    },
    cargoHash: $cargoHash
  }' > "$versions_json"

mv "$versions_json" versions.json

nixpkgs_locked="$(
  nix flake metadata --json "github:conroy-cheers/system-config" \
    | jq -r '.locks.nodes[.locks.nodes.root.inputs.nixpkgs].locked'
)"
nixpkgs_owner="$(jq -r '.owner' <<< "$nixpkgs_locked")"
nixpkgs_repo="$(jq -r '.repo' <<< "$nixpkgs_locked")"
nixpkgs_rev="$(jq -r '.rev' <<< "$nixpkgs_locked")"
nixpkgs_url="github:${nixpkgs_owner}/${nixpkgs_repo}/${nixpkgs_rev}"

awk -v url="$nixpkgs_url" '
  /nixpkgs\.url = "github:/ {
    print "    nixpkgs.url = \"" url "\";"
    next
  }
  { print }
' flake.nix > "$flake_nix"
mv "$flake_nix" flake.nix

nix flake lock

set +e
build_output="$(nix build .#codex --no-link --print-build-logs 2>&1)"
build_status=$?
set -e

cargo_hash="$(printf '%s\n' "$build_output" | sed -n 's/.*got:[[:space:]]*\(sha256-[^[:space:]]*\).*/\1/p' | tail -n 1)"
if [ -z "$cargo_hash" ]; then
  printf '%s\n' "$build_output" >&2
  if [ "$build_status" -eq 0 ]; then
    echo "Codex build unexpectedly succeeded with the fake Cargo hash" >&2
  else
    echo "could not determine Cargo hash from Nix output" >&2
  fi
  exit 1
fi

jq --arg cargoHash "$cargo_hash" '.cargoHash = $cargoHash' versions.json > "$versions_json"
mv "$versions_json" versions.json

echo "Updated Codex to $version ($tag_name)"
echo "Pinned source rev $rev"
echo "Pinned rusty_v8 $v8_version"
echo "Pinned Cargo hash $cargo_hash"
echo "Pinned nixpkgs to $nixpkgs_url"
