{
  apple-sdk,
  fetchFromGitHub,
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

  cargoHash = release.cargoHash;
  inherit cargoBuildFlags;
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
  # state, and app-server setup. The flake check covers the installed binary.
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
