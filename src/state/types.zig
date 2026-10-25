const intents = @import("intents");
const sdl = @import("sdl");
const std = @import("std");
const view_transform = @import("view_transform.zig");

const Key = intents.Key;
const KeyModifiers = intents.KeyModifiers;

pub const PositiveDimsU32 = intents.PositiveDimsU32;
pub const ZoomPreset = intents.ZoomPreset;

/// Display DPI scale factor mapping between logical UI points and physical
/// framebuffer pixels (`physical = logical * scale`).
pub const DpiScale = struct {
    x: f32 = 1.0,
    y: f32 = 1.0,

    /// Returns a sanitized `DpiScale` where non-positive or non-finite scale
    /// axes fall back to `1.0`.
    pub inline fn init(scale_x: f32, scale_y: f32) DpiScale {
        return .{
            .x = if (scale_x > 0.0 and std.math.isFinite(scale_x))
                scale_x
            else
                1.0,
            .y = if (scale_y > 0.0 and std.math.isFinite(scale_y))
                scale_y
            else
                1.0,
        };
    }
};

/// 2D width and height expressed in logical UI points (Clay layout space).
pub const LogicalDims = struct {
    w: f32 = 0.0,
    h: f32 = 0.0,

    /// Converts logical dimensions into physical framebuffer pixel dimensions
    /// using the display `DpiScale`.
    pub inline fn toPhysical(self: LogicalDims, scale: DpiScale) PhysicalDims {
        const s = DpiScale.init(scale.x, scale.y);
        return .{
            .w = self.w * s.x,
            .h = self.h * s.y,
        };
    }
};

/// 2D width and height expressed in physical framebuffer or image texel pixels.
pub const PhysicalDims = struct {
    w: f32 = 0.0,
    h: f32 = 0.0,

    /// Returns a `PhysicalDims` only when both `w` and `h` are strictly
    /// positive and finite, or `null` otherwise.
    pub inline fn initPositive(w: f32, h: f32) ?PhysicalDims {
        if (w > 0.0 and h > 0.0 and
            std.math.isFinite(w) and std.math.isFinite(h))
        {
            return .{ .w = w, .h = h };
        }
        return null;
    }

    /// Converts strictly positive finite physical dimensions to integer pixel
    /// dimensions, or returns `null` if either axis is non-positive or
    /// non-finite.
    pub inline fn toPositiveU32(self: PhysicalDims) ?PositiveDimsU32 {
        const valid = initPositive(self.w, self.h) orelse return null;
        const max_dim: f32 = @floatFromInt(std.math.maxInt(u24));
        const w_u32: u32 = @intFromFloat(@min(valid.w, max_dim));
        const h_u32: u32 = @intFromFloat(@min(valid.h, max_dim));
        if (w_u32 == 0 or h_u32 == 0) return null;
        return .{ .w = w_u32, .h = h_u32 };
    }

    /// Converts physical pixel dimensions into logical UI point dimensions
    /// using the display `DpiScale`.
    pub inline fn toLogical(self: PhysicalDims, scale: DpiScale) LogicalDims {
        const s = DpiScale.init(scale.x, scale.y);
        return .{
            .w = self.w / s.x,
            .h = self.h / s.y,
        };
    }
};

/// 2D coordinates or offset expressed in logical UI points (SDL window / Clay
/// layout space).
pub const LogicalPoint = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,

    /// Converts a logical UI point into physical framebuffer pixel coordinates
    /// using the display `DpiScale`.
    pub inline fn toPhysical(
        self: LogicalPoint,
        scale: DpiScale,
    ) PhysicalPoint {
        const s = DpiScale.init(scale.x, scale.y);
        return .{
            .x = self.x * s.x,
            .y = self.y * s.y,
        };
    }
};

/// 2D coordinates or offset expressed in physical framebuffer pixels.
pub const PhysicalPoint = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,

    /// Converts physical framebuffer pixel coordinates into a logical UI point
    /// using the display `DpiScale`.
    pub inline fn toLogical(self: PhysicalPoint, scale: DpiScale) LogicalPoint {
        const s = DpiScale.init(scale.x, scale.y);
        return .{
            .x = self.x / s.x,
            .y = self.y / s.y,
        };
    }
};

/// Complete per-quad render descriptor specifying UV sub-rectangles, alpha,
/// rotation, and dynamic geometry overrides for rendering and transitions.
pub const UvRect = struct {
    u_min: f32 = 0.0,
    v_min: f32 = 0.0,
    u_max: f32 = 1.0,
    v_max: f32 = 1.0,
    alpha: f32 = 1.0,
    rotation_angle: ?f32 = null,
    override_zoom: ?f32 = null,
    override_pan_x: ?f32 = null,
    override_pan_y: ?f32 = null,
    source_w: ?f32 = null,
    source_h: ?f32 = null,
};

/// Pre-discovered byte offsets and compression parameters for O(1) instant seeking
/// in ZIP/CBZ archives.
pub const ZipSeekOffsets = struct {
    header_zip_offset: u64,
    file_offset: u64,
    uncompressed_size: u64,
    compression_method: std.zip.CompressionMethod,
};

/// Tagged union representing indexing status of an archive media entry.
pub const ArchiveSeekInfo = union(enum) {
    unindexed,
    indexed: ZipSeekOffsets,
};

/// Media entry descriptor for an image stored inside a compressed or uncompressed
/// archive (CBZ, CBR, ZIP).
pub const ArchiveMediaEntry = struct {
    archive_path: []const u8,
    entry_name: []const u8,
    seek_info: ArchiveSeekInfo = .unindexed,
};

/// Target stream selection for stacked RAW+JPEG file pairs.
pub const PairStreamTarget = enum {
    adaptive,
    raw_preview,
    standalone_jpeg,
};

/// Holds paths to paired RAW and JPEG files sharing the same base stem.
pub const FilePair = struct {
    raw_path: []const u8,
    jpeg_path: []const u8,
};

/// Discriminated union representing either a filesystem path, a virtual entry inside
/// an archive, or a stacked RAW+JPEG file pair.
pub const MediaEntry = union(enum) {
    /// Standard file on local filesystem
    filesystem: struct {
        path: []const u8,
    },

    /// Virtual file entry inside an archive (CBZ, CBR, ZIP)
    archive_entry: ArchiveMediaEntry,

    /// Stacked RAW and companion JPEG file pair
    pair: FilePair,

    /// Returns the leaf filename of the media entry (file basename or archive entry basename).
    pub fn getBasename(self: MediaEntry) []const u8 {
        return switch (self) {
            .filesystem => |f| std.Io.Dir.path.basename(f.path),
            .archive_entry => |a| std.Io.Dir.path.basename(a.entry_name),
            .pair => |p| std.Io.Dir.path.basename(p.raw_path),
        };
    }

    /// Returns the directory containing this media file or archive container.
    pub fn getContainerName(self: MediaEntry) []const u8 {
        const raw_dir = switch (self) {
            .filesystem => |f| f.path,
            .archive_entry => |a| a.archive_path,
            .pair => |p| p.raw_path,
        };
        return std.Io.Dir.path.dirname(raw_dir) orelse ".";
    }

    /// Returns the file path or archive internal member path string.
    pub fn getPath(self: MediaEntry) []const u8 {
        return switch (self) {
            .filesystem => |f| f.path,
            .archive_entry => |a| a.entry_name,
            .pair => |p| p.raw_path,
        };
    }

    /// Returns the filesystem source path (or containing archive path for
    /// `.archive_entry`) suitable for reopening or refreshing on disk.
    pub fn getSourcePath(self: MediaEntry) []const u8 {
        return switch (self) {
            .filesystem => |f| f.path,
            .archive_entry => |a| a.archive_path,
            .pair => |p| p.raw_path,
        };
    }

    /// Returns `true` if this media item resides inside an archive container (e.g. CBZ).
    pub fn isArchive(self: MediaEntry) bool {
        return self == .archive_entry;
    }

    /// Returns `true` if this media item is a stacked RAW + JPEG pair.
    pub fn isPair(self: MediaEntry) bool {
        return self == .pair;
    }

    /// Returns the raw file path if this is a pair, or null.
    pub fn getRawPath(self: MediaEntry) ?[]const u8 {
        return switch (self) {
            .pair => |p| p.raw_path,
            .filesystem, .archive_entry => null,
        };
    }

    /// Returns the companion JPEG file path if this is a pair, or null.
    pub fn getJpegPath(self: MediaEntry) ?[]const u8 {
        return switch (self) {
            .pair => |p| p.jpeg_path,
            .filesystem, .archive_entry => null,
        };
    }

    /// Compares two path strings, normalizing any leading `"./"` prefix.
    pub fn pathsMatch(path: []const u8, target: []const u8) bool {
        if (std.mem.eql(u8, path, target)) return true;
        const p = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
        const t = if (std.mem.startsWith(u8, target, "./"))
            target[2..]
        else
            target;
        return std.mem.eql(u8, p, t);
    }

    /// Returns `true` if this media entry matches `target_path` (accounting for
    /// `./` prefixes and matching either member of a RAW+JPEG `.pair`).
    pub fn matchesTarget(self: MediaEntry, target_path: []const u8) bool {
        return switch (self) {
            .filesystem => |f| pathsMatch(f.path, target_path),
            .archive_entry => |a| pathsMatch(a.archive_path, target_path),
            .pair => |p| pathsMatch(p.raw_path, target_path) or
                pathsMatch(p.jpeg_path, target_path),
        };
    }

    /// Deeply duplicates string paths belonging to this media entry using `allocator`.
    pub fn dupe(self: MediaEntry, allocator: std.mem.Allocator) !MediaEntry {
        return switch (self) {
            .filesystem => |f| .{
                .filesystem = .{ .path = try allocator.dupe(u8, f.path) },
            },
            .archive_entry => |a| .{
                .archive_entry = .{
                    .archive_path = try allocator.dupe(u8, a.archive_path),
                    .entry_name = try allocator.dupe(u8, a.entry_name),
                    .seek_info = a.seek_info,
                },
            },
            .pair => |p| blk: {
                const raw = try allocator.dupe(u8, p.raw_path);
                errdefer allocator.free(raw);
                const jpeg = try allocator.dupe(u8, p.jpeg_path);
                break :blk .{
                    .pair = .{
                        .raw_path = raw,
                        .jpeg_path = jpeg,
                    },
                };
            },
        };
    }

    /// Frees allocated path strings for this media entry.
    pub fn deinit(self: MediaEntry, allocator: std.mem.Allocator) void {
        switch (self) {
            .filesystem => |f| allocator.free(f.path),
            .archive_entry => |a| {
                allocator.free(a.archive_path);
                allocator.free(a.entry_name);
            },
            .pair => |p| {
                allocator.free(p.raw_path);
                allocator.free(p.jpeg_path);
            },
        }
    }
};

pub const Classification = intents.Classification;
pub const ViewMode = intents.ViewMode;

/// Tagged union representing the visibility state of the current view.
/// Distinguishes empty directories, active filtered empty states, and valid image selections.
pub const VisibleState = union(enum) {
    /// No images discovered or loaded in the current directory.
    empty_directory,
    /// Filter mode active with zero matching images, preventing the stuck loading screen bug.
    filtered_empty: struct {
        mode: ViewMode,
        total_count: usize,
    },
    /// A visible image is actively selected.
    selected: struct {
        raw_index: usize,
        visible_index: usize,
        visible_count: usize,
        total_count: usize,
        classification: Classification,
    },
};

/// Type-safe zoom factor wrapper protecting against zero-initialization,
/// division-by-zero, and NaN.
pub const ZoomFactor = struct {
    value: f32 = 1.0,

    pub const MIN: f32 = 0.001;
    pub const MAX: f32 = 100.0;

    /// Initializes a sanitized zoom factor clamped to [MIN, MAX], defaulting to
    /// 1.0 on invalid or non-positive input.
    pub fn init(raw: f32) ZoomFactor {
        if (std.math.isNan(raw) or raw <= 0.0) {
            return .{ .value = 1.0 };
        }
        return .{ .value = std.math.clamp(raw, MIN, MAX) };
    }

    /// Returns the active zoom scalar, guaranteed to be positive and non-NaN.
    pub fn get(self: ZoomFactor) f32 {
        if (self.value <= 0.0 or std.math.isNan(self.value)) {
            return 1.0;
        }
        return self.value;
    }

    /// Computes the ratio of `new_zoom` relative to `self`.
    pub fn ratioTo(self: ZoomFactor, new_zoom: ZoomFactor) f32 {
        return new_zoom.get() / self.get();
    }
};

/// Dynamic zoom policy controlling automatic window-fitting vs static manual
/// inspection.
pub const ZoomMode = enum {
    fit, // Dynamic: Z tracks min(V_w / W_rot, V_h / H_rot)
    fill, // Dynamic: Z tracks max(V_w / W_rot, V_h / H_rot)
    manual, // Static:  Z is user-defined, pan is user-defined
};

/// Dynamic viewport display, scaling, pan offset, and color adjustment
/// parameters.
pub const ViewportParams = struct {
    mode: ZoomMode = .fit,
    fit_mode: ZoomPreset = .full,
    scale_filter: intents.TextureScaleMode = .linear,
    zoom_factor: ZoomFactor = .{},
    pan_x: f32 = 0.0,
    pan_y: f32 = 0.0,
    rotation_angle: f32 = 0.0,
    edits: ImageEdits = .{},
    compare_original: bool = false,

    /// Resets zoom factor, pan offsets, and comparison mode back to default
    /// center positioning.
    pub fn reset(self: *ViewportParams) void {
        self.mode = if (self.fit_mode == .none)
            .manual
        else if (self.fit_mode.isFill())
            .fill
        else
            .fit;
        self.zoom_factor = .{ .value = 1.0 };
        self.pan_x = 0.0;
        self.pan_y = 0.0;
        self.compare_original = false;
    }

    /// Explicitly assigns the pan offset coordinates.
    pub fn setPan(self: *ViewportParams, px: f32, py: f32) void {
        self.pan_x = px;
        self.pan_y = py;
    }

    /// Displaces current pan offsets by relative delta increments (`dx`, `dy`).
    pub fn panBy(self: *ViewportParams, dx: f32, dy: f32) void {
        self.pan_x += dx;
        self.pan_y += dy;
    }

    /// Returns the effective physical zoom factor Z for the current frame.
    pub fn effectiveZoom(
        self: ViewportParams,
        view_w: f32,
        view_h: f32,
        raw_w: f32,
        raw_h: f32,
    ) f32 {
        if (raw_w <= 0.0 or raw_h <= 0.0 or view_w <= 0.0 or view_h <= 0.0) {
            return self.zoom_factor.get();
        }
        return switch (self.mode) {
            .fit => view_transform.computePresetZoom(
                raw_w,
                raw_h,
                self.rotation_angle,
                view_w,
                view_h,
                self.fit_mode,
            ),
            .fill => view_transform.computePresetZoom(
                raw_w,
                raw_h,
                self.rotation_angle,
                view_w,
                view_h,
                .crop,
            ),
            .manual => self.zoom_factor.get(),
        };
    }

    /// Returns true if image content overflows the viewport bounds.
    pub fn isOverflowing(
        self: ViewportParams,
        auth_w: f32,
        auth_h: f32,
        view_w: f32,
        view_h: f32,
    ) bool {
        if (auth_w <= 0.0 or auth_h <= 0.0 or view_w <= 0.0 or view_h <= 0.0) {
            return false;
        }
        const is_swapped = view_transform.isAngle90or270(self.rotation_angle);
        const img_w = if (is_swapped) auth_h else auth_w;
        const img_h = if (is_swapped) auth_w else auth_h;
        const z = self.effectiveZoom(view_w, view_h, auth_w, auth_h);
        return (img_w * z > view_w + 1.0) or (img_h * z > view_h + 1.0);
    }

    /// Returns true if non-neutral photographic exposure or contrast
    /// adjustments are applied.
    pub fn hasAdjustments(self: ViewportParams) bool {
        return self.edits.hasEdits();
    }

    /// Toggles Before/After comparison mode (original unadjusted image vs
    /// active adjustments). If no adjustments are applied, comparison mode
    /// remains inactive.
    pub fn toggleCompare(self: *ViewportParams) void {
        if (!self.hasAdjustments()) {
            self.compare_original = false;
            return;
        }
        self.compare_original = !self.compare_original;
    }

    /// Sets brightness in [-1.0, 1.0] and contrast in [0.0, 3.0].
    pub fn setAdjustments(self: *ViewportParams, br: f32, co: f32) void {
        self.edits.set(.brightness, br);
        self.edits.set(.contrast, co);
        self.compare_original = false;
    }

    /// Adjusts brightness by adding `delta`.
    pub fn adjustBrightness(self: *ViewportParams, delta: f32) void {
        self.edits.set(.brightness, self.edits.get(.brightness) + delta);
        self.compare_original = false;
    }

    /// Adjusts contrast by adding `delta`.
    pub fn adjustContrast(self: *ViewportParams, delta: f32) void {
        self.edits.set(.contrast, self.edits.get(.contrast) + delta);
        self.compare_original = false;
    }

    /// Rotates the viewport clockwise by 90 degrees with 360-degree
    /// normalization.
    pub fn rotateCw(self: *ViewportParams) void {
        var val = self.rotation_angle + 90.0;
        if (val >= 360.0) val -= 360.0;
        self.rotation_angle = val;
    }

    /// Rotates the viewport counter-clockwise by 90 degrees with 360-degree
    /// normalization.
    pub fn rotateCcw(self: *ViewportParams) void {
        var val = self.rotation_angle - 90.0;
        if (val < 0.0) val += 360.0;
        self.rotation_angle = val;
    }

    /// Zooms viewport to a new zoom factor while anchoring pan offsets relative
    /// to a physical framebuffer focus point and viewport center.
    pub fn zoomAtPoint(
        self: *ViewportParams,
        new_zoom: ZoomFactor,
        focus: PhysicalPoint,
        center: PhysicalPoint,
    ) void {
        self.mode = .manual;
        const old_zoom = self.zoom_factor;
        self.zoom_factor = new_zoom;
        const ratio = old_zoom.ratioTo(new_zoom);
        const rel_x = focus.x - center.x;
        const rel_y = focus.y - center.y;
        self.pan_x = rel_x - (rel_x - self.pan_x) * ratio;
        self.pan_y = rel_y - (rel_y - self.pan_y) * ratio;
    }

    /// Returns the integer uniform constant representing the active resampler
    /// filter for shader pipelines.
    pub fn getShaderScaleModeInt(self: ViewportParams) i32 {
        return switch (self.scale_filter) {
            .nearest => 0,
            .linear => 1,
            .pixel_art => 2,
            .mitchell => 3,
            .lanczos3 => 4,
            .fsr => 5,
            .tiny_cnn => 6,
        };
    }

    /// Returns true if viewport is zoomed or panned away from default
    /// fit-to-window view.
    pub inline fn isZoomed(self: ViewportParams) bool {
        return self.mode != .fit or self.pan_x != 0.0 or self.pan_y != 0.0;
    }
};

/// 4-bit directional bitmask for zero-allocation navigation tracking.
pub const DirectionFlags = packed struct(u4) {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,

    pub inline fn raw(self: DirectionFlags) u4 {
        return @backingInt(self);
    }

    pub inline fn fromRaw(val: u4) DirectionFlags {
        return @fromBackingInt(val);
    }

    pub inline fn hasAny(self: DirectionFlags) bool {
        return self.raw() != 0;
    }

    pub inline fn merge(
        self: DirectionFlags,
        other: DirectionFlags,
    ) DirectionFlags {
        return @fromBackingInt(self.raw() | other.raw());
    }
};

/// Dynamic state tracking for smooth directional keyboard viewport panning.
pub const PanController = struct {
    smooth_tap_remaining: f32 = 0.0,
    tap_direction: DirectionFlags = .{},
    prev_held: DirectionFlags = .{},
    suppressed_held: DirectionFlags = .{},

    pub const TAP_DISTANCE: f32 = 30.0;
    pub const GLIDE_SPEED: f32 = 800.0; // Physical pixels per second

    pub inline fn clearMotion(self: *PanController) void {
        self.smooth_tap_remaining = 0.0;
        self.tap_direction = .{};
        self.prev_held = .{};
    }

    pub inline fn reset(self: *PanController) void {
        self.clearMotion();
        self.suppressed_held = .{};
    }

    pub inline fn suppress(self: *PanController, held: DirectionFlags) void {
        self.clearMotion();
        self.suppressed_held = held;
    }

    pub inline fn isBusy(self: PanController) bool {
        return self.smooth_tap_remaining > 0.001 or self.prev_held.hasAny();
    }
};

/// Cardinal zoom direction for keyboard zooming.
pub const ZoomDirection = enum(u2) {
    none = 0,
    in = 1,
    out = 2,
};

/// 2-bit zoom direction bitmask for zero-allocation state tracking.
pub const ZoomFlags = packed struct(u2) {
    in: bool = false,
    out: bool = false,

    pub inline fn raw(self: ZoomFlags) u2 {
        return @backingInt(self);
    }

    pub inline fn fromRaw(val: u2) ZoomFlags {
        return @fromBackingInt(val);
    }

    pub inline fn hasAny(self: ZoomFlags) bool {
        return self.raw() != 0;
    }

    pub inline fn merge(self: ZoomFlags, other: ZoomFlags) ZoomFlags {
        return @fromBackingInt(self.raw() | other.raw());
    }
};

/// Dynamic state tracking for smooth keyboard viewport zooming.
pub const ZoomController = struct {
    smooth_tap_remaining: f32 = 0.0,
    tap_direction: ZoomDirection = .none,
    prev_held: ZoomFlags = .{},
    suppressed_held: ZoomFlags = .{},
    detent_pause_ms: f32 = 0.0,
    detent_target: ?f32 = null,

    pub const TAP_STEP_RATIO: f32 = 1.25;
    pub const TAP_LOG_DISTANCE: f32 = 0.22314355; // @log(1.25)
    pub const GLIDE_RATE: f32 = 1.5; // Log units/sec (~4.5x per sec on hold)
    pub const DETENT_PAUSE_MS: f32 = 150.0; // 150ms detent pause at 1.0x

    pub inline fn clearMotion(self: *ZoomController) void {
        self.smooth_tap_remaining = 0.0;
        self.tap_direction = .none;
        self.prev_held = .{};
        self.detent_pause_ms = 0.0;
        self.detent_target = null;
    }

    pub inline fn reset(self: *ZoomController) void {
        self.clearMotion();
        self.suppressed_held = .{};
    }

    pub inline fn suppress(self: *ZoomController, held: ZoomFlags) void {
        self.clearMotion();
        self.suppressed_held = held;
    }

    pub inline fn isBusy(self: ZoomController) bool {
        return self.smooth_tap_remaining > 0.0001 or
            self.prev_held.hasAny() or
            self.detent_pause_ms > 0.001;
    }

    pub fn triggerTap(
        self: *ZoomController,
        dir: ZoomDirection,
        current_zoom: f32,
    ) void {
        if (dir == .none) return;
        self.tap_direction = dir;
        self.smooth_tap_remaining = TAP_LOG_DISTANCE;
        const factor: f32 = if (dir == .in)
            TAP_STEP_RATIO
        else
            (1.0 / TAP_STEP_RATIO);
        const projected = current_zoom * factor;
        if (dir == .in and current_zoom < 1.0 and projected >= 1.0) {
            self.detent_target = 1.0;
        } else if (dir == .out and current_zoom > 1.0 and projected <= 1.0) {
            self.detent_target = 1.0;
        } else {
            self.detent_target = null;
        }
    }
};

/// Aggregated input events, mouse coordinates, keyboard actions, and window
/// metrics for a single frame iteration.
pub const FrameInput = struct {
    win_w: f32,
    win_h: f32,
    scale_x: f32,
    scale_y: f32,
    mouse_x: f32,
    mouse_y: f32,
    mouse_left_down: bool,
    mouse_left_clicked: bool,
    mouse_inside: bool,
    quit_requested: bool,
    scroll_delta_x: f32,
    scroll_delta_y: f32,
    pinch_delta: f32 = 0.0,
    pinch_center_x: f32 = 0.0,
    pinch_center_y: f32 = 0.0,
    keys_pressed: std.ArrayList(Key),
    key_modifiers: KeyModifiers,
    directional_held: DirectionFlags = .{},
    zoom_held: ZoomFlags = .{},
    text_input: ?[]const u8,
    dropped_path: ?[]const u8,
    ticks: u64,
    delta_time_ms: f32,
    is_pointer_in_debug_panel: bool = false,

    /// Returns the sanitized display DPI scale factor for this frame.
    pub inline fn dpiScale(self: FrameInput) DpiScale {
        return DpiScale.init(self.scale_x, self.scale_y);
    }

    /// Returns the window dimensions in logical UI points.
    pub inline fn logicalWinDims(self: FrameInput) LogicalDims {
        return .{ .w = self.win_w, .h = self.win_h };
    }

    /// Returns the mouse cursor coordinates in logical UI points.
    pub inline fn logicalMousePos(self: FrameInput) LogicalPoint {
        return .{ .x = self.mouse_x, .y = self.mouse_y };
    }

    /// Returns the mouse cursor coordinates scaled to physical framebuffer
    /// pixels.
    pub inline fn physicalMousePos(self: FrameInput) PhysicalPoint {
        return self.logicalMousePos().toPhysical(self.dpiScale());
    }

    /// Returns the mouse X coordinate scaled to physical framebuffer pixels.
    pub inline fn pixMouseX(self: FrameInput) f32 {
        return self.physicalMousePos().x;
    }

    /// Returns the mouse Y coordinate scaled to physical framebuffer pixels.
    pub inline fn pixMouseY(self: FrameInput) f32 {
        return self.physicalMousePos().y;
    }

    /// Returns `true` if the cursor is positioned within Clay's debug sidebar
    /// panel.
    pub fn isPointerInDebugPanel(self: FrameInput) bool {
        return self.is_pointer_in_debug_panel;
    }
};

/// Metadata describing an action executable from the Command Palette,
/// including its shortcut and intent.
pub const ActionMetadata = intents.actions.ActionMetadata;

/// Command Palette items projected from the unified action registry.
pub const palette_action_items = intents.actions.palette_action_items;

/// Flattened keyboard shortcut entry mapping a specific key and modifier
/// combination directly to an AppIntent.
pub const FlatShortcut = intents.actions.FlatShortcut;

/// Flattened keyboard shortcuts projected from the unified action registry.
pub const flat_shortcuts = intents.actions.flat_shortcuts;

/// Unique identification tags for interactive Clay UI layout elements.
pub const ElementTag = enum(usize) {
    none = 0,
    image_viewer = 1,
    drop_zone_box = 2,
    blurred_surface = 3,

    /// Converts element tag enum to raw integer index.
    pub fn toInt(self: ElementTag) usize {
        return @backingInt(self);
    }

    /// Converts raw integer index to corresponding `ElementTag` enum variant.
    pub fn fromInt(val: usize) ElementTag {
        return switch (val) {
            1 => .image_viewer,
            2 => .drop_zone_box,
            3 => .blurred_surface,
            else => .none,
        };
    }
};

/// Title display visibility modes, unifying permanent pinned display and transient auto-hide timer.
pub const TitleDisplay = union(enum) {
    hidden,
    pinned,
    transient: struct {
        timeout_ms: u64,
    },

    pub fn isPinned(self: TitleDisplay) bool {
        return self == .pinned;
    }
};

/// Target parameter identifier for image editing controls and sliders.
pub const EditParam = intents.EditParam;

/// Logical grouping domain for photographic editing parameters.
pub const EditDomain = enum(u2) {
    tone = 0,
    color = 1,
    presence = 2,
};

/// Descriptor configuring metadata, bounds, stepping, and formatting for
/// an image adjustment parameter.
pub const ParamDescriptor = struct {
    param: EditParam,
    domain: EditDomain,
    name: []const u8,
    label: []const u8,
    min: f32,
    max: f32,
    default: f32,
    step: f32,
    snap_radius: f32,
    display_kind: DisplayKind,

    pub const DisplayKind = enum {
        percent,
        multiplier,
        temperature,
        tint,
        ratio_percent,
    };

    pub fn clamp(self: ParamDescriptor, val: f32) f32 {
        if (std.math.isNan(val) or std.math.isInf(val)) return self.default;
        return std.math.clamp(val, self.min, self.max);
    }

    pub fn snap(self: ParamDescriptor, val: f32) f32 {
        if (@abs(val - self.default) < self.snap_radius) {
            return self.default;
        }
        return self.clamp(val);
    }
};

/// Static compile-time table of descriptors for all photographic parameters.
pub const descriptors = [EditParam.count]ParamDescriptor{
    .{
        .param = .brightness,
        .domain = .tone,
        .name = "brightness",
        .label = "Exposure",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
    },
    .{
        .param = .contrast,
        .domain = .tone,
        .name = "contrast",
        .label = "Contrast",
        .min = 0.0,
        .max = 3.0,
        .default = 1.0,
        .step = 0.05,
        .snap_radius = 0.035,
        .display_kind = .multiplier,
    },
    .{
        .param = .contrast_blend,
        .domain = .tone,
        .name = "contrast_blend",
        .label = "Contrast Blend",
        .min = 0.0,
        .max = 1.0,
        .default = 1.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .ratio_percent,
    },
    .{
        .param = .highlights,
        .domain = .tone,
        .name = "highlights",
        .label = "Highlights",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
    },
    .{
        .param = .shadows,
        .domain = .tone,
        .name = "shadows",
        .label = "Shadows",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
    },
    .{
        .param = .whites,
        .domain = .tone,
        .name = "whites",
        .label = "Whites",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
    },
    .{
        .param = .blacks,
        .domain = .tone,
        .name = "blacks",
        .label = "Blacks",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
    },
    .{
        .param = .temperature,
        .domain = .color,
        .name = "temperature",
        .label = "Temperature",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .temperature,
    },
    .{
        .param = .tint,
        .domain = .color,
        .name = "tint",
        .label = "Tint",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .tint,
    },
    .{
        .param = .vibrance,
        .domain = .color,
        .name = "vibrance",
        .label = "Vibrance",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
    },
    .{
        .param = .saturation,
        .domain = .color,
        .name = "saturation",
        .label = "Saturation",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
    },
    .{
        .param = .clarity,
        .domain = .presence,
        .name = "clarity",
        .label = "Clarity",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
    },
    .{
        .param = .texture,
        .domain = .presence,
        .name = "texture",
        .label = "Texture",
        .min = -1.0,
        .max = 1.0,
        .default = 0.0,
        .step = 0.05,
        .snap_radius = 0.025,
        .display_kind = .percent,
    },
};

comptime {
    for (0..descriptors.len) |i| {
        const p: EditParam = @fromBackingInt(@intCast(i));
        std.debug.assert(descriptors[i].param == p);
        std.debug.assert(descriptors[i].min < descriptors[i].max);
        std.debug.assert(descriptors[i].default >= descriptors[i].min);
        std.debug.assert(descriptors[i].default <= descriptors[i].max);
    }
}

/// Returns the ParamDescriptor definition for the given EditParam.
pub inline fn getDescriptor(param: EditParam) ParamDescriptor {
    return descriptors[@backingInt(param)];
}

/// Element identifiers for Clay layout slider elements.
pub const SliderElementNames = struct {
    track: []const u8,
    reset: []const u8,
    knob: []const u8,
};

/// Returns element ID strings for the slider track, reset button, and knob.
pub fn getSliderElementNames(param: EditParam) SliderElementNames {
    return switch (param) {
        .brightness => .{
            .track = "SliderTrack_Brightness",
            .reset = "SliderReset_Brightness",
            .knob = "SliderKnob_Brightness",
        },
        .contrast => .{
            .track = "SliderTrack_Contrast",
            .reset = "SliderReset_Contrast",
            .knob = "SliderKnob_Contrast",
        },
        .contrast_blend => .{
            .track = "SliderTrack_ContrastBlend",
            .reset = "SliderReset_ContrastBlend",
            .knob = "SliderKnob_ContrastBlend",
        },
        .highlights => .{
            .track = "SliderTrack_Highlights",
            .reset = "SliderReset_Highlights",
            .knob = "SliderKnob_Highlights",
        },
        .shadows => .{
            .track = "SliderTrack_Shadows",
            .reset = "SliderReset_Shadows",
            .knob = "SliderKnob_Shadows",
        },
        .whites => .{
            .track = "SliderTrack_Whites",
            .reset = "SliderReset_Whites",
            .knob = "SliderKnob_Whites",
        },
        .blacks => .{
            .track = "SliderTrack_Blacks",
            .reset = "SliderReset_Blacks",
            .knob = "SliderKnob_Blacks",
        },
        .temperature => .{
            .track = "SliderTrack_Temperature",
            .reset = "SliderReset_Temperature",
            .knob = "SliderKnob_Temperature",
        },
        .tint => .{
            .track = "SliderTrack_Tint",
            .reset = "SliderReset_Tint",
            .knob = "SliderKnob_Tint",
        },
        .vibrance => .{
            .track = "SliderTrack_Vibrance",
            .reset = "SliderReset_Vibrance",
            .knob = "SliderKnob_Vibrance",
        },
        .saturation => .{
            .track = "SliderTrack_Saturation",
            .reset = "SliderReset_Saturation",
            .knob = "SliderKnob_Saturation",
        },
        .clarity => .{
            .track = "SliderTrack_Clarity",
            .reset = "SliderReset_Clarity",
            .knob = "SliderKnob_Clarity",
        },
        .texture => .{
            .track = "SliderTrack_Texture",
            .reset = "SliderReset_Texture",
            .knob = "SliderKnob_Texture",
        },
    };
}

/// Non-destructive photographic edit parameters.
pub const ImageEdits = struct {
    values: [EditParam.count]f32 = initDefaults(),

    fn initDefaults() [EditParam.count]f32 {
        var initial: [EditParam.count]f32 = undefined;
        for (std.enums.values(EditParam)) |p| {
            initial[@backingInt(p)] = getDescriptor(p).default;
        }
        return initial;
    }

    /// Gets the current value for the specified parameter.
    pub inline fn get(self: ImageEdits, param: EditParam) f32 {
        return self.values[@backingInt(param)];
    }

    /// Clamps and sets the specified parameter value.
    pub inline fn set(self: *ImageEdits, param: EditParam, val: f32) void {
        self.values[@backingInt(param)] = getDescriptor(param).clamp(val);
    }

    /// Resets the specified parameter to its default value.
    pub inline fn resetParam(self: *ImageEdits, param: EditParam) void {
        self.values[@backingInt(param)] = getDescriptor(param).default;
    }

    /// Resets all adjustments to neutral defaults.
    pub fn reset(self: *ImageEdits) void {
        for (std.enums.values(EditParam)) |p| {
            self.values[@backingInt(p)] = getDescriptor(p).default;
        }
    }

    /// Returns true if non-neutral adjustments are applied.
    pub fn hasEdits(self: ImageEdits) bool {
        for (std.enums.values(EditParam)) |p| {
            if (p == .contrast_blend) {
                // contrast_blend only has visual impact if contrast is
                // non-neutral
                const c_def = getDescriptor(.contrast).default;
                if (@abs(self.get(.contrast) - c_def) <= 1e-5) continue;
            }
            const def = getDescriptor(p).default;
            if (@abs(self.values[@backingInt(p)] - def) > 1e-5) return true;
        }
        return false;
    }

    /// Returns true if the specific parameter is at its neutral default value.
    pub fn isParamDefault(self: ImageEdits, param: EditParam) bool {
        const def = getDescriptor(param).default;
        return @abs(self.values[@backingInt(param)] - def) <= 1e-5;
    }
};

pub const EDIT_PANEL_WIDTH: f32 = 280.0;
pub const EDIT_PANEL_PADDING: f32 = 16.0;

/// Side panel state managing visibility and active slider interactions
/// for image adjustments.
pub const EditPanelState = struct {
    visible: bool = false,
    active_slider: ?EditParam = null,
    width: f32 = EDIT_PANEL_WIDTH,
};

/// Floating HUD panel state managing visibility and user-dragged 2D offset coordinates.
pub const FloatingPanel = struct {
    visible: bool = false,
    offset_x: f32 = 0.0,
    offset_y: f32 = 0.0,
};

/// Visibility modes, floating panel positions, and rendering flags for HUD overlays.
pub const OverlayState = struct {
    info_panel: FloatingPanel = .{ .visible = false, .offset_x = 20.0, .offset_y = 20.0 },
    stats_panel: FloatingPanel = .{ .visible = false, .offset_x = -20.0, .offset_y = 20.0 },
    edit_panel: EditPanelState = .{},
    title_display: TitleDisplay = .hidden,
    auto_title: bool = true,
    debug_show_thumb: bool = false,
    enable_blur: bool = true,

    /// Returns true if any floating HUD dialogs (Info or Stats) are visible.
    pub fn hasVisibleFloatingPanels(self: OverlayState) bool {
        return self.info_panel.visible or self.stats_panel.visible;
    }

    /// Dismisses all visible floating HUD dialogs.
    /// Returns true if at least one dialog was open; false otherwise.
    pub fn dismissFloatingPanels(self: *OverlayState) bool {
        const had_visible = self.hasVisibleFloatingPanels();
        self.info_panel.visible = false;
        self.stats_panel.visible = false;
        return had_visible;
    }
};

/// Rolling window of recent frame render duration samples computing mean and standard deviation.
pub const RenderStats = struct {
    samples: [60]f64 = @splat(0.0),
    head: usize = 0,
    count: usize = 0,

    /// Records a new duration sample in milliseconds into the 60-slot rolling ring buffer.
    pub fn addSample(self: *RenderStats, sample_ms: f64) void {
        self.samples[self.head] = sample_ms;
        self.head = (self.head + 1) % 60;
        if (self.count < 60) self.count += 1;
    }

    /// Computes the arithmetic mean and sample standard deviation across all
    /// recorded duration samples.
    pub fn getMeanAndStdev(self: RenderStats) struct { mean: f64, stdev: f64 } {
        if (self.count == 0) return .{ .mean = 0.0, .stdev = 0.0 };
        var sum: f64 = 0.0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            sum += self.samples[i];
        }
        const mean = sum / @as(f64, @floatFromInt(self.count));
        if (self.count < 2) return .{ .mean = mean, .stdev = 0.0 };

        var variance_sum: f64 = 0.0;
        i = 0;
        while (i < self.count) : (i += 1) {
            const diff = self.samples[i] - mean;
            variance_sum += diff * diff;
        }
        const variance = @max(0.0, variance_sum) / @as(f64, @floatFromInt(self.count - 1));
        return .{ .mean = mean, .stdev = @sqrt(variance) };
    }
};

/// Snapshot of UI rendering timing statistics, batch counts, and vertex counts
/// for on-screen telemetry.
pub const UiRenderMetricsSnapshot = struct {
    mean_render_time_ms: f64 = 0.0,
    stdev_render_time_ms: f64 = 0.0,
    last_ui_vertex_count: usize = 0,
    last_ui_batch_count: usize = 0,
};

/// UI frame rendering performance metrics, vertex counts, batch counts, and
/// rolling duration history.
pub const UiRenderMetrics = struct {
    ui_render_stats: RenderStats = .{},
    last_ui_vertex_count: usize = 0,
    last_ui_batch_count: usize = 0,

    /// Creates an immutable performance snapshot containing calculated
    /// mean/stdev and element counts.
    pub fn toSnapshot(self: UiRenderMetrics) UiRenderMetricsSnapshot {
        const stats = self.ui_render_stats.getMeanAndStdev();
        return .{
            .mean_render_time_ms = stats.mean,
            .stdev_render_time_ms = stats.stdev,
            .last_ui_vertex_count = self.last_ui_vertex_count,
            .last_ui_batch_count = self.last_ui_batch_count,
        };
    }
};

/// RAW camera sensor metadata variant eliminating impossible states
/// (e.g. RAW flag without valid dimensions).
pub const RawMetadata = union(enum) {
    none,
    raw: struct {
        sensor_w: f32,
        sensor_h: f32,
    },

    /// Safely constructs a RawMetadata variant, guaranteeing strictly positive non-NaN dimensions.
    pub fn init(sensor_w: f32, sensor_h: f32) RawMetadata {
        if (sensor_w > 0.0 and sensor_h > 0.0 and
            !std.math.isNan(sensor_w) and !std.math.isNan(sensor_h))
        {
            return .{ .raw = .{ .sensor_w = sensor_w, .sensor_h = sensor_h } };
        }
        return .none;
    }

    /// Returns `true` if this media entry is a Camera RAW file with valid embedded preview.
    pub inline fn isRaw(self: RawMetadata) bool {
        return self == .raw;
    }

    /// Returns true sensor dimensions if RAW, or `null` if standard media format.
    pub inline fn getSensorDims(self: RawMetadata) ?PhysicalDims {
        return switch (self) {
            .raw => |r| if (r.sensor_w > 0.0 and r.sensor_h > 0.0)
                .{ .w = r.sensor_w, .h = r.sensor_h }
            else
                null,
            .none => null,
        };
    }
};

/// Decoded CPU software surface stored in host RAM along with image
/// dimensions and decompression timing.
pub const CpuSurfaceComponent = struct {
    surface: sdl.Surface,
    w: f32,
    h: f32,
    size_bytes: u64,
    mime_type: []const u8 = "",
    read_time_ms: f64 = 0.0,
    decode_time_ms: f64 = 0.0,
    conversion_time_ms: f64 = 0.0,
    cbz_decompress_time_ms: f64 = 0.0,
    compressed_size_bytes: usize = 0,
};

/// Resident GPU texture allocation and VRAM memory footprint metadata uploaded
/// to the graphics device.
pub const GpuTextureComponent = struct {
    gpu_texture: sdl.gpu.Texture,
    w: f32,
    h: f32,
    size_bytes: u64,
    mime_type: []const u8 = "",
    read_time_ms: f64 = 0.0,
    decode_time_ms: f64 = 0.0,
    conversion_time_ms: f64 = 0.0,
    upload_time_ms: f64 = 0.0,
    memory_size_bytes: usize,
    num_mip_levels: u32 = 1,
    mipmap_time_ms: f64 = 0.0,
    was_fallback: bool = false,
    fallback_time_ms: f64 = 0.0,
    cbz_decompress_time_ms: f64 = 0.0,
    compressed_size_bytes: usize = 0,
};

/// State lifecycle of an image in the cache (decoding, loaded in RAM,
/// resident in VRAM, uploading, failed).
pub const CacheStatus = union(enum) {
    decoding: struct {
        has_thread: bool = false,
        start_time_ms: u64 = 0,
    },
    loaded_cpu: CpuSurfaceComponent,
    loaded_gpu: GpuTextureComponent,
    uploading: void,
    failed: void,
};

/// Source from which a preview thumbnail was loaded.
pub const ThumbnailSource = enum {
    /// Extracted from the initial 256 KB header read (EXIF IFD1 or SubIFD).
    embedded_header,
    /// Extracted via positional read at an offset beyond the 256 KB header.
    embedded_positional,
    /// Loaded from the Freedesktop Shared Thumbnail Cache
    /// (`$XDG_CACHE_HOME/thumbnails/`).
    freedesktop_cache,

    /// Returns `true` if the thumbnail bitmap is already rotated into upright
    /// visual orientation on disk (true for Freedesktop cached PNGs, false for
    /// unrotated embedded EXIF thumbnails).
    pub inline fn isPreOriented(self: ThumbnailSource) bool {
        return switch (self) {
            .embedded_header, .embedded_positional => false,
            .freedesktop_cache => true,
        };
    }

    /// Short label for "Stats for Nerds" HUD rows.
    pub fn shortLabel(self: ThumbnailSource) []const u8 {
        return switch (self) {
            .embedded_header => "Header",
            .embedded_positional => "Positional",
            .freedesktop_cache => "XDG Cache",
        };
    }

    /// Descriptive label for "Info Overlay" HUD rows.
    pub fn infoLabel(self: ThumbnailSource) []const u8 {
        return switch (self) {
            .embedded_header, .embedded_positional => "Embedded",
            .freedesktop_cache => "Freedesktop",
        };
    }
};

/// Lightweight thumbnail dimension, GPU upload latency, source, and DCT block
/// snapping metadata.
pub const ThumbnailInfo = struct {
    w: f32 = 0.0,
    h: f32 = 0.0,
    upload_time_ms: f64 = 0.0,
    dct_snapped: bool = false,
    source: ThumbnailSource = .embedded_header,
};

/// State of a cached image's preview thumbnail (none, pending, not available,
/// unloaded dimensions, or uploaded GPU texture).
pub const ThumbnailState = union(enum) {
    none,
    pending,
    not_available,
    unloaded: ThumbnailInfo,
    loaded: struct {
        texture: sdl.gpu.Texture,
        info: ThumbnailInfo,
    },

    /// Extracts the thumbnail dimension and upload duration information if present.
    pub fn getInfo(self: ThumbnailState) ?ThumbnailInfo {
        return switch (self) {
            .none, .pending, .not_available => null,
            .unloaded => |info| info,
            .loaded => |l| l.info,
        };
    }
};

/// 4-state orthogonal image orientation enum (0°, 90°, 180°, 270°).
///
/// Collapses TIFF EXIF tags 1..8 into the 4 orthogonal rotation states supported by the viewer.
/// Provides branchless scalar degree conversion and dimension swap checks.
pub const Orientation = enum(u2) {
    normal = 0,
    rotate_90 = 1,
    rotate_180 = 2,
    rotate_270 = 3,

    /// Maps TIFF 6.0 / EXIF 2.32 orientation tag values (1..8) to the 4 orthogonal rotation states.
    pub fn fromTiff(val: u16) Orientation {
        return switch (val) {
            6, 7 => .rotate_90,
            3, 4 => .rotate_180,
            8, 5 => .rotate_270,
            else => .normal,
        };
    }

    /// Direct branchless arithmetic conversion to floating-point degrees: index * 90.0.
    pub inline fn toDegrees(self: Orientation) f32 {
        return @as(f32, @floatFromInt(@backingInt(self))) * 90.0;
    }

    /// Branchless bitwise check: odd indices (1 and 3) swap width and height.
    pub inline fn isDimensionSwapped(self: Orientation) bool {
        return (@backingInt(self) & 1) != 0;
    }
};

/// Cache slot structure storing image decode status, thumbnail texture,
/// full dimensions, and orientation.
pub const CacheEntry = struct {
    status: CacheStatus,
    thumbnail: ThumbnailState = .none,
    full_dims: ?PhysicalDims = null,
    orientation: Orientation = .normal,
    raw_metadata: RawMetadata = .none,
    is_promoting: bool = false,
    requested_target: ?PairStreamTarget = null,

    /// Returns the pixel width of the currently loaded surface or texture, or null if not loaded.
    pub fn getLoadedWidth(self: CacheEntry) ?f32 {
        return switch (self.status) {
            .loaded_gpu => |gpu| gpu.w,
            .loaded_cpu => |cpu| @floatFromInt(cpu.surface.w()),
            .decoding, .uploading, .failed => null,
        };
    }

    /// Returns the pixel height of the currently loaded surface or texture, or null if not loaded.
    pub fn getLoadedHeight(self: CacheEntry) ?f32 {
        return switch (self.status) {
            .loaded_gpu => |gpu| gpu.h,
            .loaded_cpu => |cpu| @floatFromInt(cpu.surface.h()),
            .decoding, .uploading, .failed => null,
        };
    }

    /// Monotonically updates the authoritative full-resolution dimensions if
    /// the candidate `(w, h)` has a larger positive finite pixel area.
    pub fn updateFullDims(self: *CacheEntry, w: f32, h: f32) void {
        const cand = PhysicalDims.initPositive(w, h) orelse return;
        const cur_area = if (self.full_dims) |cur|
            @as(f64, cur.w) * @as(f64, cur.h)
        else
            0.0;
        const cand_area = @as(f64, cand.w) * @as(f64, cand.h);
        if (cand_area > cur_area) {
            self.full_dims = cand;
        }
    }

    /// Applies probed or thumbnail metadata, monotonically upgrading
    /// authoritative and RAW sensor dimensions without clearing existing RAW
    /// state when `raw_metadata` is `.none`.
    pub fn applyProbedMetadata(
        self: *CacheEntry,
        dims: ?PhysicalDims,
        orientation: Orientation,
        raw_metadata: RawMetadata,
    ) void {
        if (orientation != .normal or self.orientation == .normal) {
            self.orientation = orientation;
        }
        if (raw_metadata.getSensorDims()) |s_dims| {
            self.updateFullDims(s_dims.w, s_dims.h);
        }
        if (dims) |d| {
            self.updateFullDims(d.w, d.h);
        }
        if (raw_metadata.isRaw() or self.raw_metadata.isRaw()) {
            if (self.full_dims) |fd| {
                self.raw_metadata = RawMetadata.init(fd.w, fd.h);
            } else if (raw_metadata.isRaw()) {
                self.raw_metadata = raw_metadata;
            }
        }
    }

    /// Returns the true physical pixel dimensions of the original image,
    /// irrespective of what downscaled preview or thumbnail is currently
    /// resident.
    pub fn getAuthoritativeDims(self: CacheEntry) PhysicalDims {
        var best: ?PhysicalDims = self.raw_metadata.getSensorDims();
        if (self.full_dims) |fd| {
            const cur_area = if (best) |b|
                @as(f64, b.w) * @as(f64, b.h)
            else
                0.0;
            const full_area = @as(f64, fd.w) * @as(f64, fd.h);
            if (full_area >= cur_area) {
                best = fd;
            }
        }
        if (best) |b| {
            return b;
        }
        switch (self.status) {
            .loaded_gpu => |gpu| {
                if (PhysicalDims.initPositive(gpu.w, gpu.h)) |d| return d;
            },
            .loaded_cpu => |cpu| {
                if (PhysicalDims.initPositive(cpu.w, cpu.h)) |d| return d;
            },
            .decoding, .uploading, .failed => {},
        }
        if (self.thumbnail.getInfo()) |info| {
            if (PhysicalDims.initPositive(info.w, info.h)) |d| {
                if (info.source.isPreOriented() and
                    self.orientation.isDimensionSwapped())
                {
                    return .{ .w = d.h, .h = d.w };
                }
                return d;
            }
        }
        return .{ .w = 0.0, .h = 0.0 };
    }

    /// Deinitializes thumbnail texture and releases any loaded CPU surface or GPU texture.
    pub fn deinit(self: *CacheEntry, gpu_device: ?sdl.gpu.Device) void {
        switch (self.thumbnail) {
            .loaded => |thumb| {
                if (gpu_device) |dev| {
                    dev.releaseTexture(thumb.texture);
                }
            },
            .none, .pending, .not_available, .unloaded => {},
        }
        self.thumbnail = .none;

        switch (self.status) {
            .loaded_cpu => |cpu| cpu.surface.destroy(),
            .loaded_gpu => |gpu| {
                if (gpu_device) |dev| {
                    dev.releaseTexture(gpu.gpu_texture);
                }
            },
            .decoding, .uploading, .failed => {},
        }
    }
};

/// Automatic slideshow playback mode, advance interval, accumulated frame timer, and pause state.
pub const SlideshowMode = union(enum) {
    inactive,
    active: struct {
        interval_s: f32,
        timer_ms: f64 = 0.0,
        is_paused: bool = false,
    },

    pub const MIN_INTERVAL_S: f32 = 0.1;
    pub const MAX_INTERVAL_S: f32 = 3600.0;

    /// Advances the internal slideshow timer by `delta_ms`; returns `true`
    /// if the interval has elapsed. Does NOT advance when paused or inactive.
    pub fn tick(self: *SlideshowMode, delta_ms: f32) bool {
        switch (self.*) {
            .inactive => return false,
            .active => |*data| {
                if (data.is_paused or data.interval_s <= 0.0) return false;
                data.timer_ms += delta_ms;
                if (data.timer_ms >= data.interval_s * 1000.0) {
                    data.timer_ms = 0.0;
                    return true;
                }
                return false;
            },
        }
    }

    /// Resets the slideshow timer accumulator to zero without changing the interval or pause state.
    pub fn resetTimer(self: *SlideshowMode) void {
        switch (self.*) {
            .inactive => {},
            .active => |*a| a.timer_ms = 0.0,
        }
    }

    /// Returns `true` if slideshow is active and currently paused.
    pub inline fn isPaused(self: *const SlideshowMode) bool {
        return switch (self.*) {
            .inactive => false,
            .active => |a| a.is_paused,
        };
    }

    /// Pauses timer accumulation without changing interval or resetting elapsed progress.
    pub fn pause(self: *SlideshowMode) void {
        switch (self.*) {
            .inactive => {},
            .active => |*a| a.is_paused = true,
        }
    }

    /// Resumes timer accumulation from its current elapsed millisecond position.
    pub fn unpause(self: *SlideshowMode) void {
        switch (self.*) {
            .inactive => {},
            .active => |*a| a.is_paused = false,
        }
    }
};

/// Active image transition payload tracking the outgoing image during a dissolve animation.
pub const ActiveImageTransition = struct {
    prev_index: usize,
    prev_rotation: f32,
    prev_zoom: f32 = 1.0,
    prev_pan_x: f32 = 0.0,
    prev_pan_y: f32 = 0.0,
};

/// Active image transition state tracking the outgoing image during a dissolve animation.
pub const ImageTransition = union(enum) {
    none,
    active: ActiveImageTransition,

    /// Returns the protected previous image index if a crossfade transition is active.
    pub inline fn getPrevIndex(self: ImageTransition) ?usize {
        return switch (self) {
            .none => null,
            .active => |t| t.prev_index,
        };
    }
};

/// Active payload for the action confirmation snackbar.
pub const ActiveSnackbar = struct {
    reveal: f32,
    message: []const u8,
};

/// Presentation state of the action confirmation snackbar in the UI view model.
pub const SnackbarDisplay = union(enum) {
    none,
    active: ActiveSnackbar,

    /// Returns the active payload if the snackbar is currently active, or null if none.
    pub inline fn getActive(self: SnackbarDisplay) ?ActiveSnackbar {
        return switch (self) {
            .none => null,
            .active => |a| a,
        };
    }
};

/// Telemetry metrics for the active image GPU/Decoder status.
pub const ActiveImageStats = struct {
    num_mip_levels: u32 = 1,
    mipmap_time_ms: f64 = 0.0,
    fallback_time_ms: f64 = 0.0,
    was_fallback: bool = false,
    has_thumb: bool = false,
    thumb_upload_time_ms: f64 = 0.0,
    thumb_source: ThumbnailSource = .embedded_header,
    cbz_decompress_time_ms: f64 = 0.0,
    compressed_size_bytes: usize = 0,
};

/// Unified telemetry counters for thumbnail extraction, shared cache reads,
/// and background shared cache writes.
pub const ThumbnailStats = struct {
    header_hits: usize = 0,
    positional_hits: usize = 0,
    cache_hits: usize = 0,
    misses: usize = 0,
    cache_writes: usize = 0,
    cache_write_queued: usize = 0,

    /// Total number of thumbnail lookup attempts across all sources and misses.
    pub inline fn totalLookups(self: ThumbnailStats) usize {
        return self.header_hits +
            self.positional_hits +
            self.cache_hits +
            self.misses;
    }
};

/// Snapshot of application telemetry and diagnostic counters copied once per frame
/// for UI rendering ("Stats for Nerds") without reading live atomics.
pub const ViewerStats = struct {
    // Unified EXIF & Freedesktop thumbnail telemetry
    thumbs: ThumbnailStats = .{},

    // Cache telemetry
    current_image_cache_hit: bool = false,
    cached_slot_count: usize = 0,
    total_vram_bytes: usize = 0,

    // Worker telemetry (frame snapshot)
    active_decode_threads: usize = 0,
    max_decode_threads: usize = 0,

    // Active image GPU & decoder stats
    active_image: ActiveImageStats = .{},
};

/// Grace period threshold in milliseconds before displaying "Loading image..." in the UI.
/// Prevents text flickering when scrubbing through thumbnails or fast-decoding
/// formats (~2 frames at 60Hz).
pub const LOADING_GRACE_PERIOD_MS: u64 = 35;

/// Claimed SDL window handle, pixel format, fullscreen state, borderless
/// state, and title string cache.
/// Invariant: Only constructed once a real `sdl.Window` has been created and
/// claimed by the GPU device.
pub const ActiveWindow = struct {
    handle: sdl.Window,
    pixel_format: u32 = sdl.PixelFormat.unknown,
    cached_title: ?[]const u8 = null,
    is_fullscreen: bool = false,
    is_borderless: bool = false,

    /// Frees the cached window title string allocation if present.
    pub fn deinit(self: *ActiveWindow, gpa: std.mem.Allocator) void {
        if (self.cached_title) |t| {
            gpa.free(t);
            self.cached_title = null;
        }
    }
};

/// Underlying display backend: either an offscreen/headless harness or a
/// GPU-claimed SDL window handle.
pub const DisplayBackend = union(enum) {
    headless,
    windowed: ActiveWindow,

    /// Releases any memory allocations held by the backend (such as window
    /// title strings).
    pub fn deinit(self: *DisplayBackend, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .headless => {},
            .windowed => |*w| w.deinit(allocator),
        }
    }
};

/// Display visibility state wrapping the underlying `DisplayBackend`
/// (`.visible` on screen vs. `.hidden` in resident `--server` mode).
pub const DisplayState = union(enum) {
    visible: DisplayBackend,
    hidden: DisplayBackend,

    /// Default headless visible display state.
    pub const default_headless: DisplayState = .{ .visible = .headless };

    /// Returns a mutable pointer to the underlying `DisplayBackend`.
    pub inline fn backendPtr(self: *DisplayState) *DisplayBackend {
        return switch (self.*) {
            .visible => |*b| b,
            .hidden => |*b| b,
        };
    }

    /// Returns the underlying `DisplayBackend` value.
    pub inline fn backend(self: DisplayState) DisplayBackend {
        return switch (self) {
            .visible, .hidden => |b| b,
        };
    }

    /// Returns `true` if the display is currently running in fullscreen mode.
    pub inline fn isFullscreen(self: DisplayState) bool {
        return switch (self.backend()) {
            .headless => false,
            .windowed => |w| w.is_fullscreen,
        };
    }

    /// Returns `true` if the display is currently hidden (e.g. resident
    /// server mode).
    pub inline fn isHidden(self: DisplayState) bool {
        return switch (self) {
            .visible => false,
            .hidden => true,
        };
    }

    /// Returns the active SDL window handle if the display is currently visible
    /// and backed by a GPU-claimed window, or `null` when headless or hidden.
    pub inline fn visibleWindow(self: DisplayState) ?sdl.Window {
        return switch (self) {
            .hidden => null,
            .visible => |b| switch (b) {
                .headless => null,
                .windowed => |w| w.handle,
            },
        };
    }

    /// Returns the swapchain texture pixel format of the display window.
    pub inline fn getPixelFormat(self: DisplayState) u32 {
        return switch (self.backend()) {
            .headless => sdl.PixelFormat.unknown,
            .windowed => |w| w.pixel_format,
        };
    }

    /// Releases any memory allocations held by the display state (such as
    /// window title strings).
    pub fn deinit(self: *DisplayState, allocator: std.mem.Allocator) void {
        self.backendPtr().deinit(allocator);
    }
};

/// Pending asynchronous screenshot request with target destination path and IPC stream.
pub const ActiveScreenshot = struct {
    path: [:0]const u8,
    stream: std.Io.net.Stream,

    /// Writes a JSON success confirmation (`{"ok":true}\n`) back to the client
    /// IPC stream and frees request resources.
    pub fn respondOk(
        self: *ActiveScreenshot,
        io: std.Io,
        gpa: std.mem.Allocator,
    ) void {
        var write_buf: [128]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);
        std.json.Stringify.value(
            .{ .ok = true },
            .{},
            &writer.interface,
        ) catch |werr| {
            std.log.warn("Screenshot response failed: {}", .{werr});
        };
        writer.interface.writeByte('\n') catch |werr| {
            std.log.warn("Screenshot newline write failed: {}", .{werr});
        };
        writer.interface.flush() catch |ferr| {
            std.log.warn("Screenshot response flush failed: {}", .{ferr});
        };
        self.stream.close(io);
        gpa.free(self.path);
    }

    /// Writes a JSON error response (`{"ok":false,"error":"<name>"}\n`) back to
    /// the client IPC stream and frees request resources.
    pub fn respondErr(
        self: *ActiveScreenshot,
        io: std.Io,
        gpa: std.mem.Allocator,
        err: anyerror,
    ) void {
        self.respondErrName(io, gpa, @errorName(err));
    }

    /// Sends an emergency `{"ok":false,"error":"quit"}\n` response to the
    /// client IPC stream when exiting unexpectedly.
    pub fn respondQuit(
        self: *ActiveScreenshot,
        io: std.Io,
        gpa: std.mem.Allocator,
    ) void {
        self.respondErrName(io, gpa, "quit");
    }

    /// Writes a JSON error response (`{"ok":false,"error":"<err_name>"}\n`) to
    /// the client IPC stream and frees request resources.
    pub fn respondErrName(
        self: *ActiveScreenshot,
        io: std.Io,
        gpa: std.mem.Allocator,
        err_name: []const u8,
    ) void {
        var write_buf: [160]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);
        std.json.Stringify.value(
            .{ .ok = false, .@"error" = err_name },
            .{},
            &writer.interface,
        ) catch |werr| {
            std.log.warn("Screenshot error response failed: {}", .{werr});
        };
        writer.interface.writeByte('\n') catch |werr| {
            std.log.warn("Screenshot error newline write failed: {}", .{werr});
        };
        writer.interface.flush() catch |ferr| {
            std.log.warn("Screenshot response flush failed: {}", .{ferr});
        };
        self.stream.close(io);
        gpa.free(self.path);
    }
};

/// Represents current active mouse drag interaction state across the viewer UI.
pub const DragState = union(enum) {
    none,
    viewport: struct {
        last_x: f32,
        last_y: f32,
    },
    info: struct {
        start_x: f32,
        start_y: f32,
    },
    stats: struct {
        start_x: f32,
        start_y: f32,
    },
    slider: struct {
        param: EditParam,
        track_x: f32,
        track_w: f32,
    },
};

/// Stops SDL text input processing if a visible window is active.
pub fn stopTextInput(display: DisplayState) void {
    if (display.visibleWindow()) |win| {
        if (!win.stopTextInput()) {
            std.log.err("SDL_StopTextInput failed: {s}", .{sdl.getError()});
        }
    }
}

test "ViewportParams.zoomAtPoint anchors zoom relative to focus point" {
    var vp = ViewportParams{};
    try std.testing.expectEqual(@as(f32, 1.0), vp.zoom_factor.get());
    try std.testing.expectEqual(@as(f32, 0.0), vp.pan_x);
    try std.testing.expectEqual(@as(f32, 0.0), vp.pan_y);

    // Zoom in 2x focused at (100, 100) relative to viewport center (500, 400)
    // -> rel = (-400, -300)
    vp.zoomAtPoint(
        ZoomFactor.init(2.0),
        .{ .x = 100.0, .y = 100.0 },
        .{ .x = 500.0, .y = 400.0 },
    );
    try std.testing.expectEqual(@as(f32, 2.0), vp.zoom_factor.get());
    try std.testing.expectEqual(@as(f32, 400.0), vp.pan_x);
    try std.testing.expectEqual(@as(f32, 300.0), vp.pan_y);
}

test "LogicalDims, PhysicalDims, LogicalPoint, and PhysicalPoint conversions" {
    const scale = DpiScale.init(2.0, 2.0);
    const log_dims = LogicalDims{ .w = 1000.0, .h = 800.0 };
    const phys_dims = log_dims.toPhysical(scale);
    try std.testing.expectApproxEqAbs(@as(f32, 2000.0), phys_dims.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1600.0), phys_dims.h, 0.001);

    const roundtrip_dims = phys_dims.toLogical(scale);
    try std.testing.expectApproxEqAbs(
        @as(f32, 1000.0),
        roundtrip_dims.w,
        0.001,
    );
    try std.testing.expectApproxEqAbs(@as(f32, 800.0), roundtrip_dims.h, 0.001);

    const log_pt = LogicalPoint{ .x = 250.0, .y = 150.0 };
    const phys_pt = log_pt.toPhysical(scale);
    try std.testing.expectApproxEqAbs(@as(f32, 500.0), phys_pt.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 300.0), phys_pt.y, 0.001);

    // Invalid / non-positive scale sanitizes to 1.0
    const bad_scale = DpiScale.init(0.0, std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 1.0), bad_scale.x);
    try std.testing.expectEqual(@as(f32, 1.0), bad_scale.y);
}

test "ViewportParams isOverflowing and effectiveZoom" {
    var vp = ViewportParams{};
    // 1024x682 in 1024x768 with .fit (.full) mode does not overflow
    try std.testing.expect(!vp.isOverflowing(1024.0, 682.0, 1024.0, 768.0));

    // .fit_width on a tall portrait image (800x1600 in 1000x800) overflows Y
    vp.fit_mode = .fit_width;
    vp.reset();
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.25),
        vp.effectiveZoom(1000.0, 800.0, 800.0, 1600.0),
        0.0001,
    );
    try std.testing.expect(vp.isOverflowing(800.0, 1600.0, 1000.0, 800.0));

    // .fit_height on a wide landscape image (1600x800 in 1000x800) overflows X
    vp.fit_mode = .fit_height;
    vp.reset();
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        vp.effectiveZoom(1000.0, 800.0, 1600.0, 800.0),
        0.0001,
    );
    try std.testing.expect(vp.isOverflowing(1600.0, 800.0, 1000.0, 800.0));

    // .shrink on a small image (400x300 in 1000x800) keeps 1.0x and does not
    // overflow
    vp.fit_mode = .shrink;
    vp.reset();
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        vp.effectiveZoom(1000.0, 800.0, 400.0, 300.0),
        0.0001,
    );
    try std.testing.expect(!vp.isOverflowing(400.0, 300.0, 1000.0, 800.0));

    // Rotated 90 degrees in .fit_width (1600x800 -> 800x1600 in 1000x800)
    vp.fit_mode = .fit_width;
    vp.rotation_angle = 90.0;
    vp.reset();
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.25),
        vp.effectiveZoom(1000.0, 800.0, 1600.0, 800.0),
        0.0001,
    );
    try std.testing.expect(vp.isOverflowing(1600.0, 800.0, 1000.0, 800.0));
    vp.rotation_angle = 0.0;

    // .fill mode (crop) causes overflow
    vp.fit_mode = .crop;
    vp.mode = .fill;
    try std.testing.expect(vp.isOverflowing(1024.0, 682.0, 1024.0, 768.0));

    // .manual mode at 2.0x causes overflow
    vp.mode = .manual;
    vp.zoom_factor = ZoomFactor.init(2.0);
    try std.testing.expect(vp.isOverflowing(1024.0, 682.0, 1024.0, 768.0));

    // .manual mode at 0.5x fits inside
    vp.zoom_factor = ZoomFactor.init(0.5);
    try std.testing.expect(!vp.isOverflowing(1024.0, 682.0, 1024.0, 768.0));
}

test "FrameInput.pixMouseX and pixMouseY scale mouse position by display scale factor" {
    const input = FrameInput{
        .win_w = 1000.0,
        .win_h = 800.0,
        .scale_x = 2.0,
        .scale_y = 2.0,
        .mouse_x = 150.0,
        .mouse_y = 250.0,
        .mouse_left_down = false,
        .mouse_left_clicked = false,
        .mouse_inside = true,
        .quit_requested = false,
        .scroll_delta_x = 0.0,
        .scroll_delta_y = 0.0,
        .keys_pressed = undefined,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .ticks = 0,
        .delta_time_ms = 16.0,
    };
    try std.testing.expectEqual(@as(f32, 300.0), input.pixMouseX());
    try std.testing.expectEqual(@as(f32, 500.0), input.pixMouseY());
}

test "ViewportParams.getShaderScaleModeInt maps filters including lanczos3" {
    var params = ViewportParams{};
    params.scale_filter = .lanczos3;
    try std.testing.expectEqual(@as(i32, 4), params.getShaderScaleModeInt());

    params.scale_filter = .mitchell;
    try std.testing.expectEqual(@as(i32, 3), params.getShaderScaleModeInt());

    params.scale_filter = .fsr;
    try std.testing.expectEqual(@as(i32, 5), params.getShaderScaleModeInt());

    params.scale_filter = .tiny_cnn;
    try std.testing.expectEqual(@as(i32, 6), params.getShaderScaleModeInt());
}

test "Orientation.fromTiff and branchless math" {
    // Tag 1 (normal) and 2 (flip horizontal) -> normal (0°)
    try std.testing.expectEqual(Orientation.normal, Orientation.fromTiff(1));
    try std.testing.expectEqual(Orientation.normal, Orientation.fromTiff(2));
    try std.testing.expectEqual(@as(f32, 0.0), Orientation.normal.toDegrees());
    try std.testing.expect(!Orientation.normal.isDimensionSwapped());

    // Tag 6 (rotate 90 CW) and 7 (transverse) -> rotate_90 (90°)
    try std.testing.expectEqual(Orientation.rotate_90, Orientation.fromTiff(6));
    try std.testing.expectEqual(Orientation.rotate_90, Orientation.fromTiff(7));
    try std.testing.expectEqual(@as(f32, 90.0), Orientation.rotate_90.toDegrees());
    try std.testing.expect(Orientation.rotate_90.isDimensionSwapped());

    // Tag 3 (rotate 180) and 4 (flip vertical) -> rotate_180 (180°)
    try std.testing.expectEqual(Orientation.rotate_180, Orientation.fromTiff(3));
    try std.testing.expectEqual(Orientation.rotate_180, Orientation.fromTiff(4));
    try std.testing.expectEqual(@as(f32, 180.0), Orientation.rotate_180.toDegrees());
    try std.testing.expect(!Orientation.rotate_180.isDimensionSwapped());

    // Tag 8 (rotate 270 CW) and 5 (transpose) -> rotate_270 (270°)
    try std.testing.expectEqual(Orientation.rotate_270, Orientation.fromTiff(8));
    try std.testing.expectEqual(Orientation.rotate_270, Orientation.fromTiff(5));
    try std.testing.expectEqual(@as(f32, 270.0), Orientation.rotate_270.toDegrees());
    try std.testing.expect(Orientation.rotate_270.isDimensionSwapped());

    // Out of range / unknown tag values default to normal (0°)
    try std.testing.expectEqual(Orientation.normal, Orientation.fromTiff(0));
    try std.testing.expectEqual(Orientation.normal, Orientation.fromTiff(99));
}

test "RawMetadata tagged union invariants and constructor" {
    // Valid dimensions
    const valid = RawMetadata.init(6000.0, 4000.0);
    try std.testing.expect(valid.isRaw());
    const dims = valid.getSensorDims().?;
    try std.testing.expectEqual(@as(f32, 6000.0), dims.w);
    try std.testing.expectEqual(@as(f32, 4000.0), dims.h);

    // Invalid zero or negative dimensions return .none
    try std.testing.expectEqual(RawMetadata.none, RawMetadata.init(0.0, 0.0));
    try std.testing.expectEqual(RawMetadata.none, RawMetadata.init(-100.0, 4000.0));
    try std.testing.expectEqual(RawMetadata.none, RawMetadata.init(6000.0, 0.0));
    try std.testing.expectEqual(RawMetadata.none, RawMetadata.init(std.math.nan(f32), 4000.0));

    // .none variant returns false and null
    const none_meta: RawMetadata = .none;
    try std.testing.expect(!none_meta.isRaw());
    try std.testing.expect(none_meta.getSensorDims() == null);
}

test "CacheStatus.decoding defaults" {
    const dec_status: CacheStatus = .{ .decoding = .{} };
    try std.testing.expectEqual(@as(u64, 0), dec_status.decoding.start_time_ms);
    try std.testing.expect(!dec_status.decoding.has_thread);
}

test "ElementTag.fromInt" {
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(0));
    try std.testing.expectEqual(ElementTag.drop_zone_box, ElementTag.fromInt(2));
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(1337));
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(9999));
    try std.testing.expectEqual(ElementTag.none, ElementTag.fromInt(0x7fffffffd000));
}

test "SnackbarDisplay getActive" {
    const none_display: SnackbarDisplay = .none;
    try std.testing.expect(none_display.getActive() == null);

    const active_display: SnackbarDisplay = .{
        .active = .{ .reveal = 0.85, .message = "Filter: Lanczos3" },
    };
    const payload = active_display.getActive().?;
    try std.testing.expectEqual(@as(f32, 0.85), payload.reveal);
    try std.testing.expectEqualStrings("Filter: Lanczos3", payload.message);
}

test "SlideshowMode lifecycle, pause, and unpause" {
    // Inactive mode does not tick
    var mode: SlideshowMode = .inactive;
    try std.testing.expect(!mode.isPaused());
    try std.testing.expect(!mode.tick(1000.0));

    // Active mode ticking
    mode = .{ .active = .{ .interval_s = 2.0 } };
    try std.testing.expect(!mode.isPaused());

    // Advance 1s (halfway) -> returns false
    try std.testing.expect(!mode.tick(1000.0));
    try std.testing.expectEqual(@as(f64, 1000.0), mode.active.timer_ms);

    // Pause slideshow -> tick returns false and timer DOES NOT advance
    mode.pause();
    try std.testing.expect(mode.isPaused());
    try std.testing.expect(!mode.tick(1000.0));
    try std.testing.expectEqual(@as(f64, 1000.0), mode.active.timer_ms);

    // Resume -> timer continues from 1000ms
    mode.unpause();
    try std.testing.expect(!mode.isPaused());
    try std.testing.expect(mode.tick(1000.0)); // 1000 + 1000 = 2000ms >= 2.0s -> fires and resets
    try std.testing.expectEqual(@as(f64, 0.0), mode.active.timer_ms);
}

test "ImageTransition getPrevIndex and variants" {
    var trans: ImageTransition = .none;
    try std.testing.expectEqual(@as(?usize, null), trans.getPrevIndex());

    trans = .{ .active = .{ .prev_index = 42, .prev_rotation = 180.0 } };
    try std.testing.expectEqual(@as(?usize, 42), trans.getPrevIndex());
    try std.testing.expectEqual(@as(f32, 180.0), trans.active.prev_rotation);

    trans = .none;
    try std.testing.expectEqual(@as(?usize, null), trans.getPrevIndex());
}

test "OverlayState floating panel dismissal" {
    var overlays = OverlayState{};
    try std.testing.expect(!overlays.hasVisibleFloatingPanels());
    try std.testing.expect(!overlays.dismissFloatingPanels());

    // Show info panel
    overlays.info_panel.visible = true;
    try std.testing.expect(overlays.hasVisibleFloatingPanels());

    // Show stats panel as well
    overlays.stats_panel.visible = true;
    try std.testing.expect(overlays.hasVisibleFloatingPanels());

    // Dismiss should close both and return true
    try std.testing.expect(overlays.dismissFloatingPanels());
    try std.testing.expect(!overlays.info_panel.visible);
    try std.testing.expect(!overlays.stats_panel.visible);
    try std.testing.expect(!overlays.hasVisibleFloatingPanels());

    // Subsequent dismissal returns false
    try std.testing.expect(!overlays.dismissFloatingPanels());
}

test "ViewportParams Before/After comparison lifecycle" {
    var vp = ViewportParams{};
    try std.testing.expect(!vp.hasAdjustments());
    try std.testing.expect(!vp.compare_original);

    // Toggling without adjustments remains false
    vp.toggleCompare();
    try std.testing.expect(!vp.compare_original);

    // Apply adjustments
    vp.adjustBrightness(0.2);
    try std.testing.expect(vp.hasAdjustments());
    try std.testing.expect(!vp.compare_original);

    // Toggle on
    vp.toggleCompare();
    try std.testing.expect(vp.compare_original);

    // Toggle off
    vp.toggleCompare();
    try std.testing.expect(!vp.compare_original);

    // Toggle on then verify adjustBrightness resets compare_original
    vp.toggleCompare();
    try std.testing.expect(vp.compare_original);
    vp.adjustBrightness(-0.1);
    try std.testing.expect(!vp.compare_original);

    // Toggle on then verify adjustContrast resets compare_original
    vp.toggleCompare();
    try std.testing.expect(vp.compare_original);
    vp.adjustContrast(0.1);
    try std.testing.expect(!vp.compare_original);

    // Toggle on then verify setAdjustments resets compare_original
    vp.toggleCompare();
    try std.testing.expect(vp.compare_original);
    vp.setAdjustments(0.0, 1.0);
    try std.testing.expect(!vp.compare_original);
    try std.testing.expect(!vp.hasAdjustments());

    // Toggle on then verify reset() resets compare_original
    vp.setAdjustments(0.1, 1.2);
    vp.toggleCompare();
    try std.testing.expect(vp.compare_original);
    vp.reset();
    try std.testing.expect(!vp.compare_original);
}

test "ImageEdits and ParamDescriptor exhaustive verification" {
    var edits = ImageEdits{};
    try std.testing.expect(!edits.hasEdits());

    for (std.enums.values(EditParam)) |param| {
        try std.testing.expect(edits.isParamDefault(param));
        const desc = getDescriptor(param);
        try std.testing.expectEqual(desc.default, edits.get(param));

        // Test clamping
        edits.set(param, desc.min - 10.0);
        try std.testing.expectEqual(desc.min, edits.get(param));
        edits.set(param, desc.max + 10.0);
        try std.testing.expectEqual(desc.max, edits.get(param));

        // Test snapping
        const snapped = desc.snap(desc.default + desc.snap_radius * 0.5);
        try std.testing.expectEqual(desc.default, snapped);

        // Test resetParam
        edits.resetParam(param);
        try std.testing.expect(edits.isParamDefault(param));
    }

    try std.testing.expect(!edits.hasEdits());
    edits.set(.highlights, 0.4);
    try std.testing.expect(edits.hasEdits());
    edits.reset();
    try std.testing.expect(!edits.hasEdits());
}

test "MediaEntry - pair dupe, deinit, and accessors" {
    const allocator = std.testing.allocator;
    const raw = try allocator.dupe(u8, "photos/DSC00941.ARW");
    errdefer allocator.free(raw);
    const jpg = try allocator.dupe(u8, "photos/DSC00941.JPG");
    errdefer allocator.free(jpg);

    const entry = MediaEntry{
        .pair = .{
            .raw_path = raw,
            .jpeg_path = jpg,
        },
    };
    defer entry.deinit(allocator);

    try std.testing.expect(entry.isPair());
    try std.testing.expect(!entry.isArchive());
    try std.testing.expectEqualStrings("DSC00941.ARW", entry.getBasename());
    try std.testing.expectEqualStrings("photos", entry.getContainerName());
    try std.testing.expectEqualStrings("photos/DSC00941.ARW", entry.getPath());
    try std.testing.expectEqualStrings(
        "photos/DSC00941.ARW",
        entry.getSourcePath(),
    );
    try std.testing.expectEqualStrings("photos/DSC00941.ARW", entry.getRawPath().?);
    try std.testing.expectEqualStrings("photos/DSC00941.JPG", entry.getJpegPath().?);

    const duped = try entry.dupe(allocator);
    defer duped.deinit(allocator);

    try std.testing.expect(duped.isPair());
    try std.testing.expectEqualStrings("photos/DSC00941.ARW", duped.getRawPath().?);
    try std.testing.expectEqualStrings("photos/DSC00941.JPG", duped.getJpegPath().?);

    const archive_item = MediaEntry{
        .archive_entry = .{
            .archive_path = "comics/issue1.cbz",
            .entry_name = "pages/001.jpg",
            .seek_info = .unindexed,
        },
    };
    try std.testing.expectEqualStrings("pages/001.jpg", archive_item.getPath());
    try std.testing.expectEqualStrings(
        "comics/issue1.cbz",
        archive_item.getSourcePath(),
    );
}
