#!/bin/sh
#              - File: lib_action_ack.sh || version="0.02"                    #
# Generic correlated action acknowledgements for MerVLAN UI operations.

[ -n "${LIB_ACTION_ACK_LOADED:-}" ] && return 0 2>/dev/null

: "${MERV_BASE:=/jffs/addons/mervlan}"
: "${PUBLIC_MERV_BASE:=/www/user/mervlan}"
: "${ACTION_ACK_FILE:=${PUBLIC_MERV_BASE}/tmp/results/action_result.json}"

action_ack_sanitize_token() {
  printf '%s' "$1" | tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-'
}

action_ack_sanitize_action() {
  printf '%s' "$1" | tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-'
}

action_ack_json_escape() {
  # Add one transport newline for awk to consume.  Any newline already in the
  # value becomes a separate record and is emitted as the JSON escape "\\n";
  # this also preserves a trailing newline in the original shell value.
  printf '%s\n' "$1" | awk '
    BEGIN { ORS="" }
    {
      if (NR > 1) printf "\\n"
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\r/, "\\r")
      gsub(/\t/, "\\t")
      printf "%s", $0
    }
  '
}

# action_ack_write <token> <action> <status> <result-json> <message> <warnings-json> [error-code]
action_ack_write() {
  _aa_token=$(action_ack_sanitize_token "$1")
  _aa_action=$(action_ack_sanitize_action "$2")
  _aa_status="$3"
  _aa_result="$4"
  [ -n "$_aa_result" ] || _aa_result='{}'
  _aa_message="$5"
  _aa_warnings="$6"
  [ -n "$_aa_warnings" ] || _aa_warnings='[]'
  _aa_error_code="${7:-}"

  # Tokenless CLI and legacy calls remain compatible, but do not publish a
  # result that could be mistaken for a correlated browser request.
  [ -n "$_aa_token" ] || return 0
  [ -n "$_aa_action" ] || _aa_action="unknown"
  case "$_aa_status" in ok|partial|error) ;; *) _aa_status="error" ;; esac

  _aa_dir="${ACTION_ACK_FILE%/*}"
  mkdir -p "$_aa_dir" 2>/dev/null || return 1
  _aa_tmp="${ACTION_ACK_FILE}.tmp.$$"
  _aa_completed=$(date +%s 2>/dev/null || printf '0')
  case "$_aa_completed" in ''|*[!0-9]*) _aa_completed=0 ;; esac

  {
    printf '{"request_token":"%s","action":"%s","status":"%s","result":%s,"warnings":%s,"message":"%s","completed_at":%s' \
      "$(action_ack_json_escape "$_aa_token")" \
      "$(action_ack_json_escape "$_aa_action")" \
      "$_aa_status" "$_aa_result" "$_aa_warnings" \
      "$(action_ack_json_escape "$_aa_message")" "$_aa_completed"
    if [ -n "$_aa_error_code" ]; then
      printf ',"error_code":"%s"' "$(action_ack_json_escape "$_aa_error_code")"
    fi
    printf '}\n'
  } > "$_aa_tmp" 2>/dev/null || { rm -f "$_aa_tmp" 2>/dev/null; return 1; }

  chmod 644 "$_aa_tmp" 2>/dev/null || :
  mv -f "$_aa_tmp" "$ACTION_ACK_FILE" 2>/dev/null || {
    rm -f "$_aa_tmp" 2>/dev/null
    return 1
  }
  return 0
}

action_ack_ok() {
  _aa_wrapper_result="$3"
  _aa_wrapper_warnings="$5"
  [ -n "$_aa_wrapper_result" ] || _aa_wrapper_result='{}'
  [ -n "$_aa_wrapper_warnings" ] || _aa_wrapper_warnings='[]'
  action_ack_write "$1" "$2" ok "$_aa_wrapper_result" "$4" "$_aa_wrapper_warnings"
}

action_ack_partial() {
  _aa_wrapper_result="$3"
  _aa_wrapper_warnings="$5"
  [ -n "$_aa_wrapper_result" ] || _aa_wrapper_result='{}'
  [ -n "$_aa_wrapper_warnings" ] || _aa_wrapper_warnings='[]'
  action_ack_write "$1" "$2" partial "$_aa_wrapper_result" "$4" "$_aa_wrapper_warnings"
}

action_ack_error() {
  _aa_wrapper_result="$3"
  _aa_wrapper_warnings="$5"
  [ -n "$_aa_wrapper_result" ] || _aa_wrapper_result='{}'
  [ -n "$_aa_wrapper_warnings" ] || _aa_wrapper_warnings='[]'
  action_ack_write "$1" "$2" error "$_aa_wrapper_result" "$4" "$_aa_wrapper_warnings" "$6"
}

LIB_ACTION_ACK_LOADED=1
