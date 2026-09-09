const std = @import("std");
pub const easing = @import("easing.zig");
pub const EasingType = easing.EasingType;

/// Bounded set of distinct animation channels in the application.
pub const AnimationChannel = enum(u8) {
    palette_reveal = 0,
    thumb_crossfade = 1,
    title_overlay = 2,
    snackbar = 3,
    image_crossfade = 4,
};

pub const CHANNEL_COUNT: usize = @typeInfo(AnimationChannel).@"enum".fields.len;
pub const MAX_CHANNELS: usize = 32;

/// Standard animation duration constants.
pub const DURATION_PALETTE_OPEN_MS: f32 = 140.0;
pub const DURATION_PALETTE_CLOSE_MS: f32 = 100.0;
pub const DURATION_THUMB_CROSSFADE_MS: f32 = 120.0;
pub const DURATION_TITLE_OVERLAY_OPEN_MS: f32 = 140.0;
pub const DURATION_TITLE_OVERLAY_CLOSE_MS: f32 = 200.0;
pub const DURATION_SNACKBAR_OPEN_MS: f32 = 140.0;
pub const DURATION_SNACKBAR_CLOSE_MS: f32 = 200.0;
pub const DURATION_IMAGE_DISSOLVE_MS: f32 = 200.0;
pub const MIN_SLIDESHOW_DISSOLVE_INTERVAL_S: f32 = 0.5;

/// Metadata describing default durations, easings, and base values for an animation channel.
pub const ChannelDescriptor = struct {
    default_open_duration_ms: f32,
    default_close_duration_ms: f32,
    open_easing: EasingType,
    close_easing: EasingType,
    default_value: f32 = 0.0,
};

/// Returns the configuration descriptor for the specified animation channel.
pub fn getDescriptor(channel: AnimationChannel) ChannelDescriptor {
    return switch (channel) {
        .palette_reveal => .{
            .default_open_duration_ms = DURATION_PALETTE_OPEN_MS,
            .default_close_duration_ms = DURATION_PALETTE_CLOSE_MS,
            .open_easing = .ease_out_cubic,
            .close_easing = .ease_out_quad,
            .default_value = 0.0,
        },
        .thumb_crossfade => .{
            .default_open_duration_ms = DURATION_THUMB_CROSSFADE_MS,
            .default_close_duration_ms = DURATION_THUMB_CROSSFADE_MS,
            .open_easing = .ease_out_quad,
            .close_easing = .ease_out_quad,
            .default_value = 1.0,
        },
        .title_overlay => .{
            .default_open_duration_ms = DURATION_TITLE_OVERLAY_OPEN_MS,
            .default_close_duration_ms = DURATION_TITLE_OVERLAY_CLOSE_MS,
            .open_easing = .ease_out_quad,
            .close_easing = .ease_out_quad,
            .default_value = 0.0,
        },
        .snackbar => .{
            .default_open_duration_ms = DURATION_SNACKBAR_OPEN_MS,
            .default_close_duration_ms = DURATION_SNACKBAR_CLOSE_MS,
            .open_easing = .ease_out_quad,
            .close_easing = .ease_out_quad,
            .default_value = 0.0,
        },
        .image_crossfade => .{
            .default_open_duration_ms = DURATION_IMAGE_DISSOLVE_MS,
            .default_close_duration_ms = DURATION_IMAGE_DISSOLVE_MS,
            .open_easing = .ease_in_out_cubic,
            .close_easing = .ease_in_out_cubic,
            .default_value = 1.0,
        },
    };
}

/// Static descriptor table indexed by channel.
pub const CHANNEL_DESCRIPTORS = [CHANNEL_COUNT]ChannelDescriptor{
    getDescriptor(.palette_reveal),
    getDescriptor(.thumb_crossfade),
    getDescriptor(.title_overlay),
    getDescriptor(.snackbar),
    getDescriptor(.image_crossfade),
};

/// Data-Oriented animation manager using flat static Structure-of-Arrays (SoA) layout.
/// Zero heap allocations, cache-friendly contiguous parallel arrays, vectorizable ticks.
pub const AnimationState = struct {
    comptime {
        std.debug.assert(CHANNEL_COUNT <= MAX_CHANNELS);
    }

    values: [MAX_CHANNELS]f32 = initValues(),
    start_vals: [MAX_CHANNELS]f32 = initValues(),
    target_vals: [MAX_CHANNELS]f32 = initValues(),
    elapsed_ms: [MAX_CHANNELS]f32 = [_]f32{0.0} ** MAX_CHANNELS,
    durations_ms: [MAX_CHANNELS]f32 = [_]f32{0.0} ** MAX_CHANNELS,
    easings: [MAX_CHANNELS]EasingType = [_]EasingType{.linear} ** MAX_CHANNELS,
    active_mask: u32 = 0,

    fn initValues() [MAX_CHANNELS]f32 {
        var vals = [_]f32{0.0} ** MAX_CHANNELS;
        inline for (std.meta.tags(AnimationChannel)) |ch| {
            vals[@intFromEnum(ch)] = getDescriptor(ch).default_value;
        }
        return vals;
    }

    /// Instant zero-branch check for AppState.isBusy() to determine if the event loop should tick.
    pub inline fn hasActiveAnimations(self: *const AnimationState) bool {
        return self.active_mask != 0;
    }

    /// Direct O(1) indexed lookup of the current animated value for `channel`.
    pub inline fn get(self: *const AnimationState, channel: AnimationChannel) f32 {
        return self.values[@intFromEnum(channel)];
    }

    /// Returns true if the specified channel is currently animating.
    pub inline fn isActive(self: *const AnimationState, channel: AnimationChannel) bool {
        return (self.active_mask & (@as(u32, 1) << @intCast(@intFromEnum(channel)))) != 0;
    }

    /// Triggers an animation on `channel` with explicit target, duration, and easing.
    pub fn trigger(
        self: *AnimationState,
        channel: AnimationChannel,
        target: f32,
        duration_ms: f32,
        easing_type: EasingType,
    ) void {
        self.start(channel, target, duration_ms, easing_type);
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
        const current_val = self.values[idx];
        if (duration_ms <= 0.0 or current_val == target) {
            self.setImmediate(channel, target);
            return;
        }

        self.start_vals[idx] = current_val;
        self.target_vals[idx] = target;
        self.elapsed_ms[idx] = 0.0;
        self.durations_ms[idx] = duration_ms;
        self.easings[idx] = easing_type;
        self.active_mask |= (@as(u32, 1) << @intCast(idx));
    }

    /// Starts an animation on `channel` with an explicit starting baseline,
    /// overriding previous value.
    pub fn startFrom(
        self: *AnimationState,
        channel: AnimationChannel,
        from_val: f32,
        target: f32,
        duration_ms: f32,
        easing_type: EasingType,
    ) void {
        const idx = @intFromEnum(channel);
        if (duration_ms <= 0.0 or from_val == target) {
            self.setImmediate(channel, target);
            return;
        }

        self.values[idx] = from_val;
        self.start_vals[idx] = from_val;
        self.target_vals[idx] = target;
        self.elapsed_ms[idx] = 0.0;
        self.durations_ms[idx] = duration_ms;
        self.easings[idx] = easing_type;
        self.active_mask |= (@as(u32, 1) << @intCast(idx));
    }

    /// Sets the value directly without animating, deactivating the channel.
    pub fn setImmediate(self: *AnimationState, channel: AnimationChannel, val: f32) void {
        const idx = @intFromEnum(channel);
        self.values[idx] = val;
        self.start_vals[idx] = val;
        self.target_vals[idx] = val;
        self.active_mask &= ~(@as(u32, 1) << @intCast(idx));
    }

    /// Immediately snaps `channel` to its target value and marks it inactive.
    pub fn settle(self: *AnimationState, channel: AnimationChannel) void {
        const idx = @intFromEnum(channel);
        self.values[idx] = self.target_vals[idx];
        self.active_mask &= ~(@as(u32, 1) << @intCast(idx));
    }

    /// Immediately snaps all active channels to their target values and marks all inactive.
    pub fn settleAll(self: *AnimationState) void {
        if (self.active_mask == 0) return;
        var mask = self.active_mask;
        while (mask != 0) {
            const idx = @ctz(mask);
            self.values[idx] = self.target_vals[idx];
            mask &= mask - 1;
        }
        self.active_mask = 0;
    }

    /// Ticks all active animation channels forward by `delta_ms`.
    pub fn tick(self: *AnimationState, delta_ms: f32) void {
        if (self.active_mask == 0) return;

        const safe_delta = @max(delta_ms, 0.0);
        var mask = self.active_mask;
        while (mask != 0) {
            const idx = @ctz(mask);
            const bit = @as(u32, 1) << @intCast(idx);
            mask &= ~bit;

            self.elapsed_ms[idx] += safe_delta;
            const dur = self.durations_ms[idx];
            if (self.elapsed_ms[idx] >= dur) {
                self.values[idx] = self.target_vals[idx];
                self.active_mask &= ~bit;
            } else {
                const t = self.elapsed_ms[idx] / dur;
                const factor = self.easings[idx].eval(t);
                const delta = self.target_vals[idx] - self.start_vals[idx];
                self.values[idx] = self.start_vals[idx] + delta * factor;
            }
        }
    }
};

test "AnimationState lifecycle and static SoA layout" {
    var anim = AnimationState{};

    try std.testing.expectEqual(@as(usize, MAX_CHANNELS), anim.values.len);
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
    var anim = AnimationState{};

    // Start 0.0 -> 1.0 over 100ms
    anim.start(.palette_reveal, 1.0, 100.0, .linear);
    anim.tick(40.0);
    const mid_val = anim.get(.palette_reveal);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), mid_val, 0.001);

    // Reverse mid-flight towards 0.0 over 100ms
    anim.start(.palette_reveal, 0.0, 100.0, .linear);
    const reveal_idx = @intFromEnum(AnimationChannel.palette_reveal);
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.4),
        anim.start_vals[reveal_idx],
        0.001,
    );

    // Advance 50ms: halfway from 0.4 down to 0.0 is 0.2
    anim.tick(50.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), anim.get(.palette_reveal), 0.001);
}

test "AnimationState settleAll" {
    var anim = AnimationState{};

    anim.start(.palette_reveal, 1.0, 500.0, .ease_out_cubic);
    anim.start(.thumb_crossfade, 0.8, 300.0, .linear);
    try std.testing.expect(anim.hasActiveAnimations());

    anim.settleAll();
    try std.testing.expect(!anim.hasActiveAnimations());
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), anim.get(.palette_reveal), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), anim.get(.thumb_crossfade), 0.001);
}

test "AnimationState startFrom explicit baseline" {
    var anim = AnimationState{};

    // Set initial value to 0.7
    anim.setImmediate(.palette_reveal, 0.7);
    try std.testing.expectEqual(@as(f32, 0.7), anim.get(.palette_reveal));
    try std.testing.expect(!anim.isActive(.palette_reveal));

    // startFrom should explicitly reset to 0.0 and animate to 1.0
    anim.startFrom(.palette_reveal, 0.0, 1.0, 100.0, .linear);
    try std.testing.expect(anim.isActive(.palette_reveal));
    try std.testing.expectEqual(@as(f32, 0.0), anim.get(.palette_reveal));

    // Tick 50ms (halfway)
    anim.tick(50.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), anim.get(.palette_reveal), 0.001);

    // Tick remaining 50ms (settles)
    anim.tick(50.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), anim.get(.palette_reveal), 0.001);
    try std.testing.expect(!anim.isActive(.palette_reveal));
}

test "AnimationState zero duration snapping and target equal" {
    var anim = AnimationState{};

    // Duration <= 0.0 snaps immediately without activating channel
    anim.start(.palette_reveal, 0.9, 0.0, .linear);
    try std.testing.expect(!anim.hasActiveAnimations());
    try std.testing.expectEqual(@as(f32, 0.9), anim.get(.palette_reveal));

    // Start with current == target also snaps without activating channel
    anim.start(.palette_reveal, 0.9, 100.0, .linear);
    try std.testing.expect(!anim.hasActiveAnimations());
    try std.testing.expectEqual(@as(f32, 0.9), anim.get(.palette_reveal));

    // startFrom with from == target snaps without activating
    anim.startFrom(.palette_reveal, 0.4, 0.4, 100.0, .linear);
    try std.testing.expect(!anim.hasActiveAnimations());
    try std.testing.expectEqual(@as(f32, 0.4), anim.get(.palette_reveal));
}

test "AnimationState settle single channel while other remains active" {
    var anim = AnimationState{};

    anim.start(.palette_reveal, 1.0, 200.0, .linear);
    anim.start(.thumb_crossfade, 0.5, 200.0, .linear);
    try std.testing.expect(anim.isActive(.palette_reveal));
    try std.testing.expect(anim.isActive(.thumb_crossfade));

    // Settle only palette_reveal
    anim.settle(.palette_reveal);
    try std.testing.expect(!anim.isActive(.palette_reveal));
    try std.testing.expect(anim.isActive(.thumb_crossfade));
    try std.testing.expect(anim.hasActiveAnimations());
    try std.testing.expectEqual(@as(f32, 1.0), anim.get(.palette_reveal));

    // Advance thumb_crossfade
    anim.tick(100.0);
    // 1.0 -> 0.5 halfway is 0.75
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.75),
        anim.get(.thumb_crossfade),
        0.001,
    );
    try std.testing.expect(anim.isActive(.thumb_crossfade));

    anim.tick(100.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), anim.get(.thumb_crossfade), 0.001);
    try std.testing.expect(!anim.hasActiveAnimations());
}

test "AnimationState title_overlay channel transitions" {
    var anim = AnimationState{};

    // Initial default value is 0.0 (hidden)
    try std.testing.expectEqual(@as(f32, 0.0), anim.get(.title_overlay));
    try std.testing.expect(!anim.isActive(.title_overlay));

    // Open transition (0.0 -> 1.0)
    anim.start(.title_overlay, 1.0, DURATION_TITLE_OVERLAY_OPEN_MS, .ease_out_quad);
    try std.testing.expect(anim.isActive(.title_overlay));
    try std.testing.expect(anim.hasActiveAnimations());

    // Advance 50%
    anim.tick(DURATION_TITLE_OVERLAY_OPEN_MS / 2.0);
    try std.testing.expect(anim.get(.title_overlay) > 0.4);
    try std.testing.expect(anim.get(.title_overlay) < 1.0);

    // Settle open
    anim.tick(DURATION_TITLE_OVERLAY_OPEN_MS / 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), anim.get(.title_overlay), 0.001);
    try std.testing.expect(!anim.isActive(.title_overlay));

    // Close transition (1.0 -> 0.0)
    anim.start(.title_overlay, 0.0, DURATION_TITLE_OVERLAY_CLOSE_MS, .ease_out_quad);
    anim.tick(DURATION_TITLE_OVERLAY_CLOSE_MS);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), anim.get(.title_overlay), 0.001);
    try std.testing.expect(!anim.hasActiveAnimations());
}

test "AnimationState image_crossfade channel transitions" {
    var anim = AnimationState{};

    // Initial default value is 1.0 (settled / visible)
    try std.testing.expectEqual(@as(f32, 1.0), anim.get(.image_crossfade));
    try std.testing.expect(!anim.isActive(.image_crossfade));

    // Start transition from 0.0 to 1.0 over DURATION_IMAGE_DISSOLVE_MS with .ease_in_out_cubic
    anim.startFrom(.image_crossfade, 0.0, 1.0, DURATION_IMAGE_DISSOLVE_MS, .ease_in_out_cubic);
    try std.testing.expect(anim.isActive(.image_crossfade));
    try std.testing.expect(anim.hasActiveAnimations());
    try std.testing.expectEqual(@as(f32, 0.0), anim.get(.image_crossfade));

    // Advance 50%: with ease_in_out_cubic, 50% time evaluates to exactly 0.5
    anim.tick(DURATION_IMAGE_DISSOLVE_MS / 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), anim.get(.image_crossfade), 0.001);
    try std.testing.expect(anim.isActive(.image_crossfade));

    // Advance remaining 50%: settles at 1.0
    anim.tick(DURATION_IMAGE_DISSOLVE_MS / 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), anim.get(.image_crossfade), 0.001);
    try std.testing.expect(!anim.isActive(.image_crossfade));
    try std.testing.expect(!anim.hasActiveAnimations());
}
