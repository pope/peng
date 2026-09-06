{
  description = "Peng Image Viewer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    agy-nix = {
      url = "github:jacopone/antigravity-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      agy-nix,
      jail-nix,
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
          jail = jail-nix.lib.init pkgs;
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
                (jail "agy" agy-nix.packages.${system}.default (
                  with jail.combinators;
                  [
                    (fwd-env "LD_LIBRARY_PATH")
                    (fwd-env "PATH")
                    (fwd-env "PKG_CONFIG_PATH")
                    gpu
                    gui
                    network
                    no-new-session
                    time-zone
                    unsafe-dbus
                    mount-cwd
                    (readwrite (noescape "~/.antigravity"))
                    (readwrite (noescape "~/.gemini"))
                    (readonly (noescape "/nix/store"))
                    (add-pkg-deps (
                      with pkgs;
                      [
                        bashInteractive
                        curl
                        diffutils
                        findutils
                        gawkInteractive
                        git
                        gnugrep
                        gnused
                        gnutar
                        gzip
                        jq
                        ps
                        ripgrep
                        unzip
                        wget
                        which
                      ]
                    ))
                  ]
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
    builtins.foldl' nixpkgs.lib.recursiveUpdate { } (map sys-config systems);
}
