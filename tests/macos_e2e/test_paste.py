"""Cmd+V paste delivers the system clipboard into the focused terminal.

Complements test_keybinds' Cmd+C copy (xfail): copy reads the clipboard, this
writes it (via pbcopy) and asserts a real Cmd+V keystroke routes the clipboard
text through the app's paste action into the PTY, where it lands on the prompt
line and is visible through get-text.

macOS remaps the Ctrl+V paste default to Cmd+V (keybind.zig's ctrl->win
migration). The marker carries no newline, so it sits on the command line rather
than executing; a trailing Ctrl-C clears it so the shared shell stays clean.
"""
import subprocess
import shlex
import shutil
import sys
import time

import pytest

pytestmark = pytest.mark.skipif(sys.platform != "darwin", reason="macOS-only E2E harness")

_MARKER = "PHANTTY_PASTE_MARKER_42"


@pytest.mark.e2e
@pytest.mark.macos_only
def test_cmd_v_pastes_clipboard_into_pty(app, pane):
    subprocess.run(["pbcopy"], input=_MARKER, text=True, check=True)

    app.focus()
    app.ensure_keyboard_ready(pane)
    # Abort any partial line left by earlier real-keyboard tests (session-scoped shell).
    app.send_text("\x03", pane)
    time.sleep(0.3)

    app.key("v", "cmd")
    try:
        app.wait_for(pane, _MARKER, timeout=8)
    finally:
        app.send_text("\x03", pane)  # clear the pasted line off the prompt


@pytest.mark.e2e
@pytest.mark.macos_only
def test_cmd_v_preserves_multiline_script_in_vim(app, pane, tmp_path):
    """Issue #632: paste in Insert mode with indentation/comment continuation on."""
    vim = shutil.which("vim")
    if vim is None:
        pytest.skip("vim is required for the bracketed-paste regression")
    script = (
        "#SBATCH -w node01\n"
        "#SBATCH -c 24\n\n"
        "set -euo pipefail\n\n"
        'for f in "$A" "$B"; do\n'
        '    [[ -s "$f" ]] || exit 1\n'
        "done"
    )
    output = tmp_path / "pasted.sh"
    subprocess.run(["pbcopy"], input=script, text=True, check=True)
    app.focus()
    app.ensure_keyboard_ready(pane)
    app.send_text("\x03", pane)
    time.sleep(0.3)
    command = shlex.join([
        vim, "-Nu", "NONE", "-n", "-i", "NONE",
        "-c", "set nocompatible autoindent smartindent comments=b:# formatoptions=cro showmode",
        "-c", "startinsert", str(output),
    ])
    app.send_text(command + "\r", pane)
    try:
        app.wait_for(pane, "-- INSERT --", timeout=8)
        app.key("v", "cmd")
        app.wait_for(pane, "done", timeout=8)
        app.send_text("\x1b:wq\r", pane)
        deadline = time.monotonic() + 8
        while not output.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert output.read_text() == script + "\n"
    finally:
        if not output.exists():
            app.send_text("\x1b:q!\r", pane)
