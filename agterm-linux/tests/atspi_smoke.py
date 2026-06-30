#!/usr/bin/env python3
"""AT-SPI UI-test harness for agterm-linux.

Launches an isolated instance, asserts the sidebar structure through the accessibility tree
(the GTK widgets register with AT-SPI automatically when the a11y bus is up), drives a
control-channel mutation, and re-asserts that the a11y tree reflects it. This is the Linux
analogue of the macOS XCUITest suite — it drives + inspects the real running UI, not the model.

Run:  python3 agterm-linux/tests/atspi_smoke.py   (needs python3-gi + Atspi 2.0 + a running a11y bus)
Exit 0 = PASS, non-zero = FAIL.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time

import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))      # agterm-linux/
BIN = os.path.join(ROOT, ".build/debug/AgtermLinux")
CTL = os.path.abspath(os.path.join(ROOT, "../agtermCore/.build/debug/agtermctl"))


def find_app(substr):
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if substr.lower() in (app.get_name() or "").lower():
            return app
    return None


def collect(node, role=None, pred=None, out=None):
    """Depth-first collect of accessibles matching an optional role name + predicate."""
    if out is None:
        out = []
    try:
        if (role is None or node.get_role_name() == role) and (pred is None or pred(node)):
            out.append(node)
        for j in range(node.get_child_count()):
            collect(node.get_child_at_index(j), role, pred, out)
    except Exception:
        pass
    return out


def main():
    if not os.path.exists(BIN):
        print(f"FAIL: build agterm-linux first ({BIN} missing)")
        return 2
    state = tempfile.mkdtemp(prefix="agterm-atspi-")
    sock = os.path.join(state, "agterm.sock")
    env = dict(os.environ, AGTERM_STATE_DIR=state, AGTERM_CONTROL_SOCKET=sock,
               AGTERM_APP_ID="com.umputun.agterm.linux.atspi")
    proc = subprocess.Popen([BIN], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(80):
            if os.path.exists(sock):
                break
            time.sleep(0.1)
        time.sleep(1.5)   # let the window map + register with AT-SPI
        Atspi.init()

        app = find_app("agterm")
        assert app, "agterm app not present in the AT-SPI tree"

        rows = collect(app, role="list item")
        assert len(rows) >= 1, f"expected >=1 session row, got {len(rows)}"
        ws = collect(app, role="label", pred=lambda n: (n.get_name() or "") == "workspace 1")
        assert ws, "'workspace 1' label not found in the AT-SPI tree"
        print(f"OK: initial a11y tree has {len(rows)} session row(s) + the workspace label")

        # Drive a control-channel mutation and assert the a11y tree updates.
        subprocess.run([CTL, "session", "new", "--socket", sock], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.0)
        rows2 = collect(app, role="list item")
        assert len(rows2) == len(rows) + 1, \
            f"expected {len(rows) + 1} rows after session.new, got {len(rows2)}"
        print(f"OK: after session.new the a11y tree shows {len(rows2)} session rows")

        print("PASS")
        return 0
    except AssertionError as e:
        print(f"FAIL: {e}")
        return 1
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        shutil.rmtree(state, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
