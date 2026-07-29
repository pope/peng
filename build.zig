const std = @import("std");

pub fn build(b: *std.Build) void {
    const hot_reload = b.option(
        bool,
        "hot_reload",
        "Build the application viewer as a dynamic lib to allow for automatic hot-reload of code",
    ) orelse false;

    var options = b.addOptions();
    options.addOption(bool, "hot_reload", hot_reload);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zclay (clay-zig-bindings) dependency
    const zclay_dep = b.dependency("zclay", .{
        .target = target,
        .optimize = optimize,
    });
    // Transitively retrieve the clay dependency from zclay's sub-builder
    const clay_dep = zclay_dep.builder.dependency("clay", .{});

    if (hot_reload) {
        for (zclay_dep.module("zclay").link_objects.items) |link_obj| {
            switch (link_obj) {
                .other_step => |compile_step| {
                    if (std.mem.eql(u8, compile_step.name, "clay")) {
                        compile_step.root_module.pic = true;
                    }
                },
                else => {},
            }
        }
    }

    const fuzzig_dep = b.dependency("fuzzig", .{
        .target = target,
        .optimize = optimize,
    });

    // Create the standalone SDL boundary module
    const sdl_module = b.createModule(.{
        .root_source_file = b.path("src/sdl/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (target.result.os.tag == .windows) {
        const sdl3_dep = b.dependency("sdl3_devel", .{});
        const ttf_dep = b.dependency("sdl3_ttf_devel", .{});
        const img_dep = b.dependency("sdl3_image_devel", .{});

        const deps = [_]*std.Build.Dependency{ sdl3_dep, ttf_dep, img_dep };
        inline for (deps) |dep| {
            sdl_module.addIncludePath(dep.path("include"));
            sdl_module.addLibraryPath(dep.path("lib/x64"));
        }
        const sys_libs = [_][]const u8{ "SDL3", "SDL3_ttf", "SDL3_image" };
        inline for (sys_libs) |lib| {
            sdl_module.linkSystemLibrary(lib, .{});
        }

        const install_bin = struct {
            fn run(builder: *std.Build, lazy_path: std.Build.LazyPath, filename: []const u8) void {
                const install_step = builder.addInstallBinFile(lazy_path, filename);
                builder.getInstallStep().dependOn(&install_step.step);
            }
        }.run;

        install_bin(b, sdl3_dep.path("lib/x64/SDL3.dll"), "SDL3.dll");
        install_bin(b, ttf_dep.path("lib/x64/SDL3_ttf.dll"), "SDL3_ttf.dll");
        install_bin(b, img_dep.path("lib/x64/SDL3_image.dll"), "SDL3_image.dll");
        install_bin(b, img_dep.path("lib/x64/optional/libavif-16.dll"), "libavif-16.dll");
        install_bin(b, img_dep.path("lib/x64/optional/libpng16-16.dll"), "libpng16-16.dll");
        install_bin(b, img_dep.path("lib/x64/optional/libtiff-6.dll"), "libtiff-6.dll");
        install_bin(b, img_dep.path("lib/x64/optional/libwebp-7.dll"), "libwebp-7.dll");
        install_bin(b, img_dep.path("lib/x64/optional/libwebpdemux-2.dll"), "libwebpdemux-2.dll");
        install_bin(b, img_dep.path("lib/x64/optional/libwebpmux-3.dll"), "libwebpmux-3.dll");
    } else {
        const sys_libs = [_][]const u8{ "sdl3", "sdl3-ttf", "sdl3-image" };
        inline for (sys_libs) |lib| {
            sdl_module.linkSystemLibrary(lib, .{});
        }
    }

    const intents_module = b.createModule(.{
        .root_source_file = b.path("src/intents/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/app/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ui_module = b.createModule(.{
        .root_source_file = b.path("src/ui/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const config_module = b.createModule(.{
        .root_source_file = b.path("src/config/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    app_module.addImport("sdl", sdl_module);
    app_module.addImport("zclay", zclay_dep.module("zclay"));
    app_module.addImport("fuzzig", fuzzig_dep.module("fuzzig"));
    app_module.addImport("intents", intents_module);
    app_module.addImport("ui", ui_module);

    ui_module.addImport("sdl", sdl_module);
    ui_module.addImport("zclay", zclay_dep.module("zclay"));
    ui_module.addImport("app", app_module);
    ui_module.addImport("intents", intents_module);

    config_module.addImport("app", app_module);
    config_module.addImport("intents", intents_module);

    const viewer_lib = b.addLibrary(.{
        .name = "viewer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/viewer.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = if (hot_reload) .dynamic else .static,
    });
    viewer_lib.root_module.addImport("sdl", sdl_module);
    viewer_lib.root_module.addImport("zclay", zclay_dep.module("zclay"));
    viewer_lib.root_module.addImport("fuzzig", fuzzig_dep.module("fuzzig"));
    viewer_lib.root_module.addImport("app", app_module);
    viewer_lib.root_module.addImport("ui", ui_module);
    viewer_lib.root_module.addImport("config", config_module);
    viewer_lib.root_module.addImport("intents", intents_module);
    viewer_lib.root_module.addIncludePath(clay_dep.path(""));
    viewer_lib.root_module.addIncludePath(clay_dep.path("renderers/SDL3"));

    if (hot_reload) {
        b.installArtifact(viewer_lib);
    }

    const exe = b.addExecutable(.{
        .name = "peng",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addOptions("build_options", options);

    // Import the sdl module into executable module
    exe.root_module.addImport("sdl", sdl_module);

    // Import the zclay Zig module into our executable module
    exe.root_module.addImport("zclay", zclay_dep.module("zclay"));

    // Import internal modules into executable module
    exe.root_module.addImport("app", app_module);
    exe.root_module.addImport("ui", ui_module);
    exe.root_module.addImport("config", config_module);

    // Include Clay and its SDL3 renderer via root_module
    exe.root_module.addIncludePath(clay_dep.path(""));
    exe.root_module.addIncludePath(clay_dep.path("renderers/SDL3"));

    if (hot_reload) {
        exe.rdynamic = true;
    } else {
        exe.root_module.addImport("viewer", viewer_lib.root_module);
    }

    b.installArtifact(exe);

    // Shader compilation
    const compile_shaders = b.step("shaders", "Compile shaders");
    const vert_cmd = b.addSystemCommand(&.{
        "glslangValidator",
        "-V",
        "-Os",
        "-S",
        "vert",
        "src/ui/shaders/vert.glsl",
        "-o",
        "src/ui/shaders/vert.spv",
    });
    const frag_cmd = b.addSystemCommand(&.{
        "glslangValidator",
        "-V",
        "-Os",
        "-S",
        "frag",
        "src/ui/shaders/frag.glsl",
        "-o",
        "src/ui/shaders/frag.spv",
    });
    const comp_cmd = b.addSystemCommand(&.{
        "glslangValidator",
        "-V",
        "-Os",
        "-S",
        "comp",
        "src/ui/shaders/unpack_rgb.comp.glsl",
        "-o",
        "src/ui/shaders/unpack_rgb.spv",
    });
    compile_shaders.dependOn(&vert_cmd.step);
    compile_shaders.dependOn(&frag_cmd.step);
    compile_shaders.dependOn(&comp_cmd.step);

    const vert_msl_cmd = b.addSystemCommand(&.{
        "spirv-cross",
        "src/ui/shaders/vert.spv",
        "--msl",
        "--output",
        "src/ui/shaders/vert.msl",
    });
    vert_msl_cmd.step.dependOn(&vert_cmd.step);
    const frag_msl_cmd = b.addSystemCommand(&.{
        "spirv-cross",
        "src/ui/shaders/frag.spv",
        "--msl",
        "--output",
        "src/ui/shaders/frag.msl",
    });
    frag_msl_cmd.step.dependOn(&frag_cmd.step);
    const comp_msl_cmd = b.addSystemCommand(&.{
        "spirv-cross",
        "src/ui/shaders/unpack_rgb.spv",
        "--msl",
        "--output",
        "src/ui/shaders/unpack_rgb.msl",
    });
    comp_msl_cmd.step.dependOn(&comp_cmd.step);

    compile_shaders.dependOn(&vert_msl_cmd.step);
    compile_shaders.dependOn(&frag_msl_cmd.step);
    compile_shaders.dependOn(&comp_msl_cmd.step);

    exe.step.dependOn(compile_shaders);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const msg_exe = b.addExecutable(.{
        .name = "peng-msg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/msg_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(msg_exe);

    const test_runner_exe = b.addExecutable(.{
        .name = "peng-test-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_runner_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    test_runner_exe.root_module.addImport("sdl", sdl_module);
    b.installArtifact(test_runner_exe);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.step.dependOn(b.getInstallStep());

    const run_integration_tests = b.addRunArtifact(test_runner_exe);
    run_integration_tests.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_integration_tests.addArgs(args);
    }

    const sdl_tests = b.addTest(.{
        .root_module = sdl_module,
    });
    const run_sdl_tests = b.addRunArtifact(sdl_tests);
    run_sdl_tests.step.dependOn(b.getInstallStep());

    if (target.result.os.tag == .windows) {
        run_exe_tests.addPathDir(b.getInstallPath(.bin, ""));
        run_sdl_tests.addPathDir(b.getInstallPath(.bin, ""));
        run_integration_tests.addPathDir(b.getInstallPath(.bin, ""));
    }

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_sdl_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
