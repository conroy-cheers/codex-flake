{
  apple-sdk,
  fetchFromGitHub,
  fetchpatch,
  fetchurl,
  lib,
  libcap,
  openssl,
  pkg-config,
  rustPlatform,
  stdenv,
}:

let
  release = builtins.fromJSON (builtins.readFile ./versions.json);
  system = stdenv.hostPlatform.system;
  cargoBuildFlags = [
    "-p"
    "codex-cli"
    "-p"
    "codex-code-mode-host"
    "--bin"
    "codex"
    "--bin"
    "codex-code-mode-host"
  ];
  rustyV8 =
    release.rustyV8.platforms.${system}
      or (throw "rusty_v8 archive is not packaged for ${system}");
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

  # PR #31058: retry structured model-capacity failures without ending the current turn.
  # Pin both ends of the compare so this remains reproducible if the PR changes.
  patches = [
    (fetchpatch {
      url = "https://github.com/openai/codex/compare/1f0566d3f59298d1bb88820a0d35294f1eeb07ea...49b5b721c12dc1ae674abe47a347baf7f28e82d1.diff";
      hash = "sha256-q+Zdlf3fD+tXY/HwfIwOvZAWQhGjmS8a85RzzOTK9kc=";
    })
  ];
  # The upstream diff is rooted at codex-rs/, while sourceRoot is already there.
  patchFlags = [ "-p2" ];

  cargoHash = release.cargoHash;
  inherit cargoBuildFlags;
  cargoInstallFlags = cargoBuildFlags;
  cargoTestFlags = cargoBuildFlags;

  env = {
    CODEX_BUILD_COMMIT = release.rev or release.tagName;
    RUSTY_V8_ARCHIVE = fetchurl {
      inherit (rustyV8) url hash;
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
    rustyV8Archive = rustyV8;
  };

  meta = {
    description = "Lightweight coding agent that runs in your terminal";
    homepage = "https://github.com/openai/codex";
    license = lib.licenses.asl20;
    mainProgram = "codex";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  };
}
