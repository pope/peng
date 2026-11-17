const builtin = @import("builtin");
const std = @import("std");

/// Thread-safe Multi-Producer Single-Consumer queue backed by an internal
/// mutex and `ArrayList`.
pub fn MpscQueue(comptime T: type) type {
    return struct {
        mutex: std.Io.Mutex = .init,
        items: std.ArrayList(T) = .empty,
        pending_count: std.atomic.Value(usize) = .init(0),

        const Self = @This();

        /// Initializes a new empty MpscQueue instance.
        pub fn init() Self {
            return .{};
        }

        /// Returns `true` if one or more items are currently queued awaiting
        /// `drain()`.
        pub inline fn hasPending(self: *const Self) bool {
            return self.pending_count.load(.acquire) > 0;
        }

        fn deinitQueueItemElement(
            item: *T,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) void {
            if (@hasDecl(T, "deinitQueueItem")) {
                item.deinitQueueItem(allocator, io);
                return;
            }
            if (!@hasDecl(T, "deinit")) return;
            const deinit_info = @typeInfo(@TypeOf(T.deinit));
            if (deinit_info != .@"fn") return;

            if (deinit_info.@"fn".param_types.len == 2) {
                item.deinit(allocator);
            } else if (deinit_info.@"fn".param_types.len == 1) {
                item.deinit();
            }
        }

        /// Locks the queue, invokes deinit on remaining items if supported, and
        /// releases allocated buffer memory.
        pub fn deinit(
            self: *Self,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const info = @typeInfo(T);
            if (info == .@"struct" or info == .@"union") {
                for (self.items.items) |*item| {
                    deinitQueueItemElement(item, allocator, io);
                }
            }
            self.items.deinit(allocator);
            self.pending_count.store(0, .release);
        }

        /// Locks the queue and appends a new item.
        pub fn push(
            self: *Self,
            allocator: std.mem.Allocator,
            io: std.Io,
            item: T,
        ) !void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            try self.items.append(allocator, item);
            _ = self.pending_count.fetchAdd(1, .release);
        }

        /// Atomically swaps all queued items into an empty `out_list`, reusing
        /// backing capacities across frames without allocation or element
        /// copying.
        pub fn drain(
            self: *Self,
            io: std.Io,
            out_list: *std.ArrayList(T),
        ) void {
            std.debug.assert(out_list.items.len == 0);
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.items.items.len == 0) return;
            std.mem.swap(std.ArrayList(T), &self.items, out_list);
            self.pending_count.store(0, .release);
        }

        /// Pops the last queued item from the queue without thread
        /// synchronization. Intended for single-threaded testing.
        pub fn pop(self: *Self) ?T {
            if (!builtin.is_test) {
                @compileError("pop is only allowed in tests; use drain()");
            }
            const val = self.items.pop() orelse return null;
            _ = self.pending_count.fetchSub(1, .release);
            return val;
        }
    };
}

test "MpscQueue push and drain" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var queue = MpscQueue(i32).init();
    defer queue.deinit(allocator, io);

    try std.testing.expect(!queue.hasPending());
    try queue.push(allocator, io, 10);
    try queue.push(allocator, io, 20);
    try std.testing.expect(queue.hasPending());

    var batch: std.ArrayList(i32) = .empty;
    defer batch.deinit(allocator);
    try batch.ensureTotalCapacity(allocator, 8);
    const initial_batch_cap = batch.capacity;

    queue.drain(io, &batch);
    try std.testing.expect(!queue.hasPending());
    try std.testing.expectEqual(@as(usize, 2), batch.items.len);
    try std.testing.expectEqual(@as(i32, 10), batch.items[0]);
    try std.testing.expectEqual(@as(i32, 20), batch.items[1]);
    // Pre-allocated batch capacity swapped into queue.items for reuse.
    try std.testing.expectEqual(initial_batch_cap, queue.items.capacity);

    batch.clearRetainingCapacity();
    queue.drain(io, &batch);
    try std.testing.expectEqual(@as(usize, 0), batch.items.len);

    // Second push+drain cycle swaps capacities back without allocation.
    try queue.push(allocator, io, 30);
    queue.drain(io, &batch);
    try std.testing.expect(!queue.hasPending());
    try std.testing.expectEqual(@as(usize, 1), batch.items.len);
    try std.testing.expectEqual(@as(i32, 30), batch.items[0]);
    try std.testing.expectEqual(initial_batch_cap, batch.capacity);
}
