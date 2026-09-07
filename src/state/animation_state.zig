const std = @import("std");
pub const easing = @import("easing.zig");
pub const EasingType = easing.EasingType;

/// Bounded set of distinct animation channels in the application.
pub const AnimationChannel = enum(u8) {
    palette_reveal = 0,
    thumb_crossfade = 1,
};

pub const CHANNEL_COUNT: usize = @typeInfo(AnimationChannel).@"enum".fields.len;

/// Standard animation duration constants.
pub const DURATION_PALETTE_OPEN_MS: f32 = 140.0;
pub const DURATION_PALETTE_CLOSE_MS: f32 = 100.0;
pub const DURATION_THUMB_CROSSFADE_MS: f32 = 120.0;

/// Structure representing the parameters of an individual animation slot in the MultiArrayList.
pub const AnimationSlot = struct {
    channel: AnimationChannel,
    value: f32,
    start_val: f32,
    target_val: f32,
    elapsed_ms: f32,
    duration_ms: f32,
    easing: EasingType,
    active: bool,
};

/// Data-Oriented animation manager using Structure-of-Arrays (SoA) layout via `std.MultiArrayList`.
/// Contiguous parallel arrays ensure cache-line friendliness, zero pointer chasing, and vectorizable updates.
pub const AnimationState = struct {
    comptime {
        std.debug.assert(CHANNEL_COUNT <= 32);
    }

    slots: std.MultiArrayList(AnimationSlot) = .{},
    active_mask: u32 = 0,

    /// Initializes AnimationState, pre-allocating slots 1-to-1 with AnimationChannel variants.
    pub fn init(allocator: std.mem.Allocator) !AnimationState {
        var self = AnimationState{
            .slots = .{},
            .active_mask = 0,
        };
        try self.slots.ensureTotalCapacity(allocator, CHANNEL_COUNT);
        inline for (std.meta.tags(AnimationChannel)) |ch| {
            const default_val: f32 = if (ch == .thumb_crossfade) 1.0 else 0.0;
            self.slots.appendAssumeCapacity(.{
                .channel = ch,
                .value = default_val,
                .start_val = default_val,
                .target_val = default_val,
                .elapsed_ms = 0.0,
                .duration_ms = 0.0,
                .easing = .linear,
                .active = false,
            });
        }
        return self;
    }

    /// Releases MultiArrayList storage.
    pub fn deinit(self: *AnimationState, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
        self.active_mask = 0;
    }

    /// Instant zero-branch check for AppState.isBusy() to determine if the event loop should tick.
    pub inline fn hasActiveAnimations(self: *const AnimationState) bool {
        return self.active_mask != 0;
    }

    /// Direct O(1) indexed lookup of the current animated value for `channel`.
    pub inline fn get(self: *const AnimationState, channel: AnimationChannel) f32 {
        return self.slots.items(.value)[@intFromEnum(channel)];
    }

    /// Returns true if the specified channel is currently animating.
    pub inline fn isActive(self: *const AnimationState, channel: AnimationChannel) bool {
        return (self.active_mask & (@as(u32, 1) << @intCast(@intFromEnum(channel)))) != 0;
    }

    /// Starts an animation on `channel`, smoothly continuing from its current value.
    pub fn start(
        self: *AnimationState,
        channel: AnimationChannel,
        target: f32,
        duration_ms: f32,
        easing_type: EasingType,
    ) void {
        const idx = @intFromEnum(channel);
        const values = self.slots.items(.value);
        const starts = self.slots.items(.start_val);
        const targets = self.slots.items(.target_val);
        const elapsed = self.slots.items(.elapsed_ms);
        const durations = self.slots.items(.duration_ms);
        const easings = self.slots.items(.easing);
        const active = self.slots.items(.active);

        starts[idx] = values[idx];
        targets[idx] = target;
        elapsed[idx] = 0.0;
        durations[idx] = @max(duration_ms, 0.001);
        easings[idx] = easing_type;
        active[idx] = true;
        self.active_mask |= (@as(u32, 1) << @intCast(idx));
    }

    /// Sets the value directly without animating, deactivating the channel.
    pub fn setImmediate(self: *AnimationState, channel: AnimationChannel, val: f32) void {
        const idx = @intFromEnum(channel);
        self.slots.items(.value)[idx] = val;
        self.slots.items(.start_val)[idx] = val;
        self.slots.items(.target_val)[idx] = val;
        self.slots.items(.active)[idx] = false;
        self.active_mask &= ~(@as(u32, 1) << @intCast(idx));
    }

    /// Immediately snaps `channel` to its target value and marks it inactive.
    pub fn settle(self: *AnimationState, channel: AnimationChannel) void {
        const idx = @intFromEnum(channel);
        self.slots.items(.value)[idx] = self.slots.items(.target_val)[idx];
        self.slots.items(.active)[idx] = false;
        self.active_mask &= ~(@as(u32, 1) << @intCast(idx));
    }

    /// Immediately snaps all channels to their target values and marks all inactive.
    pub fn settleAll(self: *AnimationState) void {
        const count = self.slots.len;
        const values = self.slots.items(.value);
        const targets = self.slots.items(.target_val);
        const active = self.slots.items(.active);
        for (0..count) |i| {
            values[i] = targets[i];
            active[i] = false;
        }
        self.active_mask = 0;
    }

    /// Ticks all active animation channels forward by `delta_ms`.
    pub fn tick(self: *AnimationState, delta_ms: f32) void {
        if (self.active_mask == 0) return;

        const count = self.slots.len;
        const values = self.slots.items(.value);
        const starts = self.slots.items(.start_val);
        const targets = self.slots.items(.target_val);
        const elapsed = self.slots.items(.elapsed_ms);
        const durations = self.slots.items(.duration_ms);
        const easings = self.slots.items(.easing);
        const active = self.slots.items(.active);

        const safe_delta = @max(delta_ms, 0.0);
        for (0..count) |i| {
            if (!active[i]) continue;

            elapsed[i] += safe_delta;
            const dur = durations[i];
            if (elapsed[i] >= dur) {
                values[i] = targets[i];
                active[i] = false;
                self.active_mask &= ~(@as(u32, 1) << @intCast(i));
            } else {
                const t = elapsed[i] / dur;
                const factor = easings[i].eval(t);
                values[i] = starts[i] + (targets[i] - starts[i]) * factor;
            }
        }
    }
};

test "AnimationState lifecycle and MultiArrayList SoA layout" {
    const allocator = std.testing.allocator;
    var anim = try AnimationState.init(allocator);
    defer anim.deinit(allocator);

    try std.testing.expectEqual(@as(usize, CHANNEL_COUNT), anim.slots.len);
    try std.testing.expect(!anim.hasActiveAnimations());
    try std.testing.expectEqual(@as(f32, 0.0), anim.get(.palette_reveal));

    // Start palette reveal animation: 0.0 -> 1.0 over 100ms
    anim.start(.palette_reveal, 1.0, 100.0, .linear);
    try std.testing.expect(anim.hasActiveAnimations());
    try std.testing.expect(anim.isActive(.palette_reveal));

    // Tick 50ms (halfway)
    anim.tick(50.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), anim.get(.palette_reveal), 0.001);
    try std.testing.expect(anim.hasActiveAnimations());

    // Tick remaining 50ms (complete)
    anim.tick(50.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), anim.get(.palette_reveal), 0.001);
    try std.testing.expect(!anim.hasActiveAnimations());
    try std.testing.expect(!anim.isActive(.palette_reveal));
}

test "AnimationState smooth interruption" {
    const allocator = std.testing.allocator;
    var anim = try AnimationState.init(allocator);
    defer anim.deinit(allocator);

    // Start 0.0 -> 1.0 over 100ms
    anim.start(.palette_reveal, 1.0, 100.0, .linear);
    anim.tick(40.0);
    const mid_val = anim.get(.palette_reveal);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), mid_val, 0.001);

    // Reverse mid-flight towards 0.0 over 100ms
    anim.start(.palette_reveal, 0.0, 100.0, .linear);
    // Starts array should hold 0.4
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), anim.slots.items(.start_val)[@intFromEnum(AnimationChannel.palette_reveal)], 0.001);

    // Advance 50ms: halfway from 0.4 down to 0.0 is 0.2
    anim.tick(50.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), anim.get(.palette_reveal), 0.001);
}

test "AnimationState settleAll" {
    const allocator = std.testing.allocator;
    var anim = try AnimationState.init(allocator);
    defer anim.deinit(allocator);

    anim.start(.palette_reveal, 1.0, 500.0, .ease_out_cubic);
    anim.start(.thumb_crossfade, 0.8, 300.0, .linear);
    try std.testing.expect(anim.hasActiveAnimations());

    anim.settleAll();
    try std.testing.expect(!anim.hasActiveAnimations());
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), anim.get(.palette_reveal), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), anim.get(.thumb_crossfade), 0.001);
}
