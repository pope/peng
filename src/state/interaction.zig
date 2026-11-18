//! UI Interaction & Pure-Zig Layout Encapsulation Subsystem
//!
//! Provides the boundary for UI interaction state, layout hit-testing, and
//! scroll synchronization across viewer overlays.

const geom = @import("geom");
const intents = @import("intents");
const palette_pkg = @import("palette");
const std = @import("std");
const types = @import("types.zig");

const EditParam = intents.EditParam;
const FRect = geom.FRect;
const FrameInput = types.FrameInput;
const getPaletteConfig = palette_pkg.getPaletteConfig;
const LogicalDims = geom.LogicalDims;
const LogicalPoint = geom.LogicalPoint;
const PaletteState = palette_pkg.PaletteState;

/// Visible item hit-test record for the command palette overlay.
pub const PaletteItemHit = struct {
    rect: FRect,
    real_idx: usize,
};

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

/// Click hit-test outcome for the command palette overlay.
pub const PaletteClickHit = union(enum) {
    outside,
    inside_unmatched,
    item: usize,
};

/// Internal interaction state tracking pointer location and layout bounds.
pub const InteractionState = struct {
    has_layout: bool = false,
    pointer: LogicalPoint = .{ .x = -1.0, .y = -1.0 },
    pointer_inside: bool = false,
    palette_scroll_y: f32 = 0.0,
    edit_scroll_y: f32 = 0.0,
    edit_content_h: f32 = 0.0,

    viewport: ?FRect = null,
    info_card: ?FRect = null,
    info_close_btn: ?FRect = null,
    stats_card: ?FRect = null,
    stats_close_btn: ?FRect = null,
    atlas_card: ?FRect = null,
    atlas_close_btn: ?FRect = null,
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
    palette_items: [32]PaletteItemHit = undefined,
    palette_item_count: usize = 0,

    /// Resets all interaction state back to uninitialized default values.
    pub fn reset(self: *InteractionState) void {
        self.* = .{};
    }

    /// Resets all recorded hit-test geometries before the frame layout pass.
    pub fn beginFrameLayout(self: *InteractionState) void {
        self.has_layout = true;
        self.viewport = null;
        self.info_card = null;
        self.info_close_btn = null;
        self.stats_card = null;
        self.stats_close_btn = null;
        self.atlas_card = null;
        self.atlas_close_btn = null;
        self.edit_panel = null;
        self.edit_scroll_list = null;
        self.edit_close_btn = null;
        self.edit_reset_btn = null;
        self.edit_compare_btn = null;
        self.slider_tracks = @splat(null);
        self.slider_knobs = @splat(null);
        self.slider_resets = @splat(null);
        self.palette_modal = null;
        self.palette_captures_pointer = false;
        self.palette_item_count = 0;
    }

    /// Returns true if the pointer is currently inside `rect`.
    pub fn isHovered(self: *const InteractionState, rect: FRect) bool {
        return self.pointer_inside and rect.contains(self.pointer);
    }

    /// Injects test pointer position for unit testing.
    pub fn setPointerStateForTest(
        self: *InteractionState,
        pt: LogicalPoint,
    ) void {
        self.pointer = pt;
        self.pointer_inside = true;
    }

    /// Records the bounding rectangles for the info overlay card and close
    /// button.
    pub fn setInfoPanelRects(
        self: *InteractionState,
        card: FRect,
        close_btn: FRect,
    ) void {
        self.info_card = card;
        self.info_close_btn = close_btn;
    }

    /// Records the bounding rectangles for the stats overlay card and close
    /// button.
    pub fn setStatsPanelRects(
        self: *InteractionState,
        card: FRect,
        close_btn: FRect,
    ) void {
        self.stats_card = card;
        self.stats_close_btn = close_btn;
    }

    /// Records the bounding rectangles for the font atlas overlay card and
    /// close button.
    pub fn setAtlasPanelRects(
        self: *InteractionState,
        card: FRect,
        close_btn: FRect,
    ) void {
        self.atlas_card = card;
        self.atlas_close_btn = close_btn;
    }

    /// Records the bounding rectangles for the edit side panel and its
    /// controls.
    pub fn setEditPanelRects(
        self: *InteractionState,
        panel: FRect,
        close_btn: FRect,
        reset_btn: FRect,
        compare_btn: FRect,
        scroll_list: FRect,
    ) void {
        self.edit_panel = panel;
        self.edit_close_btn = close_btn;
        self.edit_reset_btn = reset_btn;
        self.edit_compare_btn = compare_btn;
        self.edit_scroll_list = scroll_list;
    }

    /// Records the bounding rectangles for an individual slider.
    pub fn setSliderRects(
        self: *InteractionState,
        param: EditParam,
        track: FRect,
        knob: FRect,
        reset_btn: FRect,
    ) void {
        const idx = @backingInt(param);
        if (idx < EditParam.count) {
            self.slider_tracks[idx] = track;
            self.slider_knobs[idx] = knob;
            self.slider_resets[idx] = reset_btn;
        }
    }

    /// Records the bounding rectangle for the command palette modal dialog.
    pub fn setPaletteModalRect(
        self: *InteractionState,
        rect: FRect,
        captures_pointer: bool,
    ) void {
        self.palette_modal = rect;
        self.palette_captures_pointer = captures_pointer;
    }

    /// Records a visible palette item hit target.
    pub fn recordPaletteItem(
        self: *InteractionState,
        rect: FRect,
        real_idx: usize,
    ) void {
        if (self.palette_item_count < self.palette_items.len) {
            self.palette_items[self.palette_item_count] = .{
                .rect = rect,
                .real_idx = real_idx,
            };
            self.palette_item_count += 1;
        }
    }

    /// Synchronizes window dimensions, mouse pointer state, and scroll
    /// containers.
    pub fn syncFrameInput(
        self: *InteractionState,
        input: FrameInput,
        is_slider_active: bool,
    ) void {
        self.pointer = if (input.mouse_inside)
            input.logicalMousePos()
        else
            .{ .x = -1.0, .y = -1.0 };
        self.pointer_inside = input.mouse_inside;

        if (!is_slider_active and input.scroll_delta_y != 0.0) {
            if (self.edit_scroll_list) |srect| {
                if (srect.contains(self.pointer)) {
                    const max_scroll =
                        @max(0.0, self.edit_content_h - srect.h);
                    const next_scroll = self.edit_scroll_y +
                        (input.scroll_delta_y * 24.0);
                    self.edit_scroll_y =
                        std.math.clamp(next_scroll, -max_scroll, 0.0);
                }
            }
        }
    }

    /// Returns true if pointer is hovering over the info close button.
    pub fn isPointerOverInfoCloseBtn(self: *const InteractionState) bool {
        if (!self.has_layout) return false;
        const btn = self.info_close_btn orelse return false;
        return btn.contains(self.pointer);
    }

    /// Returns true if pointer is hovering over the stats close button.
    pub fn isPointerOverStatsCloseBtn(self: *const InteractionState) bool {
        if (!self.has_layout) return false;
        const btn = self.stats_close_btn orelse return false;
        return btn.contains(self.pointer);
    }

    /// Returns true if pointer is hovering over the font atlas close button.
    pub fn isPointerOverAtlasCloseBtn(self: *const InteractionState) bool {
        if (!self.has_layout) return false;
        const btn = self.atlas_close_btn orelse return false;
        return btn.contains(self.pointer);
    }

    /// Returns true if pointer is hovering over the info overlay panel.
    pub fn isPointerOverInfoPanel(self: *const InteractionState) bool {
        if (!self.has_layout) return false;
        const card = self.info_card orelse return false;
        return card.contains(self.pointer);
    }

    /// Returns true if pointer is hovering over the stats overlay panel.
    pub fn isPointerOverStatsPanel(self: *const InteractionState) bool {
        if (!self.has_layout) return false;
        const card = self.stats_card orelse return false;
        return card.contains(self.pointer);
    }

    /// Returns true if pointer is hovering over the font atlas overlay panel.
    pub fn isPointerOverAtlasPanel(self: *const InteractionState) bool {
        if (!self.has_layout) return false;
        const card = self.atlas_card orelse return false;
        return card.contains(self.pointer);
    }

    /// Returns true if pointer is hovering over the edit side panel.
    pub fn isPointerOverEditPanel(self: *const InteractionState) bool {
        if (!self.has_layout) return false;
        const panel = self.edit_panel orelse return false;
        return panel.contains(self.pointer);
    }

    /// Returns true if pointer is hovering over the main viewport.
    pub fn isPointerOverViewport(self: *const InteractionState) bool {
        if (!self.has_layout) return false;
        const vp = self.viewport orelse return false;
        if (!vp.contains(self.pointer)) return false;
        if (self.palette_captures_pointer) {
            if (self.palette_modal) |modal| {
                if (modal.contains(self.pointer)) return false;
            }
        }
        if (self.info_card) |card| {
            if (card.contains(self.pointer)) return false;
        }
        if (self.stats_card) |card| {
            if (card.contains(self.pointer)) return false;
        }
        if (self.atlas_card) |card| {
            if (card.contains(self.pointer)) return false;
        }
        return true;
    }

    /// Resolves the center coordinates of the main viewport element in logical
    /// UI coordinates, falling back to layout math when element is not found.
    pub fn resolveViewportCenter(
        self: *const InteractionState,
        win_dims: LogicalDims,
        edit_docked_w: f32,
    ) LogicalPoint {
        if (self.viewport) |vp| {
            return vp.center();
        }
        const available_width =
            @max(win_dims.w - edit_docked_w, 1.0);
        return .{
            .x = available_width * 0.5,
            .y = win_dims.h * 0.5,
        };
    }

    /// Hit-tests pointer clicks against edit panel controls (buttons and
    /// sliders).
    pub fn hitTestEditPanel(self: *const InteractionState) ?EditPanelHit {
        if (!self.has_layout) return null;

        if (self.edit_close_btn) |btn| {
            if (btn.contains(self.pointer)) return .close;
        }
        if (self.edit_reset_btn) |btn| {
            if (btn.contains(self.pointer)) return .reset_all;
        }
        if (self.edit_compare_btn) |btn| {
            if (btn.contains(self.pointer)) return .toggle_compare;
        }

        inline for (std.enums.values(EditParam)) |param| {
            const idx = @backingInt(param);
            if (idx < EditParam.count) {
                if (self.slider_resets[idx]) |rbtn| {
                    if (rbtn.contains(self.pointer)) {
                        return .{ .reset_param = param };
                    }
                }
                const track_opt = self.slider_tracks[idx];
                const knob_opt = self.slider_knobs[idx];
                const over_track = if (track_opt) |t|
                    t.contains(self.pointer)
                else
                    false;
                const over_knob = if (knob_opt) |k|
                    k.contains(self.pointer)
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

    /// Hit-tests a mouse pointer click against the command palette modal and
    /// items.
    pub fn hitTestPaletteClick(
        self: *const InteractionState,
    ) PaletteClickHit {
        if (!self.has_layout) return .inside_unmatched;

        if (self.palette_modal) |modal| {
            if (!modal.contains(self.pointer)) {
                return .outside;
            }
        }

        for (self.palette_items[0..self.palette_item_count]) |item| {
            if (item.rect.contains(self.pointer)) {
                return .{ .item = item.real_idx };
            }
        }
        return .inside_unmatched;
    }

    /// Synchronizes palette scroll container offset with the active selection
    /// index.
    pub fn syncPaletteScroll(
        self: *InteractionState,
        palette: *PaletteState,
    ) void {
        const mode = palette.visibleMode() orelse return;
        const cfg = getPaletteConfig(mode);
        self.palette_scroll_y = cfg.resolveScrollOffsetY(
            self.palette_scroll_y,
            palette.matches.items.len,
            palette.selected_idx,
            palette.selection_dirty,
        );
        palette.selection_dirty = false;
    }
};

test "resolveViewportCenter fallback arithmetic" {
    var state_inst: InteractionState = .{};

    const center = state_inst.resolveViewportCenter(
        .{ .w = 1000.0, .h = 800.0 },
        200.0,
    );
    // available_width = 1000 - 200 = 800 -> center x = 400, center y = 400
    try std.testing.expectEqual(@as(f32, 400.0), center.x);
    try std.testing.expectEqual(@as(f32, 400.0), center.y);
}

test "interaction state hit-testing and viewport isolation" {
    var state_inst: InteractionState = .{};

    state_inst.beginFrameLayout();
    state_inst.viewport = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    state_inst.setInfoPanelRects(
        .{ .x = 10, .y = 10, .w = 300, .h = 200 },
        .{ .x = 280, .y = 14, .w = 20, .h = 20 },
    );

    state_inst.setPointerStateForTest(.{ .x = 290, .y = 20 });
    try std.testing.expect(state_inst.isPointerOverInfoCloseBtn());
    try std.testing.expect(state_inst.isPointerOverInfoPanel());
    try std.testing.expect(!state_inst.isPointerOverViewport());

    state_inst.setPointerStateForTest(.{ .x = 500, .y = 300 });
    try std.testing.expect(!state_inst.isPointerOverInfoCloseBtn());
    try std.testing.expect(!state_inst.isPointerOverInfoPanel());
    try std.testing.expect(state_inst.isPointerOverViewport());
}
