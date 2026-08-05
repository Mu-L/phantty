//! Windows notification backend: system alert sound via `MessageBeep`,
//! taskbar/caption attention via `FlashWindowEx`, and desktop notifications
//! via a `Shell_NotifyIcon` tray balloon. On Windows 10 1607+ the shell
//! automatically surfaces tray balloons as toast notifications, so this gives
//! native toasts with plain `extern "shell32"` calls — no AppUserModelID,
//! COM, or WinRT required. Clicking the balloon foregrounds the main window.

const std = @import("std");
const platform_window = @import("window.zig");

const NativeHandle = platform_window.NativeHandle;
const windows = std.os.windows;
const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const HWND = windows.HWND;
const HINSTANCE = windows.HINSTANCE;
const WPARAM = windows.WPARAM;
const LPARAM = windows.LPARAM;
const LRESULT = windows.LRESULT;
const UINT = u32;
const WCHAR = u16;
const HICON = *opaque {};
const HCURSOR = *opaque {};
const HBRUSH = *opaque {};
const HMENU = *opaque {};
const ATOM = u16;
const INT = i32;

const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

extern "user32" fn MessageBeep(uType: UINT) callconv(.winapi) BOOL;
extern "user32" fn FlashWindowEx(pfwi: *const FLASHWINFO) callconv(.winapi) BOOL;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: [*:0]const WCHAR,
    lpWindowName: [*:0]const WCHAR,
    dwStyle: DWORD,
    X: INT,
    Y: INT,
    nWidth: INT,
    nHeight: INT,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn LoadImageW(hInst: ?HINSTANCE, name: usize, type: UINT, cx: INT, cy: INT, fuLoad: UINT) callconv(.winapi) ?HICON;
extern "user32" fn LoadIconW(hInstance: ?HINSTANCE, lpIconName: usize) callconv(.winapi) ?HICON;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: INT) callconv(.winapi) BOOL;
extern "user32" fn IsIconic(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn EnumWindows(lpEnumFunc: WNDENUMPROC, lParam: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn GetWindowThreadProcessId(hWnd: HWND, lpdwProcessId: ?*DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const WCHAR) callconv(.winapi) ?HINSTANCE;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "shell32" fn Shell_NotifyIconW(dwMessage: DWORD, lpData: *NOTIFYICONDATAW) callconv(.winapi) BOOL;

const WNDENUMPROC = *const fn (HWND, LPARAM) callconv(.winapi) BOOL;

const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: INT = 0,
    cbWndExtra: INT = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?[*:0]const WCHAR = null,
    lpszClassName: [*:0]const WCHAR,
    hIconSm: ?HICON = null,
};

const GUID = extern struct {
    data1: DWORD,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

/// Vista-sized NOTIFYICONDATAW (cbSize = 976 on x64). Fields after
/// `szInfoTitle` are kept so `NIM_SETVERSION` with NOTIFYICON_VERSION_4 is
/// accepted and balloon clicks arrive as NIN_BALLOONUSERCLICK.
const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD,
    hWnd: HWND,
    uID: UINT,
    uFlags: UINT,
    uCallbackMessage: UINT,
    hIcon: ?HICON,
    szTip: [128]WCHAR,
    dwState: DWORD,
    dwStateMask: DWORD,
    szInfo: [256]WCHAR,
    /// Union with uTimeout; with version 4 the timeout is system-controlled.
    uVersion: UINT,
    szInfoTitle: [64]WCHAR,
    dwInfoFlags: DWORD,
    guidItem: GUID,
    hBalloonIcon: ?HICON,
};

const FLASHWINFO = extern struct {
    cbSize: UINT,
    hwnd: HWND,
    dwFlags: DWORD,
    uCount: UINT,
    dwTimeout: DWORD,
};

const FLASHW_ALL: DWORD = 3; // Flash both caption and taskbar
const FLASHW_TIMERNOFG: DWORD = 12; // Flash until window comes to foreground
const MB_OK: UINT = 0x00000000; // Default system sound

// Tray icon / balloon plumbing.
const WM_USER: UINT = 0x0400;
const WM_APP: UINT = 0x8000;
const TRAY_CALLBACK_MSG: UINT = WM_APP + 0x4E; // 'N' for notification
const TRAY_ICON_ID: UINT = 1;
const NIM_ADD: DWORD = 0;
const NIM_MODIFY: DWORD = 1;
const NIM_DELETE: DWORD = 2;
const NIM_SETVERSION: DWORD = 4;
const NIF_MESSAGE: UINT = 0x1;
const NIF_ICON: UINT = 0x2;
const NIF_TIP: UINT = 0x4;
const NIF_INFO: UINT = 0x10;
const NIIF_INFO: DWORD = 0x1;
const NOTIFYICON_VERSION_4: UINT = 4;
const NIN_BALLOONUSERCLICK: UINT = WM_USER + 5;
const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));
const SW_RESTORE: INT = 9;
const IMAGE_ICON: UINT = 1;
const LR_SHARED: UINT = 0x8000;
const IDI_APPLICATION: usize = 32512;
/// Embedded application icon resource ID (see assets/wispterm.rc and
/// apprt/win32.zig, which loads the same ID for the window icon).
const APP_ICON_RESOURCE_ID: usize = 1;

/// All tray-toast state lives here: whether NIM_ADD succeeded, the
/// message-only window receiving tray callbacks, the cached main-window
/// handle used to foreground the app on balloon click, and the icon handle.
const TrayState = struct {
    mutex: std.Thread.Mutex = .{},
    icon_added: bool = false,
    class_registered: bool = false,
    msg_hwnd: ?HWND = null,
    main_hwnd: ?HWND = null,
    icon: ?HICON = null,
};

var tray: TrayState = .{};

pub fn bell() void {
    _ = MessageBeep(MB_OK);
}

pub fn requestAttention(handle: NativeHandle) void {
    // Cache the window handle so a balloon click can foreground it even when
    // no other path handed us a window handle.
    tray.mutex.lock();
    tray.main_hwnd = handle;
    tray.mutex.unlock();

    // Only flash if the window is not already the foreground window.
    if (GetForegroundWindow() == handle) return;
    var fwi = FLASHWINFO{
        .cbSize = @sizeOf(FLASHWINFO),
        .hwnd = handle,
        .dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG,
        .uCount = 3,
        .dwTimeout = 0, // Use default cursor blink rate
    };
    _ = FlashWindowEx(&fwi);
}

/// Copy UTF-8 into a null-terminated UTF-16 field, truncating at a codepoint
/// boundary so the text plus terminator always fits (szInfo/szInfoTitle are
/// fixed-size: 255/63 UTF-16 code units of payload).
fn copyUtf16Truncated(dest: []WCHAR, src: []const u8) void {
    const max_units = dest.len - 1;
    var out: usize = 0;
    const view = std.unicode.Utf8View.init(src) catch {
        dest[0] = 0;
        return;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x10000) {
            if (out + 1 > max_units) break;
            dest[out] = @intCast(cp);
            out += 1;
        } else {
            if (out + 2 > max_units) break;
            const c = cp - 0x10000;
            dest[out] = @intCast(0xD800 + (c >> 10));
            dest[out + 1] = @intCast(0xDC00 + (c & 0x3FF));
            out += 2;
        }
    }
    dest[out] = 0;
}

/// Lazily create the message-only window and register the tray icon.
/// Caller must hold tray.mutex.
fn ensureTrayLocked() bool {
    if (tray.icon_added) return true;

    const hInstance = GetModuleHandleW(null);
    const tray_class = std.unicode.utf8ToUtf16LeStringLiteral("WispTermTrayCallback");

    if (!tray.class_registered) {
        const wc = WNDCLASSEXW{
            .lpfnWndProc = trayWndProc,
            .hInstance = hInstance,
            .lpszClassName = tray_class,
        };
        // May already be registered from a previous window thread — that's OK.
        _ = RegisterClassExW(&wc);
        tray.class_registered = true;
    }

    if (tray.msg_hwnd == null) {
        tray.msg_hwnd = CreateWindowExW(
            0,
            tray_class,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            0,
            0,
            0,
            0,
            0,
            HWND_MESSAGE,
            null,
            hInstance,
            null,
        ) orelse return false;
    }

    const icon = LoadImageW(hInstance, APP_ICON_RESOURCE_ID, IMAGE_ICON, 0, 0, LR_SHARED) orelse
        LoadIconW(null, IDI_APPLICATION) orelse return false;
    tray.icon = icon;

    var data = std.mem.zeroes(NOTIFYICONDATAW);
    data.cbSize = @sizeOf(NOTIFYICONDATAW);
    data.hWnd = tray.msg_hwnd.?;
    data.uID = TRAY_ICON_ID;
    data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    data.uCallbackMessage = TRAY_CALLBACK_MSG;
    data.hIcon = icon;
    copyUtf16Truncated(&data.szTip, "WispTerm");
    if (Shell_NotifyIconW(NIM_ADD, &data) == 0) return false;

    // Version 4: balloon clicks arrive as NIN_BALLOONUSERCLICK.
    data.uVersion = NOTIFYICON_VERSION_4;
    _ = Shell_NotifyIconW(NIM_SETVERSION, &data);

    tray.icon_added = true;
    return true;
}

/// Tray callback receiver (runs on the thread that created the message-only
/// window, which pumps messages as part of the normal render loop).
fn trayWndProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    if (msg == TRAY_CALLBACK_MSG and wParam == TRAY_ICON_ID) {
        // With NOTIFYICON_VERSION_4 the event code is in LOWORD(lParam).
        const event: UINT = @as(u16, @truncate(@as(u64, @bitCast(lParam))));
        if (event == NIN_BALLOONUSERCLICK) {
            tray.mutex.lock();
            const cached = tray.main_hwnd;
            tray.mutex.unlock();
            if (cached orelse findMainWindow()) |main_hwnd| {
                if (IsIconic(main_hwnd) != 0) _ = ShowWindow(main_hwnd, SW_RESTORE);
                _ = SetForegroundWindow(main_hwnd);
            }
            return 0;
        }
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

/// Fallback main-window lookup: first visible top-level window owned by this
/// process (the message-only tray window is not top-level and never matches).
const FindCtx = struct {
    pid: DWORD,
    hwnd: ?HWND = null,
};

fn enumWindowsProc(hwnd: HWND, lParam: LPARAM) callconv(.winapi) BOOL {
    const ctx: *FindCtx = @ptrFromInt(@as(usize, @bitCast(lParam)));
    var pid: DWORD = 0;
    _ = GetWindowThreadProcessId(hwnd, &pid);
    if (pid == ctx.pid and IsWindowVisible(hwnd) != 0) {
        ctx.hwnd = hwnd;
        return 0; // stop enumerating
    }
    return 1;
}

fn findMainWindow() ?HWND {
    var ctx = FindCtx{ .pid = GetCurrentProcessId() };
    _ = EnumWindows(enumWindowsProc, @bitCast(@as(isize, @intCast(@intFromPtr(&ctx)))));
    return ctx.hwnd;
}

pub fn showDesktopNotification(title: [:0]const u8, body: [:0]const u8) void {
    tray.mutex.lock();
    defer tray.mutex.unlock();
    if (!ensureTrayLocked()) {
        std.log.debug("toast: tray icon unavailable, dropping notification title={s}", .{title});
        return;
    }
    if (!sendBalloonLocked(title, body)) {
        // The callback window may have lived on a window thread that has
        // since exited (the system destroys it with the thread), leaving a
        // stale HWND. Drop the dead state and rebuild the tray icon once.
        tray.icon_added = false;
        tray.msg_hwnd = null;
        if (ensureTrayLocked() and sendBalloonLocked(title, body)) {
            std.log.debug("toast: tray balloon sent after tray rebuild, title={s}", .{title});
        } else {
            std.log.debug("toast: NIM_MODIFY failed for title={s}", .{title});
        }
        return;
    }
    std.log.debug("toast: tray balloon sent title={s}", .{title});
}

/// NIM_MODIFY the existing tray icon to show a balloon. Caller holds the lock
/// and has ensured the tray icon exists.
fn sendBalloonLocked(title: [:0]const u8, body: [:0]const u8) bool {
    var data = std.mem.zeroes(NOTIFYICONDATAW);
    data.cbSize = @sizeOf(NOTIFYICONDATAW);
    data.hWnd = tray.msg_hwnd.?;
    data.uID = TRAY_ICON_ID;
    data.uFlags = NIF_INFO;
    copyUtf16Truncated(&data.szInfoTitle, title);
    copyUtf16Truncated(&data.szInfo, body);
    data.dwInfoFlags = NIIF_INFO;
    return Shell_NotifyIconW(NIM_MODIFY, &data) != 0;
}

pub fn notificationAuthStatus() u8 {
    // Tray balloons need no user grant; the OS-level notification settings
    // (Focus Assist etc.) apply at display time and are not queryable here.
    return 2; // authorized
}

pub fn requestNotificationAuth() void {}

/// Remove the tray icon and destroy the callback window. Called once from the
/// app shutdown path; safe to call when nothing was ever initialized.
pub fn cleanup() void {
    tray.mutex.lock();
    defer tray.mutex.unlock();
    if (tray.icon_added) {
        var data = std.mem.zeroes(NOTIFYICONDATAW);
        data.cbSize = @sizeOf(NOTIFYICONDATAW);
        data.hWnd = tray.msg_hwnd.?;
        data.uID = TRAY_ICON_ID;
        _ = Shell_NotifyIconW(NIM_DELETE, &data);
        tray.icon_added = false;
    }
    // The message window may have been created on a window thread that has
    // already exited (the system destroys it with the thread); a cross-thread
    // DestroyWindow simply fails and is ignored.
    if (tray.msg_hwnd) |hwnd| {
        _ = DestroyWindow(hwnd);
        tray.msg_hwnd = null;
    }
    tray.main_hwnd = null;
}
