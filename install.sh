#!/usr/bin/env bash
# install.sh [--apply] [--dest DIR]
#
# Copy hooks, helper scripts and skills into ~/.claude (or DIR). Dry run by
# default: it prints what it would copy and never overwrites a file that differs
# without --apply. It does NOT edit settings.json; merge settings.example.json
# into it yourself, because a hook config is the one thing you should read first.
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEST="$HOME/.claude"
APPLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dest)  DEST=$2; shift 2 ;;
    *) echo "usage: $0 [--apply] [--dest DIR]" >&2; exit 2 ;;
  esac
done

for dep in jq gh python3; do
  command -v "$dep" >/dev/null 2>&1 || echo "warning: $dep not found; hooks fail open without it" >&2
done
command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 \
  || echo "note: no timeout command; GitHub calls in hooks run unbounded (macOS: brew install coreutils)" >&2

install_file() {  # install_file <relative source> <relative dest>
  local from="$SRC/$1" to="$DEST/$2"
  if [ -f "$to" ] && cmp -s "$from" "$to"; then
    echo "  same     $2"; return
  fi
  local verb="new"; [ -f "$to" ] && verb="update"
  echo "  $verb $( [ "$verb" = new ] && printf '    ' || printf ' ')$2"
  [ -n "$APPLY" ] || return 0
  mkdir -p "$(dirname "$to")"
  [ -f "$to" ] && cp "$to" "$to.bak.$(date +%Y%m%d%H%M%S)"
  cp "$from" "$to"
  case "$2" in *.sh|bin/*) chmod +x "$to" ;; esac
}

if [ -n "$APPLY" ]; then echo "Installing into $DEST"; else echo "Dry run into $DEST"; fi
for f in hooks/*.sh; do install_file "$f" "$f"; done
for f in bin/*; do install_file "$f" "$f"; done
for f in skills/*/*; do install_file "$f" "$f"; done
install_file templates/deploy-profiles-README.md deploy-profiles/README.md

if [ -z "$APPLY" ]; then
  echo
  echo "Nothing written. Re-run with --apply, then merge settings.example.json into $DEST/settings.json."
fi
