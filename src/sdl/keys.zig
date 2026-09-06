const c = @import("c.zig").c;

pub const Keycode = u32;

pub const escape: Keycode = c.SDLK_ESCAPE;
pub const return_key: Keycode = c.SDLK_RETURN;
pub const kp_enter: Keycode = c.SDLK_KP_ENTER;
pub const backspace: Keycode = c.SDLK_BACKSPACE;
pub const tab: Keycode = c.SDLK_TAB;
pub const space: Keycode = c.SDLK_SPACE;
pub const left: Keycode = c.SDLK_LEFT;
pub const right: Keycode = c.SDLK_RIGHT;
pub const up: Keycode = c.SDLK_UP;
pub const down: Keycode = c.SDLK_DOWN;
pub const equals: Keycode = c.SDLK_EQUALS;
pub const kp_plus: Keycode = c.SDLK_KP_PLUS;
pub const minus: Keycode = c.SDLK_MINUS;
pub const kp_minus: Keycode = c.SDLK_KP_MINUS;
pub const left_bracket: Keycode = c.SDLK_LEFTBRACKET;
pub const right_bracket: Keycode = c.SDLK_RIGHTBRACKET;
pub const home: Keycode = c.SDLK_HOME;
pub const end: Keycode = c.SDLK_END;
pub const page_up: Keycode = c.SDLK_PAGEUP;
pub const page_down: Keycode = c.SDLK_PAGEDOWN;
pub const f1: Keycode = c.SDLK_F1;
pub const f11: Keycode = c.SDLK_F11;

pub const char_0: Keycode = c.SDLK_0;
pub const kp_0: Keycode = c.SDLK_KP_0;
pub const char_1: Keycode = c.SDLK_1;
pub const kp_1: Keycode = c.SDLK_KP_1;
pub const char_2: Keycode = c.SDLK_2;
pub const kp_2: Keycode = c.SDLK_KP_2;
pub const char_3: Keycode = c.SDLK_3;
pub const kp_3: Keycode = c.SDLK_KP_3;
pub const char_4: Keycode = c.SDLK_4;
pub const kp_4: Keycode = c.SDLK_KP_4;
pub const char_5: Keycode = c.SDLK_5;
pub const kp_5: Keycode = c.SDLK_KP_5;
pub const char_6: Keycode = c.SDLK_6;
pub const kp_6: Keycode = c.SDLK_KP_6;
pub const char_7: Keycode = c.SDLK_7;
pub const kp_7: Keycode = c.SDLK_KP_7;
pub const char_8: Keycode = c.SDLK_8;
pub const kp_8: Keycode = c.SDLK_KP_8;
pub const char_9: Keycode = c.SDLK_9;
pub const kp_9: Keycode = c.SDLK_KP_9;

pub const key_a: Keycode = c.SDLK_A;
pub const key_b: Keycode = c.SDLK_B;
pub const key_c: Keycode = c.SDLK_C;
pub const key_d: Keycode = c.SDLK_D;
pub const key_e: Keycode = c.SDLK_E;
pub const key_f: Keycode = c.SDLK_F;
pub const key_g: Keycode = c.SDLK_G;
pub const key_h: Keycode = c.SDLK_H;
pub const key_i: Keycode = c.SDLK_I;
pub const key_j: Keycode = c.SDLK_J;
pub const key_k: Keycode = c.SDLK_K;
pub const key_l: Keycode = c.SDLK_L;
pub const key_m: Keycode = c.SDLK_M;
pub const key_n: Keycode = c.SDLK_N;
pub const key_o: Keycode = c.SDLK_O;
pub const key_p: Keycode = c.SDLK_P;
pub const key_q: Keycode = c.SDLK_Q;
pub const key_r: Keycode = c.SDLK_R;
pub const key_s: Keycode = c.SDLK_S;
pub const key_t: Keycode = c.SDLK_T;
pub const key_u: Keycode = c.SDLK_U;
pub const key_v: Keycode = c.SDLK_V;
pub const key_w: Keycode = c.SDLK_W;
pub const key_x: Keycode = c.SDLK_X;
pub const key_y: Keycode = c.SDLK_Y;
pub const key_z: Keycode = c.SDLK_Z;

/// Bitmask constants representing keyboard modifier keys (Ctrl, Shift, Alt, GUI).
pub const mod = struct {
    pub const ctrl: u16 = c.SDL_KMOD_CTRL;
    pub const shift: u16 = c.SDL_KMOD_SHIFT;
    pub const alt: u16 = c.SDL_KMOD_ALT;
    pub const gui: u16 = c.SDL_KMOD_GUI;
};

/// Queries the current keyboard modifier key state mask from SDL.
pub fn getModState() u16 {
    return c.SDL_GetModState();
}
