const FrameContext = @import("root.zig").FrameContext;

/// System function that copies real-time atomic worker counters, active image GPU telemetry,
/// and cache status into `state.viewer.stats` once per frame tick for UI layout rendering ("Stats for Nerds").
pub fn sysSyncMetrics(ctx: FrameContext) void {
    const state = ctx.state;

    state.viewer.stats.thumb_header_hits = state.workers.thumb_header_hits.load(.acquire);
    state.viewer.stats.thumb_positional_hits = state.workers.thumb_positional_hits.load(.acquire);
    state.viewer.stats.thumb_misses = state.workers.thumb_misses.load(.acquire);
    state.viewer.stats.active_worker_threads = state.workers.active_threads.load(.acquire);
    state.viewer.stats.active_decode_threads = state.workers.active_decode_threads.load(.acquire);
    state.viewer.stats.cached_slot_count = state.cache.count();
    state.viewer.stats.total_vram_bytes = state.cache.getTotalVramBytes();

    if (state.getCurrentEntry()) |entry| {
        const has_thumb, const thumb_upload_time_ms =
            if (entry.thumbnail.getInfo()) |info|
                .{ true, info.upload_time_ms }
            else
                .{ false, 0.0 };

        switch (entry.status) {
            .loaded_gpu => |gpu| {
                state.viewer.stats.active_image = .{
                    .num_mip_levels = gpu.num_mip_levels,
                    .mipmap_time_ms = gpu.mipmap_time_ms,
                    .gpu_upload_time_ms = gpu.upload_time_ms,
                    .read_time_ms = gpu.read_time_ms,
                    .decode_time_ms = gpu.decode_time_ms,
                    .conversion_time_ms = gpu.conversion_time_ms,
                    .fallback_time_ms = gpu.fallback_time_ms,
                    .was_fallback = gpu.was_fallback,
                    .has_thumb = has_thumb,
                    .thumb_upload_time_ms = thumb_upload_time_ms,
                };
            },
            .loaded_cpu => |cpu| {
                state.viewer.stats.active_image = .{
                    .num_mip_levels = 1,
                    .mipmap_time_ms = 0.0,
                    .gpu_upload_time_ms = 0.0,
                    .read_time_ms = cpu.read_time_ms,
                    .decode_time_ms = cpu.decode_time_ms,
                    .conversion_time_ms = cpu.conversion_time_ms,
                    .fallback_time_ms = 0.0,
                    .was_fallback = false,
                    .has_thumb = has_thumb,
                    .thumb_upload_time_ms = thumb_upload_time_ms,
                };
            },
            else => {
                state.viewer.stats.active_image = .{
                    .has_thumb = has_thumb,
                    .thumb_upload_time_ms = thumb_upload_time_ms,
                };
            },
        }
    } else {
        state.viewer.stats.active_image = .{};
    }
}
