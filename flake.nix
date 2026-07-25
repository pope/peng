{
  description = "Peng Image Viewer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    jailed-agents = {
      url = "github:andersonjoseph/jailed-agents";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        llm-agents.follows = "llm-agents";
      };
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      jailed-agents,
      nixpkgs,
      llm-agents,
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
          sdl3-image = pkgs.sdl3-image.override { enableSTB = false; };
          peng = pkgs.callPackage ./nix/peng.nix { inherit sdl3-image; };
          jail = jailed-agents.lib.${system}.internals.jail;
          updateNixDeps = pkgs.writeShellApplication {
            name = "update-nix-deps";
            runtimeInputs = with pkgs; [
              gnused
              self.formatter.${system}
              zon2nix
            ];
            text = ''
              zon2nix > nix/deps.nix
              sed 's|?ref=.*"|"|' -i nix/deps.nix
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
                (jailed-agents.lib.${system}.makeJailedAgent {
                  name = "agy";
                  pkg = llm-agents.packages.${system}.antigravity-cli;
                  baseJailOptions = with jail.combinators; [
                    (fwd-env "LD_LIBRARY_PATH")
                    (fwd-env "PATH")
                    (fwd-env "PKG_CONFIG_PATH")
                    gpu
                    gui
                    network
                    no-new-session
                    time-zone
                    wayland
                  ];
                  configPaths = [
                    "~/.antigravity"
                    "~/.gemini"
                  ];
                  extraReadonlyDirs = [ "/nix/store" ];
                })
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
    builtins.foldl' nixpkgs.lib.recursiveUpdate { } (map sys-config systems);
}
