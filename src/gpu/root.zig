//! GPU Pipeline Module
//!
//! Provides zero-Clay GPU pipeline components, texture upload helpers, and
//! persistent staging buffers for host-to-device transfers.
//!
//! INVARIANT: Code in `src/gpu/` MUST NOT depend on zclay, `src/ui/`, or
//! `src/app/` (zero imports of Clay, UI layout/renderer, AppState, or systems).

/// 2D vertex generation, color packing, and rounded rectangle tessellation.
pub const geometry = @import("geometry.zig");

/// SDL GPU device lifecycle, pipeline creation, and offscreen render targets.
pub const graphics = @import("graphics.zig");

/// GPU render pass execution, text glyph upload, and frame target lifecycle.
pub const pass = @import("pass.zig");

/// Image viewer vertex emission and viewport batch commands.
pub const render_image = @import("render_image.zig");

/// Hash-based glyph and text texture caching with LRU eviction.
pub const text_cache = @import("text_cache.zig");

/// Submodule handling texture staging, compute unpack, and GPU uploads.
pub const upload = @import("upload.zig");

/// Result payload containing the created GPU texture, dimensions, and
/// ingestion telemetry.
pub const GpuUploadResult = upload.GpuUploadResult;

/// Reusable GPU staging buffers for texture uploads, eliminating allocation
/// and deallocation churn on every frame by retaining and geometrically
/// growing transfer and storage buffers.
pub const UploadStagingBuffer = upload.UploadStagingBuffer;

/// Uploads a CPU surface into an SDL GPU texture with automatic mipmap pyramid
/// generation, using an optional compute pipeline for fast RGB24/BGR24 unpack
/// and optional staging buffer reuse.
pub const uploadSurfaceToGpu = upload.uploadSurfaceToGpu;

test {
    _ = geometry;
    _ = graphics;
    _ = pass;
    _ = render_image;
    _ = text_cache;
    _ = upload;
}
