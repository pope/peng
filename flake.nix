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
                    package = agy.google-antigravity;
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
    builtins.foldl' nixpkgs.lib.recursiveUpdate { } (map sys-config systems);
}
