//! UI Interaction & Clay Encapsulation Subsystem
//!
//! Provides the sole boundary for Clay UI layout initialization, context
//! management, scroll synchronization, and element hit-testing.
//!
//! INVARIANT: Code outside `src/ui/` MUST NOT import `zclay`. All UI queries,
//! dimension calculations, and pointer hit tests must be routed through this
//! module.

const clay = @import("zclay");
const intents = @import("intents");
const palette_pkg = @import("palette");
const state = @import("state");
const std = @import("std");
const text_utils = @import("text_utils.zig");

const EditParam = intents.EditParam;
const FrameInput = state.FrameInput;
const getPaletteConfig = palette_pkg.getPaletteConfig;
const getSpec = intents.getSpec;
const LogicalDims = state.LogicalDims;
const LogicalPoint = state.LogicalPoint;
const measureText = text_utils.measureText;
const MeasureTextUserData = text_utils.MeasureTextUserData;
const PaletteState = palette_pkg.PaletteState;

/// Opaque Clay context handle wrapping internal layout engine state.
pub const ClayContext = struct {
    raw: *clay.Context,
};

/// Returns minimum byte buffer capacity required to initialize a Clay context.
pub fn minClayMemorySize() usize {
    return clay.minMemorySize();
}

/// Initializes a new Clay layout context using caller-provided backing memory.
pub fn initClayContext(memory: []u8, dims: LogicalDims) ClayContext {
    return .{
        .raw = clay.initialize(
            clay.Arena.init(memory),
            .{ .w = dims.w, .h = dims.h },
            .{},
        ),
    };
}

/// Sets the active thread-local Clay context pointer.
pub fn setCurrentClayContext(ctx: ClayContext) void {
    clay.setCurrentContext(ctx.raw);
}

/// Resets Clay's global active context pointer to null, ensuring no dangling
/// references remain after deallocating context memory.
pub fn resetCurrentClayContext() void {
    const setNullCtx = @as(
        *const fn (?*clay.Context) callconv(.c) void,
        @ptrCast(&clay.cdefs.Clay_SetCurrentContext),
    );
    setNullCtx(null);
}

/// Registers the font measurement callback with Clay.
pub fn bindMeasureText(measure_data: *const MeasureTextUserData) void {
    clay.setMeasureTextFunction(
        *const MeasureTextUserData,
        measure_data,
        measureText,
    );
}

/// Clears cached text dimensions within Clay's internal measurement cache.
pub fn resetMeasureTextCache() void {
    clay.cdefs.Clay_ResetMeasureTextCache();
}

fn isContextActive() bool {
    return @intFromPtr(clay.cdefs.Clay_GetCurrentContext()) != 0;
}

/// Returns true if Clay's built-in visual debug panel is currently enabled.
pub fn isDebugModeEnabled() bool {
    if (!isContextActive()) return false;
    return clay.isDebugModeEnabled();
}

/// Toggles or sets the visibility of Clay's visual layout debug overlay.
pub fn setDebugModeEnabled(enabled: bool) void {
    if (!isContextActive()) return;
    clay.setDebugModeEnabled(enabled);
}

/// Toggles the active state of Clay's layout debug inspection mode.
pub fn toggleDebugMode() void {
    if (!isContextActive()) return;
    clay.setDebugModeEnabled(!clay.isDebugModeEnabled());
}

/// Returns logical pixel width of Clay's debug inspection sidebar when open.
pub fn debugPanelWidth() f32 {
    if (!isDebugModeEnabled()) return 0.0;
    return @floatFromInt(clay.Clay__debugViewWidth);
}

/// Synchronizes window dimensions, mouse pointer state, and scroll containers
/// with Clay, updating debug panel pointer intersection on `FrameInput`.
pub fn syncFrameInput(
    input: FrameInput,
    is_slider_active: bool,
) FrameInput {
    if (!isContextActive()) return input;

    clay.setLayoutDimensions(.{ .w = input.win_w, .h = input.win_h });

    if (input.mouse_inside) {
        clay.setPointerState(
            .{ .x = input.mouse_x, .y = input.mouse_y },
            input.mouse_left_down,
        );
    } else {
        clay.setPointerState(
            .{ .x = -1.0, .y = -1.0 },
            false,
        );
    }

    const scroll_delta: clay.Vector2 = if (is_slider_active)
        .{ .x = 0.0, .y = 0.0 }
    else
        .{ .x = input.scroll_delta_x, .y = input.scroll_delta_y };

    clay.updateScrollContainers(
        false,
        scroll_delta,
        input.delta_time_ms / 1000.0,
    );

    var update_input = input;
    const debug_w = debugPanelWidth();
    if (debug_w > 0.0) {
        update_input.is_pointer_in_debug_panel =
            input.mouse_x >= (input.win_w - debug_w);
    }
    return update_input;
}

/// Returns true if pointer is hovering over the info close button.
pub fn isPointerOverInfoCloseBtn() bool {
    if (!isContextActive()) return false;
    return clay.pointerOver(clay.getElementId("InfoCloseBtn"));
}

/// Returns true if pointer is hovering over the stats close button.
pub fn isPointerOverStatsCloseBtn() bool {
    if (!isContextActive()) return false;
    return clay.pointerOver(clay.getElementId("StatsCloseBtn"));
}

/// Returns true if pointer is hovering over the info overlay panel.
pub fn isPointerOverInfoPanel() bool {
    if (!isContextActive()) return false;
    return clay.pointerOver(clay.getElementId("InfoOverlayCard"));
}

/// Returns true if pointer is hovering over the stats overlay panel.
pub fn isPointerOverStatsPanel() bool {
    if (!isContextActive()) return false;
    return clay.pointerOver(clay.getElementId("StatsPanel"));
}

/// Returns true if pointer is hovering over the edit side panel.
pub fn isPointerOverEditPanel() bool {
    if (!isContextActive()) return false;
    return clay.pointerOver(clay.getElementId("EditSidePanel"));
}

/// Returns true if pointer is hovering over the main viewport.
pub fn isPointerOverViewport() bool {
    if (!isContextActive()) return false;
    return clay.pointerOver(clay.getElementId("Viewport"));
}

/// Resolves the center coordinates of the main viewport element in logical UI
/// coordinates, falling back to layout math when element is not found.
pub fn resolveViewportCenter(
    win_dims: LogicalDims,
    edit_docked_w: f32,
) LogicalPoint {
    if (isContextActive()) {
        const vp_data = clay.getElementData(clay.getElementId("Viewport"));
        if (vp_data.found) {
            return .{
                .x = vp_data.bounding_box.x + vp_data.bounding_box.width * 0.5,
                .y = vp_data.bounding_box.y + vp_data.bounding_box.height * 0.5,
            };
        }
    }
    const available_width =
        @max(win_dims.w - debugPanelWidth() - edit_docked_w, 1.0);
    return .{
        .x = available_width * 0.5,
        .y = win_dims.h * 0.5,
    };
}

/// Hit-test target union for interactive controls on the image edit panel.
pub const EditPanelHit = union(enum) {
    close,
    reset_all,
    toggle_compare,
    reset_param: EditParam,
    slider: struct {
        param: EditParam,
        track_x: f32,
        track_w: f32,
    },
};

/// Hit-tests pointer clicks against edit panel controls (buttons and sliders).
pub fn hitTestEditPanel(win_w: f32) ?EditPanelHit {
    if (!isContextActive()) return null;

    if (clay.pointerOver(clay.getElementId("EditCloseBtn"))) {
        return .close;
    }
    if (clay.pointerOver(clay.getElementId("EditResetBtn"))) {
        return .reset_all;
    }
    if (clay.pointerOver(clay.getElementId("EditCompareBtn"))) {
        return .toggle_compare;
    }

    const panel_w = state.EDIT_PANEL_WIDTH;
    const padding = state.EDIT_PANEL_PADDING;
    const fallback_track_w = panel_w - (padding * 2.0);
    const debug_w = debugPanelWidth();
    const fallback_track_x = win_w - debug_w - panel_w + padding;

    inline for (std.enums.values(EditParam)) |param| {
        const spec = getSpec(param);

        if (clay.pointerOver(clay.getElementId(spec.reset_id))) {
            return .{ .reset_param = param };
        }

        const track_id = clay.getElementId(spec.track_id);
        const knob_id = clay.getElementId(spec.knob_id);
        if (clay.pointerOver(track_id) or clay.pointerOver(knob_id)) {
            const elem_data = clay.getElementData(track_id);
            const track_x = if (elem_data.found)
                elem_data.bounding_box.x
            else
                fallback_track_x;
            const track_w = if (elem_data.found)
                elem_data.bounding_box.width
            else
                fallback_track_w;

            return .{
                .slider = .{
                    .param = param,
                    .track_x = track_x,
                    .track_w = track_w,
                },
            };
        }
    }

    return null;
}

/// Synchronizes palette scroll container offset with the active selection
/// index.
pub fn syncPaletteScroll(palette: *PaletteState) void {
    if (!isContextActive()) return;

    const cfg = getPaletteConfig(palette.mode);
    const scroll_data = clay.cdefs.Clay_GetScrollContainerData(
        clay.getElementId(cfg.list_id),
    );
    if (scroll_data.found) {
        scroll_data.scroll_position.y = cfg.resolveScrollOffsetY(
            scroll_data.scroll_position.y,
            palette.matches.items.len,
            palette.selected_idx,
            palette.selection_dirty,
        );
        palette.selection_dirty = false;
    }
}

/// Click hit-test outcome for the command palette overlay.
pub const PaletteClickHit = union(enum) {
    outside,
    inside_unmatched,
    item: usize,
};

/// Hit-tests a mouse pointer click against the command palette modal and items.
pub fn hitTestPaletteClick(
    palette: *const PaletteState,
) PaletteClickHit {
    if (!isContextActive()) return .inside_unmatched;

    const cfg = getPaletteConfig(palette.mode);
    if (!clay.pointerOver(clay.getElementId(cfg.element_id))) {
        return .outside;
    }

    for (palette.matches.items) |real_idx| {
        var item_id_buf: [64]u8 = undefined;
        const item_id_str = std.fmt.bufPrint(
            &item_id_buf,
            "{s}{}",
            .{ cfg.item_prefix, real_idx },
        ) catch |err| blk: {
            std.log.warn("Failed to format palette item ID: {}", .{err});
            break :blk cfg.item_prefix;
        };
        if (clay.pointerOver(clay.getElementId(item_id_str))) {
            return .{ .item = real_idx };
        }
    }
    return .inside_unmatched;
}

fn createTestFrameInput(
    win_w: f32,
    win_h: f32,
    mouse_x: f32,
    mouse_y: f32,
) FrameInput {
    return .{
        .win_w = win_w,
        .win_h = win_h,
        .scale_x = 1.0,
        .scale_y = 1.0,
        .mouse_x = mouse_x,
        .mouse_y = mouse_y,
        .mouse_left_down = false,
        .mouse_left_clicked = false,
        .mouse_inside = true,
        .quit_requested = false,
        .scroll_delta_x = 0.0,
        .scroll_delta_y = 0.0,
        .keys_pressed = .empty,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .delta_time_ms = 16.0,
    };
}

var test_clay_memory: [1024 * 1024]u8 = undefined;

test "syncFrameInput debug mode pointer localization" {
    resetCurrentClayContext();
    defer resetCurrentClayContext();

    const ctx = initClayContext(&test_clay_memory, .{ .w = 1024, .h = 768 });
    setCurrentClayContext(ctx);

    setDebugModeEnabled(true);
    defer setDebugModeEnabled(false);

    const debug_w = debugPanelWidth();
    try std.testing.expect(debug_w > 0.0);

    const input_outside = createTestFrameInput(1024.0, 768.0, 100.0, 100.0);
    const synced_outside = syncFrameInput(input_outside, false);
    try std.testing.expect(!synced_outside.is_pointer_in_debug_panel);

    const input_inside = createTestFrameInput(
        1024.0,
        768.0,
        1024.0 - (debug_w * 0.5),
        100.0,
    );
    const synced_inside = syncFrameInput(input_inside, false);
    try std.testing.expect(synced_inside.is_pointer_in_debug_panel);
}

test "resolveViewportCenter fallback arithmetic" {
    resetCurrentClayContext();
    defer resetCurrentClayContext();

    const ctx = initClayContext(&test_clay_memory, .{ .w = 1000, .h = 800 });
    setCurrentClayContext(ctx);
    setDebugModeEnabled(false);

    const center = resolveViewportCenter(
        .{ .w = 1000.0, .h = 800.0 },
        200.0,
    );
    // available_width = 1000 - 0 - 200 = 800 -> center x = 400, center y = 400
    try std.testing.expectEqual(@as(f32, 400.0), center.x);
    try std.testing.expectEqual(@as(f32, 400.0), center.y);
}
