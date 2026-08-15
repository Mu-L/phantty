# Linux SDL Drag/Resize Test Plan

**Branch:** `cursor/fix-sdl-drag-resize-6adf`  
**PR:** #605  
**Platform:** Linux SDL (Debian 13 XFCE, 1280×800 or similar)  
**Baseline:** Commit a585d4c4 (WispTerm 1.35.4) + this fix

## Build

```bash
zig build
./zig-out/bin/wispterm
```

## Background

After #603 and #604 merged, Linux SDL manual drag/resize had a coordinate-space bug: SDL mouse motion events are window-relative, so after moving/resizing the window, computed deltas reset to zero and drag/resize froze after ~1 pixel.

**This fix:** Update tracked window geometry (`drag_window_x/y/w/h`) after each SDL operation so deltas accumulate correctly.

---

## Test Cases

### 1. Titlebar Drag (Primary Fix)

**Goal:** Empty titlebar area (gap between hamburger and caption buttons) should move the window smoothly and continuously.

**Before fix:** Window moves ~1 pixel then freezes; must release and re-drag to move again.  
**After fix:** Window moves fluidly with mouse for the entire drag.

#### Steps:
1. Launch WispTerm on Linux.
2. Position mouse in **empty titlebar gap** (x ≈ 400–1000, y ≈ 10–20, depending on window width).
   - This is the area AFTER the hamburger button and BEFORE the config/help/caption buttons.
3. Click and hold left mouse button.
4. Drag mouse slowly **horizontally** ~200 pixels.
5. Drag mouse slowly **vertically** ~100 pixels.
6. Release mouse button.

**Expected:**
- [ ] Window follows mouse continuously during entire drag.
- [ ] No freeze or stutter after initial pixel.
- [ ] Window moves in both X and Y directions smoothly.

**Unexpected (regression):**
- ❌ Window moves 1 pixel then freezes (old bug).
- ❌ Window jumps or lags behind mouse cursor.

---

### 2. Bottom Edge Resize (Primary Fix)

**Goal:** Dragging the bottom edge should resize window height continuously.

**Before fix:** Window resizes ~1 pixel then freezes.  
**After fix:** Window resizes smoothly with mouse for the entire drag.

#### Steps:
1. Position mouse at **bottom edge** of window (y ≈ window_height - 4).
   - Cursor should change to vertical resize cursor (↕).
2. Click and hold left mouse button.
3. Drag mouse **downward** ~100 pixels to increase height.
4. Drag mouse **upward** ~50 pixels to decrease height.
5. Release mouse button.

**Expected:**
- [ ] Window height changes continuously during drag.
- [ ] No freeze after initial resize.
- [ ] Resize is smooth and follows mouse Y position.

**Unexpected:**
- ❌ Window resizes 1 pixel then freezes.
- ❌ Window height jumps or does not match mouse position.

---

### 3. Right Edge Resize

**Goal:** Dragging the right edge should resize window width continuously.

#### Steps:
1. Position mouse at **right edge** (x ≈ window_width - 4).
   - Cursor should change to horizontal resize cursor (↔).
2. Click and hold left mouse button.
3. Drag mouse **rightward** ~100 pixels to increase width.
4. Drag mouse **leftward** ~50 pixels to decrease width.
5. Release mouse button.

**Expected:**
- [ ] Window width changes continuously during drag.
- [ ] No freeze after initial resize.

---

### 4. Left Edge Resize

**Goal:** Dragging the left edge should resize width AND reposition window so right edge stays fixed.

#### Steps:
1. Position mouse at **left edge** (x < 4).
   - Cursor should change to horizontal resize cursor (↔).
2. Click and hold left mouse button.
3. Drag mouse **leftward** ~100 pixels (should increase width, move window left).
4. Drag mouse **rightward** ~50 pixels (should decrease width, move window right).
5. Release mouse button.

**Expected:**
- [ ] Window width changes continuously.
- [ ] Window X position adjusts so right edge stays roughly fixed.
- [ ] No freeze after initial resize.

---

### 5. Top Edge Resize

**Goal:** Dragging the top edge should resize height AND reposition window so bottom edge stays fixed.

#### Steps:
1. Position mouse at **top edge** (y < 4, but NOT in titlebar buttons).
2. Click and hold left mouse button.
3. Drag mouse **upward** ~50 pixels (increase height, move window up).
4. Drag mouse **downward** ~30 pixels (decrease height, move window down).
5. Release mouse button.

**Expected:**
- [ ] Window height changes continuously.
- [ ] Window Y position adjusts so bottom edge stays roughly fixed.
- [ ] No freeze after initial resize.

---

### 6. Corner Resize

**Goal:** All four corners should resize both dimensions simultaneously.

#### Test each corner:
1. **Bottom-right corner** (x ≈ width-4, y ≈ height-4):
   - [ ] Resizes width and height together.
   - [ ] Window top-left position stays fixed.

2. **Top-left corner** (x < 4, y < 4):
   - [ ] Resizes width and height together.
   - [ ] Window bottom-right position stays roughly fixed.
   - [ ] Window repositions to compensate for size change.

3. **Top-right corner** (x ≈ width-4, y < 4):
   - [ ] Resizes width and height.
   - [ ] Window bottom-left position stays roughly fixed.

4. **Bottom-left corner** (x < 4, y ≈ height-4):
   - [ ] Resizes width and height.
   - [ ] Window top-right position stays roughly fixed.

**Expected for all corners:**
- Continuous resize without freeze.
- Correct position compensation for top/left corners.

---

### 7. Titlebar Buttons DO NOT Drag

**Goal:** Clicking titlebar buttons should perform their action, NOT start a window drag.

#### Steps:
1. Click **hamburger button** (leftmost, x ≈ 0–46).
   - **Expected:** [ ] Toggles sidebar. Window does NOT move.

2. Click **gear/config button** (right side, before caption buttons).
   - **Expected:** [ ] Opens settings. Window does NOT move.

3. Click **help button** (if present).
   - **Expected:** [ ] Opens help. Window does NOT move.

4. Click **copilot button** (if present).
   - **Expected:** [ ] Opens copilot. Window does NOT move.

5. Click **caption buttons** (minimize/maximize/close at far right).
   - **Expected:** [ ] Performs button action. Window does NOT move.

**Unexpected:**
- ❌ Any button click starts a window drag.

---

### 8. Keyboard Shortcuts (No Regression of #603)

**Goal:** Keyboard shortcuts added in #603 should still work.

#### Steps:
1. Press **Ctrl+V** with text in clipboard.
   - **Expected:** [ ] Pastes clipboard content into terminal.

2. Press **Ctrl+Shift+P**.
   - **Expected:** [ ] Opens command center overlay.

3. Press **Ctrl+Shift++** (Ctrl+Shift+Equals).
   - **Expected:** [ ] Splits terminal vertically (new pane appears).

4. Test other shortcuts as needed (Ctrl+C, Ctrl+T, etc.).
   - **Expected:** [ ] All shortcuts remain functional.

**Unexpected:**
- ❌ Any shortcut is broken or does not respond.

---

## Success Criteria

**ALL** of the following must be true:

- [ ] **Titlebar drag** works smoothly and continuously (test case 1).
- [ ] **Bottom edge resize** works smoothly and continuously (test case 2).
- [ ] **Right, left, and top edge resize** work correctly (tests 3–5).
- [ ] **All four corner resizes** work correctly (test case 6).
- [ ] **Titlebar button clicks** do NOT start a drag (test case 7).
- [ ] **Keyboard shortcuts** remain functional (test case 8, no #603 regression).

**If any test fails**, this fix is incomplete and needs further debugging.

---

## Debug Tips

If titlebar drag or edge resize still freezes:

1. **Check SDL version:** `SDL_GetVersion()` should be SDL3 (3.x.y).
2. **Check WM:** Some WMs override SDL borderless window behavior.
   - Test on XFCE, KDE, GNOME to isolate WM-specific issues.
3. **Add debug logging:** Insert `std.debug.print` in the drag/resize motion handlers:
   ```zig
   std.debug.print("drag: mx={} my={} dx={} dy={} new_x={} new_y={}\n", 
                   .{mx, my, dx, dy, new_x, new_y});
   ```
   Check if `dx`/`dy` reset to zero after the first motion event.

4. **Verify hit-test:** Check that `classify()` returns `.draggable` for the empty titlebar and `.resize_bottom` for the bottom edge.

---

## Platform Note

**This fix applies ONLY to Linux SDL.** Windows (D3D11) and macOS (Metal) use native window APIs and are NOT affected by this bug or this fix.
