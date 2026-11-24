{
  apple-sdk,
  fetchFromGitHub,
  fetchurl,
  lib,
  libcap,
  openssl,
  pkg-config,
  python3,
  ripgrep,
  rustPlatform,
  stdenv,
}:

let
  release = builtins.fromJSON (builtins.readFile ./versions.json);
  system = stdenv.hostPlatform.system;
  cargoBuildFlags =
    [
      "-p"
      "codex-cli"
      "-p"
      "codex-code-mode-host"
      "-p"
      "codex-exec-server-cli"
      "--bin"
      "codex"
      "--bin"
      "codex-code-mode-host"
      "--bin"
      "codex-exec-server"
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      "-p"
      "codex-bwrap"
      "--bin"
      "bwrap"
    ];
  rustyV8Artifacts =
    release.rustyV8.platforms.${system}
      or (throw "rusty_v8 artifacts are not packaged for ${system}");
in
rustPlatform.buildRustPackage {
  pname = "codex";
  version = release.version;

  src = fetchFromGitHub {
    owner = "openai";
    repo = "codex";
    rev = release.tagName;
    hash = release.source.hash;
  };

  postUnpack = ''
    sourceRoot="$sourceRoot/codex-rs"
  '';

  postPatch = ''
    if ! grep -q '^#!\[recursion_limit = "256"\]$' chatgpt/src/lib.rs; then
      sed -i '1i #![recursion_limit = "256"]' chatgpt/src/lib.rs
    fi
  '';

  cargoHash = release.cargoHash;
  inherit cargoBuildFlags;
  cargoInstallFlags = cargoBuildFlags;
  cargoTestFlags = cargoBuildFlags;

  postInstall = ''
    # The daemon discovers the release layout relative to the real executable.
    binaries="$(mktemp -d)"
    mv "$out/bin" "$binaries/bin"
    packageArgs=(
      --target ${stdenv.hostPlatform.rust.rustcTarget}
      --package-version "$version"
      --package-dir "$out"
      --entrypoint-bin "$binaries/bin/codex"
      --code-mode-host-bin "$binaries/bin/codex-code-mode-host"
      --exec-server-bin "$binaries/bin/codex-exec-server"
      ${lib.optionalString stdenv.hostPlatform.isLinux ''--bwrap-bin "$binaries/bin/bwrap"''}
      --rg-bin ${lib.getExe ripgrep}
      --strip none
    )
    CODEX_REPO_ROOT="$(dirname "$PWD")" \
      ${lib.getExe python3} ../scripts/build_codex_package.py "''${packageArgs[@]}"
  '';

  env = {
    CODEX_BUILD_COMMIT = release.rev or release.tagName;
    RUSTY_V8_ARCHIVE = fetchurl {
      inherit (rustyV8Artifacts.archive) url hash;
    };
    RUSTY_V8_SRC_BINDING_PATH = fetchurl {
      inherit (rustyV8Artifacts.binding) url hash;
    };
  };

  nativeBuildInputs = [ pkg-config ];
  buildInputs =
    [
      openssl
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ libcap ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      apple-sdk
    ];

  # Upstream tests include integration cases that expect network, writable home
  # state, and app-server setup. The flake checks cover the installed binaries.
  doCheck = false;

  passthru = {
    inherit (release) tagName publishedAt;
    rustyV8Archive = rustyV8Artifacts.archive;
    rustyV8Binding = rustyV8Artifacts.binding;
  };

  meta = {
    description = "Lightweight coding agent that runs in your terminal";
    homepage = "https://github.com/openai/codex";
    license = lib.licenses.asl20;
    mainProgram = "codex";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];
  };
}
