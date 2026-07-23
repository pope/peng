const std = @import("std");
const c = @import("c.zig").c;

pub const JobPriority = enum(u8) {
    high = 0, // Currently visible image
    medium = 1, // Neighbor ±1
    low = 2, // Neighbor ±2
};

pub const CancelToken = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ref_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),

    pub fn create(allocator: std.mem.Allocator) !*CancelToken {
        const token = try allocator.create(CancelToken);
        token.* = .{
            .cancelled = std.atomic.Value(bool).init(false),
            .ref_count = std.atomic.Value(usize).init(1),
        };
        return token;
    }

    pub fn acquire(self: *CancelToken) *CancelToken {
        _ = self.ref_count.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn release(self: *CancelToken, allocator: std.mem.Allocator) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            allocator.destroy(self);
        }
    }

    pub fn cancel(self: *CancelToken) void {
        self.cancelled.store(true, .release);
    }

    pub fn isCancelled(self: *const CancelToken) bool {
        return self.cancelled.load(.acquire);
    }
};

pub const PipelineJob = struct {
    index: usize,
    generation: usize,
    path: [:0]const u8,
    priority: JobPriority,
    cancel_token: *CancelToken,

    pub fn deinit(self: *PipelineJob, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.cancel_token.release(allocator);
        allocator.destroy(self);
    }
};

pub fn comparePipelineJobs(_: void, a: *PipelineJob, b: *PipelineJob) std.math.Order {
    const p_a = @intFromEnum(a.priority);
    const p_b = @intFromEnum(b.priority);
    if (p_a < p_b) return .lt;
    if (p_a > p_b) return .gt;
    if (a.generation > b.generation) return .lt;
    if (a.generation < b.generation) return .gt;
    return .eq;
}

test "CancelToken lifecycle" {
    const allocator = std.testing.allocator;
    const token = try CancelToken.create(allocator);
    try std.testing.expect(!token.isCancelled());

    const ref = token.acquire();
    token.cancel();
    try std.testing.expect(ref.isCancelled());

    token.release(allocator);
    ref.release(allocator);
}
