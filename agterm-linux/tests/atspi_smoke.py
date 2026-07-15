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


def editable_descendant(node):
    for item in descendants(node):
        try:
            if item.get_editable_text_iface():
                return item
        except Exception:
            pass
    return None


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


def press_ctrl_comma(process_id, window_title=None):
    # AT-SPI's device-event controller cannot inject keys on non-Mutter Wayland.
    # Hyprland's compositor dispatcher sends the real shortcut to this test PID;
    # X11 and other environments continue through AT-SPI below.
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        target = f"title:^({window_title})$" if window_title else f"pid:{process_id}"
        subprocess.run(
            [
                "hyprctl", "dispatch", "sendshortcut",
                f"CTRL,comma,{target}",
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


def press_ctrl_shift_p(process_id, window_title=None):
    """Open the command palette in the focused isolated window."""
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        target = f"title:^({window_title})$" if window_title else f"pid:{process_id}"
        subprocess.run(
            [
                "hyprctl", "dispatch", "sendshortcut",
                f"CTRL SHIFT,P,{target}",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return
    modifiers = (1 << int(Atspi.ModifierType.CONTROL)) | (1 << int(Atspi.ModifierType.SHIFT))
    Atspi.generate_keyboard_event(modifiers, None, Atspi.KeySynthType.LOCKMODIFIERS)
    Atspi.generate_keyboard_event(ord("p"), None, Atspi.KeySynthType.PRESSRELEASE)
    Atspi.generate_keyboard_event(modifiers, None, Atspi.KeySynthType.UNLOCKMODIFIERS)


def press_escape(process_id, window_title=None):
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        target = f"title:^({window_title})$" if window_title else f"pid:{process_id}"
        subprocess.run(
            ["hyprctl", "dispatch", "sendshortcut", f",escape,{target}"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return
    Atspi.generate_keyboard_event(0xFF1B, None, Atspi.KeySynthType.PRESSRELEASE)


def press_return(process_id, window_title=None):
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        target = f"title:^({window_title})$" if window_title else f"pid:{process_id}"
        subprocess.run(
            ["hyprctl", "dispatch", "sendshortcut", f",return,{target}"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return
    Atspi.generate_keyboard_event(0xFF0D, None, Atspi.KeySynthType.PRESSRELEASE)


def focus_window(process_id):
    """Give the isolated app real keyboard focus before testing its shortcut."""
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        subprocess.run(
            ["hyprctl", "dispatch", "focuswindow", f"pid:{process_id}"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def focus_accessible_window(window, process_id):
    """Focus one exact window when the isolated process owns more than one."""
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        title = window.get_name() or ""
        subprocess.run(
            ["hyprctl", "dispatch", "focuswindow", f"title:^({title})$"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return
    component = window.get_component_iface()
    assert component and component.grab_focus(), "could not focus the requested accessible window"


def mouse_click(node_provider, process_id, window_title=None, button="right"):
    """Send a real pointer click to an accessible in one exact GTK window."""
    focus_window(process_id)
    deadline = time.monotonic() + 8
    bounds = None
    while time.monotonic() < deadline:
        try:
            node = node_provider()
            component = node.get_component_iface() if node else None
            if component:
                bounds = component.get_extents(Atspi.CoordType.SCREEN)
                break
        except Exception:
            pass
        time.sleep(0.1)
    assert bounds, "session row did not expose stable screen bounds"
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        # Wayland intentionally hides global coordinates from AT-SPI (SCREEN reports 0,0), while
        # WINDOW coordinates remain valid. Combine those with Hyprland's own client origin.
        local = component.get_extents(Atspi.CoordType.WINDOW)
        clients = json.loads(subprocess.check_output(["hyprctl", "-j", "clients"], text=True))
        client = next(
            (
                item for item in clients
                if item.get("pid") == process_id
                and (window_title is None or item.get("title") == window_title)
            ),
            None,
        )
        assert client, "Hyprland did not expose the isolated agterm client"
        subprocess.run(
            ["hyprctl", "dispatch", "focuswindow", f"address:{client['address']}"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        x = client["at"][0] + local.x + max(1, local.width // 2)
        y = client["at"][1] + local.y + max(1, local.height // 2)
        if shutil.which("dotool"):
            pointer = subprocess.Popen(
                ["dotool"], stdin=subprocess.PIPE, text=True,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            try:
                time.sleep(0.5)  # Let Hyprland register the temporary uinput pointer.
                subprocess.run(
                    ["hyprctl", "dispatch", "movecursor", str(x), str(y)],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                time.sleep(0.2)
                pointer.stdin.write(f"click {button}\n")
                pointer.stdin.flush()
                time.sleep(0.2)
            finally:
                pointer.stdin.close()
                pointer.wait(timeout=3)
            return
        number = 3 if button == "right" else 1
        assert Atspi.generate_mouse_event(x, y, f"b{number}c"), "AT-SPI click failed"
        return
    x = bounds.x + max(1, bounds.width // 2)
    y = bounds.y + max(1, bounds.height // 2)
    number = 3 if button == "right" else 1
    assert Atspi.generate_mouse_event(x, y, f"b{number}c"), "AT-SPI click failed"


def right_click(node_provider, process_id, window_title=None):
    mouse_click(node_provider, process_id, window_title=window_title, button="right")


def launch(env):
    process = subprocess.Popen([BIN], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    app = wait_for(lambda: find_app(process.pid), "agterm app not present in the AT-SPI tree")
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") and shutil.which("hyprctl"):
        subprocess.run(
            ["hyprctl", "dispatch", "movetoworkspacesilent", f"3,pid:{process.pid}"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
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
        timeout=5,
    )
    return json.loads(output)


def window_list(env):
    return control_json(env, "window", "list", "--json")["result"]["windows"]


def select_window(env, window_id):
    control_json(env, "window", "select", window_id, "--json")
    wait_for(
        lambda: next(
            (item for item in window_list(env) if item["id"] == window_id), {}
        ).get("active"),
        f"window {window_id} did not become active",
    )


def window_tree(env, window_id):
    return control_json(env, "tree", "--window", window_id, "--json")["result"]["tree"]


def session_count(tree):
    return sum(len(workspace["sessions"]) for workspace in tree["workspaces"])


def activate_reveal_action(env, identity):
    subprocess.run(
        ["gapplication", "action", env["AGTERM_APP_ID"], "reveal", f"'{identity}'"],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
    )


def run_palette_action(app, process_id, window_title, action_name):
    window = wait_for(
        lambda: named(app, window_title, role="frame"),
        f"custom-command window {window_title!r} is missing",
    )
    focus_accessible_window(window, process_id)
    press_ctrl_shift_p(process_id, window_title=window_title)
    palette = wait_for(
        lambda: named(app, "Command Palette", role="frame"),
        f"command palette did not open in {window_title!r}",
    )
    search = wait_for(
        lambda: editable_descendant(palette),
        "command palette search is missing",
    )
    assert search.get_editable_text_iface().set_text_contents(action_name)
    wait_for(
        lambda: named(palette, action_name) and not named(palette, "About agterm"),
        f"palette action {action_name!r} did not become the selected result",
    )
    press_return(process_id, window_title="Command Palette")
    wait_for(
        lambda: not named(app, "Command Palette", role="frame"),
        f"command palette did not close after {action_name!r}",
    )


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

        # Closing a native window removes its AppController before GTK finishes unmapping it. Exercise
        # the late notify::is-active callback and prove it cannot dereference the retired controller.
        created = control_json(env, "window", "new", "teardown-check", "--json")["result"]["id"]
        control_json(env, "window", "close", created, "--json")
        assert process.poll() is None, "closing a secondary window terminated the application"
        control_json(env, "tree", "--json")

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


def verify_context_menu(env):
    process, app = launch(env)
    try:
        rows = wait_for(lambda: collect(app, role="list item"), "expected at least one session row")
        flag = None
        for _ in range(3):
            right_click(lambda: next(iter(collect(app, role="list item")), None), process.pid)
            try:
                flag = wait_for(lambda: actionable(app, "Flag"), "session context menu did not open", timeout=1)
                break
            except AssertionError:
                pass
        assert flag, "session context menu did not open"
        assert process.poll() is None, "session context menu terminated the app"
        created = control_json(env, "window", "new", "context-background", "--json")["result"]["id"]
        assert process.poll() is None, "backgrounding a window with a context menu terminated the app"
        control_json(env, "window", "close", created, "--json")
        activate(wait_for(lambda: actionable(app, "New Session"), "New Session button is not actionable"))
        wait_for(
            lambda: len(collect(app, role="list item")) == len(rows) + 1,
            "creating a session with a context menu open blocked the app",
        )
        control_json(env, "tree", "--json")
        print("OK: session context menu survives a sidebar rebuild")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


def verify_window_callback_ownership(env):
    process, app = launch(env)
    try:
        primary_id = wait_for(
            lambda: next((item["id"] for item in window_list(env) if item["open"]), None),
            "primary window was not registered",
        )
        control_json(env, "session", "rename", "primary-session", "--window", primary_id, "--json")
        secondary_id = control_json(env, "window", "new", "secondary", "--json")["result"]["id"]
        control_json(env, "session", "rename", "secondary-session", "--window", secondary_id, "--json")

        primary = wait_for(
            lambda: named(app, "primary-session", role="frame"),
            "primary window did not expose its unique session title",
        )
        wait_for(
            lambda: named(app, "secondary-session", role="frame"),
            "secondary window did not expose its unique session title",
        )
        select_window(env, secondary_id)
        before_primary = session_count(window_tree(env, primary_id))
        before_secondary = session_count(window_tree(env, secondary_id))
        activate(wait_for(
            lambda: actionable(primary, "New Session"),
            "background primary window's New Session button is not actionable",
        ))
        wait_for(
            lambda: session_count(window_tree(env, primary_id)) == before_primary + 1,
            "background-window action did not mutate its owning window",
        )
        assert session_count(window_tree(env, secondary_id)) == before_secondary, (
            "background-window action mutated the frontmost window"
        )
        control_json(env, "session", "rename", "primary-session", "--window", primary_id, "--json")
        primary = wait_for(
            lambda: named(app, "primary-session", role="frame"),
            "primary frame title did not follow its new active session",
        )

        # Open an auxiliary palette from the primary window, then make the secondary window frontmost
        # before editing its search. The callback must filter the originating palette, not look for a
        # nonexistent palette on the newly frontmost controller.
        select_window(env, primary_id)
        focus_accessible_window(primary, process.pid)
        wait_for(
            lambda: next(
                (item for item in window_list(env) if item["id"] == primary_id), {}
            ).get("active"),
            "primary window did not receive keyboard focus",
        )
        press_ctrl_shift_p(process.pid, window_title="primary-session")
        palette = wait_for(
            lambda: named(app, "Command Palette", role="frame"),
            "primary command palette did not open",
        )
        select_window(env, secondary_id)
        palette_search = wait_for(
            lambda: editable_descendant(palette),
            "background command palette did not expose an editable search",
        )
        assert palette_search.get_editable_text_iface().set_text_contents("New Session")
        wait_for(
            lambda: named(palette, "New Session   ctrl+shift+t") and not named(palette, "About agterm"),
            "background command palette search routed to the frontmost window",
        )
        press_escape(process.pid, window_title="Command Palette")
        wait_for(
            lambda: not named(app, "Command Palette", role="frame"),
            "background command palette did not close through its owner-bound key callback",
        )

        # Exercise a pending split restore while another window becomes active, then prove the original
        # session still accepts and persists a divider resize through its explicit window address.
        primary_session = window_tree(env, primary_id)["workspaces"][0]["sessions"][0]["id"]
        select_window(env, primary_id)
        control_json(
            env, "session", "split", "on", "--target", primary_session,
            "--window", primary_id, "--json",
        )
        select_window(env, secondary_id)
        control_json(
            env, "session", "resize", "--split-ratio", "0.31", "--target", primary_session,
            "--window", primary_id, "--json",
        )
        wait_for(
            lambda: abs(
                window_tree(env, primary_id)["workspaces"][0]["sessions"][0].get("splitRatio", 0) - 0.31
            ) < 0.001,
            "background split ratio was not persisted after its restore timer",
        )

        # Keep Preferences open on the primary, move focus away, and toggle a setting through the
        # background dialog. This covers both the GAction root context and settings widget ancestry.
        select_window(env, primary_id)
        primary = wait_for(
            lambda: named(app, "primary-session", role="frame"),
            "primary frame disappeared before Preferences coverage",
        )
        focus_accessible_window(primary, process.pid)
        press_ctrl_comma(process.pid, window_title="primary-session")
        preferences = wait_for(
            lambda: named(app, "Preferences", role="dialog"),
            "primary Preferences dialog did not open",
        )
        select_window(env, secondary_id)
        right_click_switch = wait_for(
            lambda: actionable(preferences, "Right-click pastes"),
            "background Preferences switch is not actionable",
        )
        activate(right_click_switch)
        assert process.poll() is None, "background Preferences activity terminated the application"
        select_window(env, primary_id)
        press_escape(process.pid, window_title="primary-session")
        wait_for(
            lambda: not named(app, "Preferences", role="dialog"),
            "background Preferences dialog did not close through its owning window",
        )

        # Repeatedly close secondary windows with a fresh split restore and palette/window callbacks in
        # flight. The application and the surviving primary controller must remain usable.
        for index in range(4):
            transient_id = control_json(
                env, "window", "new", f"teardown-{index}", "--json"
            )["result"]["id"]
            transient_session = window_tree(env, transient_id)["workspaces"][0]["sessions"][0]["id"]
            control_json(
                env, "session", "split", "on", "--target", transient_session,
                "--window", transient_id, "--json",
            )
            control_json(env, "window", "close", transient_id, "--json")
            assert process.poll() is None, "closing a secondary window terminated the application"
        control_json(env, "tree", "--window", primary_id, "--json")

        print("OK: background callbacks and pending secondary-window teardown keep their owners")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


def verify_notification_reveal(env):
    process, app = launch(env)
    try:
        primary_id = wait_for(
            lambda: next((item["id"] for item in window_list(env) if item["open"]), None),
            "primary notification window was not registered",
        )
        primary_tree = window_tree(env, primary_id)
        session_id = primary_tree["workspaces"][0]["sessions"][0]["id"]
        control_json(
            env, "session", "split", "on", "--target", session_id,
            "--window", primary_id, "--json",
        )
        control_json(
            env, "session", "focus", "right", "--target", session_id,
            "--window", primary_id, "--json",
        )
        secondary_id = control_json(env, "window", "new", "reveal-survivor", "--json")["result"]["id"]
        control_json(env, "window", "close", primary_id, "--json")
        wait_for(
            lambda: not next(
                (item for item in window_list(env) if item["id"] == primary_id), {"open": True}
            )["open"],
            "source notification window did not close",
        )

        identity = f"{primary_id}:{session_id}:split"
        activate_reveal_action(env, identity)
        wait_for(
            lambda: next(
                (item for item in window_list(env) if item["id"] == primary_id), {}
            ).get("open"),
            "notification reveal did not reopen its encoded window",
        )

        def revealed_split():
            tree = window_tree(env, primary_id)
            sessions = [session for workspace in tree["workspaces"] for session in workspace["sessions"]]
            target = next((session for session in sessions if session["id"] == session_id), None)
            return target and target.get("active") and target.get("splitFocused")

        wait_for(revealed_split, "notification reveal did not select the encoded split pane")
        assert next(
            item for item in window_list(env) if item["id"] == secondary_id
        )["open"], "notification reveal disturbed the surviving window"
        assert process.poll() is None, "notification reveal terminated the application"
        print("OK: notification action reopens its encoded window and split pane")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


def verify_notification_focus_policy(env):
    with open(os.path.join(env["AGTERM_STATE_DIR"], "settings.json"), "w", encoding="utf-8") as target:
        json.dump({"notificationsEnabled": False}, target)
    process, app = launch(env)
    try:
        focus_window(process.pid)
        tree = control_json(env, "tree", "--json")["result"]["tree"]
        initial = tree["workspaces"][0]["sessions"][0]
        window_id = next(item["id"] for item in window_list(env) if item["open"])
        time.sleep(1.0)  # let the initial login shell reach its prompt before injecting printf

        def unseen(session_id):
            current = window_tree(env, window_id)
            sessions = [session for workspace in current["workspaces"] for session in workspace["sessions"]]
            return next(session for session in sessions if session["id"] == session_id).get("unseen", 0)

        def emit_osc(session_id, title):
            command = f"printf '\\033]9;{title} Body\\007'\n"
            control_json(
                env, "session", "type", command, "--target", session_id,
                "--window", window_id, "--json",
            )

        emit_osc(initial["id"], "Focused")
        time.sleep(0.6)
        assert unseen(initial["id"]) == 0, "focused pane OSC notification created an unseen badge"

        foreground_id = control_json(
            env, "session", "new", "--name", "foreground", "--window", window_id, "--json"
        )["result"]["id"]
        wait_for(
            lambda: window_tree(env, window_id)["workspaces"][0]["sessions"][-1].get("active"),
            "new foreground session did not become active",
        )
        wait_for(
            lambda: named(app, "foreground", role="frame"),
            "new foreground session did not become the visible GTK surface",
        )
        time.sleep(0.5)
        emit_osc(initial["id"], "Hidden")
        wait_for(
            lambda: unseen(initial["id"]) == 1,
            "hidden pane OSC notification did not create an unseen badge",
        )

        control_json(
            env, "notify", "--title", "Explicit", "--target", foreground_id,
            "control bypass", "--window", window_id, "--json",
        )
        wait_for(
            lambda: unseen(foreground_id) == 1,
            "explicit control notification did not bypass focused-pane suppression",
        )
        assert process.poll() is None, "notification focus policy terminated the application"
        print("OK: focused OSC suppresses badge while hidden and explicit notifications deliver")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


def verify_notification_banner_round_trip(env):
    assert shutil.which("makoctl"), "makoctl is required for the desktop-banner round trip"
    notification_id = None
    process, app = launch(env)
    try:
        focus_window(process.pid)
        tree = control_json(env, "tree", "--json")["result"]["tree"]
        initial = tree["workspaces"][0]["sessions"][0]
        window_id = next(item["id"] for item in window_list(env) if item["open"])
        time.sleep(1.0)

        def unseen(session_id):
            current = window_tree(env, window_id)
            sessions = [session for workspace in current["workspaces"] for session in workspace["sessions"]]
            return next(session for session in sessions if session["id"] == session_id).get("unseen", 0)

        def emit_osc(session_id, body):
            control_json(
                env, "session", "type", f"printf '\\033]9;{body}\\007'\n",
                "--target", session_id, "--window", window_id, "--json",
            )

        test_suffix = os.path.basename(env["AGTERM_STATE_DIR"])
        suppressed_body = f"Focused banner must suppress {test_suffix}"
        delivered_body = f"Hidden banner must deliver {test_suffix}"
        emit_osc(initial["id"], suppressed_body)
        time.sleep(0.8)
        assert unseen(initial["id"]) == 0
        assert not any(
            item.get("body") == suppressed_body
            for item in json.loads(subprocess.check_output(["makoctl", "list", "-j"], text=True))
        ), "focused pane posted a desktop banner"

        control_json(env, "session", "new", "--name", "banner-foreground", "--window", window_id, "--json")
        wait_for(lambda: named(app, "banner-foreground", role="frame"), "foreground banner session not visible")
        time.sleep(0.5)
        emit_osc(initial["id"], delivered_body)
        wait_for(lambda: unseen(initial["id"]) == 1, "hidden pane did not raise its badge")
        notification = wait_for(
            lambda: next((
                item for item in json.loads(subprocess.check_output(["makoctl", "list", "-j"], text=True))
                if item.get("body") == delivered_body
            ), None),
            "hidden pane did not post a desktop banner",
        )
        notification_id = notification["id"]

        survivor = control_json(env, "window", "new", "banner-survivor", "--json")["result"]["id"]
        control_json(env, "window", "close", window_id, "--json")
        wait_for(
            lambda: not next(item for item in window_list(env) if item["id"] == window_id)["open"],
            "banner source window did not close",
        )
        subprocess.run(["makoctl", "invoke", "-n", str(notification_id)], check=True)
        wait_for(
            lambda: next(item for item in window_list(env) if item["id"] == window_id)["open"],
            "desktop banner action did not reopen the source window",
        )
        wait_for(
            lambda: next(
                session for workspace in window_tree(env, window_id)["workspaces"]
                for session in workspace["sessions"] if session["id"] == initial["id"]
            ).get("active"),
            "desktop banner action did not select its source session",
        )
        assert next(item for item in window_list(env) if item["id"] == survivor)["open"]
        print("OK: real desktop banner suppresses, delivers, and reopens its source window")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        if notification_id is not None:
            subprocess.run(
                ["makoctl", "dismiss", "-n", str(notification_id), "-h"], check=False
            )
        stop(process)


def verify_custom_command_failures(env):
    config = os.path.join(env["AGTERM_STATE_DIR"], "config")
    os.makedirs(config)
    with open(os.path.join(config, "keymap.conf"), "w", encoding="utf-8") as target:
        target.write(
            'command "Launch Failure" true\n'
            'command "Exit Failure" exit 23\n'
            'command "Slow Failure" sleep 1; exit 29\n'
        )
    process, app = launch(env)
    try:
        first_window = next(item["id"] for item in window_list(env) if item["open"])
        first_cwd = os.path.join(env["AGTERM_STATE_DIR"], "command-cwd-a")
        second_cwd = os.path.join(env["AGTERM_STATE_DIR"], "command-cwd-b")
        os.makedirs(first_cwd)
        os.makedirs(second_cwd)
        first_session = control_json(
            env, "session", "new", "--name", "command-origin-a", "--cwd", first_cwd,
            "--window", first_window, "--json",
        )["result"]["id"]
        second_window = control_json(env, "window", "new", "command-window-b", "--json")["result"]["id"]
        second_session = control_json(
            env, "session", "new", "--name", "command-origin-b", "--cwd", second_cwd,
            "--window", second_window, "--json",
        )["result"]["id"]

        def frame(title):
            return named(app, title, role="frame")

        def failure_named(window, prefix):
            return next((item for item in collect(window) if (item.get_name() or "").startswith(prefix)), None)

        wait_for(lambda: frame("command-origin-a"), "first command window did not become accessible")
        wait_for(lambda: frame("command-origin-b"), "second command window did not become accessible")
        time.sleep(0.5)
        shutil.rmtree(first_cwd)
        shutil.rmtree(second_cwd)
        exit_titles = {}
        for window_id, session_id, title, other_title in (
            (first_window, first_session, "command-origin-a", "command-origin-b"),
            (second_window, second_session, "command-origin-b", "command-exit-a"),
        ):
            run_palette_action(app, process.pid, title, "Launch Failure  (custom)")
            launch_prefix = "command failed to launch: Launch Failure —"
            wait_for(
                lambda: failure_named(frame(title), launch_prefix),
                f"launch failure toast did not appear in {title}",
            )
            assert not failure_named(frame(other_title), launch_prefix), (
                f"launch failure from {title} leaked into {other_title}"
            )

            suffix = "a" if window_id == first_window else "b"
            exit_title = f"command-exit-{suffix}"
            control_json(
                env, "session", "new", "--name", exit_title, "--cwd", "/tmp",
                "--window", window_id, "--json",
            )
            wait_for(lambda: frame(exit_title), f"{exit_title} did not become accessible")
            exit_titles[window_id] = exit_title
            run_palette_action(app, process.pid, exit_title, "Exit Failure  (custom)")
            exit_message = "command failed (exit 23): Exit Failure"
            wait_for(
                lambda: named(frame(exit_title), exit_message),
                f"non-zero failure toast did not appear in {exit_title}",
            )
            assert not named(frame(other_title), exit_message), (
                f"non-zero failure from {exit_title} leaked into {other_title}"
            )

        run_palette_action(app, process.pid, exit_titles[first_window], "Slow Failure  (custom)")
        control_json(env, "window", "close", first_window, "--json")
        wait_for(
            lambda: not next(item for item in window_list(env) if item["id"] == first_window)["open"],
            "slow-command source window did not close",
        )
        control_json(env, "window", "select", first_window, "--json")
        wait_for(
            lambda: next(item for item in window_list(env) if item["id"] == first_window)["open"],
            "slow-command source window did not reopen",
        )
        time.sleep(1.4)
        slow_message = "command failed (exit 29): Slow Failure"
        assert not named(frame(exit_titles[first_window]), slow_message), (
            "old command completion reached the reopened controller incarnation"
        )
        assert not named(frame(exit_titles[second_window]), slow_message), (
            "old command completion leaked into the other window"
        )
        print("OK: custom-command failures stay with their originating controller incarnation")
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
        os.makedirs(os.path.join(home, ".pi/agent"))
        env = dict(
            env,
            AGTERM_APP_ID=env["AGTERM_APP_ID"] + ".integrations",
            AGTERM_ATSPI_OPEN_PREFERENCES="integrations",
        )
        process, app = launch(env)
        window_title = wait_for(
            lambda: next((item.get_name() for item in collect(app, role="frame") if item.get_name()), None),
            "integration test window title is missing",
        )
        pi_row = wait_for(lambda: named(app, "Pi Extension"), "Pi integration row is missing")
        pi_install = wait_for(
            lambda: next((item for item in descendants(pi_row) if item.get_name() == "Install"), None),
            "Pi extension did not become installable",
        )
        activate(pi_install)
        wait_for(lambda: named(app, "Apply Integration Changes?"), "Pi hooks preflight was not shown")
        pi_extension = os.path.join(home, ".pi/agent/extensions/agterm-status.ts")
        assert not os.path.exists(pi_extension), "Pi preflight mutated HOME"
        wait_for(lambda: actionable(app, "Apply"), "Pi hooks preflight has no Apply action")
        press_return(process.pid, window_title=window_title)
        wait_for(lambda: os.path.exists(pi_extension), "Pi extension was not installed")
        with open(pi_extension, encoding="utf-8") as source:
            assert "// agterm-pi-status-extension" in source.read(), "Pi ownership marker is missing"
        wait_for(lambda: named(app, "Integration Updated"), "Pi hooks result was not shown")
        wait_for(lambda: actionable(app, "OK"), "Pi hooks result has no OK action")
        press_escape(process.pid, window_title=window_title)
        wait_for(
            lambda: next((item for item in descendants(pi_row) if item.get_name() == "Current"), None),
            "Pi row did not refresh to Current",
        )

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
        print("OK: Preferences pages, Pi hooks preflight/apply, and safe skill install")
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


def verify_session_pickers(env, state):
    settings_path = os.path.join(state, "settings.json")
    with open(settings_path, "w", encoding="utf-8") as destination:
        json.dump({"attentionButtonEnabled": True}, destination)

    process, app = launch(env)
    try:
        tree = control_json(env, "tree", "--json")["result"]["tree"]
        original_id = tree["workspaces"][0]["sessions"][0]["id"]
        subprocess.run(
            [CTL, "session", "new", "--socket", env["AGTERM_CONTROL_SOCKET"]],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        subprocess.run(
            [
                CTL, "session", "status", "blocked", "--target", original_id,
                "--socket", env["AGTERM_CONTROL_SOCKET"],
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )

        recent = wait_for(
            lambda: actionable(app, "Recent Sessions (Ctrl+Tab)"),
            "Recent Sessions button is missing or not actionable",
        )
        activate(recent)
        recent_row = wait_for(
            lambda: next(
                (
                    item for item in collect(app, role="button")
                    if "workspace 1 ·" in (item.get_name() or "")
                ),
                None,
            ),
            "Recent Sessions popover did not expose a session row",
        )
        activate(recent_row)
        wait_for(
            lambda: actionable(app, "Show sessions that need attention (Ctrl+Shift+I)"),
            "Attention button is missing or not actionable",
        )
        activate(actionable(app, "Show sessions that need attention (Ctrl+Shift+I)"))
        wait_for(
            lambda: next(
                (
                    item for item in collect(app, role="button")
                    if "workspace 1 ·" in (item.get_name() or "")
                ),
                None,
            ),
            "Attention popover did not expose a session row",
        )
        print("OK: recent-session and attention popovers expose actionable rows")
    except AssertionError:
        describe_tree(app)
        raise
    finally:
        stop(process)


def verify_auto_follow(env, state):
    auto_state = state + "-auto-follow"
    os.makedirs(auto_state)
    auto_env = dict(
        env,
        AGTERM_STATE_DIR=auto_state,
        AGTERM_CONTROL_SOCKET=os.path.join(auto_state, "agterm.sock"),
        AGTERM_APP_ID="io.github.melonamin.agterm.atspi.autofollow",
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
        for child_scenario in (
            "normal", "context-menu", "window-ownership", "preferences-pages",
            "notification-reveal", "notification-focus", "session-pickers",
            "custom-command-failures", "auto-follow", "hidden-toolbar",
        ):
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
        AGTERM_APP_ID=f"io.github.melonamin.agterm.atspi.{scenario.replace('-', '_')}",
        PATH="/usr/bin:/bin",
    )
    if scenario in ("preferences-pages", "auto-follow"):
        # Page inspection and auto-follow need an already-mapped modal while another process owns focus.
        env["AGTERM_ATSPI_OPEN_PREFERENCES"] = "general"
    try:
        Atspi.init()
        if scenario == "normal":
            verify_normal_toolbar(env, state, home)
        elif scenario == "context-menu":
            verify_context_menu(env)
        elif scenario == "window-ownership":
            verify_window_callback_ownership(env)
        elif scenario == "notification-reveal":
            verify_notification_reveal(env)
        elif scenario == "notification-focus":
            verify_notification_focus_policy(env)
        elif scenario == "notification-banner":
            verify_notification_banner_round_trip(env)
        elif scenario == "custom-command-failures":
            verify_custom_command_failures(env)
        elif scenario == "preferences-pages":
            verify_preferences_pages(env, home)
        elif scenario == "auto-follow":
            verify_auto_follow(env, state)
        elif scenario == "session-pickers":
            verify_session_pickers(env, state)
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
