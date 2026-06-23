{
  description = "OpenAI Codex CLI source package";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/a799d3e3886da994fa307f817a6bc705ae538eeb";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      release = builtins.fromJSON (builtins.readFile ./versions.json);
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          codex = pkgs.callPackage ./package.nix { };
        in
        {
          inherit codex;
          default = codex;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          update = pkgs.writeShellApplication {
            name = "update-codex-flake";
            runtimeInputs = [
              pkgs.bash
              pkgs.curl
              pkgs.gawk
              pkgs.jq
              pkgs.nix
            ];
            text = ''
              exec bash "$PWD/scripts/update.sh" "$@"
            '';
          };
        in
        {
          default = {
            type = "app";
            program = "${self.packages.${system}.codex}/bin/codex";
          };

          update = {
            type = "app";
            program = "${update}/bin/update-codex-flake";
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          codex-version = pkgs.runCommand "codex-${release.version}-version-check" { } ''
            version="$(${self.packages.${system}.codex}/bin/codex --version)"
            case "$version" in
              *"${release.version}"*) touch "$out" ;;
              *)
                echo "expected codex version ${release.version}, got: $version" >&2
                exit 1
                ;;
            esac
          '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.curl
              pkgs.jq
              pkgs.nix
            ];
          };
        }
      );
    };
}
