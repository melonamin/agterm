#!/usr/bin/env bash
# Build a self-contained, relocatable agterm-linux tarball: the binary + its non-system shared libs
# (the Swift runtime + libghostty) + the ghostty resources + a launcher that wires LD_LIBRARY_PATH and
# GHOSTTY resources. GTK4/libadwaita are expected from the host (any modern Linux desktop has them).
# Usage: scripts/dist-linux.sh [output.tar.gz]
# The output defaults to agterm-linux-dist.tar.gz at the repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/agterm-linux"

if (( $# > 1 )); then
  echo "usage: scripts/dist-linux.sh [output.tar.gz]" >&2
  exit 2
fi

BIN="$APP/.build/release/AgtermLinux"
CTL="$APP/.build/release/agtermctl-linux"
[ -f "$BIN" ] || { echo "no agterm-linux release build found — run 'swift build -c release' in agterm-linux/ first" >&2; exit 1; }
[ -f "$CTL" ] || { echo "no agtermctl-linux release build found — run 'swift build -c release' in agterm-linux/ first" >&2; exit 1; }

STAGE="$(mktemp -d)/agterm-linux"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/share"

cp "$BIN" "$STAGE/bin/agterm-linux.bin"
cp "$CTL" "$STAGE/bin/agtermctl"
# Bundle only the NON-system libs the binaries link (the Swift runtime + libghostty); GTK/glibc stay host.
{ ldd "$BIN"; ldd "$CTL"; } | awk '/=> \// {print $3}' | grep -E '/(swift|ghostty)|libghostty|swift-linux-compat' | sort -u \
  | while read -r lib; do [ -f "$lib" ] && cp -L "$lib" "$STAGE/lib/" || true; done

# Ghostty resources (shell-integration + themes) plus the sibling terminfo used by xterm-ghostty;
# skipped cleanly if not staged.
[ -d "$APP/vendor/ghostty/share/ghostty" ] && cp -r "$APP/vendor/ghostty/share/ghostty" "$STAGE/share/ghostty" || \
  echo "NOTE: no vendored ghostty resources to bundle (runtime falls back to /usr/share/ghostty)" >&2
[ -d "$APP/vendor/ghostty/share/terminfo" ] && cp -r "$APP/vendor/ghostty/share/terminfo" "$STAGE/share/terminfo" || true

# Custom symbolic toolbar icons. The app looks beside the launcher at share/icons before falling back to
# installed hicolor icons or dev resource paths.
[ -d "$APP/Resources/icons" ] && cp -r "$APP/Resources/icons" "$STAGE/share/icons" || true

# Relocatable launcher: resolve its own dir, wire the bundled libs + resources, exec the binary.
cat > "$STAGE/bin/agterm-linux" <<'LAUNCH'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
export LD_LIBRARY_PATH="$HERE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
[ -d "$HERE/share/ghostty" ] && export AGTERM_GHOSTTY_RESOURCES="$HERE/share/ghostty"
exec "$HERE/bin/agterm-linux.bin" "$@"
LAUNCH
chmod +x "$STAGE/bin/agterm-linux"

cp "$ROOT/packaging/linux/com.umputun.agterm.linux.desktop" "$STAGE/" 2>/dev/null || true

OUT="${1:-agterm-linux-dist.tar.gz}"
[[ "$OUT" = /* ]] || OUT="$ROOT/$OUT"
tar czf "$OUT" -C "$(dirname "$STAGE")" agterm-linux
rm -rf "$(dirname "$STAGE")"
echo "→ $OUT ($(du -h "$OUT" | cut -f1))"
