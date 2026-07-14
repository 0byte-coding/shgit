{
  description = "shgit - personal project overlay manager for git";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        zig = pkgs.zig_0_16 or pkgs.zig;
      in
      {
        packages.default = pkgs.callPackage ./nix/package.nix { inherit zig; };
        packages.shgit = self.packages.${system}.default;

        apps.default = flake-utils.lib.mkApp {
          drv = self.packages.${system}.default;
          name = "shgit";
        };

        devShells.default = pkgs.mkShell {
          packages = [
            zig
            pkgs.zls
          ];
        };

        formatter = pkgs.nixfmt;
      }
    )
    // {
      overlays.default = final: prev: {
        shgit = final.callPackage ./nix/package.nix {
          zig = final.zig_0_16 or final.zig;
        };
      };
    };
}
