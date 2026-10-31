//! UI Interaction & Pure-Zig Layout Encapsulation Subsystem
//!
//! Provides the boundary for UI interaction state, layout hit-testing, and
//! scroll synchronization across viewer overlays.

const geom = @import("geom");
const intents = @import("intents");
const palette_pkg = @import("palette");
const state = @import("state");
const std = @import("std");

const EditParam = intents.EditParam;
const FRect = geom.FRect;
const FrameInput = state.FrameInput;
const getPaletteConfig = palette_pkg.getPaletteConfig;
const LogicalDims = geom.LogicalDims;
const LogicalPoint = geom.LogicalPoint;
const PaletteState = palette_pkg.PaletteState;

/// Visible item hit-test record for the command palette overlay.
pub const PaletteItemHit = struct {
    rect: FRect,
    real_idx: usize,
};

/// Internal interaction state tracking pointer location and layout bounds.
const InteractionState = struct {
    has_layout: bool = false,
    pointer: LogicalPoint = .{ .x = -1.0, .y = -1.0 },
    pointer_inside: bool = false,
    pointer_down: bool = false,
    palette_scroll_y: f32 = 0.0,
    edit_scroll_y: f32 = 0.0,
    edit_content_h: f32 = 0.0,

    viewport: ?FRect = null,
    info_card: ?FRect = null,
    info_close_btn: ?FRect = null,
    stats_card: ?FRect = null,
    stats_close_btn: ?FRect = null,
    edit_panel: ?FRect = null,
    edit_scroll_list: ?FRect = null,
    edit_close_btn: ?FRect = null,
    edit_reset_btn: ?FRect = null,
    edit_compare_btn: ?FRect = null,
    slider_tracks: [EditParam.count]?FRect = @splat(null),
    slider_knobs: [EditParam.count]?FRect = @splat(null),
    slider_resets: [EditParam.count]?FRect = @splat(null),
    palette_modal: ?FRect = null,
    palette_captures_pointer: bool = false,
    palette_list: ?FRect = null,
    palette_items: [32]PaletteItemHit = undefined,
    palette_item_count: usize = 0,
};

var state_data: InteractionState = .{};

/// Resets all recorded hit-test geometries before the frame layout pass.
pub fn beginFrameLayout() void {
    state_data.has_layout = true;
    state_data.viewport = null;
    state_data.info_card = null;
    state_data.info_close_btn = null;
    state_data.stats_card = null;
    state_data.stats_close_btn = null;
    state_data.edit_panel = null;
    state_data.edit_scroll_list = null;
    state_data.edit_close_btn = null;
    state_data.edit_reset_btn = null;
    state_data.edit_compare_btn = null;
    state_data.slider_tracks = @splat(null);
    state_data.slider_knobs = @splat(null);
    state_data.slider_resets = @splat(null);
    state_data.palette_modal = null;
    state_data.palette_captures_pointer = false;
    state_data.palette_list = null;
    state_data.palette_item_count = 0;
}

/// Resets global interaction state back to its default uninitialized values.
pub fn resetInteractionState() void {
    state_data = .{};
}

/// Returns true if the pointer is currently inside `rect`.
pub fn isHovered(rect: FRect) bool {
    return state_data.pointer_inside and rect.contains(state_data.pointer);
}

/// Injects test pointer position and button state for unit testing.
pub fn setPointerStateForTest(pt: LogicalPoint, down: bool) void {
    state_data.pointer = pt;
    state_data.pointer_inside = true;
    state_data.pointer_down = down;
}

/// Sets the main viewport bounding rectangle for hit testing.
pub fn setViewportRect(rect: FRect) void {
    state_data.viewport = rect;
}

/// Records the bounding rectangles for the info overlay card and close button.
pub fn setInfoPanelRects(card: FRect, close_btn: FRect) void {
    state_data.info_card = card;
    state_data.info_close_btn = close_btn;
}

/// Records the bounding rectangles for the stats overlay card and close button.
pub fn setStatsPanelRects(card: FRect, close_btn: FRect) void {
    state_data.stats_card = card;
    state_data.stats_close_btn = close_btn;
}

/// Records the bounding rectangles for the edit side panel and its controls.
pub fn setEditPanelRects(
    panel: FRect,
    close_btn: FRect,
    reset_btn: FRect,
    compare_btn: FRect,
    scroll_list: FRect,
) void {
    state_data.edit_panel = panel;
    state_data.edit_close_btn = close_btn;
    state_data.edit_reset_btn = reset_btn;
    state_data.edit_compare_btn = compare_btn;
    state_data.edit_scroll_list = scroll_list;
}

/// Records the bounding rectangles for an individual slider.
pub fn setSliderRects(
    param: EditParam,
    track: FRect,
    knob: FRect,
    reset_btn: FRect,
) void {
    const idx = @backingInt(param);
    if (idx < EditParam.count) {
        state_data.slider_tracks[idx] = track;
        state_data.slider_knobs[idx] = knob;
        state_data.slider_resets[idx] = reset_btn;
    }
}

/// Returns current scroll offset for the edit side panel.
pub fn getEditScrollY() f32 {
    return state_data.edit_scroll_y;
}

/// Sets total content height of edit panel to clamp scroll range.
pub fn setEditContentHeight(h: f32) void {
    state_data.edit_content_h = h;
}

/// Returns current scroll offset for the command palette list.
pub fn getPaletteScrollY() f32 {
    return state_data.palette_scroll_y;
}

/// Sets scroll offset for the command palette list.
pub fn setPaletteScrollY(y: f32) void {
    state_data.palette_scroll_y = y;
}

/// Records the bounding rectangle for the command palette modal dialog.
pub fn setPaletteModalRect(rect: FRect, captures_pointer: bool) void {
    state_data.palette_modal = rect;
    state_data.palette_captures_pointer = captures_pointer;
}

/// Records the bounding rectangle for the virtualized command palette list.
pub fn setPaletteListRect(rect: FRect) void {
    state_data.palette_list = rect;
}

/// Records a visible palette item hit target.
pub fn recordPaletteItem(rect: FRect, real_idx: usize) void {
    if (state_data.palette_item_count < state_data.palette_items.len) {
        state_data.palette_items[state_data.palette_item_count] = .{
            .rect = rect,
            .real_idx = real_idx,
        };
        state_data.palette_item_count += 1;
    }
}

/// Synchronizes window dimensions, mouse pointer state, and scroll containers.
pub fn syncFrameInput(
    input: FrameInput,
    is_slider_active: bool,
) void {
    state_data.pointer = if (input.mouse_inside)
        input.logicalMousePos()
    else
        .{ .x = -1.0, .y = -1.0 };
    state_data.pointer_inside = input.mouse_inside;
    state_data.pointer_down = input.mouse_left_down;

    if (!is_slider_active and input.scroll_delta_y != 0.0) {
        if (state_data.edit_scroll_list) |srect| {
            if (srect.contains(state_data.pointer)) {
                const max_scroll =
                    @max(0.0, state_data.edit_content_h - srect.h);
                const next_scroll = state_data.edit_scroll_y +
                    (input.scroll_delta_y * 24.0);
                state_data.edit_scroll_y =
                    std.math.clamp(next_scroll, -max_scroll, 0.0);
            }
        }
    }
}

/// Returns true if pointer is hovering over the info close button.
pub fn isPointerOverInfoCloseBtn() bool {
    if (!state_data.has_layout) return false;
    const btn = state_data.info_close_btn orelse return false;
    return btn.contains(state_data.pointer);
}

/// Returns true if pointer is hovering over the stats close button.
pub fn isPointerOverStatsCloseBtn() bool {
    if (!state_data.has_layout) return false;
    const btn = state_data.stats_close_btn orelse return false;
    return btn.contains(state_data.pointer);
}

/// Returns true if pointer is hovering over the info overlay panel.
pub fn isPointerOverInfoPanel() bool {
    if (!state_data.has_layout) return false;
    const card = state_data.info_card orelse return false;
    return card.contains(state_data.pointer);
}

/// Returns true if pointer is hovering over the stats overlay panel.
pub fn isPointerOverStatsPanel() bool {
    if (!state_data.has_layout) return false;
    const card = state_data.stats_card orelse return false;
    return card.contains(state_data.pointer);
}

/// Returns true if pointer is hovering over the edit side panel.
pub fn isPointerOverEditPanel() bool {
    if (!state_data.has_layout) return false;
    const panel = state_data.edit_panel orelse return false;
    return panel.contains(state_data.pointer);
}

/// Returns true if pointer is hovering over the main viewport.
pub fn isPointerOverViewport() bool {
    if (!state_data.has_layout) return false;
    const vp = state_data.viewport orelse return false;
    if (!vp.contains(state_data.pointer)) return false;
    if (state_data.palette_captures_pointer) {
        if (state_data.palette_modal) |modal| {
            if (modal.contains(state_data.pointer)) return false;
        }
    }
    if (state_data.info_card) |card| {
        if (card.contains(state_data.pointer)) return false;
    }
    if (state_data.stats_card) |card| {
        if (card.contains(state_data.pointer)) return false;
    }
    return true;
}

/// Resolves the center coordinates of the main viewport element in logical UI
/// coordinates, falling back to layout math when element is not found.
pub fn resolveViewportCenter(
    win_dims: LogicalDims,
    edit_docked_w: f32,
) LogicalPoint {
    if (state_data.viewport) |vp| {
        return vp.center();
    }
    const available_width =
        @max(win_dims.w - edit_docked_w, 1.0);
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
    if (!state_data.has_layout) return null;
    _ = win_w;

    if (state_data.edit_close_btn) |btn| {
        if (btn.contains(state_data.pointer)) return .close;
    }
    if (state_data.edit_reset_btn) |btn| {
        if (btn.contains(state_data.pointer)) return .reset_all;
    }
    if (state_data.edit_compare_btn) |btn| {
        if (btn.contains(state_data.pointer)) return .toggle_compare;
    }

    inline for (std.enums.values(EditParam)) |param| {
        const idx = @backingInt(param);
        if (idx < EditParam.count) {
            if (state_data.slider_resets[idx]) |rbtn| {
                if (rbtn.contains(state_data.pointer)) {
                    return .{ .reset_param = param };
                }
            }
            const track_opt = state_data.slider_tracks[idx];
            const knob_opt = state_data.slider_knobs[idx];
            const over_track = if (track_opt) |t|
                t.contains(state_data.pointer)
            else
                false;
            const over_knob = if (knob_opt) |k|
                k.contains(state_data.pointer)
            else
                false;
            if (over_track or over_knob) {
                if (track_opt) |t| {
                    return .{
                        .slider = .{
                            .param = param,
                            .track_x = t.x,
                            .track_w = t.w,
                        },
                    };
                }
            }
        }
    }

    return null;
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
    _ = palette;
    if (!state_data.has_layout) return .inside_unmatched;

    if (state_data.palette_modal) |modal| {
        if (!modal.contains(state_data.pointer)) {
            return .outside;
        }
    }

    for (state_data.palette_items[0..state_data.palette_item_count]) |item| {
        if (item.rect.contains(state_data.pointer)) {
            return .{ .item = item.real_idx };
        }
    }
    return .inside_unmatched;
}

/// Synchronizes palette scroll container offset with the active selection
/// index.
pub fn syncPaletteScroll(palette: *PaletteState) void {
    const cfg = getPaletteConfig(palette.mode);
    state_data.palette_scroll_y = cfg.resolveScrollOffsetY(
        state_data.palette_scroll_y,
        palette.matches.items.len,
        palette.selected_idx,
        palette.selection_dirty,
    );
    palette.selection_dirty = false;
}

test "resolveViewportCenter fallback arithmetic" {
    resetInteractionState();
    defer resetInteractionState();

    const center = resolveViewportCenter(
        .{ .w = 1000.0, .h = 800.0 },
        200.0,
    );
    // available_width = 1000 - 200 = 800 -> center x = 400, center y = 400
    try std.testing.expectEqual(@as(f32, 400.0), center.x);
    try std.testing.expectEqual(@as(f32, 400.0), center.y);
}

test "interaction state hit-testing and viewport isolation" {
    resetInteractionState();
    defer resetInteractionState();

    beginFrameLayout();
    setViewportRect(.{ .x = 0, .y = 0, .w = 800, .h = 600 });
    setInfoPanelRects(
        .{ .x = 10, .y = 10, .w = 300, .h = 200 },
        .{ .x = 280, .y = 14, .w = 20, .h = 20 },
    );

    setPointerStateForTest(.{ .x = 290, .y = 20 }, false);
    try std.testing.expect(isPointerOverInfoCloseBtn());
    try std.testing.expect(isPointerOverInfoPanel());
    try std.testing.expect(!isPointerOverViewport());

    setPointerStateForTest(.{ .x = 500, .y = 300 }, false);
    try std.testing.expect(!isPointerOverInfoCloseBtn());
    try std.testing.expect(!isPointerOverInfoPanel());
    try std.testing.expect(isPointerOverViewport());
}
