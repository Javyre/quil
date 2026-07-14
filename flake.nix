# vim:set et sw=2
{
  description = "Quil deps.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    zig-src.url = "github:Javyre/nix-zig-build";
    zig-src.inputs.nixpkgs.follows = "nixpkgs";

    zls.url = "github:zigtools/zls";
    zls.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ ];
      systems = [
        "x86_64-linux"
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
          zig = inputs'.zig-src.packages.zig.override {
            release = {
              version = "0.17.0-dev.1414+80d06578a";
              src = {
                rev = "80d06578ac66bce3aa0a21e9610cdb782b9a0593";
                hash = "sha256-Zb0v4QUq57NBDilUwc0BFC8PLFoxa5Cy5iWZlOrXc80=";
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
