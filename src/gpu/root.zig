//! GPU Pipeline Module
//!
//! Provides zero-Clay GPU pipeline components, texture upload helpers, and
//! persistent staging buffers for host-to-device transfers.
//!
//! INVARIANT: Code in `src/gpu/` MUST NOT depend on zclay, `src/ui/`, or
//! `src/app/` (zero imports of Clay, UI layout/renderer, AppState, or systems).

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
    _ = upload;
}
