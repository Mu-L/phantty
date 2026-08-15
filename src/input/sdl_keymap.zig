//! Pure SDL3 scancode/modifier → neutral input mapping. Operates on SDL3's
//! stable ABI integer values (see SDL_scancode.h / SDL_keycode.h KMOD_*), so it
//! has no SDL dependency and runs in the fast suite. The SDL shell
//! (`apprt/sdl.zig`) passes `@intFromEnum(event.key.scancode)` and the keymod
//! bitmask here.
const std = @import("std");
const ev = @import("../platform/input_events.zig");

pub const Mods = struct { ctrl: bool, shift: bool, alt: bool, super: bool };

/// SDL3 stable scancode values → neutral KeyCode. Returns null for keys whose
/// text should arrive via SDL_EVENT_TEXT_INPUT (printable characters).
pub fn keyCodeFromScancode(scancode: u32) ?ev.KeyCode {
    return switch (scancode) {
        42 => ev.key_backspace, // SDL_SCANCODE_BACKSPACE
        43 => ev.key_tab, // TAB
        44 => ev.key_space, // SPACE
        40 => ev.key_enter, // RETURN
        41 => ev.key_escape, // ESCAPE
        62 => ev.key_f5, // F5
        73 => ev.key_insert, // INSERT
        74 => ev.key_home, // HOME
        75 => ev.key_page_up, // PAGEUP
        76 => ev.key_delete, // DELETE
        77 => ev.key_end, // END
        78 => ev.key_page_down, // PAGEDOWN
        79 => ev.key_right, // RIGHT
        80 => ev.key_left, // LEFT
        81 => ev.key_down, // DOWN
        82 => ev.key_up, // UP
        224 => ev.key_left_control, // LCTRL
        225 => ev.key_left_shift, // LSHIFT
        226 => ev.key_left_alt, // LALT
        227 => null, // LGUI: super flag only, no key code constant
        228 => ev.key_right_control, // RCTRL
        229 => ev.key_right_shift, // RSHIFT
        230 => ev.key_right_alt, // RALT
        else => null,
    };
}

/// SDL3 keycode → neutral KeyCode for alphanumeric and punctuation keys.
/// Returns uppercase letters ('A'-'Z'), digits ('0'-'9'), and common punctuation.
/// Returns null for keys that should be handled via scancode or text input.
pub fn keyCodeFromSdlKeycode(keycode: u32) ?ev.KeyCode {
    // SDL keycodes for lowercase letters are 'a'-'z' (97-122)
    // SDL keycodes for uppercase letters are 'A'-'Z' (65-90)
    // Convert lowercase to uppercase for consistency with Windows/macOS keybind system
    if (keycode >= 'a' and keycode <= 'z') {
        return keycode - ('a' - 'A');
    }
    // Uppercase letters and digits are their ASCII values
    if ((keycode >= 'A' and keycode <= 'Z') or (keycode >= '0' and keycode <= '9')) {
        return keycode;
    }
    // Common punctuation that may be used in shortcuts
    // These match the Key constants in keybind.zig
    return switch (keycode) {
        '`' => 0xC0, // backquote
        ',' => 0xBC, // comma
        '+' => 0xBB, // plus
        '=' => 0xBB, // equal (same as plus for keybinds)
        '-' => 0xBD, // minus
        '[' => 0xDB, // bracket_left
        ']' => 0xDD, // bracket_right
        else => null,
    };
}

/// SDL3 keymod bitmask (KMOD_*) → neutral modifier flags.
pub fn modifiers(mod: u16) Mods {
    return .{
        .ctrl = (mod & (0x0040 | 0x0080)) != 0, // LCTRL|RCTRL
        .shift = (mod & (0x0001 | 0x0002)) != 0, // LSHIFT|RSHIFT
        .alt = (mod & (0x0100 | 0x0200)) != 0, // LALT|RALT
        .super = (mod & (0x0400 | 0x0800)) != 0, // LGUI|RGUI
    };
}

test "special scancodes map to neutral key codes" {
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_left), keyCodeFromScancode(80)); // SDL_SCANCODE_LEFT
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_up), keyCodeFromScancode(82)); // SDL_SCANCODE_UP
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_enter), keyCodeFromScancode(40)); // SDL_SCANCODE_RETURN
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_escape), keyCodeFromScancode(41)); // SDL_SCANCODE_ESCAPE
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_delete), keyCodeFromScancode(76)); // SDL_SCANCODE_DELETE
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_left_shift), keyCodeFromScancode(225)); // SDL_SCANCODE_LSHIFT
    // A printable key has no special mapping (text arrives via TEXT_INPUT).
    try std.testing.expectEqual(@as(?ev.KeyCode, null), keyCodeFromScancode(4)); // SDL_SCANCODE_A
}

test "modifier bitmask decodes to neutral flags" {
    const m = modifiers(0x0040 | 0x0001); // KMOD_LCTRL | KMOD_LSHIFT
    try std.testing.expect(m.ctrl and m.shift and !m.alt and !m.super);
    const g = modifiers(0x0400); // KMOD_LGUI
    try std.testing.expect(g.super and !g.ctrl);
}

test "SDL keycode maps alphanumeric keys to uppercase for shortcuts" {
    // Lowercase letters convert to uppercase
    try std.testing.expectEqual(@as(?ev.KeyCode, 'V'), keyCodeFromSdlKeycode('v'));
    try std.testing.expectEqual(@as(?ev.KeyCode, 'P'), keyCodeFromSdlKeycode('p'));
    try std.testing.expectEqual(@as(?ev.KeyCode, 'C'), keyCodeFromSdlKeycode('c'));
    // Uppercase letters pass through
    try std.testing.expectEqual(@as(?ev.KeyCode, 'A'), keyCodeFromSdlKeycode('A'));
    // Digits pass through
    try std.testing.expectEqual(@as(?ev.KeyCode, '1'), keyCodeFromSdlKeycode('1'));
    try std.testing.expectEqual(@as(?ev.KeyCode, '9'), keyCodeFromSdlKeycode('9'));
    // Common punctuation used in shortcuts
    try std.testing.expectEqual(@as(?ev.KeyCode, 0xBB), keyCodeFromSdlKeycode('+')); // plus
    try std.testing.expectEqual(@as(?ev.KeyCode, 0xBB), keyCodeFromSdlKeycode('=')); // equal (same as plus)
    try std.testing.expectEqual(@as(?ev.KeyCode, 0xBD), keyCodeFromSdlKeycode('-')); // minus
}
