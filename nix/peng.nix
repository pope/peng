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
  writeShellApplication,
  zig,
  # CPU target: "baseline", "x86_64_v2", "x86_64_v3", "native", etc.
  cpu ? (
    if stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isx86_64 then "x86_64_v3" else "baseline"
  ),
  # Optimization mode: "ReleaseSafe", "ReleaseFast", "ReleaseSmall", "Debug"
  optimize ? "ReleaseSafe",
  # Statically link SDL libs and emit a portable binary with zero /nix/store paths
  static ? false,
  # Zig target triple when building with static = true (supplied by static-deps.nix)
  zigTarget ? null,
  # Optional runtime library path exposed via passthru for running portable static builds on NixOS
  linuxDlopenLibraryPath ? "",
}:
assert lib.assertMsg (static -> zigTarget != null) "zigTarget must be set when static = true";
let
  pkgConfigStatic = writeShellApplication {
    name = "pkg-config-static";
    runtimeInputs = [ pkg-config ];
    text = ''
      exec pkg-config --static "$@"
    '';
  };
in
stdenv.mkDerivation (_finalAttrs: {
  pname = "peng";
  version = "0.1.0";
  src = ../.;

  __structuredAttrs = true;
  strictDeps = true;

  dontSetZigDefaultFlags = true;

  desktopItems =
    let
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
        "image/x-dcraw"
        "image/x-sony-arw"
        "image/x-sony-sr2"
        "image/x-sony-srf"
        "image/x-fuji-raf"
        "image/x-canon-cr2"
        "image/x-canon-cr3"
        "image/x-canon-crw"
        "image/x-nikon-nef"
        "image/x-nikon-nrw"
        "image/x-adobe-dng"
        "image/x-olympus-orf"
        "image/x-panasonic-rw"
        "image/x-panasonic-rw2"
        "image/x-pentax-pef"
        "image/x-sigma-x3f"
        "image/x-samsung-srw"
      ];
      categories = [
        "Graphics"
        "2DGraphics"
        "Viewer"
        "Photography"
      ];
    in
    lib.optionals (stdenv.hostPlatform.isLinux && !static) [
      (makeDesktopItem {
        name = "peng";
        desktopName = "Peng";
        genericName = "Image Viewer";
        comment = "GPU-accelerated image viewer built in Zig";
        exec = "peng-msg --spawn open %f";
        icon = "image-x-generic";
        terminal = false;
        inherit categories mimeTypes;
        actions = {
          new-window = {
            name = "Open in New Window";
            exec = "peng %F";
          };
        };
      })
      (makeDesktopItem {
        name = "peng-new-window";
        desktopName = "Peng (New Window)";
        genericName = "Image Viewer";
        comment = "Open in a standalone Peng window";
        exec = "peng %F";
        icon = "image-x-generic";
        terminal = false;
        noDisplay = true;
        inherit categories mimeTypes;
      })
    ];

  postConfigure = ''
    mkdir -p .zig-cache/p
    cp -r --no-preserve=mode ${callPackage ./deps.nix { }}/* .zig-cache/p/
    export ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache
  '';

  dontPatchELF = static;
  dontPatchShebangs = static;

  preBuild = lib.optionalString static ''
    export PKG_CONFIG="${lib.getExe pkgConfigStatic}"
  '';

  zigBuildFlags = [
    "--system"
    ".zig-cache/p"
    "-Dcpu=${cpu}"
    "-Doptimize=${optimize}"
  ]
  ++ lib.optionals static [
    "-Dstatic_sdl=true"
    "-Dtarget=${zigTarget}"
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
  ]
  ++ lib.optionals (stdenv.hostPlatform.isLinux && !static) [
    copyDesktopItems
  ];

  buildInputs = [
    (lib.getDev sdl3)
    sdl3-ttf
    sdl3-image
  ]
  ++ lib.optionals (stdenv.hostPlatform.isLinux && !static) [
    libxkbcommon
    wayland
  ];

  outputChecks = lib.optionalAttrs static {
    out.allowedReferences = [ ];
  };

  passthru =
    lib.optionalAttrs (static && stdenv.hostPlatform.isLinux && linuxDlopenLibraryPath != "")
      {
        inherit linuxDlopenLibraryPath;
      };

  meta = {
    description = "GPU-accelerated image viewer built in Zig";
    homepage = "https://p0.pe/my-git-repos/peng.git";
    license = lib.licenses.gpl3Only;
    mainProgram = "peng";
  };
})
