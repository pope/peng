//! Pure Data-Driven Intent Schema Definition
//!
//! Defines high-level application intents, scaling modes, palette modes,
//! and command payloads without depending on UI, hardware, or state structs.

const std = @import("std");

pub const keys = @import("keys.zig");
pub const types = @import("types.zig");
pub const actions = @import("actions.zig");

pub const Key = keys.Key;
pub const KeyModifiers = keys.KeyModifiers;
pub const KeyboardShortcut = keys.KeyboardShortcut;

pub const Classification = types.Classification;
pub const PositiveDimsU32 = types.PositiveDimsU32;
pub const ViewMode = types.ViewMode;
pub const ZoomPreset = types.ZoomPreset;
pub const TextureScaleMode = types.TextureScaleMode;
pub const ThumbCacheMode = types.ThumbCacheMode;
pub const scale_modes_string = types.scale_modes_string;
pub const filter_modes_string = types.filter_modes_string;
pub const thumb_cache_modes_string = types.thumb_cache_modes_string;
pub const TextInputBounds = types.TextInputBounds;
pub const PaletteMode = types.PaletteMode;
pub const EditParam = types.EditParam;
pub const StepDirection = types.StepDirection;
pub const AdjustIntent = types.AdjustIntent;
pub const AppIntent = types.AppIntent;

pub const CliTarget = actions.CliTarget;
pub const OptionId = actions.OptionId;
pub const CliOption = actions.CliOption;
pub const IpcCommandDesc = actions.IpcCommandDesc;

test {
    _ = keys;
    _ = types;
    _ = actions;
}
