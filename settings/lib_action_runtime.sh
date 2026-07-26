#!/bin/sh
#
# ============================================================================ #
# MerVLAN shared action-runtime marker                                        #
# ============================================================================ #
#
# Publishes the small piece of transient state that the HTML needs to know
# whether a configuration apply is currently running. This is separate from
# the user-facing progress token because boot/event applies have no browser
# token but still need to block redundant client refreshes.
#
[ -n "${LIB_ACTION_RUNTIME_LOADED:-}" ] && return 0 2>/dev/null
LIB_ACTION_RUNTIME_LOADED=1

: "${PUBLIC_MERV_BASE:=/www/user/mervlan}"
: "${MERV_ACTION_RUNTIME_FILE:=$PUBLIC_MERV_BASE/tmp/results/vlan_action_status.json}"
MERV_ACTION_RUNTIME_OWNED=0

merv_action_runtime_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

merv_action_runtime_start() {
  _marr_action="$1"
  _marr_label="$2"
  _marr_message="$3"
  [ -n "$_marr_action" ] || return 1

  _marr_dir=${MERV_ACTION_RUNTIME_FILE%/*}
  mkdir -p "$_marr_dir" 2>/dev/null || return 1

  # Do not replace a live parent marker. This matters when the full
  # router+nodes wrapper starts its local manager as a child process.
  if [ -f "$MERV_ACTION_RUNTIME_FILE" ]; then
    _marr_pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
      "$MERV_ACTION_RUNTIME_FILE" 2>/dev/null | head -n 1)
    if [ -n "$_marr_pid" ] && kill -0 "$_marr_pid" 2>/dev/null; then
      return 1
    fi
    rm -f "$MERV_ACTION_RUNTIME_FILE" 2>/dev/null || return 1
  fi

  _marr_now=$(date +%s 2>/dev/null || printf '0')
  _marr_label_json=$(merv_action_runtime_escape "$_marr_label")
  _marr_message_json=$(merv_action_runtime_escape "$_marr_message")
  _marr_tmp="${MERV_ACTION_RUNTIME_FILE}.tmp.$$"
  printf '{"state":"running","action":"%s","label":"%s","message":"%s","pid":%s,"started":%s}\n' \
    "$_marr_action" "$_marr_label_json" "$_marr_message_json" "$$" "$_marr_now" \
    > "$_marr_tmp" 2>/dev/null || {
      rm -f "$_marr_tmp" 2>/dev/null || :
      return 1
    }
  mv "$_marr_tmp" "$MERV_ACTION_RUNTIME_FILE" 2>/dev/null || {
    rm -f "$_marr_tmp" 2>/dev/null || :
    return 1
  }
  MERV_ACTION_RUNTIME_OWNED=1
  return 0
}

merv_action_runtime_finish() {
  [ "${MERV_ACTION_RUNTIME_OWNED:-0}" -eq 1 ] || return 0
  # Only remove a marker owned by this process. A newer operation must never
  # be hidden by an older cleanup trap.
  _marr_owner=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    "$MERV_ACTION_RUNTIME_FILE" 2>/dev/null | head -n 1)
  if [ "$_marr_owner" = "$$" ]; then
    rm -f "$MERV_ACTION_RUNTIME_FILE" 2>/dev/null || :
  fi
  MERV_ACTION_RUNTIME_OWNED=0
}
