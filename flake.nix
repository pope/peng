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
          packages =
            with pkgs;
            [
              glslang
              hyperfine
              lldb
              self.formatter.${system}
              shaderc
              zls
            ]
            ++ lib.optionals stdenv.isLinux [
              perf
              poop
            ];
          nativeBuildInputs =
            with pkgs;
            [
              pkg-config
              zig
            ]
            ++ lib.optionals stdenv.isLinux [
              wayland-scanner
            ];
          buildInputs =
            with pkgs;
            [
              sdl3.dev
              sdl3-ttf
              sdl3-image
            ]
            ++ lib.optionals stdenv.isLinux [
              libglvnd
              libxkbcommon
              wayland
            ];
          jail = jailed-agents.lib.${system}.internals.jail;
        in
        {
          devShells.${system}.default = pkgs.mkShell {
            inherit nativeBuildInputs buildInputs;
            packages = packages ++ [
              (jailed-agents.lib.${system}.makeJailedAgent {
                name = "agy";
                pkg = llm-agents.packages.${system}.antigravity-cli;
                baseJailOptions = with jail.combinators; [
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
                extraPkgs = packages ++ nativeBuildInputs ++ buildInputs;
                extraReadonlyDirs = with pkgs; [
                  (lib.getDev sdl3)
                  (lib.getLib sdl3)

                  (lib.getDev sdl3-image)
                  (lib.getLib sdl3-image)

                  (lib.getDev shaderc)
                  (lib.getLib shaderc)

                  (lib.getDev glslang)
                ];
                env.LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath buildInputs;
              })
            ];
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath buildInputs;
          };
          formatter.${system} = treefmt-eval.config.build.wrapper;
          checks.${system}.treefmt = treefmt-eval.config.build.check self;
        };
    in
    builtins.foldl' nixpkgs.lib.recursiveUpdate { } (map sys-config systems);
}
