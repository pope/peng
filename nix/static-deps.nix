{
  pkgs,
  zigTarget ? (
    if pkgs.stdenv.hostPlatform.isLinux then
      if pkgs.stdenv.hostPlatform.isx86_64 then
        "x86_64-linux-gnu.2.28"
      else if pkgs.stdenv.hostPlatform.isAarch64 then
        "aarch64-linux-gnu.2.28"
      else
        throw "Unsupported Linux architecture: ${pkgs.stdenv.hostPlatform.system}"
    else if pkgs.stdenv.hostPlatform.isDarwin then
      let
        minVer = pkgs.stdenv.hostPlatform.darwinMinVersion;
      in
      if pkgs.stdenv.hostPlatform.isx86_64 then
        "x86_64-macos.${minVer}"
      else if pkgs.stdenv.hostPlatform.isAarch64 then
        "aarch64-macos.${minVer}"
      else
        throw "Unsupported Darwin architecture: ${pkgs.stdenv.hostPlatform.system}"
    else
      throw "Unsupported platform: ${pkgs.stdenv.hostPlatform.system}"
  ),
}:
let
  inherit (pkgs) lib;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  # On Linux, wrapper scripts around `zig cc` / `zig c++` / `zig ar` / `zig ranlib`
  # ensure all static C/C++ archives use Zig's libc++ ABI and baseline glibc.
  mkZigCompiler =
    name: subcmd:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.zig ];
      text = ''
        export ZIG_GLOBAL_CACHE_DIR="''${ZIG_GLOBAL_CACHE_DIR:-''${TMPDIR:-/tmp}/zig-cache}"
        orig_args=("$@")
        is_linking=1
        has_opt=0
        for a in "''${orig_args[@]}"; do
          case "$a" in
            -c|-E|-S|--version|-v|-V|-dumpversion|-dumpmachine)
              is_linking=0
              ;;
            -O|-O0|-O1|-O2|-O3|-Os|-Oz|-Og|-Ofast)
              has_opt=1
              ;;
          esac
        done

        extra=()
        set -f
        # Nix stdenv passes space-delimited compiler flags in NIX_CFLAGS_COMPILE.
        # shellcheck disable=SC2086
        set -- ''${NIX_CFLAGS_COMPILE:-}
        set +f
        while [ $# -gt 0 ]; do
          case "$1" in
            -isystem|-idirafter)
              if [ $# -ge 2 ]; then
                extra+=("$1" "$2")
                shift 2
              else
                shift
              fi
              ;;
            -I*|-D*|-U*)
              extra+=("$1")
              shift
              ;;
            -O|-O0|-O1|-O2|-O3|-Os|-Oz|-Og|-Ofast)
              if [ "$has_opt" -eq 0 ]; then
                extra+=("$1")
                has_opt=1
              fi
              shift
              ;;
            *)
              shift
              ;;
          esac
        done
        if [ "$is_linking" -eq 0 ] && [ "$has_opt" -eq 0 ]; then
          extra+=("-O2")
        fi

        if [ "$is_linking" -eq 1 ]; then
          set -f
          # Nix stdenv passes space-delimited linker flags in NIX_LDFLAGS.
          # shellcheck disable=SC2086
          set -- ''${NIX_LDFLAGS:-}
          set +f
          while [ $# -gt 0 ]; do
            case "$1" in
              -L)
                if [ $# -ge 2 ]; then
                  extra+=("$1" "$2")
                  shift 2
                else
                  shift
                fi
                ;;
              -L*)
                extra+=("$1")
                shift
                ;;
              *)
                shift
                ;;
            esac
          done
        fi

        exec zig ${subcmd} -target ${zigTarget} -fno-sanitize=undefined -fPIC -Wno-date-time "''${extra[@]}" "''${orig_args[@]}"
      '';
    };

  zigCC = mkZigCompiler "zig-cc" "cc";
  zigCXX = mkZigCompiler "zig-cxx" "c++";

  mkZigTool =
    name: subcmd:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.zig ];
      text = ''
        exec zig ${subcmd} "$@"
      '';
    };

  zigAR = mkZigTool "zig-ar" "ar";
  zigRanlib = mkZigTool "zig-ranlib" "ranlib";

  mesonCrossFile = pkgs.writeText "zig-meson-cross.ini" ''
    [binaries]
    c = '${zigCC}/bin/zig-cc'
    cpp = '${zigCXX}/bin/zig-cxx'
    ar = '${zigAR}/bin/zig-ar'
    ranlib = '${zigRanlib}/bin/zig-ranlib'
    pkg-config = 'pkg-config'

    [host_machine]
    system = 'linux'
    cpu_family = '${if pkgs.stdenv.hostPlatform.isx86_64 then "x86_64" else "aarch64"}'
    cpu = '${pkgs.stdenv.hostPlatform.parsed.cpu.name}'
    endian = 'little'
  '';

  staticStdenv = pkgs.stdenvAdapters.makeStaticLibraries pkgs.stdenv;

  useZigFlags = old: {
    doCheck = false;
    doInstallCheck = false;
    preConfigure =
      (old.preConfigure or "")
      + "\n"
      + lib.optionalString isLinux ''
        export ZIG_GLOBAL_CACHE_DIR="''${TMPDIR:-/tmp}/zig-cache"
        export CC="${zigCC}/bin/zig-cc"
        export CXX="${zigCXX}/bin/zig-cxx"
        export AR="${zigAR}/bin/zig-ar"
        export RANLIB="${zigRanlib}/bin/zig-ranlib"
      '';
    cmakeFlags =
      (old.cmakeFlags or [ ])
      ++ lib.optionals isLinux [
        "-DCMAKE_C_COMPILER=${zigCC}/bin/zig-cc"
        "-DCMAKE_CXX_COMPILER=${zigCXX}/bin/zig-cxx"
        "-DCMAKE_AR=${zigAR}/bin/zig-ar"
        "-DCMAKE_RANLIB=${zigRanlib}/bin/zig-ranlib"
      ];
  };

  mkStatic =
    pkg: overrideArgs: extraAttrs:
    ((pkg.override ({ stdenv = staticStdenv; } // overrideArgs)).overrideAttrs (
      old:
      let
        z = useZigFlags old;
        e = if builtins.isFunction extraAttrs then extraAttrs (old // z) else extraAttrs;
      in
      z // e
    ));

  autotoolsCrossFlags = lib.optionals isLinux [
    "--build=${pkgs.stdenv.buildPlatform.parsed.cpu.name}-pc-linux-gnu"
    "--host=${pkgs.stdenv.hostPlatform.config}"
  ];

  zlib =
    mkStatic pkgs.zlib
      {
        shared = false;
        splitStaticOutput = false;
      }
      {
        postInstall = "";
      };

  bzip2 =
    mkStatic pkgs.bzip2
      {
        enableShared = false;
        enableStatic = true;
      }
      (old: {
        configureFlags = (old.configureFlags or [ ]) ++ autotoolsCrossFlags;
      });

  brotli = mkStatic pkgs.brotli { } (old: {
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DBUILD_SHARED_LIBS=OFF" ];
  });

  xz = mkStatic pkgs.xz { } (old: {
    configureFlags = (old.configureFlags or [ ]) ++ autotoolsCrossFlags;
  });

  zstd =
    mkStatic pkgs.zstd
      {
        enableStatic = true;
        buildContrib = false;
      }
      (old: {
        cmakeFlags = (lib.filter (f: !(lib.hasPrefix "-DZSTD_BUILD_" f)) (old.cmakeFlags or [ ])) ++ [
          "-DZSTD_BUILD_SHARED=OFF"
          "-DZSTD_BUILD_STATIC=ON"
          "-DZSTD_BUILD_PROGRAMS=OFF"
          "-DZSTD_BUILD_TESTS=OFF"
        ];
        postInstall =
          (old.postInstall or "")
          + "\n"
          + ''
            mkdir -p "$man"
          '';
      });

  libdeflate = mkStatic pkgs.libdeflate { } (old: {
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [
      "-DLIBDEFLATE_BUILD_SHARED_LIB=OFF"
      "-DLIBDEFLATE_BUILD_STATIC_LIB=ON"
      "-DLIBDEFLATE_BUILD_GZIP=OFF"
    ];
  });

  libpng =
    mkStatic pkgs.libpng
      {
        inherit zlib;
      }
      (old: {
        # On Darwin, nixpkgs' libpng hardcodes darwin.bootstrapStdenv instead of
        # its stdenv argument, bypassing makeStaticLibraries' default flags.
        dontDisableStatic = true;
        configureFlags =
          (old.configureFlags or [ ])
          ++ [
            "--enable-static"
            "--disable-shared"
          ]
          ++ autotoolsCrossFlags;
      });

  libjpeg = mkStatic pkgs.libjpeg_turbo {
    enableShared = false;
    enableStatic = true;
  } { };

  giflib = mkStatic pkgs.giflib { } (old: {
    configureFlags = (old.configureFlags or [ ]) ++ autotoolsCrossFlags;
    postPatch =
      (old.postPatch or "")
      + "\n"
      + ''
        substituteInPlace Makefile \
          --replace-fail 'all: shared-lib static-lib $(UTILS)' 'all: static-lib $(UTILS)' \
          --replace-fail 'install-lib: install-static-lib install-shared-lib' 'install-lib: install-static-lib'
      '';
  });

  libwebp =
    mkStatic pkgs.libwebp
      {
        pngSupport = false;
        jpegSupport = false;
        tiffSupport = false;
        gifSupport = false;
        openglSupport = false;
      }
      (old: {
        cmakeFlags = (lib.filter (f: !(lib.hasPrefix "-DBUILD_SHARED_LIBS" f)) (old.cmakeFlags or [ ])) ++ [
          "-DBUILD_SHARED_LIBS=OFF"
        ];
      });

  libtiff =
    mkStatic pkgs.libtiff
      {
        inherit
          zlib
          libjpeg
          xz
          zstd
          libdeflate
          libwebp
          ;
        withLerc = false;
      }
      (old: {
        cmakeFlags = (lib.filter (f: !(lib.hasPrefix "-DBUILD_SHARED_LIBS" f)) (old.cmakeFlags or [ ])) ++ [
          "-DBUILD_SHARED_LIBS=OFF"
        ];
        postFixup =
          (old.postFixup or "")
          + "\n"
          + ''
            rm -rf "$dev/lib/cmake/tiff"
          '';
      });

  plutovg = mkStatic pkgs.plutovg { } (old: {
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DBUILD_SHARED_LIBS=OFF" ];
  });

  plutosvg =
    mkStatic pkgs.plutosvg
      {
        inherit plutovg;
        enableFreetype = false;
      }
      (old: {
        cmakeFlags = (lib.filter (f: !(lib.hasPrefix "-DBUILD_SHARED_LIBS" f)) (old.cmakeFlags or [ ])) ++ [
          "-DBUILD_SHARED_LIBS=OFF"
        ];
      });

  freetype =
    mkStatic pkgs.freetype
      {
        inherit
          zlib
          bzip2
          brotli
          libpng
          ;
      }
      (old: {
        configureFlags = (old.configureFlags or [ ]) ++ autotoolsCrossFlags;
      });

  graphite2 = mkStatic pkgs.graphite2 { } (old: {
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DBUILD_SHARED_LIBS=OFF" ];
  });

  harfbuzz =
    mkStatic pkgs.harfbuzz
      {
        inherit freetype graphite2;
        withIntrospection = false;
        withCairo = false;
        withCoreText = false;
        withIcu = false;
      }
      (old: {
        nativeBuildInputs = lib.filter (
          p:
          !(builtins.elem (p.pname or "") [
            "gettext"
            "glib"
            "gtk-doc"
          ])
        ) (old.nativeBuildInputs or [ ]);
        buildInputs = [ freetype ];
        mesonFlags =
          (lib.filter (f: !(lib.hasPrefix "-Dglib=" f)) (old.mesonFlags or [ ]))
          ++ lib.optionals isLinux [ "--cross-file=${mesonCrossFile}" ]
          ++ [
            "-Dglib=disabled"
            "-Dgobject=disabled"
            "-Dtests=disabled"
            "-Ddocs=disabled"
            "-Dutilities=disabled"
          ];
        postInstall = (old.postInstall or "") + ''
          mkdir -p "$devdoc"
        '';
      });

  xxhash = mkStatic pkgs.xxhash { } { };

  dav1d =
    mkStatic pkgs.dav1d
      {
        inherit xxhash;
      }
      (old: {
        mesonFlags = (old.mesonFlags or [ ]) ++ lib.optionals isLinux [ "--cross-file=${mesonCrossFile}" ];
      });

  libaom =
    mkStatic pkgs.libaom
      {
        enableVmaf = false;
      }
      (old: {
        cmakeFlags = (lib.filter (f: !(lib.hasPrefix "-DBUILD_SHARED_LIBS" f)) (old.cmakeFlags or [ ])) ++ [
          "-DBUILD_SHARED_LIBS=OFF"
          "-DENABLE_DOCS=OFF"
          "-DENABLE_EXAMPLES=OFF"
          "-DENABLE_TOOLS=OFF"
        ];
        postFixup = ''
          mkdir -p "$static" "$bin"
        '';
      });

  libyuv =
    mkStatic pkgs.libyuv
      {
        inherit libjpeg;
      }
      (old: {
        buildInputs = [ libjpeg ];
        cmakeFlags = (lib.filter (f: !(lib.hasPrefix "-DUNIT_TEST" f)) (old.cmakeFlags or [ ])) ++ [
          "-DBUILD_SHARED_LIBS=OFF"
          "-DUNIT_TEST=OFF"
        ];
      });

  libavif =
    mkStatic pkgs.libavif
      {
        inherit
          zlib
          libpng
          libjpeg
          libwebp
          dav1d
          libaom
          libyuv
          ;
      }
      (old: {
        nativeBuildInputs = lib.filter (p: p != null && (p.pname or "") != "gdk-pixbuf") (
          old.nativeBuildInputs or [ ]
        );
        buildInputs = [
          zlib
          libpng
          libjpeg
          libwebp
        ];
        propagatedBuildInputs = [
          dav1d
          libaom
          libyuv
        ];
        postPatch = ''
          rm -f contrib/gdk-pixbuf/avif.thumbnailer.in
          substituteInPlace CMakeLists.txt \
            --replace-fail 'if(BUILD_SHARED_LIBS OR VCPKG_TARGET_TRIPLET)' 'if(TRUE)'
        '';
        cmakeFlags = [
          "-DBUILD_SHARED_LIBS=OFF"
          "-DAVIF_CODEC_AOM=SYSTEM"
          "-DAVIF_CODEC_DAV1D=SYSTEM"
          "-DAVIF_BUILD_APPS=OFF"
          "-DAVIF_BUILD_GDK_PIXBUF=OFF"
          "-DAVIF_LIBSHARPYUV=SYSTEM"
          "-DAVIF_LIBXML2=OFF"
          "-DAVIF_BUILD_TESTS=OFF"
        ];
        postInstall = ''
          substituteInPlace "$out/lib/pkgconfig/libavif.pc" \
            --replace-fail 'Libs.private: -lyuv' "Libs.private: -L${libyuv}/lib -lyuv"
        '';
      });

  lcms2 = mkStatic pkgs.lcms2 { } (old: {
    configureFlags = (old.configureFlags or [ ]) ++ autotoolsCrossFlags;
  });

  libhwy = mkStatic pkgs.libhwy { } (old: {
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [
      "-DBUILD_SHARED_LIBS=OFF"
      "-DBUILD_TESTING=OFF"
    ];
  });

  libjxl =
    mkStatic pkgs.libjxl
      {
        inherit
          brotli
          giflib
          libhwy
          libjpeg
          libpng
          libwebp
          lcms2
          zlib
          ;
        enablePlugins = false;
      }
      (old: {
        nativeBuildInputs = lib.filter (
          p:
          p != null
          && !(builtins.elem (p.pname or "") [
            "gdk-pixbuf"
            "asciidoc"
            "doxygen"
          ])
        ) (old.nativeBuildInputs or [ ]);
        buildInputs = [
          lcms2
          giflib
          libjpeg
          libpng
          libwebp
          zlib
        ];
        propagatedBuildInputs = [
          brotli
          libhwy
        ];
        cmakeFlags =
          (lib.filter (
            f:
            !(lib.hasPrefix "-DJPEGXL_ENABLE_" f)
            && !(lib.hasPrefix "-DJPEGXL_FORCE_SYSTEM_GTEST" f)
            && !(lib.hasPrefix "-DBUILD_TESTING" f)
          ) (old.cmakeFlags or [ ]))
          ++ [
            "-DBUILD_SHARED_LIBS=OFF"
            "-DBUILD_TESTING=OFF"
            "-DJPEGXL_ENABLE_SKCMS=OFF"
            "-DJPEGXL_ENABLE_TOOLS=OFF"
            "-DJPEGXL_ENABLE_MANPAGES=OFF"
            "-DJPEGXL_ENABLE_DOXYGEN=OFF"
            "-DJPEGXL_ENABLE_BENCHMARK=OFF"
            "-DJPEGXL_ENABLE_EXAMPLES=OFF"
            "-DJPEGXL_ENABLE_PLUGINS=OFF"
            "-DJPEGXL_ENABLE_TCMALLOC=OFF"
            "-DJPEGXL_ENABLE_OPENEXR=OFF"
            "-DJPEGXL_ENABLE_SJPEG=OFF"
            "-DJPEGXL_ENABLE_JNI=OFF"
          ];
        postInstall = ''
          mkdir -p "$bin" "$benchmark"
        '';
      });

  sdl3 =
    (pkgs.sdl3.override (
      lib.optionalAttrs isDarwin {
        openglSupport = false;
        vulkanSupport = false;
        x11Support = false;
      }
    )).overrideAttrs
      (
        old:
        let
          z = useZigFlags old;
        in
        z
        // {
          pname = "sdl3-static";
          # Clear Nixpkgs' postPatch so SDL3 dlopen()s generic system SONAMEs instead of /nix/store paths.
          postPatch = "";
          cmakeFlags =
            (lib.filter (
              flag:
              !(lib.hasPrefix "-DSDL_DEPS_SHARED=" flag)
              && !(lib.hasPrefix "-DSDL_TESTS=" flag)
              && !(lib.hasPrefix "-DSDL_INSTALL_TESTS=" flag)
            ) (z.cmakeFlags or [ ]))
            ++ [
              (lib.cmakeBool "SDL_SHARED" false)
              (lib.cmakeBool "SDL_STATIC" true)
              (lib.cmakeBool "SDL_DEPS_SHARED" true)
              (lib.cmakeBool "SDL_TESTS" false)
              (lib.cmakeBool "SDL_INSTALL_TESTS" false)
            ];
          postInstall = (old.postInstall or "") + ''
            mkdir -p "$installedTests"
          '';
        }
      );

  sdl3-ttf =
    mkStatic pkgs.sdl3-ttf
      {
        inherit
          sdl3
          freetype
          harfbuzz
          plutosvg
          ;
        glib = null;
      }
      (old: {
        pname = "sdl3-ttf-static";
        buildInputs = [
          sdl3
          freetype
          harfbuzz
          plutosvg
        ];
        propagatedBuildInputs = lib.concatMap pkgOutputs [
          sdl3
          freetype
          harfbuzz
          graphite2
          plutosvg
          plutovg
          zlib
          bzip2
          brotli
          libpng
        ];
        cmakeFlags = (old.cmakeFlags or [ ]) ++ [
          "-DBUILD_SHARED_LIBS=OFF"
          "-DSDLTTF_INSTALL_MAN=OFF"
        ];
      });

  sdl3-image =
    mkStatic pkgs.sdl3-image
      {
        inherit
          sdl3
          libtiff
          libpng
          libwebp
          libjxl
          libavif
          libjpeg
          ;
        enableImageIO = false;
        enableSTB = false;
        enableTests = false;
      }
      (old: {
        pname = "sdl3-image-static";
        buildInputs = (old.buildInputs or [ ]) ++ lib.optional isDarwin libavif;
        propagatedBuildInputs = lib.concatMap pkgOutputs [
          sdl3
          libtiff
          zlib
          xz
          zstd
          libdeflate
          libwebp
          libjpeg
          libpng
          giflib
          libavif
          dav1d
          xxhash
          libaom
          libyuv
          libjxl
          libhwy
          lcms2
          brotli
        ];
        cmakeFlags =
          (lib.filter (
            f: !(lib.hasPrefix "-DSDLIMAGE_DEPS_SHARED=" f) && !(lib.hasPrefix "-DSDLIMAGE_AVIF=" f)
          ) (old.cmakeFlags or [ ]))
          ++ [
            "-DBUILD_SHARED_LIBS=OFF"
            "-DSDLIMAGE_AVIF=ON"
            "-DSDLIMAGE_DEPS_SHARED=OFF"
            "-DSDLIMAGE_SAMPLES=OFF"
          ];
      });
  pkgOutputs =
    p:
    lib.unique (
      [
        (lib.getDev p)
        (lib.getLib p)
        p
      ]
      ++ lib.optional (p ? static) p.static
    );

  linuxDlopenLibs = lib.optionals isLinux (
    with pkgs;
    [
      vulkan-loader
      wayland
      libxkbcommon
      libx11
      libxcb
      libGL
      libglvnd
      libdecor
      libdrm
      libgbm
      libxcursor
      libxext
      libxfixes
      libxi
      libxrandr
      libxscrnsaver
      libxtst
    ]
  );

  linuxDlopenLibraryPath = lib.optionalString isLinux (
    "/run/opengl-driver/lib:" + lib.makeLibraryPath linuxDlopenLibs
  );
in
{
  inherit
    libjpeg
    sdl3
    sdl3-ttf
    sdl3-image
    linuxDlopenLibs
    linuxDlopenLibraryPath
    zigTarget
    ;
}
