const app_state = @import("../state.zig");
const context = @import("context.zig");
const intents = @import("intents");
const state = @import("state");
const std = @import("std");
const ui = @import("ui");

const AppState = app_state.AppState;
const EditParam = intents.EditParam;
const FrameContext = context.FrameContext;
const FrameInput = state.FrameInput;
const getSpec = intents.getSpec;
const ParamSpec = intents.ParamSpec;

fn computeSliderValue(
    spec: ParamSpec,
    track_x: f32,
    track_w: f32,
    mouse_x: f32,
) f32 {
    const knob_d: f32 = 16.0;
    const usable_w = @max(track_w - knob_d, 1.0);
    const rel_x = mouse_x - track_x;
    const offset_x = rel_x - (knob_d * 0.5);
    const t = std.math.clamp(offset_x / usable_w, 0.0, 1.0);
    const raw_val = spec.min + t * (spec.max - spec.min);
    return spec.snap(raw_val);
}

fn processEditPanelClicks(self: *AppState, input: FrameInput) !void {
    const hit = ui.interaction.hitTestEditPanel(input.win_w) orelse return;
    switch (hit) {
        .close => try self.pushIntent(.{ .set_edit_panel = false }),
        .reset_all => try self.pushIntent(.{ .adjust = .reset_all }),
        .toggle_compare => try self.pushIntent(.{ .adjust = .toggle_compare }),
        .reset_param => |param| {
            try self.pushIntent(.{ .adjust = .{ .reset_param = param } });
        },
        .slider => |s| {
            self.viewer.drag_state = .{
                .slider = .{
                    .param = s.param,
                    .track_x = s.track_x,
                    .track_w = s.track_w,
                },
            };
            self.viewer.ui.overlays.edit_panel.active_slider = s.param;

            const spec = getSpec(s.param);
            const val = computeSliderValue(
                spec,
                s.track_x,
                s.track_w,
                input.mouse_x,
            );
            try self.pushIntent(.{
                .adjust = .{ .set = .{ .param = s.param, .value = val } },
            });
        },
    }
}

/// System Pass: Process discrete UI component pointer interactions
/// (close buttons, controls, sliders).
///
/// Responsibilities:
/// 1. Updates continuous slider dragging state while mouse button is held.
/// 2. Tests mouse clicks against interactive buttons (close, compare, reset).
/// 3. Initiates slider dragging when clicking on track or knob.
pub fn sysProcessUiInteractions(
    ctx: FrameContext,
    palette_closed_this_frame: bool,
) !void {
    const self = ctx.state;
    const input = ctx.input orelse return;
    const palette_blocking = self.viewer.ui.palette.isAcceptingInput() or
        palette_closed_this_frame;

    // 1. Continuous Slider Dragging Update
    switch (self.viewer.drag_state) {
        .slider => |s| {
            if (input.mouse_left_down and
                !palette_blocking and
                self.viewer.ui.overlays.edit_panel.visible)
            {
                const spec = getSpec(s.param);
                const val = computeSliderValue(
                    spec,
                    s.track_x,
                    s.track_w,
                    input.mouse_x,
                );
                try self.pushIntent(.{
                    .adjust = .{ .set = .{ .param = s.param, .value = val } },
                });
            } else {
                self.viewer.drag_state = .none;
                self.viewer.ui.overlays.edit_panel.active_slider = null;
            }
        },
        .none, .viewport, .info, .stats, .atlas => {},
    }

    // 2. Discrete Clicks (Buttons & Initial Slider Click)
    if (palette_blocking or !input.mouse_left_clicked) {
        return;
    }

    // Floating Overlays Close Buttons
    if (self.viewer.ui.overlays.info_panel.visible and
        ui.interaction.isPointerOverInfoCloseBtn())
    {
        try self.pushIntent(.{ .set_info = false });
    }
    if (self.viewer.ui.overlays.stats_panel.visible and
        ui.interaction.isPointerOverStatsCloseBtn())
    {
        try self.pushIntent(.{ .set_stats = false });
    }
    if (self.viewer.ui.overlays.atlas_panel.visible and
        ui.interaction.isPointerOverAtlasCloseBtn())
    {
        try self.pushIntent(.{ .set_atlas = false });
    }

    // Edit Side Panel Controls
    if (self.viewer.ui.overlays.edit_panel.visible) {
        try processEditPanelClicks(self, input);
    }
}

test "sysProcessUiInteractions cancels slider drag when palette opens" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var app_st = try AppState.initHeadless(allocator, io);
    defer app_st.deinit();

    app_st.viewer.ui.overlays.edit_panel.visible = true;
    app_st.viewer.ui.overlays.edit_panel.active_slider = .brightness;
    app_st.viewer.drag_state = .{
        .slider = .{
            .param = .brightness,
            .track_x = 100.0,
            .track_w = 200.0,
        },
    };

    const frame_input = FrameInput{
        .win_w = 800,
        .win_h = 600,
        .scale_x = 1.0,
        .scale_y = 1.0,
        .mouse_x = 150.0,
        .mouse_y = 100.0,
        .mouse_left_down = true,
        .mouse_left_clicked = false,
        .mouse_inside = true,
        .quit_request = .none,
        .scroll_delta_x = 0,
        .scroll_delta_y = 0,
        .keys_pressed = .empty,
        .key_modifiers = .{},
        .text_input = null,
        .dropped_path = null,
        .delta_time_ms = 16.0,
    };

    // Opening the palette while dragging a slider cancels the drag
    app_st.viewer.ui.palette.mode = .actions;
    app_st.viewer.ui.palette.is_closing = false;
    try sysProcessUiInteractions(.{
        .state = &app_st,
        .frame_allocator = allocator,
        .input = frame_input,
        .delta_time_ms = 16.0,
    }, false);

    try std.testing.expectEqual(state.DragState.none, app_st.viewer.drag_state);
    try std.testing.expectEqual(
        @as(?EditParam, null),
        app_st.viewer.ui.overlays.edit_panel.active_slider,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        app_st.pending_intents.items.len,
    );
}
