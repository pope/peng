{
  description = "Peng Image Viewer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      self,
      treefmt-nix,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      sys-config =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          treefmt-eval = treefmt-nix.lib.evalModule pkgs (_: {
            projectRootFile = "flake.nix";
            programs = {
              deadnix.enable = true;
              mdformat.enable = true;
              nixfmt.enable = true;
              statix.enable = true;
              zig.enable = true;
            };
            settings.global.excludes = [ ".envrc" ];
          });
        in
        {
          devShells.${system}.default = pkgs.mkShell rec {
            packages =
              with pkgs;
              [
                hyperfine
                lldb
                self.formatter.${system}
                zls
              ]
              ++ lib.optionals stdenv.isLinux [
                perf
                poop
              ];
            nativeBuildInputs =
              with pkgs;
              [
                zig
              ]
              ++ lib.optionals stdenv.isLinux [
                wayland-scanner
              ];
            buildInputs =
              with pkgs;
              [
                sdl3.dev
              ]
              ++ lib.optionals stdenv.isLinux [
                libglvnd
                libxkbcommon
                wayland
              ];
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath buildInputs;
          };
          formatter.${system} = treefmt-eval.config.build.wrapper;
          checks.${system}.treefmt = treefmt-eval.config.build.check self;
        };
    in
    builtins.foldl' nixpkgs.lib.recursiveUpdate { } (map sys-config systems);
}
