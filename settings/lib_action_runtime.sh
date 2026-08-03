#!/bin/sh
# MerVLAN shared action-runtime marker.
# The marker is transient, but its ownership is durable for the lifetime of
# the process: PID, /proc start time, and a per-acquisition nonce must all
# match before a writer may replace, update, or remove it.

[ -n "${LIB_ACTION_RUNTIME_LOADED:-}" ] && return 0 2>/dev/null
LIB_ACTION_RUNTIME_LOADED=1

: "${MERV_BASE:=/jffs/addons/mervlan}"
: "${PUBLIC_MERV_BASE:=/www/user/mervlan}"
: "${MERV_ACTION_RUNTIME_FILE:=$PUBLIC_MERV_BASE/tmp/results/vlan_action_status.json}"
MERV_ACTION_RUNTIME_OWNED=0

if [ -z "${LIB_IDENTITY_LOADED:-}" ] && [ -f "$MERV_BASE/settings/lib_identity.sh" ]; then
  . "$MERV_BASE/settings/lib_identity.sh" 2>/dev/null || return 1 2>/dev/null || exit 1
fi

merv_action_runtime_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

_marr_owner_fields() {
  _marr_file="$1"
  MERV_ACTION_RUNTIME_FILE_PID=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_marr_file" 2>/dev/null | head -n 1)
  MERV_ACTION_RUNTIME_FILE_START=$(sed -n 's/.*"owner_start"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_marr_file" 2>/dev/null | head -n 1)
  MERV_ACTION_RUNTIME_FILE_NONCE=$(sed -n 's/.*"owner_nonce"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9._:-]*\)".*/\1/p' "$_marr_file" 2>/dev/null | head -n 1)
  [ -n "$MERV_ACTION_RUNTIME_FILE_PID" ] && [ -n "$MERV_ACTION_RUNTIME_FILE_START" ] &&
    [ -n "$MERV_ACTION_RUNTIME_FILE_NONCE" ]
}

merv_action_runtime_start() {
  _marr_action="$1"
  _marr_label="$2"
  _marr_message="$3"
  [ -n "$_marr_action" ] || return 1

  _marr_dir=${MERV_ACTION_RUNTIME_FILE%/*}
  mkdir -p "$_marr_dir" 2>/dev/null || return 1
  _marr_start=$(merv_identity_current_start 2>/dev/null || printf '')
  [ -n "$_marr_start" ] || return 1
  _marr_nonce=$(merv_identity_nonce 2>/dev/null || printf '')
  [ -n "$_marr_nonce" ] || return 1

  if [ -f "$MERV_ACTION_RUNTIME_FILE" ]; then
    _marr_owner_fields "$MERV_ACTION_RUNTIME_FILE" || return 1
    if merv_identity_matches "$MERV_ACTION_RUNTIME_FILE_PID" "$MERV_ACTION_RUNTIME_FILE_START" 2>/dev/null; then
      return 1
    fi
    # A structurally valid, dead/reused owner can be retired.  Malformed
    # markers remain visible for recovery instead of being guessed free.
    rm -f "$MERV_ACTION_RUNTIME_FILE" 2>/dev/null || return 1
  fi

  _marr_now=$(date +%s 2>/dev/null || printf '0')
  _marr_label_json=$(merv_action_runtime_escape "$_marr_label")
  _marr_message_json=$(merv_action_runtime_escape "$_marr_message")
  _marr_tmp="${MERV_ACTION_RUNTIME_FILE}.tmp.$$"
  ( umask 077
    printf '{"format_version":2,"state":"running","action":"%s","label":"%s","message":"%s","pid":%s,"owner_start":%s,"owner_nonce":"%s","started":%s,"heartbeat":%s}\n' \
      "$_marr_action" "$_marr_label_json" "$_marr_message_json" "$$" "$_marr_start" "$_marr_nonce" "$_marr_now" "$_marr_now" > "$_marr_tmp"
  ) 2>/dev/null || { rm -f "$_marr_tmp" 2>/dev/null; return 1; }
  chmod 600 "$_marr_tmp" 2>/dev/null || { rm -f "$_marr_tmp" 2>/dev/null; return 1; }
  mv -f "$_marr_tmp" "$MERV_ACTION_RUNTIME_FILE" 2>/dev/null || { rm -f "$_marr_tmp" 2>/dev/null; return 1; }
  MERV_ACTION_RUNTIME_OWNED=1
  MERV_ACTION_RUNTIME_NONCE="$_marr_nonce"
  MERV_ACTION_RUNTIME_START="$_marr_start"
  return 0
}

merv_action_runtime_heartbeat() {
  [ "${MERV_ACTION_RUNTIME_OWNED:-0}" -eq 1 ] || return 1
  [ -f "$MERV_ACTION_RUNTIME_FILE" ] || return 1
  _marr_owner_fields "$MERV_ACTION_RUNTIME_FILE" || return 1
  [ "$MERV_ACTION_RUNTIME_FILE_PID" = "$$" ] &&
    [ "$MERV_ACTION_RUNTIME_FILE_START" = "${MERV_ACTION_RUNTIME_START:-}" ] &&
    [ "$MERV_ACTION_RUNTIME_FILE_NONCE" = "${MERV_ACTION_RUNTIME_NONCE:-}" ] || return 1
  merv_identity_matches "$$" "${MERV_ACTION_RUNTIME_START:-}" 2>/dev/null || return 1
  _marr_now=$(date +%s 2>/dev/null || printf '0')
  _marr_tmp="${MERV_ACTION_RUNTIME_FILE}.tmp.$$"
  sed "s/\"heartbeat\"[[:space:]]*:[[:space:]]*[0-9][0-9]*/\"heartbeat\":$_marr_now/" \
    "$MERV_ACTION_RUNTIME_FILE" > "$_marr_tmp" 2>/dev/null || { rm -f "$_marr_tmp" 2>/dev/null; return 1; }
  chmod 600 "$_marr_tmp" 2>/dev/null || { rm -f "$_marr_tmp" 2>/dev/null; return 1; }
  mv -f "$_marr_tmp" "$MERV_ACTION_RUNTIME_FILE" 2>/dev/null
}

merv_action_runtime_finish() {
  [ "${MERV_ACTION_RUNTIME_OWNED:-0}" -eq 1 ] || return 0
  _marr_owner_fields "$MERV_ACTION_RUNTIME_FILE" || { MERV_ACTION_RUNTIME_OWNED=0; return 1; }
  if [ "$MERV_ACTION_RUNTIME_FILE_PID" = "$$" ] &&
     [ "$MERV_ACTION_RUNTIME_FILE_START" = "${MERV_ACTION_RUNTIME_START:-}" ] &&
     [ "$MERV_ACTION_RUNTIME_FILE_NONCE" = "${MERV_ACTION_RUNTIME_NONCE:-}" ]; then
    merv_identity_matches "$$" "${MERV_ACTION_RUNTIME_START:-}" 2>/dev/null || {
      MERV_ACTION_RUNTIME_OWNED=0
      return 1
    }
    rm -f "$MERV_ACTION_RUNTIME_FILE" 2>/dev/null || return 1
    MERV_ACTION_RUNTIME_OWNED=0
    return 0
  fi
  MERV_ACTION_RUNTIME_OWNED=0
  return 1
}
