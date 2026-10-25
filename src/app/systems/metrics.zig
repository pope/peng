const FrameContext = @import("context.zig").FrameContext;
const state_pkg = @import("state");

/// System function that copies real-time atomic worker counters, active
/// image GPU telemetry, and cache status into `state.viewer.stats` once per
/// frame tick for UI layout rendering ("Stats for Nerds").
pub fn sysSyncMetrics(ctx: FrameContext) void {
    const state = ctx.state;

    state.viewer.stats.thumbs = state.workers.snapshotThumbStats();
    state.viewer.stats.active_decode_threads = state.workers.active_decode_threads.load(.acquire);
    state.viewer.stats.max_decode_threads = state.workers.getMaxConcurrentDecodes();
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
                    .num_mip_levels = gpu.num_mip_levels,
                    .mipmap_time_ms = gpu.mipmap_time_ms,
                    .fallback_time_ms = gpu.fallback_time_ms,
                    .was_fallback = gpu.was_fallback,
                    .has_thumb = has_thumb,
                    .thumb_upload_time_ms = thumb_upload_time_ms,
                    .thumb_source = thumb_source,
                    .cbz_decompress_time_ms = gpu.cbz_decompress_time_ms,
                    .compressed_size_bytes = gpu.compressed_size_bytes,
                };
            },
            .loaded_cpu => |cpu| {
                state.viewer.stats.active_image = .{
                    .num_mip_levels = 1,
                    .mipmap_time_ms = 0.0,
                    .fallback_time_ms = 0.0,
                    .was_fallback = false,
                    .has_thumb = has_thumb,
                    .thumb_upload_time_ms = thumb_upload_time_ms,
                    .thumb_source = thumb_source,
                    .cbz_decompress_time_ms = cpu.cbz_decompress_time_ms,
                    .compressed_size_bytes = cpu.compressed_size_bytes,
                };
            },
            .none, .failed => {
                state.viewer.stats.active_image = .{
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
