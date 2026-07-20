#!/usr/bin/env bash
# Build the pinned libghostty and deterministic Linux resources into agterm-linux/vendor/ghostty.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="$ROOT/linux/patches/ghostty-embedded-opengl.patch"
INPUT_HANDOFF_PATCH="$ROOT/linux/patches/ghostty-embedded-input-handoff.patch"
RESOURCE_PATCH="$ROOT/linux/patches/ghostty-lib-resources.patch"
VENDOR="$ROOT/agterm-linux/vendor/ghostty"
VERIFY="$ROOT/scripts/verify-linux-resources.sh"
GHOSTTY_REPO="https://github.com/ghostty-org/ghostty"
# shellcheck source=../linux/ghostty-resources.env
source "$ROOT/linux/ghostty-resources.env"

cache_is_complete() {
  [[ -s "$VENDOR/lib/libghostty.so" && -s "$VENDOR/include/ghostty.h"
    && -s "$VENDOR/include/ghostty/vt.h" ]] \
    && "$VERIFY" "$VENDOR/share" >/dev/null 2>&1
}

if cache_is_complete; then
  echo "complete libghostty resource cache already vendored at $VENDOR"
  exit 0
fi

for command in git curl tar sha256sum tic infocmp; do
  command -v "$command" >/dev/null || { echo "$command is required to vendor libghostty" >&2; exit 1; }
done
ZIG="$(command -v zig || true)"
if [[ -z "$ZIG" ]] && command -v mise >/dev/null; then
  ZIG="$(mise where zig@0.15.2 2>/dev/null || true)/bin/zig"
fi
[[ -x "$ZIG" ]] || { echo "zig 0.15.2 is required to build libghostty" >&2; exit 1; }
[[ "$($ZIG version)" == "0.15.2" ]] || { echo "setup-linux.sh requires zig 0.15.2" >&2; exit 1; }

BUILD_DIR="$(mktemp -d)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR" "$STAGE"' EXIT

echo "fetching ghostty $GHOSTTY_REV..."
git init -q "$BUILD_DIR"
git -C "$BUILD_DIR" remote add origin "$GHOSTTY_REPO"
git -C "$BUILD_DIR" fetch -q --depth 1 origin "$GHOSTTY_REV"
git -C "$BUILD_DIR" -c advice.detachedHead=false checkout -q FETCH_HEAD
[[ "$(git -C "$BUILD_DIR" rev-parse HEAD)" == "$GHOSTTY_REV" ]]
grep -F "$GHOSTTY_THEMES_URL" "$BUILD_DIR/build.zig.zon" >/dev/null || {
  echo "pinned Ghostty source no longer declares the recorded theme dependency" >&2
  exit 1
}

echo "applying embedded-OpenGL patch..."
git -C "$BUILD_DIR" apply "$PATCH"
git -C "$BUILD_DIR" apply "$INPUT_HANDOFF_PATCH"
git -C "$BUILD_DIR" apply "$RESOURCE_PATCH"
echo "building libghostty and generated terminfo source..."
# Zig defaults to Debug, whose terminal integrity checks make sustained PTY output unusably slow.
(
  cd "$BUILD_DIR"
  "$ZIG" build -Doptimize=ReleaseFast -Dapp-runtime=none -Dtarget=x86_64-linux-gnu.2.39 \
    -Demit-themes=false -Demit-terminfo=true
)

mkdir -p "$STAGE/lib" "$STAGE/include" "$STAGE/share/ghostty/themes"
cp "$BUILD_DIR/zig-out/lib/ghostty-internal.so" "$STAGE/lib/libghostty.so"
cp -R "$BUILD_DIR/zig-out/include/." "$STAGE/include/"
cp -R "$BUILD_DIR/src/shell-integration" "$STAGE/share/ghostty/shell-integration"

echo "fetching pinned Ghostty theme dependency..."
curl -fsSLo "$BUILD_DIR/ghostty-themes.tgz" "$GHOSTTY_THEMES_URL"
echo "$GHOSTTY_THEMES_SHA256  $BUILD_DIR/ghostty-themes.tgz" | sha256sum --check
tar -xzf "$BUILD_DIR/ghostty-themes.tgz" -C "$STAGE/share/ghostty/themes" --strip-components=1
cp "$ROOT/linux/ghostty-resources.env" "$STAGE/share/ghostty/themes/.agterm-resource-manifest"

TERMINFO_SOURCE="$BUILD_DIR/zig-out/share/terminfo/ghostty.terminfo"
[[ -s "$TERMINFO_SOURCE" ]] || { echo "Ghostty build did not generate ghostty.terminfo" >&2; exit 1; }
# Keep the compiler input beside Ghostty's generator for an explicit source-to-tic provenance chain.
cp "$TERMINFO_SOURCE" "$BUILD_DIR/src/terminfo/ghostty.terminfo"
tic -x -o "$STAGE/share/terminfo" "$BUILD_DIR/src/terminfo/ghostty.terminfo"

"$VERIFY" "$STAGE/share"
rm -rf "$VENDOR"
mkdir -p "$(dirname "$VENDOR")"
mv "$STAGE" "$VENDOR"
echo "→ vendored deterministic libghostty and resources into $VENDOR"
