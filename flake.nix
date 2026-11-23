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
        "aarch64-darwin"
      ];
      overlay = final: _prev: {
        peng = final.callPackage ./nix/peng.nix {
          sdl3-image = final.sdl3-image.override {
            enableImageIO = false;
            enableSTB = false;
          };
        };
        peng-static =
          let
            staticDeps = final.callPackage ./nix/static-deps.nix { };
          in
          final.peng.override {
            static = true;
            inherit (staticDeps)
              linuxDlopenLibraryPath
              sdl3
              sdl3-image
              sdl3-ttf
              zigTarget
              ;
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
          packages.${system} = rec {
            inherit (pkgs) peng peng-static;
            default = peng;
          };
          devShells.${system}.default = pkgs.mkShell {
            inputsFrom = [ pkgs.peng ];
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
              ];
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (
              pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                pkgs.libglvnd
              ]
            );
          };
          formatter.${system} = treefmt-eval.config.build.wrapper;
          checks.${system} = {
            inherit (self.packages.${system}) peng;
            treefmt = treefmt-eval.config.build.check self;
            hot-reload = pkgs.peng.overrideAttrs {
              pname = "peng-hot-reload";
              desktopItems = [ ];
              # test-hot-reload depends on install, so skip buildPhase to avoid
              # invoking `zig build` twice; $out is an empty sentinel file.
              dontBuild = true;
              dontFixup = true;
              doCheck = true;
              zigBuildFlags = [
                "--system"
                ".zig-cache/p"
                "-Dcpu=baseline"
                "-Dhot_reload=true"
              ];
              checkPhase = ''
                runHook preCheck
                local flagsArray=("-j''${NIX_BUILD_CORES:-1}")
                concatTo flagsArray zigBuildFlags zigBuildFlagsArray
                TERM=dumb zig build test-hot-reload "''${flagsArray[@]}" --verbose
                runHook postCheck
              '';
              installPhase = ''
                runHook preInstall
                touch "$out"
                runHook postInstall
              '';
            };
          };
        };
    in
    builtins.foldl' nixpkgs.lib.recursiveUpdate {
      overlays.default = overlay;
    } (map sys-config systems);
}
