#!/usr/bin/env bash
# Reproduce the empty-resource package defect and exercise the strict resource verifier with fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$ROOT/scripts/verify-linux-resources.sh"
# shellcheck source=../linux/ghostty-resources.env
source "$ROOT/linux/ghostty-resources.env"

command -v tic >/dev/null || { echo "tic is required to test Ghostty resources" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/empty/share/ghostty"
if "$VERIFY" "$WORK/empty/share" >/dev/null 2>&1; then
  echo "empty Ghostty resources unexpectedly passed verification" >&2
  exit 1
fi

SHARE="$WORK/complete/share"
THEMES="$SHARE/ghostty/themes"
mkdir -p "$THEMES" "$SHARE/ghostty/shell-integration/bash" "$SHARE/ghostty/shell-integration/zsh"
printf 'fixture\n' > "$SHARE/ghostty/shell-integration/bash/ghostty.bash"
printf 'fixture\n' > "$SHARE/ghostty/shell-integration/zsh/ghostty-integration"
for theme in "${GHOSTTY_KNOWN_THEMES[@]}"; do
  printf 'background = 000000\n' > "$THEMES/$theme"
done
for number in $(seq 1 "$((GHOSTTY_THEME_COUNT - ${#GHOSTTY_KNOWN_THEMES[@]}))"); do
  printf 'background = 000000\n' > "$THEMES/Fixture $number"
done
cp "$ROOT/linux/ghostty-resources.env" "$THEMES/.agterm-resource-manifest"

printf 'xterm-ghostty|agterm resource verifier fixture,\n\tuse=xterm-256color,\n' > "$WORK/ghostty.terminfo"
tic -x -o "$SHARE/terminfo" "$WORK/ghostty.terminfo"
"$VERIFY" "$SHARE" >/dev/null

if grep -En '/usr(/local)?/share/ghostty/themes|\.local/share/ghostty/themes' "$ROOT/scripts/setup-linux.sh"; then
  echo "setup-linux.sh still permits a system theme source" >&2
  exit 1
fi

echo "→ resource verifier rejects the empty v0.13-style payload and accepts a complete pinned fixture"
