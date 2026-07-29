pub const input = @import("input/root.zig");

pub const mapKeyFromSdl = input.mapKeyFromSdl;
pub const mapModFromSdl = input.mapModFromSdl;
pub const FrameInputState = input.FrameInputState;
pub const processSDLEvent = input.processSDLEvent;
pub const pollFrameInput = input.pollFrameInput;
pub const MOUSE_WHEEL_SCROLL_MULTIPLIER = input.MOUSE_WHEEL_SCROLL_MULTIPLIER;

pub const KeyContext = input.KeyContext;
pub const InputAction = input.InputAction;
pub const mapKeyToAction = input.mapKeyToAction;

pub const handlePaletteKeys = input.handlePaletteKeys;
pub const handleKeyDown = input.handleKeyDown;
