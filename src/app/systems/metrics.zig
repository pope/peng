const app_state = @import("../state.zig");
const context = @import("context.zig");
const sdl = @import("sdl");
const state_pkg = @import("state");
const std = @import("std");

const AppState = app_state.AppState;
const FrameContext = context.FrameContext;

/// System function that copies real-time atomic worker counters, active
/// image GPU telemetry, and cache status into `state.viewer.stats` once per
/// frame tick for UI layout rendering ("Stats for Nerds").
pub fn sysSyncMetrics(ctx: FrameContext) void {
    const state = ctx.state;

    state.viewer.stats.thumbs = state.workers.snapshotThumbStats();
    state.viewer.stats.active_decode_threads =
        state.workers.active_decode_threads.load(.acquire);
    state.viewer.stats.max_decode_threads =
        state.workers.getMaxConcurrentDecodes();
    state.viewer.stats.cached_slot_count = state.cache.count();
    state.viewer.stats.total_vram_bytes = state.cache.getTotalVramBytes();

    if (state.getCurrentEntry()) |entry| {
        const thumb_info = entry.resident.thumbnail.getInfo();
        const has_thumb = thumb_info != null;
        const thumb_upload_time_ms: f64 =
            if (thumb_info) |info| info.upload_time_ms else 0.0;
        const thumb_source: state_pkg.ThumbnailSource =
            if (thumb_info) |info| info.source else .embedded_header;

        switch (entry.resident.asset) {
            .loaded_gpu => |gpu| {
                state.viewer.stats.active_image = .{
                    .decode = gpu.decode,
                    .ingest = gpu.ingest,
                    .has_thumb = has_thumb,
                    .thumb_upload_time_ms = thumb_upload_time_ms,
                    .thumb_source = thumb_source,
                };
            },
            .loaded_cpu => |cpu| {
                state.viewer.stats.active_image = .{
                    .decode = cpu.decode,
                    .ingest = null,
                    .has_thumb = has_thumb,
                    .thumb_upload_time_ms = thumb_upload_time_ms,
                    .thumb_source = thumb_source,
                };
            },
            .none, .failed => {
                state.viewer.stats.active_image = .{
                    .decode = null,
                    .ingest = null,
                    .has_thumb = has_thumb,
                    .thumb_upload_time_ms = thumb_upload_time_ms,
                    .thumb_source = thumb_source,
                };
            },
        }
    } else {
        state.viewer.stats.active_image = .{};
    }
}

test "metrics - sysSyncMetrics maps CPU and GPU telemetry cleanly" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var state = try AppState.initHeadless(allocator, io);
    defer state.deinit();

    _ = try state.viewer.navigation.appendEntry(allocator, .{
        .filesystem = .{ .path = "test.jpg" },
    });
    state.viewer.navigation.current_index = 0;
    const id0 = state.viewer.navigation.getIdAt(0).?;

    const surf = sdl.Surface.create(10, 10, sdl.PixelFormat.rgba32) orelse
        return error.SurfaceFailed;

    const key0 = try state.cache.appendSlot(allocator, id0, .{
        .resident = .{
            .asset = .{
                .loaded_cpu = .{
                    .surface = surf,
                    .w = 10.0,
                    .h = 10.0,
                    .size_bytes = 400,
                    .decode = .{
                        .read_time_ms = 1.25,
                        .decode_time_ms = 3.5,
                        .conversion_time_ms = 0.5,
                        .archive = .none,
                    },
                },
            },
        },
    });

    const ctx = FrameContext{ .state = &state, .frame_allocator = allocator };
    sysSyncMetrics(ctx);

    // CPU-loaded asset must have decode telemetry but ingest == null
    try std.testing.expect(state.viewer.stats.active_image.decode != null);
    try std.testing.expect(state.viewer.stats.active_image.ingest == null);
    const dec = state.viewer.stats.active_image.decode.?;
    try std.testing.expectEqual(@as(f64, 1.25), dec.read_time_ms);
    try std.testing.expectEqual(@as(f64, 3.5), dec.decode_time_ms);
    try std.testing.expectEqual(state_pkg.ArchiveTelemetry.none, dec.archive);

    // Now test GPU-loaded asset
    const entry = state.cache.get(key0).?;
    entry.resident.asset = .{
        .loaded_gpu = .{
            .gpu_texture = .{ .ptr = @ptrFromInt(0x1234) },
            .w = 10.0,
            .h = 10.0,
            .size_bytes = 400,
            .decode = .{
                .read_time_ms = 1.25,
                .decode_time_ms = 3.5,
                .conversion_time_ms = 0.5,
                .archive = state_pkg.ArchiveTelemetry.init(4.2, 2048),
            },
            .ingest = .{
                .upload_time_ms = 0.8,
                .memory_size_bytes = 1024,
                .mode = .direct,
                .mipmaps = state_pkg.MipmapTelemetry.init(3, 1.1),
            },
        },
    };

    sysSyncMetrics(ctx);

    try std.testing.expect(state.viewer.stats.active_image.decode != null);
    try std.testing.expect(state.viewer.stats.active_image.ingest != null);
    const gpu_ing = state.viewer.stats.active_image.ingest.?;
    try std.testing.expectEqual(@as(f64, 0.8), gpu_ing.upload_time_ms);
    try std.testing.expectEqual(@as(usize, 1024), gpu_ing.memory_size_bytes);
    try std.testing.expectEqual(state_pkg.UploadMode.direct, gpu_ing.mode);
    switch (gpu_ing.mipmaps) {
        .disabled => return error.TestExpectedGenerated,
        .generated => |g| {
            try std.testing.expectEqual(@as(u32, 3), g.num_levels);
            try std.testing.expectEqual(@as(f64, 1.1), g.generate_time_ms);
        },
    }
}
