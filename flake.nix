# vim:set et sw=2
{
  description = "Quil deps.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    zig.url = "github:mitchellh/zig-overlay";
    zig.inputs.nixpkgs.follows = "nixpkgs";

    zig-src.url = "github:Javyre/nix-zig-build";
    zig-src.inputs.nixpkgs.follows = "nixpkgs";

    zls.url = "github:zigtools/zls";
    zls.inputs.nixpkgs.follows = "nixpkgs";
    zls.inputs.zig-overlay.follows = "zig";
  };

  outputs =
    inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ ];
      systems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      perSystem =
        {
          config,
          self',
          inputs',
          pkgs,
          system,
          ...
        }:
        let
          # zig = inputs'.zig.packages.master;
          zig = inputs'.zig-src.packages.zig.override {
            release = {
              version = "0.16.0-dev.2224+041701416";
              src = {
                rev = "041701416be59b94189c3a9d85053e5d69e7ba2c";
                hash = "sha256-jsOaVGqEbSlTQUmuuqcvC4u4zCzKt5ElJI0wT6WQIdA=";
              };
            };
          };
          zls = inputs'.zls.packages.zls;
          # zig-llvmPackages = (
          #   pkgs.llvmPackages_git.override rec {
          #     monorepoSrc = pkgs.fetchFromGitHub rec {
          #       owner = "jacobly0";
          #       repo = "llvm-project";
          #       rev = "lldb-zig";
          #       sha256 = "sha256-M8Nf2CjLiOGbEy3c/IlDOp8o5VlxlzXYdMORtFTlpTA=";
          #       passthru = { inherit owner repo rev; };
          #     };
          #     doCheck = false;
          #   }
          # );
        in
        {
          formatter = pkgs.nixfmt-rfc-style;

          devShells.default = pkgs.mkShell {
            buildInputs = [
              zig
              zls
              # zig-llvmPackages.lldb
              pkgs.llvmPackages.lldb
              pkgs.vscode-extensions.vadimcn.vscode-lldb.adapter
            ];
          };
        };
      flake = { };
    };
}
