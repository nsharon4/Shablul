#!/usr/bin/env bash
# knowledge.sh — TTL enforcement for knowledge/ notes.
# Technical notes live 7 days. On expiry they are DELETED and regenerated from source.
# Dynamic data (prices, quotes, live figures) is never stored here at all.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/knowledge"
TTL_DAYS="${TTL_DAYS:-7}"

now_epoch() { date -u +%s; }

# Read a front-matter scalar from a note.
fm() { sed -n '/^---$/,/^---$/p' "$1" | grep -m1 "^$2:" | sed "s/^$2:[[:space:]]*//" | tr -d '"'; }

notes() { find "$DIR" -maxdepth 1 -name '*.md' ! -name '_TEMPLATE.md' ! -name 'README.md' -print | sort; }

# Echoes "EXPIRED" or "fresh" for a note.
state_of() {
  local f="$1" exp
  exp="$(fm "$f" expires_utc || true)"
  [ -z "$exp" ] && { echo "NO-TTL"; return; }
  local exp_e now_e
  exp_e="$(date -u -d "$exp" +%s 2>/dev/null || echo 0)"
  now_e="$(now_epoch)"
  if [ "$exp_e" -eq 0 ]; then echo "BAD-DATE"
  elif [ "$now_e" -ge "$exp_e" ]; then echo "EXPIRED"
  else echo "fresh"; fi
}

cmd_status() {
  local any=0
  printf '%-44s %-10s %-22s %s\n' "NOTE" "STATE" "EXPIRES (UTC)" "KIND"
  printf '%.0s-' {1..96}; echo
  while IFS= read -r f; do
    any=1
    printf '%-44s %-10s %-22s %s\n' \
      "$(basename "$f")" "$(state_of "$f")" "$(fm "$f" expires_utc)" "$(fm "$f" kind)"
  done < <(notes)
  [ "$any" -eq 0 ] && echo "(no notes)"
  return 0
}

cmd_expired() {
  while IFS= read -r f; do
    [ "$(state_of "$f")" = "EXPIRED" ] && basename "$f" .md
  done < <(notes)
  return 0
}

cmd_purge() {
  local n=0
  while IFS= read -r f; do
    if [ "$(state_of "$f")" = "EXPIRED" ]; then
      echo "DELETING expired note: $(basename "$f")  (regenerate it from its sources)"
      rm -f "$f"; n=$((n+1))
    fi
  done < <(notes)
  echo "purged: $n"
}

cmd_new() {
  local slug="${1:?usage: knowledge.sh new <slug> \"<title>\"}" title="${2:-$1}"
  local out="$DIR/$slug.md"
  [ -e "$out" ] && { echo "refusing to overwrite existing note: $out" >&2; exit 1; }
  local now exp
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  exp="$(date -u -d "+$TTL_DAYS days" +%Y-%m-%dT%H:%M:%SZ)"
  sed -e "s|{{TITLE}}|$title|g" -e "s|{{NOW}}|$now|g" -e "s|{{EXPIRES}}|$exp|g" \
      -e "s|{{TTL}}|$TTL_DAYS|g" "$DIR/_TEMPLATE.md" > "$out"
  echo "created $out (expires $exp)"
}

case "${1:-status}" in
  status)  cmd_status ;;
  expired) cmd_expired ;;
  purge)   cmd_purge ;;
  new)     shift; cmd_new "$@" ;;
  *) echo "usage: knowledge.sh [status|expired|purge|new <slug> \"<title>\"]" >&2; exit 2 ;;
esac
