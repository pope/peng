//! Pure Data-Driven Intent Schema Definition
//!
//! Defines high-level application intents, scaling modes, palette modes,
//! and command payloads without depending on UI, hardware, or state structs.

const std = @import("std");

pub const actions = @import("actions.zig");
pub const keys = @import("keys.zig");
pub const types = @import("types.zig");

pub const AdjustIntent = types.AdjustIntent;
pub const AppIntent = types.AppIntent;
pub const Classification = types.Classification;
pub const CliOption = actions.CliOption;
pub const CliTarget = actions.CliTarget;
pub const DisplayKind = types.DisplayKind;
pub const EditDomain = types.EditDomain;
pub const EditParam = types.EditParam;
pub const filter_modes_string = types.filter_modes_string;
pub const fromSlug = types.fromSlug;
pub const getSpec = types.getSpec;
pub const IpcCommandDesc = actions.IpcCommandDesc;
pub const Key = keys.Key;
pub const KeyboardShortcut = keys.KeyboardShortcut;
pub const KeyModifiers = keys.KeyModifiers;
pub const OptionId = actions.OptionId;
pub const PaletteMode = types.PaletteMode;
pub const ParamSpec = types.ParamSpec;
pub const PositiveDimsU32 = types.PositiveDimsU32;
pub const scale_modes_string = types.scale_modes_string;
pub const specs = types.specs;
pub const StepDirection = types.StepDirection;
pub const TextInputBounds = types.TextInputBounds;
pub const TextureScaleMode = types.TextureScaleMode;
pub const ThumbCacheMode = types.ThumbCacheMode;
pub const thumb_cache_modes_string = types.thumb_cache_modes_string;
pub const ViewMode = types.ViewMode;
pub const ZoomPreset = types.ZoomPreset;

test {
    _ = actions;
    _ = keys;
    _ = types;
}
