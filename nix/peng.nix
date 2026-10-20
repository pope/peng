{
  callPackage,
  copyDesktopItems,
  glslang,
  lib,
  libxkbcommon,
  makeDesktopItem,
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
  version = "0.1.0";
  src = ../.;

  __structuredAttrs = true;

  desktopItems = lib.optionals stdenv.hostPlatform.isLinux [
    (makeDesktopItem {
      name = "peng";
      desktopName = "Peng";
      genericName = "Image Viewer";
      comment = "GPU-accelerated image viewer built in Zig";
      exec = "peng %F";
      icon = "multimedia-photo-viewer";
      terminal = false;
      categories = [
        "Graphics"
        "2DGraphics"
        "Viewer"
        "Photography"
      ];
      mimeTypes = [
        "image/png"
        "image/jpeg"
        "image/webp"
        "image/avif"
        "image/bmp"
        "image/x-tga"
        "image/svg+xml"
        "image/gif"
        "image/tiff"
        "application/vnd.comicbook+zip"
        "application/x-cbz"
        "image/x-sony-arw"
        "image/x-fuji-raf"
        "image/x-canon-cr2"
        "image/x-nikon-nef"
        "image/x-adobe-dng"
        "image/x-olympus-orf"
        "image/x-panasonic-rw2"
        "image/x-pentax-pef"
      ];
    })
  ];

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
    copyDesktopItems
    wayland-scanner
  ];

  buildInputs = [
    sdl3.dev
    sdl3-ttf
    sdl3-image
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
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
