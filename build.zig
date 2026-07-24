const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zclay (clay-zig-bindings) dependency
    const zclay_dep = b.dependency("zclay", .{
        .target = target,
        .optimize = optimize,
    });
    // Transitively retrieve the clay dependency from zclay's sub-builder
    const clay_dep = zclay_dep.builder.dependency("clay", .{});

    const exe = b.addExecutable(.{
        .name = "peng",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Configure system library dependencies.
    // We link them dynamically to the executable so they are resolved at final link time.
    const sys_libs = [_][]const u8{ "sdl3", "sdl3-ttf", "sdl3-image" };
    inline for (sys_libs) |lib| {
        exe.root_module.linkSystemLibrary(lib, .{});
    }

    // Import the zclay Zig module into our executable module
    exe.root_module.addImport("zclay", zclay_dep.module("zclay"));

    // Include Clay and its SDL3 renderer via root_module
    exe.root_module.addIncludePath(clay_dep.path(""));
    exe.root_module.addIncludePath(clay_dep.path("renderers/SDL3"));

    // Add Clay's C implementation (which compiles the SDL3 renderer code)
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/clay.c"),
    });

    b.installArtifact(exe);

    // Shader compilation
    const compile_shaders = b.step("shaders", "Compile shaders");
    const vert_cmd = b.addSystemCommand(&.{ "glslangValidator", "-V", "-Os", "-S", "vert", "src/shaders/vert.glsl", "-o", "src/shaders/vert.spv" });
    const frag_cmd = b.addSystemCommand(&.{ "glslangValidator", "-V", "-Os", "-S", "frag", "src/shaders/frag.glsl", "-o", "src/shaders/frag.spv" });
    compile_shaders.dependOn(&vert_cmd.step);
    compile_shaders.dependOn(&frag_cmd.step);

    const vert_msl_cmd = b.addSystemCommand(&.{ "spirv-cross", "src/shaders/vert.spv", "--msl", "--output", "src/shaders/vert.msl" });
    vert_msl_cmd.step.dependOn(&vert_cmd.step);
    const frag_msl_cmd = b.addSystemCommand(&.{ "spirv-cross", "src/shaders/frag.spv", "--msl", "--output", "src/shaders/frag.msl" });
    frag_msl_cmd.step.dependOn(&frag_cmd.step);

    compile_shaders.dependOn(&vert_msl_cmd.step);
    compile_shaders.dependOn(&frag_msl_cmd.step);

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
    inline for (&.{ "sdl3", "sdl3-ttf", "sdl3-image" }) |lib| {
        test_runner_exe.root_module.linkSystemLibrary(lib, .{});
    }
    b.installArtifact(test_runner_exe);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const run_integration_tests = b.addRunArtifact(test_runner_exe);
    run_integration_tests.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_integration_tests.addArgs(args);
    }

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
