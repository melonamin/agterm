#!/usr/bin/env bash
# Stage the relocatable agterm-linux payload shared by tar, DEB, RPM, AppImage, and Flatpak packaging.
# Usage: scripts/stage-linux.sh DESTINATION
set -euo pipefail

if (( $# != 1 )); then
  echo "usage: scripts/stage-linux.sh DESTINATION" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/agterm-linux"
DEST="$1"
[[ "$DEST" = /* ]] || DEST="$ROOT/$DEST"

if [[ -d "$DEST" ]] && find "$DEST" -mindepth 1 -print -quit | grep -q .; then
  echo "staging destination is not empty: $DEST" >&2
  exit 1
fi

BIN="$APP/.build/release/AgtermLinux"
CTL="$APP/.build/release/agtermctl-linux"
[[ -f "$BIN" ]] || {
  echo "no agterm-linux release build found — run 'swift build -c release' in agterm-linux/ first" >&2
  exit 1
}
[[ -f "$CTL" ]] || {
  echo "no agtermctl-linux release build found — run 'swift build -c release' in agterm-linux/ first" >&2
  exit 1
}

mkdir -p "$DEST/bin" "$DEST/lib" "$DEST/share/applications" "$DEST/share/pixmaps"
install -m755 "$BIN" "$DEST/bin/agterm-linux.bin"
install -m755 "$CTL" "$DEST/bin/agtermctl.bin"

# Bundle the non-system libraries that make the Swift app portable. GTK, libadwaita, and glibc remain
# host dependencies in tar/DEB/RPM; the AppImage packaging pass adds its GTK stack separately.
{ ldd "$BIN"; ldd "$CTL"; } \
  | awk '/=> \// {print $3}' \
  | grep -E '/(swift|ghostty)|libghostty|swift-linux-compat' \
  | sort -u \
  | while read -r lib; do
      [[ -f "$lib" ]] && cp -L "$lib" "$DEST/lib/"
    done

if [[ -d "$APP/vendor/ghostty/share/ghostty" ]]; then
  cp -R "$APP/vendor/ghostty/share/ghostty" "$DEST/share/ghostty"
else
  echo "NOTE: no vendored ghostty resources to bundle (runtime falls back to /usr/share/ghostty)" >&2
fi
[[ -d "$APP/vendor/ghostty/share/terminfo" ]] \
  && cp -R "$APP/vendor/ghostty/share/terminfo" "$DEST/share/terminfo"

[[ -d "$APP/Resources/icons" ]] && cp -R "$APP/Resources/icons" "$DEST/share/icons"

DESKTOP="$ROOT/packaging/linux/com.umputun.agterm.linux.desktop"
install -m644 "$DESKTOP" "$DEST/share/applications/com.umputun.agterm.linux.desktop"
# Keep the historical root copy consumed by the local Flatpak manifest and convenient for tar users.
install -m644 "$DESKTOP" "$DEST/com.umputun.agterm.linux.desktop"

ICON_SRC="$(find "$ROOT/agterm/AppIcon.icon/Assets" -maxdepth 1 -type f -name '*.png' -print -quit)"
if [[ -n "$ICON_SRC" ]]; then
  install -m644 "$ICON_SRC" "$DEST/share/pixmaps/com.umputun.agterm.linux.png"
  IMAGE_CONVERTER="$(command -v magick || command -v convert || true)"
  if [[ -n "$IMAGE_CONVERTER" ]]; then
    for size in 16 32 48 64 128 256 512; do
      ICON_DIR="$DEST/share/icons/hicolor/${size}x${size}/apps"
      mkdir -p "$ICON_DIR"
      "$IMAGE_CONVERTER" "$ICON_SRC" -resize "${size}x${size}" \
        "$ICON_DIR/com.umputun.agterm.linux.png"
    done
  fi
fi

cat > "$DEST/bin/agterm-linux" <<'LAUNCH'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
export LD_LIBRARY_PATH="$HERE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
[[ -d "$HERE/share/ghostty" ]] && export AGTERM_GHOSTTY_RESOURCES="$HERE/share/ghostty"
exec "$HERE/bin/agterm-linux.bin" "$@"
LAUNCH
chmod 0755 "$DEST/bin/agterm-linux"

cat > "$DEST/bin/agtermctl" <<'LAUNCH'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
export LD_LIBRARY_PATH="$HERE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/bin/agtermctl.bin" "$@"
LAUNCH
chmod 0755 "$DEST/bin/agtermctl"

echo "→ staged agterm-linux payload at $DEST"
