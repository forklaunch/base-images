#!/usr/bin/env bash
# Render a template: replace every @@KEY@@ with KEY's value from the given
# env-style pin files (KEY=value lines; later files win) and from KEY=value
# arguments. Fails if any @@...@@ token is left.
#
# Usage: scripts/render.sh <template> <out> [pins-file | KEY=value]...
set -euo pipefail
template="$1"; out="$2"; shift 2
tmp="$(mktemp)"; trap 'rm -f "$tmp" "$tmp.sed"' EXIT
: > "$tmp.sed"
add() { printf 's|@@%s@@|%s|g\n' "$1" "$(printf '%s' "$2" | sed 's/[|&\\]/\\&/g')" >> "$tmp.sed"; }
for arg in "$@"; do
  if [ -f "$arg" ]; then
    while IFS= read -r line; do
      case "$line" in ''|'#'*) continue;; esac
      case "$line" in *=*) add "${line%%=*}" "${line#*=}";; esac
    done < "$arg"
  else
    add "${arg%%=*}" "${arg#*=}"
  fi
done
sed -f "$tmp.sed" "$template" > "$tmp"
if grep -n '@@[A-Za-z0-9_:.-]*@@' "$tmp" >&2; then
  echo "render: unresolved tokens in $template" >&2; exit 1
fi
mkdir -p "$(dirname "$out")"; mv "$tmp" "$out"
