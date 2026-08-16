"""Linux companion of test_mcp_discovery: startup MCP handshake against ~/.config/wispterm.

The macOS original hardcodes APP_BUNDLE + ~/Library/Application Support/wispterm.
This launches the Linux binary with the same isolated-HOME / XDG config the
driver uses, and asserts initialize + tools/list reached a fake stdio server.
"""
import json
import os
import sys
import time

import pytest

from tests.macos_e2e.conftest import CTL_BINARY, LINUX_BINARY, linux_only, require_linux_gui
from tests.macos_e2e.driver.linux import LinuxDriver

_FAKE_MCP_SERVER = '''
import sys, json
record_path = sys.argv[1]

def rec(method):
    with open(record_path, "a") as f:
        f.write(method + "\\n")

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\\n")
    sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    method, mid = msg.get("method"), msg.get("id")
    rec(method or "?")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
            "serverInfo": {"name": "e2e-fake", "version": "1"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [
            {"name": "e2e_probe", "description": "probe", "inputSchema": {"type": "object"}}]}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}})
'''


@pytest.mark.e2e
@linux_only
def test_mcp_servers_discovered_at_startup():
    require_linux_gui()
    driver = LinuxDriver(binary=LINUX_BINARY, ctl_binary=CTL_BINARY)
    try:
        cfg_dir = driver._config_dir()
        os.makedirs(cfg_dir, exist_ok=True)

        server_path = os.path.join(driver.home, "fake_mcp_server.py")
        record_path = os.path.join(driver.home, "mcp_requests.log")
        with open(server_path, "w") as f:
            f.write(_FAKE_MCP_SERVER)
        with open(os.path.join(cfg_dir, "mcp.json"), "w") as f:
            json.dump(
                {"mcpServers": {"e2e": {"command": sys.executable, "args": [server_path, record_path]}}},
                f,
            )

        driver.launch()

        methods = []
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if os.path.exists(record_path):
                methods = open(record_path).read().split()
                if "initialize" in methods and "tools/list" in methods:
                    break
            time.sleep(0.3)

        assert "initialize" in methods, f"app never sent initialize to the MCP server; recorded {methods}"
        assert "tools/list" in methods, f"app never sent tools/list to the MCP server; recorded {methods}"
    finally:
        driver.quit()
