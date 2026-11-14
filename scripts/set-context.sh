#!/usr/bin/env bash
# Raise the Codex context window (model_context_window in config.toml).
# macOS / Linux / WSL / Git Bash. Needs only bash + awk (no jq, no python).
# Edits only the top-level `model_context_window` key in $CODEX_HOME/config.toml
# (default ~/.codex/config.toml) and backs the file up first as
# config.toml.ctxbak-<timestamp>. models_cache.json is only read.
set -euo pipefail

VALUE=1000000
MODEL=""
MODE=set
DRY=0
PREFIX="config.toml.ctxbak-"

usage() {
  cat <<'EOF'
Usage: set-context.sh [--status] [--value N] [--model SLUG] [--dry-run] [--restore]

  --status      show current settings and limits, change nothing
  --value N     context window to write (default 1000000)
  --model SLUG  model to look up limits for (default: `model` in config.toml)
  --dry-run     show what would change, write nothing
  --restore     undo the most recent change made by this script
EOF
}

die() { echo "Error: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --value)   [ $# -ge 2 ] || die "--value needs a number"; VALUE="$2"; shift 2 ;;
    --model)   [ $# -ge 2 ] || die "--model needs a name"; MODEL="$2"; shift 2 ;;
    --status)  MODE=status; shift ;;
    --restore) MODE=restore; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
case "$VALUE" in ''|*[!0-9]*) die "--value must be a whole number, got '$VALUE'" ;; esac
[ "$VALUE" -ge 1000 ] || die "--value is too small: $VALUE"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CFG="$CODEX_HOME/config.toml"
CACHE="$CODEX_HOME/models_cache.json"

# Value of a key that sits before the first [section] header.
toplevel_get() {
  [ -f "$CFG" ] || return 0
  awk -v k="$1" '
    { sub(/\r$/, "") }
    /^[[:space:]]*\[/ { exit }
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/["\047]/, ""); print; exit
    }' "$CFG"
}

# Prints "default max percent" from the cached model list (blank if unknown).
model_limits() {
  [ -f "$CACHE" ] && [ -n "$1" ] || { echo ""; return 0; }
  awk -v m="$1" '
    /"slug"[[:space:]]*:/ {
      if (found) exit
      v = $0; sub(/.*"slug"[[:space:]]*:[[:space:]]*"/, "", v); sub(/".*/, "", v)
      if (v == m) found = 1
      next
    }
    found && cw == "" && /"context_window"[[:space:]]*:/ { v = $0; gsub(/[^0-9]/, "", v); cw = v }
    found && mx == "" && /"max_context_window"[[:space:]]*:/ { v = $0; gsub(/[^0-9]/, "", v); mx = v }
    found && pc == "" && /"effective_context_window_percent"[[:space:]]*:/ { v = $0; gsub(/[^0-9]/, "", v); pc = v }
    END { if (found) print cw " " mx " " pc }' "$CACHE"
}

fmt() { if [ -z "${1:-}" ]; then echo "unknown"; else echo "$1 (~$(( ($1 + 500) / 1000 ))K)"; fi; }

effective() { # $1 = setting (may be blank)
  local w="${1:-}"
  [ -n "$LIM_MAX$LIM_DEF" ] || { echo ""; return; }
  [ -n "$w" ] || w="$LIM_DEF"
  [ -n "$w" ] || { echo ""; return; }
  if [ -n "$LIM_MAX" ] && [ "$w" -gt "$LIM_MAX" ]; then w="$LIM_MAX"; fi
  echo $(( w * ${LIM_PCT:-100} / 100 ))
}

[ -n "$MODEL" ] || MODEL="$(toplevel_get model)"
read -r LIM_DEF LIM_MAX LIM_PCT <<<"$(model_limits "$MODEL") " || true
CURRENT="$(toplevel_get model_context_window)"

echo "Codex home          : $CODEX_HOME"
echo "Config file         : $CFG$([ -f "$CFG" ] || echo ' (does not exist yet)')"
echo "Model               : ${MODEL:-not set in config (Codex default)}"
echo "model_context_window: ${CURRENT:-not set}"
if [ -n "$LIM_DEF$LIM_MAX" ]; then
  echo "Cached limits       : default $(fmt "$LIM_DEF"), max $(fmt "$LIM_MAX"), usable ${LIM_PCT:-100}%"
  echo "Usable right now    : $(fmt "$(effective "$CURRENT")")"
else
  echo "Cached limits       : not found (open Codex once so it downloads models_cache.json, or pass --model)"
fi

[ "$MODE" = status ] && exit 0

if [ "$MODE" = restore ]; then
  latest="$(ls -1 "$CODEX_HOME"/"$PREFIX"* 2>/dev/null | sort | tail -n 1 || true)"
  if [ -z "$latest" ]; then echo; echo "No backup ($PREFIX*) found in $CODEX_HOME. Nothing to restore."; exit 1; fi
  if [ "$DRY" = 1 ]; then echo; echo "[dry run] Would restore $latest"; exit 0; fi
  cat "$latest" > "$CFG"
  rm -f "$latest"
  echo; echo "Restored config.toml from $(basename "$latest")."
  echo "Quit Codex completely and reopen it for this to take effect."
  exit 0
fi

NEWLINE="model_context_window = $VALUE"
tmp="$(mktemp "${TMPDIR:-/tmp}/codex-ctx.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

if [ -s "$CFG" ]; then
  # Drop top-level model_context_window lines; insert the new one after `model =`.
  rc=0
  awk -v line="$NEWLINE" '
    !sec && /^[[:space:]]*\[/ { sec = 1 }
    !sec && /^[[:space:]]*model_context_window[[:space:]]*=/ { next }
    { print }
    !sec && !ins && /^[[:space:]]*model[[:space:]]*=/ { cr = ($0 ~ /\r$/) ? "\r" : ""; print line cr; ins = 1 }
    END { if (!ins) exit 3 }' "$CFG" > "$tmp" || rc=$?
  if [ "$rc" = 3 ]; then
    # No top-level `model =` line: put the setting at the very top.
    { printf '%s\n' "$NEWLINE"
      awk '/^[[:space:]]*\[/ { sec = 1 }
           !sec && /^[[:space:]]*model_context_window[[:space:]]*=/ { next }
           { print }' "$CFG"; } > "$tmp"
  elif [ "$rc" != 0 ]; then
    die "could not edit $CFG"
  fi
else
  printf '%s\n' "$NEWLINE" > "$tmp"
fi

AFTER="$(effective "$VALUE")"
if [ "$DRY" = 1 ]; then
  echo; echo "[dry run] Would write: $NEWLINE"
  echo "[dry run] Usable after restart: $(fmt "$AFTER")"
  exit 0
fi

mkdir -p "$CODEX_HOME"
backup=""
if [ -f "$CFG" ]; then
  backup="$CODEX_HOME/$PREFIX$(date +%Y%m%d-%H%M%S)"
  cp -p "$CFG" "$backup"
fi
cat "$tmp" > "$CFG"

echo; echo "Done: $NEWLINE"
[ -n "$backup" ] && echo "Backup              : $backup"
echo "Usable after restart: $(fmt "$AFTER")"
if [ -n "$LIM_MAX" ] && [ "$VALUE" -gt "$LIM_MAX" ]; then
  echo "Note: Codex caps $MODEL at $(fmt "$LIM_MAX"), so the window stops there; the rest is reserved by Codex."
fi
echo "Next: quit Codex completely, reopen it and start a NEW conversation."
