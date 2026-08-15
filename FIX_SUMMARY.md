# SDL Drag/Resize Fix - Implementation Summary

## Branch & PR
- **Branch:** `cursor/fix-sdl-drag-resize-6adf`
- **PR:** [#605](https://github.com/xuzhougeng/wispterm/pull/605)
- **Status:** Ready for Linux testing

## What Was Fixed

### Bugs Identified (Post #603+#604 merge, commit a585d4c4)
1. **Titlebar drag frozen** — Empty titlebar drag moved window ~1 pixel then stopped responding.
2. **Bottom edge resize frozen** — Bottom edge drag resized ~1 pixel then stopped responding.
3. **Left/right/top edge resizes** — Partial work, but same underlying coordinate bug.

### Root Cause
SDL mouse motion events report **window-relative coordinates**. After `SDL_SetWindowPosition` or `SDL_SetWindowSize`, the next motion event's `(mx, my)` reflects the **new** window frame origin. Without updating the tracked window state, computed deltas `dx = mx - drag_start_x` used the **old** frame as reference, causing:
- `dx` to reset to zero or incorrect values
- Window to "snap back" or freeze mid-drag/resize

### Solution
After each `SDL_SetWindowPosition` and `SDL_SetWindowSize`, **update the tracked geometry**:
- `drag_window_x`, `drag_window_y` (for drag and left/top resize)
- `drag_window_w`, `drag_window_h` (for all resizes)

This ensures deltas accumulate correctly as the coordinate frame changes.

## Code Changes

### File: `src/apprt/sdl.zig`

**1. Titlebar drag fix (lines 727-731):**
```zig
_ = c.SDL_SetWindowPosition(w.sdl_window, @intCast(new_x), @intCast(new_y));
// Update tracked window position so deltas accumulate correctly.
// Mouse coordinates are window-relative; after moving the window,
// the next motion event's (mx,my) reflects the new window origin.
w.drag_window_x = new_x;
w.drag_window_y = new_y;
```

**2. Edge/corner resize fix (lines 791-797):**
```zig
_ = c.SDL_SetWindowPosition(w.sdl_window, @intCast(new_x), @intCast(new_y));
_ = c.SDL_SetWindowSize(w.sdl_window, @intCast(new_w), @intCast(new_h));
// Update tracked window geometry so deltas accumulate correctly.
// Mouse coordinates are window-relative; after resizing/repositioning,
// the next motion event reflects the new window frame.
w.drag_window_x = new_x;
w.drag_window_y = new_y;
w.drag_window_w = new_w;
w.drag_window_h = new_h;
```

## Testing

### Test Plan Document
[`LINUX_TEST_PLAN.md`](./LINUX_TEST_PLAN.md) — comprehensive checklist covering:
- Titlebar drag (primary fix)
- All 4 edge resizes (bottom/right/left/top)
- All 4 corner resizes
- Button click isolation (no drag on hamburger/gear/help/caption)
- Keyboard shortcut regression check (#603)
- Debug tips for WM-specific issues

### Quick Smoke Test
```bash
# Build and run
zig build
./zig-out/bin/wispterm

# Test 1: Titlebar drag
# Click and hold empty titlebar gap (x≈400-1000, y≈10-20)
# Drag mouse 200px horizontally, 100px vertically
# ✅ Window should follow mouse smoothly (not freeze after 1px)

# Test 2: Bottom edge resize
# Click and hold bottom edge (y ≈ height-4)
# Drag downward 100px
# ✅ Window should resize height smoothly (not freeze after 1px)

# Test 3: No regression
# Ctrl+V → pastes
# Ctrl+Shift+P → opens command center
# Ctrl+Shift++ → splits terminal
```

### Platform Scope
**Linux SDL only.** Windows (D3D11) and macOS (Metal) use native window APIs and are NOT affected.

## Commits

```
ba1e785 Fix SDL manual drag/resize on Linux by updating tracked window state
8864b4a Add comprehensive Linux test plan for drag/resize fix
```

## Formatting Note
`zig fmt` was not run due to missing Zig 0.15.2 compiler in the build environment. Code changes manually verified to follow existing file style:
- 4-space indentation (consistent with surrounding code)
- Inline comment style matches file convention
- Line lengths consistent with existing code
- No structural/semantic changes, only state-tracking updates

## Next Steps
1. **Linux tester** runs smoke test or full `LINUX_TEST_PLAN.md`
2. If tests pass → merge to `main`
3. If tests fail → additional debugging (see test plan debug tips)

## Verification Logic

### Why This Fix Works

**Before fix:**
```zig
// Mouse button down at window-local (50, 50), window at screen (100, 100)
drag_start_x = 50;
drag_window_x = 100;

// Mouse motion to window-local (100, 100) — user moved 50px right on screen
dx = 100 - 50 = 50;
new_x = 100 + 50 = 150;
SDL_SetWindowPosition(150, ...);
// ❌ drag_window_x still 100 (not updated)

// Next motion to window-local (100, 100) — user moved another 50px right
// (window is now at 150, so same window-local coords)
dx = 100 - 50 = 50;
new_x = 100 + 50 = 150;  // ❌ Using OLD drag_window_x
SDL_SetWindowPosition(150, ...);  // Window already at 150 → no movement!
```

**After fix:**
```zig
// First motion
new_x = 100 + 50 = 150;
SDL_SetWindowPosition(150, ...);
drag_window_x = 150;  // ✅ Updated

// Second motion
new_x = 150 + 50 = 200;  // ✅ Using CURRENT drag_window_x
SDL_SetWindowPosition(200, ...);
drag_window_x = 200;  // ✅ Updated
// Window moves correctly!
```

The fix ensures we track the **current** window position after each move, so subsequent deltas are computed relative to the correct reference frame.
