const std = @import("std");
const sdl = @import("sdl");
const intents = @import("intents");
const palette_state = @import("palette_state.zig");
const clay = @import("zclay");

pub const Key = enum {
    unknown,
    escape,
    return_key,
    backspace,
    tab,
    space,
    left,
    right,
    up,
    down,
    equals,
    minus,
    left_bracket,
    right_bracket,
    home,
    end,
    page_up,
    page_down,
    f1,
    f11,
    char_0,
    char_1,
    char_2,
    char_3,
    char_4,
    char_5,
    char_6,
    char_7,
    char_8,
    char_9,
    char_a,
    char_b,
    char_c,
    char_d,
    char_e,
    char_f,
    char_g,
    char_h,
    char_i,
    char_j,
    char_k,
    char_l,
    char_m,
    char_n,
    char_o,
    char_p,
    char_q,
    char_r,
    char_s,
    char_t,
    char_u,
    char_v,
    char_w,
    char_x,
    char_y,
    char_z,
};

pub const KeyModifiers = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    gui: bool = false,

    pub fn eql(self: KeyModifiers, other: KeyModifiers) bool {
        return self.ctrl == other.ctrl and
            self.shift == other.shift and
            self.alt == other.alt and
            self.gui == other.gui;
    }
};

/// Type-safe zoom factor wrapper protecting against zero-initialization, division-by-zero, and NaN.
pub const ZoomFactor = struct {
    value: f32 = 1.0,

    pub const MIN: f32 = 0.01;
    pub const MAX: f32 = 500.0;

    pub fn init(raw: f32) ZoomFactor {
        if (std.math.isNan(raw) or raw <= 0.0) {
            return .{ .value = 1.0 };
        }
        return .{ .value = std.math.clamp(raw, MIN, MAX) };
    }

    pub fn get(self: ZoomFactor) f32 {
        if (self.value <= 0.0 or std.math.isNan(self.value)) {
            return 1.0;
        }
        return self.value;
    }

    pub fn ratioTo(self: ZoomFactor, new_zoom: ZoomFactor) f32 {
        return new_zoom.get() / self.get();
    }
};

pub const ViewportParams = struct {
    fit_mode: intents.ScaleMode = .full,
    scale_filter: intents.TextureScaleMode = .linear,
    texture_scale_mode: intents.TextureScaleMode = .linear,
    zoom_factor: ZoomFactor = .{},
    pan_x: f32 = 0.0,
    pan_y: f32 = 0.0,
    rotation_angle: f32 = 0.0,
    brightness: f32 = 0.0,
    contrast: f32 = 1.0,

    pub fn reset(self: *ViewportParams) void {
        self.zoom_factor = .{};
        self.pan_x = 0.0;
        self.pan_y = 0.0;
    }

    pub fn getShaderScaleModeInt(self: ViewportParams) i32 {
        const f = if (self.scale_filter != .linear) self.scale_filter else self.texture_scale_mode;
        return switch (f) {
            .nearest => 0,
            .linear => 1,
            .pixel_art => 2,
            .mitchell => 3,
            .lanczos3 => 4,
        };
    }
};

pub const ViewParams = struct {
    viewport: ViewportParams,
    win_w: f32,
    win_h: f32,
    scale_x: f32,
    scale_y: f32,
    is_fullscreen: bool,

    pub fn getDpiScale(self: ViewParams) f32 {
        return self.scale_x;
    }

    pub fn getLogicalWidth(self: ViewParams) f32 {
        return if (self.scale_x > 0.0) self.win_w / self.scale_x else self.win_w;
    }

    pub fn getLogicalHeight(self: ViewParams) f32 {
        return if (self.scale_y > 0.0) self.win_h / self.scale_y else self.win_h;
    }
};

pub const FrameInput = struct {
    win_w: f32,
    win_h: f32,
    pix_w: f32,
    pix_h: f32,
    scale_x: f32,
    scale_y: f32,
    dpi_scale: f32,
    mouse_x: f32,
    mouse_y: f32,
    mouse_left_down: bool,
    mouse_left_clicked: bool,
    mouse_inside: bool,
    quit_requested: bool,
    scroll_delta_x: f32,
    scroll_delta_y: f32,
    keys_pressed: std.ArrayList(Key),
    key_modifiers: KeyModifiers,
    text_input: ?[]const u8,
    dropped_path: ?[]const u8,
    ticks: u64,
    delta_time_ms: f32,
    window_resized: bool = false,

    pub fn pixMouseX(self: FrameInput) f32 {
        return self.mouse_x;
    }

    pub fn pixMouseY(self: FrameInput) f32 {
        return self.mouse_y;
    }

    pub fn isPointerInDebugPanel(self: FrameInput) bool {
        if (!clay.isDebugModeEnabled()) return false;
        const debug_w: f32 = @floatFromInt(clay.Clay__debugViewWidth);
        return self.mouse_x >= (self.win_w - debug_w);
    }
};

pub const KeyboardShortcut = struct {
    key: Key,
    mod: KeyModifiers = .{},
};

pub const ActionMetadata = struct {
    name: []const u8,
    shortcut_text: []const u8,
    show_in_palette: bool,
    shortcuts: []const KeyboardShortcut,
    intent: intents.AppIntent,
};

pub const palette_action_items = [_]ActionMetadata{
    .{ .name = "Next Image", .shortcut_text = "Space / Right Arrow", .show_in_palette = true, .shortcuts = &.{ .{ .key = .space }, .{ .key = .right } }, .intent = .next_image },
    .{ .name = "Previous Image", .shortcut_text = "Backspace / Left Arrow", .show_in_palette = true, .shortcuts = &.{ .{ .key = .backspace }, .{ .key = .left } }, .intent = .prev_image },
    .{ .name = "Toggle Image Info", .shortcut_text = "I", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_i }}, .intent = .toggle_info },
    .{ .name = "Toggle Performance Overlay", .shortcut_text = "Shift+I", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_i, .mod = .{ .shift = true } }}, .intent = .toggle_stats },
    .{ .name = "Toggle Fullscreen", .shortcut_text = "F / F11", .show_in_palette = true, .shortcuts = &.{ .{ .key = .char_f }, .{ .key = .f11 } }, .intent = .toggle_fullscreen },
    .{ .name = "Open File Finder...", .shortcut_text = "Ctrl+P", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_p, .mod = .{ .ctrl = true } }}, .intent = .{ .set_palette = .{ .mode = .files } } },
    .{ .name = "Navigate Directories...", .shortcut_text = "Ctrl+O", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_o, .mod = .{ .ctrl = true } }}, .intent = .{ .set_palette = .{ .mode = .directory_navigator } } },
    .{ .name = "Toggle Clay Debug Mode", .shortcut_text = "Ctrl+D", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_d, .mod = .{ .ctrl = true } }}, .intent = .toggle_debug_mode },
    .{ .name = "Toggle Debug Thumbnail Overlay", .shortcut_text = "Ctrl+T", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_t, .mod = .{ .ctrl = true } }}, .intent = .toggle_debug_thumb },
    .{ .name = "Quit", .shortcut_text = "Q / Esc", .show_in_palette = true, .shortcuts = &.{ .{ .key = .char_q }, .{ .key = .escape } }, .intent = .quit },
    .{ .name = "First Image", .shortcut_text = "Home", .show_in_palette = true, .shortcuts = &.{.{ .key = .home }}, .intent = .first_image },
    .{ .name = "Last Image", .shortcut_text = "End", .show_in_palette = true, .shortcuts = &.{.{ .key = .end }}, .intent = .last_image },
    .{ .name = "Zoom In", .shortcut_text = "= / +", .show_in_palette = true, .shortcuts = &.{.{ .key = .equals }}, .intent = .zoom_in },
    .{ .name = "Zoom Out", .shortcut_text = "-", .show_in_palette = true, .shortcuts = &.{.{ .key = .minus }}, .intent = .zoom_out },
    .{ .name = "Reset Zoom & Pan", .shortcut_text = "R / 0", .show_in_palette = true, .shortcuts = &.{ .{ .key = .char_r }, .{ .key = .char_0 } }, .intent = .reset_zoom },
    .{ .name = "Set Scale Mode: 100% (Actual Size)", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_scale = .none } },
    .{ .name = "Set Scale Mode: Fit if Larger (Shrink)", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_scale = .shrink } },
    .{ .name = "Set Scale Mode: Fit Window (Full)", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_scale = .full } },
    .{ .name = "Set Scale Mode: Fill Window (Crop)", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_scale = .crop } },
    .{ .name = "Rotate Clockwise (90°)", .shortcut_text = "]", .show_in_palette = true, .shortcuts = &.{.{ .key = .right_bracket }}, .intent = .rotate_cw },
    .{ .name = "Rotate Counter-Clockwise (90°)", .shortcut_text = "[", .show_in_palette = true, .shortcuts = &.{.{ .key = .left_bracket }}, .intent = .rotate_ccw },
    .{ .name = "Reset Rotation", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .reset_rotation },
    .{ .name = "Set Scaling Filter: Nearest Neighbor", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_filter = .nearest } },
    .{ .name = "Set Scaling Filter: Bilinear (Smooth)", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_filter = .linear } },
    .{ .name = "Set Scaling Filter: Pixel Art (Crisp)", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_filter = .pixel_art } },
    .{ .name = "Set Scaling Filter: Mitchell-Netravali (HQ Bicubic)", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_filter = .mitchell } },
    .{ .name = "Set Scaling Filter: Lanczos3 (Ultra HQ Resampler)", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_filter = .lanczos3 } },
    .{ .name = "Increase Brightness (+10%)", .shortcut_text = "P", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_p }}, .intent = .increase_brightness },
    .{ .name = "Decrease Brightness (-10%)", .shortcut_text = "O", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_o }}, .intent = .decrease_brightness },
    .{ .name = "Increase Contrast (+10%)", .shortcut_text = "L", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_l }}, .intent = .increase_contrast },
    .{ .name = "Decrease Contrast (-10%)", .shortcut_text = "K", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_k }}, .intent = .decrease_contrast },
    .{ .name = "Reset Brightness & Contrast", .shortcut_text = "Shift+R", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_r, .mod = .{ .shift = true } }}, .intent = .reset_adjustments },
    .{ .name = "Set Brightness (Type Value)...", .shortcut_text = "Shift+B", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_b, .mod = .{ .shift = true } }}, .intent = .{ .set_palette = .{ .mode = .set_brightness } } },
    .{ .name = "Set Contrast (Type Value)...", .shortcut_text = "Shift+C", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_c, .mod = .{ .shift = true } }}, .intent = .{ .set_palette = .{ .mode = .set_contrast } } },
    .{ .name = "Go to Image...", .shortcut_text = "Shift+G", .show_in_palette = true, .shortcuts = &.{.{ .key = .char_g, .mod = .{ .shift = true } }}, .intent = .{ .set_palette = .{ .mode = .go_to_image } } },
    .{ .name = "Search Actions (Command Palette)", .shortcut_text = "F1 / Ctrl+Shift+P", .show_in_palette = true, .shortcuts = &.{ .{ .key = .f1 }, .{ .key = .char_p, .mod = .{ .ctrl = true, .shift = true } } }, .intent = .{ .set_palette = .{ .mode = .actions } } },
    .{ .name = "Start Slide Show...", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .{ .set_palette = .{ .mode = .set_slideshow_interval } } },
    .{ .name = "Stop Slide Show", .shortcut_text = "", .show_in_palette = true, .shortcuts = &.{}, .intent = .stop_slideshow },
};

pub const FlatShortcut = struct {
    key: Key,
    mod: KeyModifiers,
    intent: intents.AppIntent,
};

pub const flat_shortcuts = blk: {
    var count: usize = 0;
    for (palette_action_items) |item| {
        count += item.shortcuts.len;
    }
    var list: [count]FlatShortcut = undefined;
    var idx: usize = 0;
    for (palette_action_items) |item| {
        for (item.shortcuts) |sc| {
            list[idx] = .{
                .key = sc.key,
                .mod = sc.mod,
                .intent = item.intent,
            };
            idx += 1;
        }
    }
    break :blk list;
};

pub const ElementTag = enum(usize) {
    none = 0,
    image_viewer = 1,
    drop_zone_box = 2,

    pub fn toInt(self: ElementTag) usize {
        return @intFromEnum(self);
    }

    pub fn fromInt(val: usize) ElementTag {
        return switch (val) {
            1 => .image_viewer,
            2 => .drop_zone_box,
            else => .none,
        };
    }
};

pub const OverlayState = struct {
    show_info: bool = false,
    show_stats: bool = false,
    debug_show_thumb: bool = false,
    info_offset_x: f32 = 20.0,
    info_offset_y: f32 = 20.0,
    stats_offset_x: f32 = -20.0,
    stats_offset_y: f32 = 20.0,
    mouse_inside: bool = true,
    last_mouse_x: f32 = -1.0,
    last_mouse_y: f32 = -1.0,
    last_win_w: f32 = 0.0,
    last_win_h: f32 = 0.0,
};

pub const RenderStats = struct {
    samples: [60]f64 = [_]f64{0.0} ** 60,
    head: usize = 0,
    count: usize = 0,

    pub fn addSample(self: *RenderStats, sample_ms: f64) void {
        self.samples[self.head] = sample_ms;
        self.head = (self.head + 1) % 60;
        if (self.count < 60) self.count += 1;
    }

    pub fn getAverageMs(self: RenderStats) f64 {
        if (self.count == 0) return 0.0;
        var sum: f64 = 0.0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            sum += self.samples[i];
        }
        return sum / @as(f64, @floatFromInt(self.count));
    }

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

pub const UiRenderMetrics = struct {
    last_ui_render_time_ms: f64 = 0.0,
    ui_render_stats: RenderStats = .{},
    last_ui_vertex_count: usize = 0,
    last_ui_batch_count: usize = 0,
};

pub const CpuSurfaceComponent = struct {
    surface: sdl.Surface,
    w: f32,
    h: f32,
    size_bytes: u64,
    mime_type: []const u8 = "",
    decode_time_ms: f64 = 0.0,
    conversion_time_ms: f64 = 0.0,
};

pub const GpuTextureComponent = struct {
    gpu_texture: sdl.gpu.Texture,
    w: f32,
    h: f32,
    size_bytes: u64,
    mime_type: []const u8 = "",
    decode_time_ms: f64 = 0.0,
    conversion_time_ms: f64 = 0.0,
    upload_time_ms: f64 = 0.0,
    memory_size_bytes: usize,
    num_mip_levels: u32 = 1,
    mipmap_time_ms: f64 = 0.0,
    was_fallback: bool = false,
    fallback_time_ms: f64 = 0.0,
};

pub const ThumbComponent = struct {
    texture: sdl.gpu.Texture,
    w: f32,
    h: f32,
    upload_time_ms: f64,
};

pub const CacheStatus = union(enum) {
    decoding: struct {
        has_thread: bool = false,
    },
    loaded_cpu: CpuSurfaceComponent,
    loaded_gpu: GpuTextureComponent,
    uploading: void,
    failed: void,
};

pub const ThumbnailInfo = struct {
    w: f32 = 0.0,
    h: f32 = 0.0,
    upload_time_ms: f64 = 0.0,
};

pub const ThumbnailState = union(enum) {
    none,
    unloaded: ThumbnailInfo,
    loaded: struct {
        texture: sdl.gpu.Texture,
        info: ThumbnailInfo,
    },

    pub fn getInfo(self: ThumbnailState) ?ThumbnailInfo {
        return switch (self) {
            .none => null,
            .unloaded => |info| info,
            .loaded => |l| l.info,
        };
    }
};

pub const CacheEntry = struct {
    status: CacheStatus,
    thumbnail: ThumbnailState = .none,
    full_w: f32 = 0.0,
    full_h: f32 = 0.0,
    exif_orientation: f32 = 0.0,

    pub fn deinit(self: *CacheEntry, gpu_device: ?sdl.gpu.Device) void {
        switch (self.thumbnail) {
            .loaded => |thumb| {
                if (gpu_device) |dev| {
                    dev.releaseTexture(thumb.texture);
                }
            },
            else => {},
        }
        self.thumbnail = .none;

        switch (self.status) {
            .loaded_cpu => |cpu| cpu.surface.destroy(),
            .loaded_gpu => |gpu| {
                if (gpu_device) |dev| {
                    dev.releaseTexture(gpu.gpu_texture);
                }
            },
            else => {},
        }
    }
};

pub const SlideshowMode = union(enum) {
    inactive,
    active: struct {
        interval_s: f32,
        timer_ms: f64,
    },

    pub fn tick(self: *SlideshowMode, delta_ms: f32) bool {
        switch (self.*) {
            .inactive => return false,
            .active => |*data| {
                if (data.interval_s <= 0.0) return false;
                data.timer_ms += delta_ms;
                if (data.timer_ms >= data.interval_s * 1000.0) {
                    data.timer_ms = 0.0;
                    return true;
                }
                return false;
            },
        }
    }

    pub fn resetTimer(self: *SlideshowMode) void {
        switch (self.*) {
            .inactive => {},
            .active => |*a| a.timer_ms = 0.0,
        }
    }
};

/// Telemetry metrics for the active image GPU/Decoder status.
pub const ActiveImageStats = struct {
    num_mip_levels: u32 = 1,
    mipmap_time_ms: f64 = 0.0,
    gpu_upload_time_ms: f64 = 0.0,
    decode_time_ms: f64 = 0.0,
    conversion_time_ms: f64 = 0.0,
    fallback_time_ms: f64 = 0.0,
    was_fallback: bool = false,
    has_thumb: bool = false,
    thumb_upload_time_ms: f64 = 0.0,
};

/// Snapshot of application telemetry and diagnostic counters copied once per frame
/// for UI rendering ("Stats for Nerds") without reading live atomics.
pub const ViewerStats = struct {
    // EXIF Thumbnail extraction telemetry
    thumb_header_hits: usize = 0,
    thumb_positional_hits: usize = 0,
    thumb_misses: usize = 0,

    // Cache telemetry
    current_image_cache_hit: bool = false,
    cached_slot_count: usize = 0,
    total_vram_bytes: usize = 0,

    // Worker telemetry (frame snapshot)
    active_worker_threads: usize = 0,
    active_decode_threads: usize = 0,

    // Active image GPU & decoder stats
    active_image: ActiveImageStats = .{},
};

pub const UiViewModel = struct {
    is_fullscreen: bool,
    total_images: usize,
    image_list: []const []const u8 = &.{},
    current_index: ?usize,
    current_image_path: ?[]const u8,
    current_entry: ?CacheEntry = null,
    is_loading_files: bool,
    slideshow: SlideshowMode = .inactive,
    overlays: OverlayState,
    metrics: *UiRenderMetrics,
    viewport: ViewportParams,
    palette: *palette_state.PaletteState,
    display: *DisplayState,
    total_vram_bytes: usize = 0,
    cached_slot_count: usize = 0,
    gpa_allocator: std.mem.Allocator,
    io: std.Io,
    cache_slot_map: *anyopaque,
    navigation: *anyopaque,
    pending_intents: *std.ArrayList(intents.AppIntent),
    debug_show_thumb: bool,
    stats: ViewerStats = .{},
};

pub const MeasureTextUserData = struct {
    fonts: []const ?sdl.Font,
    is_debug_measuring: bool = false,
    allocator: std.mem.Allocator = undefined,
};

pub const ActiveWindow = struct {
    handle: sdl.Window,
    pixel_format: u32 = sdl.PixelFormat.unknown,
    cached_title: ?[]const u8 = null,
    is_fullscreen: bool = false,
    claimed: bool = false,

    pub fn deinit(self: *ActiveWindow, gpa: std.mem.Allocator) void {
        if (self.cached_title) |t| {
            gpa.free(t);
        }
    }
};

pub const DisplayState = union(enum) {
    headless,
    windowed: ActiveWindow,

    pub inline fn getTitle(self: DisplayState) ?[]const u8 {
        return switch (self) {
            .headless => null,
            .windowed => |w| w.cached_title,
        };
    }

    pub inline fn isFullscreen(self: DisplayState) bool {
        return switch (self) {
            .headless => false,
            .windowed => |w| w.is_fullscreen,
        };
    }

    pub inline fn isClaimed(self: DisplayState) bool {
        return switch (self) {
            .headless => false,
            .windowed => |w| w.claimed,
        };
    }

    pub inline fn getPixelFormat(self: DisplayState) u32 {
        return switch (self) {
            .headless => sdl.PixelFormat.unknown,
            .windowed => |w| w.pixel_format,
        };
    }

    pub fn deinit(self: *DisplayState, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .headless => {},
            .windowed => |*w| {
                if (w.cached_title) |title| {
                    allocator.free(title);
                    w.cached_title = null;
                }
            },
        }
    }
};

pub const ActiveScreenshot = struct {
    path: [:0]const u8,
    stream: std.Io.net.Stream,

    pub fn respondOk(self: *ActiveScreenshot, io: std.Io, gpa: std.mem.Allocator) void {
        var write_buf: [128]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);
        writer.interface.writeAll("OK\n") catch |werr| std.log.warn("Screenshot response failed: {}", .{werr});
        writer.interface.flush() catch |ferr| std.log.warn("Screenshot response flush failed: {}", .{ferr});
        self.stream.close(io);
        gpa.free(self.path);
    }

    pub fn respondErr(self: *ActiveScreenshot, io: std.Io, gpa: std.mem.Allocator, err: anyerror) void {
        var response_buf: [128]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf, "ERR {s}\n", .{@errorName(err)}) catch "ERR SaveFailed\n";
        var write_buf: [128]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);
        writer.interface.writeAll(response) catch |werr| std.log.warn("Screenshot response failed: {}", .{werr});
        writer.interface.flush() catch |ferr| std.log.warn("Screenshot response flush failed: {}", .{ferr});
        self.stream.close(io);
        gpa.free(self.path);
    }

    pub fn respondQuit(self: *ActiveScreenshot, io: std.Io, gpa: std.mem.Allocator) void {
        var write_buf: [64]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);
        writer.interface.writeAll("ERR quit\n") catch |err| std.log.warn("Emergency screenshot response write failed: {}", .{err});
        writer.interface.flush() catch |ferr| std.log.warn("Emergency screenshot response flush failed: {}", .{ferr});
        self.stream.close(io);
        gpa.free(self.path);
    }
};

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
};

pub fn stopTextInput(display: DisplayState) void {
    switch (display) {
        .headless => {},
        .windowed => |win| {
            if (!win.handle.stopTextInput()) {
                std.log.err("SDL_StopTextInput failed: {s}", .{sdl.getError()});
            }
        },
    }
}
