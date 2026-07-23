#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${AGTERM_UI_ARTIFACT_DIR:-$ROOT/artifacts/linux-ui}"
PYTHON="${PYTHON:-/usr/bin/python3}"
BIN="${AGTERM_TEST_BIN:-$ROOT/agterm-linux/.build/debug/AgtermLinux}"
CTL="${AGTERM_TEST_CTL:-$ROOT/agterm-linux/.build/debug/agtermctl-linux}"
RUN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agterm-linux-ui.XXXXXX")"

cleanup() {
  rm -rf "$RUN_ROOT"
}
trap cleanup EXIT

for command in dbus-run-session openbox xdotool xvfb-run "$PYTHON"; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "missing Linux UI test dependency: $command" >&2
    exit 1
  fi
done
for product in "$BIN" "$CTL"; do
  if [[ ! -x "$product" ]]; then
    echo "missing Linux UI test build product: $product" >&2
    exit 1
  fi
done
"$PYTHON" -c 'import gi; gi.require_version("Atspi", "2.0"); from gi.repository import Atspi'

mkdir -p "$ARTIFACT_DIR" "$RUN_ROOT/home" "$RUN_ROOT/state" "$RUN_ROOT/runtime" "$RUN_ROOT/tmp"
chmod 0700 "$RUN_ROOT/runtime"

export HOME="$RUN_ROOT/home"
export XDG_CONFIG_HOME="$RUN_ROOT/home/.config"
export XDG_CACHE_HOME="$RUN_ROOT/home/.cache"
export XDG_DATA_HOME="$RUN_ROOT/home/.local/share"
export XDG_RUNTIME_DIR="$RUN_ROOT/runtime"
export TMPDIR="$RUN_ROOT/tmp"
export AGTERM_STATE_DIR="$RUN_ROOT/state"
export AGTERM_CONTROL_SOCKET="$RUN_ROOT/state/agterm.sock"
export AGTERM_TEST_BIN="$BIN"
export AGTERM_TEST_CTL="$CTL"
export AGTERM_RESOURCE_ROOT="${AGTERM_RESOURCE_ROOT:-$ROOT/agterm/Resources}"
export GDK_BACKEND=x11
export GTK_A11Y=atspi
export NO_AT_BRIDGE=0
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
export XDG_SESSION_TYPE=x11
unset WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE SWAYSOCK

LOG="$ARTIFACT_DIR/atspi.log"
XVFB_LOG="$ARTIFACT_DIR/xvfb.log"
WM_LOG="$ARTIFACT_DIR/openbox.log"
set +e
dbus-run-session -- \
  xvfb-run --auto-servernum \
    --error-file="$XVFB_LOG" \
    --server-args="-screen 0 1440x900x24 -nolisten tcp +extension GLX +render -noreset" \
    bash -c '
      openbox --sm-disable >"$1" 2>&1 &
      wm_pid=$!
      trap "kill $wm_pid 2>/dev/null || true" EXIT
      "$2" "$3"
    ' _ "$WM_LOG" "$PYTHON" "$ROOT/agterm-linux/tests/atspi_smoke.py" 2>&1 | tee "$LOG"
status="${PIPESTATUS[0]}"
set -e

if [[ "$status" -ne 0 ]]; then
  cp "$LOG" "$ARTIFACT_DIR/accessibility-tree.txt"
  echo "Linux UI smoke failed; diagnostics are in $ARTIFACT_DIR" >&2
fi
exit "$status"
