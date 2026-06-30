#!/usr/bin/env bash
# Build libghostty for Linux (OpenGL embedded apprt) and vendor it into
# agterm-linux/vendor/ghostty. Applies linux/patches/ghostty-embedded-opengl.patch
# which adds a host-GL surface to the embedded apprt (see LINUX_PORT.md Spike 4).
# Idempotent: skips the build if the vendored lib is already present.
set -euo pipefail
cd "$(dirname "$0")/.."

GHOSTTY_REPO="https://github.com/ghostty-org/ghostty"
GHOSTTY_REV="4dcb09ada0c0909717d92547623b26eafa50ca8a"
PATCH="$(pwd)/linux/patches/ghostty-embedded-opengl.patch"
VENDOR="$(pwd)/agterm-linux/vendor/ghostty"

# Present-check is the lib only (the always-producible artifact) so an existing checkout never force-
# rebuilds just for the share resources. Resources stage during the (re)build below; to re-vendor them
# on an already-built tree, `rm -rf agterm-linux/vendor/ghostty` first. At runtime a missing vendored
# resource falls back to ~/.local/share/agterm or /usr/share/ghostty, so this is best-effort.
if [[ -f "$VENDOR/lib/libghostty.so" && -f "$VENDOR/include/ghostty.h" ]]; then
  echo "libghostty already vendored at $VENDOR"; exit 0
fi

command -v zig >/dev/null || eval "$(mise activate bash 2>/dev/null || true)"
ZIG="$(command -v zig || echo "$HOME/.local/share/mise/installs/zig/0.15.2/zig")"

BUILD_DIR="$(mktemp -d)"; trap 'rm -rf "$BUILD_DIR"' EXIT
echo "fetching ghostty $GHOSTTY_REV..."
git init -q "$BUILD_DIR"
git -C "$BUILD_DIR" remote add origin "$GHOSTTY_REPO"
git -C "$BUILD_DIR" fetch -q --depth 1 origin "$GHOSTTY_REV"
git -C "$BUILD_DIR" -c advice.detachedHead=false checkout -q FETCH_HEAD
echo "applying embedded-OpenGL patch..."
git -C "$BUILD_DIR" apply "$PATCH"
echo "building libghostty (zig build -Dapp-runtime=none, targeting glibc 2.39 for portability)..."
# Target an OLDER glibc (2.39) so the vendored libghostty runs against runtimes older than the rolling-
# release host's (Arch ships glibc 2.43, which baked a GLIBC_2.43 libm symbol requirement into the .so —
# that breaks the flatpak's GNOME 47 runtime [glibc 2.40] and any non-bleeding-edge box). The host has
# >= 2.39 so it keeps working; targeting down only narrows the symbol versions the lib binds to.
( cd "$BUILD_DIR" && "$ZIG" build -Dapp-runtime=none -Dtarget=x86_64-linux-gnu.2.39 )

mkdir -p "$VENDOR/lib" "$VENDOR/include"
cp "$BUILD_DIR/zig-out/lib/ghostty-internal.so" "$VENDOR/lib/libghostty.so"
cp -R "$BUILD_DIR/zig-out/include/." "$VENDOR/include/"
echo "vendored libghostty into $VENDOR"

# Stage ghostty's resources: shell-integration + themes under share/ghostty, and the compiled terminfo
# DB under the SIBLING share/terminfo. The app points GHOSTTY_RESOURCES_DIR at share/ghostty and
# libghostty derives TERMINFO as dirname(that)/terminfo, so the sibling layout makes xterm-ghostty
# resolve. The -Dapp-runtime=none build may skip the share step, so fall back to src; all staging is
# best-effort (a missing piece warns, never aborts — the runtime falls back to a system/installed dir).
rm -rf "$VENDOR/share"; mkdir -p "$VENDOR/share/ghostty"
if [[ -d "$BUILD_DIR/zig-out/share/ghostty/shell-integration" ]]; then
  cp -R "$BUILD_DIR/zig-out/share/ghostty/shell-integration" "$VENDOR/share/ghostty/"
  [[ -d "$BUILD_DIR/zig-out/share/ghostty/themes" ]] && cp -R "$BUILD_DIR/zig-out/share/ghostty/themes" "$VENDOR/share/ghostty/"
elif [[ -d "$BUILD_DIR/src/shell-integration" ]]; then
  cp -R "$BUILD_DIR/src/shell-integration" "$VENDOR/share/ghostty/shell-integration"
else
  echo "WARN: no ghostty shell-integration in the build output; skipped (runtime falls back to a system dir)"
fi
# Themes: the -Dapp-runtime=none build skips the share/themes generation, so they're absent from zig-out.
# Fall back to a system/installed ghostty's themes (the iTerm2-Color-Schemes set is stable across ghostty
# versions) so the bundled + INSTALLED theme picker isn't empty on a machine without a system ghostty.
if [[ ! -d "$VENDOR/share/ghostty/themes" ]]; then
  for sys in /usr/share/ghostty/themes /usr/local/share/ghostty/themes "$HOME/.local/share/ghostty/themes"; do
    [[ -d "$sys" ]] && cp -R "$sys" "$VENDOR/share/ghostty/themes" && echo "vendored themes from $sys ($(ls "$sys" | wc -l) themes)" && break
  done
fi
if [[ -d "$BUILD_DIR/zig-out/share/terminfo/x" ]]; then
  cp -R "$BUILD_DIR/zig-out/share/terminfo" "$VENDOR/share/terminfo"
elif [[ -f "$BUILD_DIR/src/terminfo/ghostty.terminfo" ]] && command -v tic >/dev/null; then
  # compile into a temp dir, move into place ONLY after the entry verifies (no broken turd on failure).
  ti_tmp="$(mktemp -d)"
  if tic -x -o "$ti_tmp" "$BUILD_DIR/src/terminfo/ghostty.terminfo" 2>/dev/null \
     && [[ -f "$ti_tmp/x/xterm-ghostty" ]]; then
    mv "$ti_tmp" "$VENDOR/share/terminfo"
  else
    rm -rf "$ti_tmp"
    echo "WARN: could not compile ghostty terminfo; skipped (runtime falls back to a system terminfo)"
  fi
else
  echo "WARN: no ghostty terminfo in the build output and no tic-able source; skipped"
fi
echo "vendored ghostty resources (best-effort) into $VENDOR/share"
