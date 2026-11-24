//! Terminal Preview Worker Module
//!
//! Spawns background worker tasks on `WorkerManager` to decode, downscale,
//! and serialize raw RGBA32 temporary files for Kitty Graphics Protocol
//! (`t=t`) previews requested over IPC.

const context = @import("context.zig");
const core = @import("core");
const geom = @import("geom");
const ipc = @import("ipc");
const manager = @import("manager.zig");
const sdl = @import("sdl");
const std = @import("std");

const CancellationToken = context.CancellationToken;
const PositiveDimsU32 = geom.PositiveDimsU32;
const renderPreviewRgbaFile = core.preview.renderPreviewRgbaFile;
const WorkerManager = manager.WorkerManager;

/// Contextual arguments passed to background terminal preview worker tasks.
pub const PreviewWorkerArgs = struct {
    workers: *WorkerManager,
    allocator: std.mem.Allocator,
    io: std.Io,
    client_stream: std.Io.net.Stream,
    path: []const u8,
    max_dims: PositiveDimsU32,
    generation: usize = 0,

    /// Builds a cooperative cancellation token for this preview task.
    pub inline fn cancelToken(
        self: *const PreviewWorkerArgs,
    ) CancellationToken {
        return .{
            .exiting = &self.workers.exiting,
            .generation = self.generation,
            .current_generation = &self.workers.preview_generation,
        };
    }

    /// Frees the owned path slice and argument struct.
    pub fn deinit(self: *PreviewWorkerArgs) void {
        const alloc = self.allocator;
        alloc.free(self.path);
        alloc.destroy(self);
    }
};

/// Spawns a background `previewWorker` task on `workers.group` to decode,
/// downscale, and write a raw RGBA32 temporary file for Kitty `t=t` display.
pub fn spawnPreview(args: *PreviewWorkerArgs) void {
    args.generation =
        args.workers.preview_generation.fetchAdd(1, .acq_rel) +% 1;
    _ = args.workers.active_decode_threads.fetchAdd(1, .monotonic);
    _ = args.workers.active_threads.fetchAdd(1, .monotonic);
    args.workers.group.async(args.io, previewWorker, .{args});
}

fn previewWorker(args: *PreviewWorkerArgs) void {
    const workers = args.workers;
    const alloc = args.allocator;
    const io = args.io;
    const stream = args.client_stream;
    defer {
        const prev_decodes = workers.active_decode_threads.fetchSub(
            1,
            .acq_rel,
        );
        if (prev_decodes == 1) {
            sdl.reclaimProcessHeap();
        }
        _ = workers.active_threads.fetchSub(1, .acq_rel);
        context.wakeUpMainThread();
    }
    defer args.deinit();

    const cancel = args.cancelToken();
    const res = renderPreviewRgbaFile(
        alloc,
        io,
        workers.thumb_cache_config,
        args.path,
        args.max_dims,
        cancel,
    ) catch |err| {
        ipc.respondErrorName(io, stream, @errorName(err));
        return;
    };

    ipc.respondPreview(
        io,
        stream,
        res.path(),
        res.dims,
    ) catch |err| {
        std.log.warn("IPC preview response write failed: {}", .{err});
        std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, res.path()) catch |del_e| {
            std.log.warn(
                "Failed to delete unconsumed preview temp file '{s}': {}",
                .{ res.path(), del_e },
            );
        };
    };
}

test "renderPreviewRgbaFile aborts when preview_generation advances" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var workers = WorkerManager{};
    defer workers.deinit(allocator, io);
    workers.preview_generation.store(2, .release);

    const cancel: CancellationToken = .{
        .exiting = &workers.exiting,
        .generation = 1,
        .current_generation = &workers.preview_generation,
    };

    const result = renderPreviewRgbaFile(
        allocator,
        io,
        .disabled,
        "testfiles/images/000_0_1024x682.jpg",
        .{ .w = 160, .h = 120 },
        cancel,
    );
    try std.testing.expectError(error.Canceled, result);
}
