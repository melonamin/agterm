#!/usr/bin/env python3
"""AT-SPI smoke coverage for the real GTK frontend, always under isolated state and HOME."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(ROOT)
BIN = os.environ.get("AGTERM_TEST_BIN", os.path.join(ROOT, ".build/debug/AgtermLinux"))
CTL = os.environ.get("AGTERM_TEST_CTL", os.path.join(ROOT, ".build/debug/agtermctl-linux"))
RESOURCE_ROOT = os.environ.get("AGTERM_RESOURCE_ROOT", os.path.join(REPO, "agterm/Resources"))


def collect(node, role=None, name=None, out=None):
    """Depth-first collection that tolerates transiently disappearing GTK nodes."""
    if out is None:
        out = []
    try:
        node_name = node.get_name() or ""
        if (role is None or node.get_role_name() == role) and (name is None or node_name == name):
            out.append(node)
        for index in range(node.get_child_count()):
            collect(node.get_child_at_index(index), role, name, out)
    except Exception:
        pass
    return out


def find_app(process_id):
    desktop = Atspi.get_desktop(0)
    matches = []
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if (
            app.get_process_id() == process_id
            and "agterm" in (app.get_name() or "").lower()
            and app.get_child_count() > 0
        ):
            matches.append(app)
    return matches[-1] if matches else None


def wait_for(predicate, message, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise AssertionError(message)


def named(root, name, role=None):
    matches = collect(root, role=role, name=name)
    return matches[0] if matches else None


def actionable(root, name):
    for item in reversed(collect(root, name=name)):
        try:
            actions = item.get_action_iface()
            if actions and actions.get_n_actions() > 0:
                return item
        except Exception:
            pass
    return None


def activate(node):
    assert node is not None, "cannot activate a missing accessible"
    actions = node.get_action_iface()
    assert actions and actions.get_n_actions() > 0, f"{node.get_name()!r} has no accessible action"
    assert actions.do_action(0), f"accessible action failed for {node.get_name()!r}"


def descendants(node, role=None, name=None):
    result = collect(node, role=role, name=name)
    return [item for item in result if item != node]


def describe_tree(node, depth=0):
    """Print a compact tree on failure so toolkit accessibility changes are diagnosable."""
    try:
        name = node.get_name() or ""
        if name or depth < 2:
            print(f"A11Y {'  ' * depth}{node.get_role_name()}: {name!r}")
        for index in range(node.get_child_count()):
            describe_tree(node.get_child_at_index(index), depth + 1)
    except Exception:
        pass


def press_ctrl_comma(process_id):
    # AT-SPI's device-event controller cannot inject keys on non-Mutter Wayland.
    # Hyprland's compositor dispatcher sends the real shortcut to this test PID;
    # X11 and other environments continue through AT-SPI below.
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        subprocess.run(
            [
                "hyprctl", "dispatch", "sendshortcut",
                f"CTRL,comma,pid:{process_id}",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return
    control_mask = 1 << int(Atspi.ModifierType.CONTROL)
    Atspi.generate_keyboard_event(
        control_mask, None, Atspi.KeySynthType.LOCKMODIFIERS
    )
    Atspi.generate_keyboard_event(ord(","), None, Atspi.KeySynthType.PRESSRELEASE)
    Atspi.generate_keyboard_event(
        control_mask, None, Atspi.KeySynthType.UNLOCKMODIFIERS
    )


def focus_window(process_id):
    """Give the isolated app real keyboard focus before testing its shortcut."""
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        subprocess.run(
            ["hyprctl", "dispatch", "focuswindow", f"pid:{process_id}"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def launch(env):
    process = subprocess.Popen([BIN], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    app = wait_for(lambda: find_app(process.pid), "agterm app not present in the AT-SPI tree")
    return process, app


def stop(process):
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
    wait_for(lambda: find_app(process.pid) is None, "agterm remained in the accessibility tree after exit")


def control_json(env, *arguments):
    output = subprocess.check_output(
        [CTL, *arguments, "--socket", env["AGTERM_CONTROL_SOCKET"]],
        env=env,
        text=True,
    )
    return json.loads(output)


def verify_normal_toolbar(env, state, home):
    process, app = launch(env)
    try:
        rows = wait_for(lambda: collect(app, role="list item"), "expected at least one session row")
        wait_for(lambda: named(app, "workspace 1", role="label"), "workspace label is missing")

        subprocess.run(
            [CTL, "session", "new", "--socket", env["AGTERM_CONTROL_SOCKET"]],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        wait_for(
            lambda: len(collect(app, role="list item")) == len(rows) + 1,
            "session.new did not update the accessibility tree",
        )

        assert not named(app, "Main Menu"), "toolbar still exposes the removed Main Menu button"

        assert not named(app, "Preferences", role="dialog"), "Preferences was open before shortcut verification"
        focus_window(process.pid)
        press_ctrl_comma(process.pid)
        wait_for(
            lambda: named(app, "Preferences", role="dialog"),
            "Ctrl+, did not open Preferences",
        )
        press_ctrl_comma(process.pid)
        wait_for(
            lambda: len(collect(app, role="dialog", name="Preferences")) == 1,
            "Ctrl+, did not preserve the single Preferences dialog",
        )
        print("OK: menu-free toolbar and Ctrl+, Preferences shortcut")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


def verify_preferences_pages(env, home):
    process, app = launch(env)
    try:
        focus_window(process.pid)
        assert not named(app, "Main Menu"), "Preferences test found the removed Main Menu button"
        wait_for(
            lambda: named(app, "Right-click pastes"),
            "Preferences did not expose the corrected Right-click pastes row",
        )
        for page in ["General", "Appearance", "Notifications", "Agent Status", "Key Mapping", "Integrations"]:
            assert named(app, page), f"Preferences page {page!r} is missing"

        wait_for(lambda: actionable(app, "Right-click pastes"), "Right-click switch is not actionable")
        stop(process)
        process = None
        env = dict(
            env,
            AGTERM_APP_ID=env["AGTERM_APP_ID"] + ".integrations",
            AGTERM_ATSPI_OPEN_PREFERENCES="integrations",
        )
        process, app = launch(env)
        skill_row = wait_for(lambda: named(app, "Agent Skill"), "Agent Skill integration row is missing")
        install = wait_for(
            lambda: next((item for item in descendants(skill_row) if item.get_name() == "Install"), None),
            "Agent Skill did not become installable",
        )
        activate(install)
        wait_for(lambda: named(app, "Apply Integration Changes?"), "integration preflight was not shown")
        assert not os.path.exists(os.path.join(home, ".claude/skills/agterm")), "preflight mutated HOME"
        stop(process)
        process = None
        assert not os.path.exists(os.path.join(home, ".claude/skills/agterm")), "closing preflight mutated HOME"

        subprocess.run(
            [CTL, "integration", "install", "skill"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        wait_for(
            lambda: os.path.exists(os.path.join(home, ".claude/skills/agterm/SKILL.md"))
            and os.path.exists(os.path.join(home, ".codex/skills/agterm/SKILL.md")),
            "safe skill installation did not write both isolated destinations",
        )
        assert os.path.realpath(home) not in os.path.realpath(os.path.expanduser("~/.claude")), "test HOME is not isolated"
        print("OK: Preferences pages, preflight cancellation, and safe install")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        if process is not None:
            stop(process)


def verify_hidden_toolbar(env, state):
    settings_path = os.path.join(state, "settings.json")
    settings = {}
    if os.path.exists(settings_path):
        with open(settings_path, encoding="utf-8") as source:
            settings = json.load(source)
    settings["toolbarMode"] = "hidden"
    with open(settings_path, "w", encoding="utf-8") as destination:
        json.dump(settings, destination)

    process, app = launch(env)
    try:
        assert not named(app, "Main Menu"), "hidden toolbar still exposes the header menu"
        assert not named(app, "Preferences", role="dialog"), "Preferences was open before hidden-toolbar shortcut"
        focus_window(process.pid)
        press_ctrl_comma(process.pid)
        wait_for(
            lambda: named(app, "Preferences", role="dialog"),
            "Ctrl+, did not open Preferences with toolbar hidden",
        )
        print("OK: Preferences remains keyboard-accessible with the toolbar hidden")
    finally:
        stop(process)


def verify_auto_follow(env, state):
    auto_state = state + "-auto-follow"
    os.makedirs(auto_state)
    auto_env = dict(
        env,
        AGTERM_STATE_DIR=auto_state,
        AGTERM_CONTROL_SOCKET=os.path.join(auto_state, "agterm.sock"),
        AGTERM_APP_ID="com.umputun.agterm.linux.atspi.autofollow",
    )
    with open(os.path.join(auto_state, "settings.json"), "w", encoding="utf-8") as destination:
        json.dump({"autoFollowAttention": "s5"}, destination)

    process, app = launch(auto_env)
    try:
        tree = control_json(auto_env, "tree", "--json")["result"]["tree"]
        blocked_id = tree["workspaces"][0]["sessions"][0]["id"]
        subprocess.run(
            [CTL, "session", "new", "--socket", auto_env["AGTERM_CONTROL_SOCKET"]],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=auto_env,
        )
        def set_status(status):
            subprocess.run(
                [
                    CTL, "session", "status", status, "--target", blocked_id,
                    "--socket", auto_env["AGTERM_CONTROL_SOCKET"],
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=auto_env,
            )

        def auto_followed():
            sessions = control_json(auto_env, "tree", "--json")["result"]["tree"]["workspaces"][0]["sessions"]
            return next((session for session in sessions if session["id"] == blocked_id), {}).get("active")

        wait_for(
            lambda: named(app, "Preferences", role="dialog"),
            "startup Preferences dialog did not open for auto-follow test",
        )
        set_status("blocked")
        time.sleep(6)
        assert not auto_followed(), "auto-follow changed sessions while Preferences was open"
        print("OK: GTK/GLib auto-follow pauses for Preferences")
    finally:
        stop(process)


def main():
    for path in (BIN, CTL):
        if not os.path.exists(path):
            print(f"FAIL: required build product is missing: {path}")
            return 2

    scenario = os.environ.get("AGTERM_ATSPI_SCENARIO")
    if scenario is None:
        for child_scenario in ("normal", "preferences-pages", "auto-follow", "hidden-toolbar"):
            child_env = dict(os.environ, AGTERM_ATSPI_SCENARIO=child_scenario)
            result = subprocess.run([sys.executable, __file__], env=child_env)
            if result.returncode != 0:
                return result.returncode
        print("PASS")
        return 0

    root = tempfile.mkdtemp(prefix="agterm-atspi-")
    home = os.path.join(root, "home")
    state = os.path.join(root, "state")
    os.makedirs(os.path.join(home, ".claude"))
    os.makedirs(os.path.join(home, ".codex"))
    os.makedirs(state)
    socket = os.path.join(state, "agterm.sock")
    env = dict(
        os.environ,
        HOME=home,
        AGTERM_STATE_DIR=state,
        AGTERM_CONTROL_SOCKET=socket,
        AGTERM_RESOURCE_ROOT=RESOURCE_ROOT,
        AGTERM_APP_ID="com.umputun.agterm.linux.atspi",
        PATH="/usr/bin:/bin",
    )
    if scenario in ("preferences-pages", "auto-follow"):
        # Page inspection and auto-follow need an already-mapped modal while another process owns focus.
        env["AGTERM_ATSPI_OPEN_PREFERENCES"] = "general"
    try:
        Atspi.init()
        if scenario == "normal":
            verify_normal_toolbar(env, state, home)
        elif scenario == "preferences-pages":
            verify_preferences_pages(env, home)
        elif scenario == "auto-follow":
            verify_auto_follow(env, state)
        elif scenario == "hidden-toolbar":
            verify_hidden_toolbar(env, state)
        else:
            raise ValueError(f"unknown AT-SPI scenario: {scenario}")
        print(f"PASS: {scenario}")
        return 0
    except (AssertionError, subprocess.CalledProcessError, OSError, ValueError) as error:
        print(f"FAIL: {error}")
        return 1
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
