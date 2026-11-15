#!/usr/bin/env bash
# Raise the Codex context window (model_context_window in config.toml).
# macOS / Linux / WSL / Git Bash. Needs only bash + awk (no jq, no python).
# Edits only the top-level `model_context_window` key in $CODEX_HOME/config.toml
# (default ~/.codex/config.toml) and backs the file up first as
# a field-level config.toml.ctxundo-* record. models_cache.json is only read.
set -euo pipefail

VALUE=1000000
MODEL=""
MODE=set
DRY=0

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

lock=""
tmp=""
cleanup() {
  [ -z "$tmp" ] || rm -f "$tmp" "$tmp.line"
  [ -z "$lock" ] || rmdir "$lock" 2>/dev/null || true
}
trap cleanup EXIT
if [ "$MODE" != status ] && [ "$DRY" = 0 ]; then
  mkdir -p "$CODEX_HOME"
  lock="$CODEX_HOME/config.toml.ctxlock"
  if ! mkdir "$lock" 2>/dev/null; then
    lock=""
    die "Another context operation is running (config.toml.ctxlock exists). If a previous run crashed, inspect it before removing the stale lock."
  fi
fi

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
# Refuse ambiguous keys rather than creating an undo record that cannot restore them.
if [ -f "$CFG" ]; then
  awk '
    /^[[:space:]]*\[/ { exit }
    /^[[:space:]]*model_context_window[[:space:]]*=/ {
      n++; v=$0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]*#.*$/, "", v); sub(/[[:space:]]*$/, "", v)
      if (v !~ /^[0-9]+(_[0-9]+)*$/) bad=1
    }
    END {exit (n>1 || bad)}' "$CFG" || die "Duplicate or unsupported context value; resolve it manually first."
fi
CURRENT="$(printf '%s' "$CURRENT" | tr -d '_[:space:]')"

# Undo records are separate from legacy whole-file backups. Never source metadata.
UNDO_PREFIX="config.toml.ctxundo-"
if [ "$MODE" = restore ]; then
  latest="$(find "$CODEX_HOME" -maxdepth 1 -type d -name "$UNDO_PREFIX*" 2>/dev/null | sort | tail -n 1 || true)"
  [ -n "$latest" ] || die "No safe undo record found. Legacy ctxbak files must be reviewed manually; restore only model_context_window, not the whole file."
  [ -f "$latest/before" ] && [ -f "$latest/applied" ] && [ -f "$latest/existed" ] || die "Incomplete undo record: $latest"
  expected="$(cat "$latest/applied")"
  existed="$(cat "$latest/existed")"
  case "$expected" in ''|*[!0-9]*) die "Invalid undo record" ;; esac
  case "$existed" in 0|1) ;; *) die "Invalid undo record" ;; esac
  [ "$CURRENT" = "$expected" ] || die "Conflict: model_context_window changed since installation. No files changed; review the current value and undo record."
  [ "$DRY" = 0 ] || { echo "[dry run] Would undo only model_context_window using $latest"; exit 0; }
  oldline="$(awk '/^[[:space:]]*\[/ {exit} /^[[:space:]]*model_context_window[[:space:]]*=/ {print; exit}' "$latest/before")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/codex-ctx.XXXXXX")"
  # Pass the original line through a file, not awk -v (which interprets escapes).
  printf '%s\n' "$oldline" > "$tmp.line"
  awk 'NR==FNR { old=$0; next }
       /^[[:space:]]*\[/ {sec=1}
       !sec && /^[[:space:]]*model_context_window[[:space:]]*=/ {if (old!="") print old; next}
       {print}' "$tmp.line" "$CFG" > "$tmp"
  if [ "$existed" = 0 ] && [ ! -s "$tmp" ]; then
    rm -f "$CFG"
  else
    cat "$tmp" > "$CFG"
  fi
  rm -f "$latest/before" "$latest/applied" "$latest/existed"
  rmdir "$latest"
  echo "Restored only model_context_window; other settings preserved."
  exit 0
fi

# Reinstalling the same value does not obscure the original undo state.
if [ "$CURRENT" = "$VALUE" ]; then
  echo "Already set to $VALUE; nothing changed."
  exit 0
fi

NEWLINE="model_context_window = $VALUE"
tmp="$(mktemp "${TMPDIR:-/tmp}/codex-ctx.XXXXXX")"

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
# Collision-free, sortable records, also understood by the PowerShell script.
stamp="$(date +%Y%m%d-%H%M%S)"
sequence=0
while :; do
  record="$CODEX_HOME/$UNDO_PREFIX$stamp-$(printf '%06d' "$sequence")"
  if (umask 077; mkdir "$record") 2>/dev/null; then break; fi
  sequence=$((sequence + 1))
  [ "$sequence" -lt 1000000 ] || die "Could not allocate undo record"
done
if [ -f "$CFG" ]; then
  cp -p "$CFG" "$record/before"
  printf '1\n' > "$record/existed"
else
  : > "$record/before"
  printf '0\n' > "$record/existed"
fi
printf '%s\n' "$VALUE" > "$record/applied"
cat "$tmp" > "$CFG"
backup="$record"

echo; echo "Done: $NEWLINE"
[ -n "$backup" ] && echo "Backup              : $backup"
echo "Usable after restart: $(fmt "$AFTER")"
if [ -n "$LIM_MAX" ] && [ "$VALUE" -gt "$LIM_MAX" ]; then
  echo "Note: Codex caps $MODEL at $(fmt "$LIM_MAX"), so the window stops there; the rest is reserved by Codex."
fi
echo "Next: quit Codex completely, reopen it and start a NEW conversation."
