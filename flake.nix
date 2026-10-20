{
  description = "Peng Image Viewer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    jailed-antigravity = {
      url = "git+https://p0.pe/my-git-repos/jailed-antigravity.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      jailed-antigravity,
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
      overlay = final: _prev: {
        peng = final.callPackage ./nix/peng.nix {
          sdl3-image = final.sdl3-image.override { enableSTB = false; };
        };
      };
      sys-config =
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ overlay ];
          };
          treefmt-eval = treefmt-nix.lib.evalModule pkgs (_: {
            projectRootFile = "flake.nix";
            programs = {
              clang-format.enable = true;
              deadnix.enable = true;
              mdformat = {
                enable = true;
                plugins =
                  ps: with ps; [
                    mdformat-frontmatter
                    mdformat-gfm
                  ];
                settings = {
                  end-of-line = "lf";
                  number = true;
                };
              };
              nixfmt.enable = true;
              statix.enable = true;
              zig.enable = true;
            };
            settings.global.excludes = [ ".envrc" ];
          });
          inherit (pkgs) peng;
          updateNixDeps = pkgs.writeShellApplication {
            name = "update-nix-deps";
            runtimeInputs = with pkgs; [
              git
              nix
              nix-prefetch-git
              self.formatter.${system}
              zig
            ];
            text = ''
              zig run tools/zon2nix.zig > nix/deps.nix
              treefmt
            '';
          };
        in
        {
          packages.${system} = {
            inherit peng;
            default = peng;
          };
          devShells.${system}.default = pkgs.mkShell {
            inputsFrom = [ peng ];
            packages =
              with pkgs;
              [
                hyperfine
                lldb
                self.formatter.${system}
                updateNixDeps
                zls
              ]
              ++ lib.optionals stdenv.hostPlatform.isLinux [
                perf
                poop
                (jailed-antigravity.lib.${system}.makeJailedAntigravity (
                  { agy, ... }: {
                    inherit pkgs;
                    package = agy.google-antigravity-cli;
                    fwdEnv = [
                      "LD_LIBRARY_PATH"
                      "PATH"
                      "PKG_CONFIG_PATH"
                    ];
                  }
                ))
              ];
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (
              pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                pkgs.libglvnd
              ]
            );
          };
          formatter.${system} = treefmt-eval.config.build.wrapper;
          checks.${system}.treefmt = treefmt-eval.config.build.check self;
        };
    in
    builtins.foldl' nixpkgs.lib.recursiveUpdate {
      overlays.default = overlay;
    } (map sys-config systems);
}
