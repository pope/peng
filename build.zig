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
    const vert_cmd = b.addSystemCommand(&.{ "glslangValidator", "-V", "-S", "vert", "src/shaders/vert.glsl", "-o", "src/shaders/vert.spv" });
    const frag_cmd = b.addSystemCommand(&.{ "glslangValidator", "-V", "-S", "frag", "src/shaders/frag.glsl", "-o", "src/shaders/frag.spv" });
    compile_shaders.dependOn(&vert_cmd.step);
    compile_shaders.dependOn(&frag_cmd.step);

    exe.step.dependOn(compile_shaders);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
