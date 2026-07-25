{
  callPackage,
  glslang,
  lib,
  libxkbcommon,
  pkg-config,
  sdl3,
  sdl3-image,
  sdl3-ttf,
  shaderc,
  spirv-cross,
  stdenv,
  wayland,
  wayland-scanner,
  zig,
}:
stdenv.mkDerivation (_finalAttrs: {
  pname = "peng";
  version = "0.0.0";
  src = ../.;

  __structuredAttrs = true;

  postConfigure = ''
    mkdir -p .zig-cache/p
    cp -r --no-preserve=mode ${callPackage ./deps.nix { }}/* .zig-cache/p/
    export ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache
  '';

  zigBuildFlags = [
    "--system"
    ".zig-cache/p"
  ];

  nativeBuildInputs = [
    glslang
    pkg-config
    shaderc
    spirv-cross
    zig
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    wayland-scanner
  ];

  buildInputs = [
    sdl3.dev
    sdl3-ttf
    sdl3-image
  ]
  ++ lib.optionals stdenv.isLinux [
    libxkbcommon
    wayland
  ];

  meta = {
    description = "GPU-accelerated image viewer built in Zig";
    homepage = "https://p0.pe/my-git-repos/peng.git";
    license = lib.licenses.gpl3Only;
    mainProgram = "peng";
  };
})
