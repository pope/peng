//! GPU Pipeline Module
//! Provides pure-Zig GPU pipeline components, texture upload helpers, and
//! persistent staging buffers for host-to-device transfers.
//! INVARIANT: Code in `src/gpu/` MUST NOT depend on `src/ui/` or `src/app/`
//! (zero imports of UI layout/renderer, AppState, or systems).

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

/// Non-null GPU texture handle passed across module boundaries without
/// exposing `sdl` types to pure presentation modules.
pub const TextureRef = render_image.TextureRef;

/// Reusable GPU staging buffers for texture uploads, retaining buffers up to
/// 96 MiB warm across frames and decaying oversized buffers after 30s idle.
pub const UploadStagingBuffer = upload.UploadStagingBuffer;

/// Uploads a CPU surface into an SDL GPU texture with automatic mipmap pyramid
/// generation, using an optional compute pipeline for fast RGB24/BGR24 unpack
/// and optional staging buffer reuse.
pub const uploadSurfaceToGpu = upload.uploadSurfaceToGpu;

/// Ownership contract for the source `sdl.Surface` during async staging.
pub const SurfaceOwnership = upload.SurfaceOwnership;

/// Pixel staging operation performed on the background copy worker.
pub const StagingCopyMode = upload.StagingCopyMode;

/// GPU-side submission path paired with `PreparedGpuUpload`.
pub const AsyncUploadPath = upload.AsyncUploadPath;

/// Pure-CPU staging copy job executed on a background worker thread.
pub const StagedTransferJob = upload.StagedTransferJob;

/// Main-thread GPU state retained while a background worker populates the
/// mapped staging transfer buffer.
pub const PreparedGpuUpload = upload.PreparedGpuUpload;

/// Paired main-thread GPU state and pure-CPU worker copy job.
pub const BeginAsyncUploadResult = upload.BeginAsyncUploadResult;

/// Begins a 2-phase async GPU texture upload on the main thread.
pub const beginAsyncUpload = upload.beginAsyncUpload;

/// Completes a 2-phase async GPU texture upload on the main thread.
pub const finishAsyncUpload = upload.finishAsyncUpload;

/// Cancels an in-flight async GPU texture upload after worker join.
pub const cancelAsyncUpload = upload.cancelAsyncUpload;

test {
    _ = geometry;
    _ = graphics;
    _ = pass;
    _ = render_image;
    _ = text_cache;
    _ = upload;
}
