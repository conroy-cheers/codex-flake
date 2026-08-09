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

v8_package_script="$source_path/scripts/codex_package/v8.py"
if [ ! -f "$v8_package_script" ]; then
  echo "could not find Codex V8 package metadata: $v8_package_script" >&2
  exit 1
fi

v8_profile="$(
  awk -F'"' '
    $1 == "V8_ARTIFACT_PROFILE = " {
      print $2
      exit
    }
  ' "$v8_package_script"
)"
if [ -z "$v8_profile" ]; then
  if awk '/librusty_v8_release_/ { found = 1 } END { exit !found }' "$v8_package_script"; then
    v8_profile="release"
  else
    echo "could not determine Codex rusty_v8 artifact profile" >&2
    exit 1
  fi
fi

case "$v8_profile" in
  "" | *[!a-z0-9_]*)
    echo "invalid Codex rusty_v8 artifact profile: $v8_profile" >&2
    exit 1
    ;;
esac

printf '{}\n' > "$rusty_v8_json"

add_rusty_v8_platform() {
  local system="$1"
  local triple="$2"
  local release_url archive_name binding_name checksums_name checksums_file
  local archive_url archive_sha archive_hash binding_url binding_sha binding_hash
  local next_json

  release_url="https://github.com/openai/codex/releases/download/rusty-v8-v$v8_version"
  archive_name="librusty_v8_${v8_profile}_${triple}.a.gz"
  binding_name="src_binding_${v8_profile}_${triple}.rs"
  checksums_name="rusty_v8_${v8_profile}_${triple}.sha256"
  checksums_file="$tmpdir/rusty-v8-$system.sha256"

  curl -fsSL "$release_url/$checksums_name" > "$checksums_file"
  if ! awk -v archive="$archive_name" -v binding="$binding_name" '
    NF == 0 { next }
    NF != 2 { invalid = 1; next }
    $2 == archive { archives++ ; next }
    $2 == binding { bindings++ ; next }
    { invalid = 1 }
    END { exit !(invalid == 0 && archives == 1 && bindings == 1) }
  ' "$checksums_file"; then
    echo "invalid Codex rusty_v8 checksum manifest: $checksums_name" >&2
    exit 1
  fi

  archive_sha="$(awk -v name="$archive_name" '$2 == name { print $1 }' "$checksums_file")"
  binding_sha="$(awk -v name="$binding_name" '$2 == name { print $1 }' "$checksums_file")"
  if ! [[ "$archive_sha" =~ ^[0-9a-f]{64}$ && "$binding_sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "invalid Codex rusty_v8 checksums for $triple" >&2
    exit 1
  fi

  archive_url="$release_url/$archive_name"
  binding_url="$release_url/$binding_name"
  archive_hash="$(nix hash convert --hash-algo sha256 --to sri "$archive_sha")"
  binding_hash="$(nix hash convert --hash-algo sha256 --to sri "$binding_sha")"
  next_json="$tmpdir/rusty-v8-$system.json"

  jq \
    --arg system "$system" \
    --arg archiveUrl "$archive_url" \
    --arg archiveHash "$archive_hash" \
    --arg bindingUrl "$binding_url" \
    --arg bindingHash "$binding_hash" \
    '. + {
      ($system): {
        archive: {url: $archiveUrl, hash: $archiveHash},
        binding: {url: $bindingUrl, hash: $bindingHash}
      }
    }' \
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
  --arg v8Profile "$v8_profile" \
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
      profile: $v8Profile,
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
echo "Pinned rusty_v8 $v8_version ($v8_profile)"
echo "Pinned Cargo hash $cargo_hash"
echo "Pinned nixpkgs to $nixpkgs_url"
