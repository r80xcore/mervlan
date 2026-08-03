#!/bin/sh
#              - File: lib_action_ack.sh || version="0.02"                    #
# Generic correlated action acknowledgements for MerVLAN UI operations.

[ -n "${LIB_ACTION_ACK_LOADED:-}" ] && return 0 2>/dev/null

: "${MERV_BASE:=/jffs/addons/mervlan}"
: "${PUBLIC_MERV_BASE:=/www/user/mervlan}"
: "${ACTION_ACK_FILE:=${PUBLIC_MERV_BASE}/tmp/results/action_result.json}"
: "${MERV_STATE_ROOT:=/jffs/addons/mervlan_state}"
: "${ACTION_ACK_INTERNAL_FILE:=$MERV_STATE_ROOT/action_ack.latest.json}"
: "${ACTION_ACK_DIR:=${PUBLIC_MERV_BASE}/tmp/results/actions}"
: "${ACTION_ACK_PENDING_DIR:=$MERV_STATE_ROOT/action_ack_pending}"

action_ack_sanitize_token() {
  printf '%s' "$1" | tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-'
}

action_ack_token_valid() {
  case "${1:-}" in
    ''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*) return 1 ;;
  esac
  [ "${#1}" -le 96 ] 2>/dev/null
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

# _action_ack_render <token> <action> <status> <result-json> <message> <warnings-json> [error-code]
_action_ack_render() {
  _aa_render_token="$1"
  _aa_render_action="$2"
  _aa_render_status="$3"
  _aa_render_result="$4"
  _aa_render_message="$5"
  _aa_render_warnings="$6"
  _aa_render_error_code="${7:-}"
  _aa_render_completed=$(date +%s 2>/dev/null || printf '0')
  case "$_aa_render_completed" in ''|*[!0-9]*) _aa_render_completed=0 ;; esac
  {
    printf '{"request_token":"%s","action":"%s","status":"%s","result":%s,"warnings":%s,"message":"%s","completed_at":%s' \
      "$(action_ack_json_escape "$_aa_render_token")" \
      "$(action_ack_json_escape "$_aa_render_action")" \
      "$_aa_render_status" "$_aa_render_result" "$_aa_render_warnings" \
      "$(action_ack_json_escape "$_aa_render_message")" "$_aa_render_completed"
    if [ -n "$_aa_render_error_code" ]; then
      printf ',"error_code":"%s"' "$(action_ack_json_escape "$_aa_render_error_code")"
    fi
    printf '}\n'
  }
}

_action_ack_atomic_copy() {
  _aa_source="$1"
  _aa_target="$2"
  _aa_mode="${3:-644}"
  _aa_parent="${_aa_target%/*}"
  _aa_seq="${ACTION_ACK_WRITE_SEQ:-0}"
  ACTION_ACK_WRITE_SEQ=$(( _aa_seq + 1 ))
  export ACTION_ACK_WRITE_SEQ
  _aa_tmp="${_aa_target}.tmp.$$.$ACTION_ACK_WRITE_SEQ"
  mkdir -p "$_aa_parent" 2>/dev/null || return 1
  ( umask 077; cp "$_aa_source" "$_aa_tmp" ) 2>/dev/null || {
    rm -f "$_aa_tmp" 2>/dev/null
    return 1
  }
  chmod "$_aa_mode" "$_aa_tmp" 2>/dev/null || {
    rm -f "$_aa_tmp" 2>/dev/null
    return 1
  }
  mv -f "$_aa_tmp" "$_aa_target" 2>/dev/null || {
    rm -f "$_aa_tmp" 2>/dev/null
    return 1
  }
  return 0
}

_action_ack_prune() {
  [ -d "$ACTION_ACK_DIR" ] || return 0
  _aa_keep=64
  _aa_count=0
  # Token names are restricted to shell-safe characters, so word splitting of
  # this controlled glob is safe on BusyBox ash. Keep this deliberately
  # conservative: failure to list or remove a result never blocks publication.
  for _aa_file in $(ls -1t "$ACTION_ACK_DIR"/*.json 2>/dev/null); do
    [ -f "$_aa_file" ] || continue
    _aa_count=$((_aa_count + 1))
    [ "$_aa_count" -le "$_aa_keep" ] && continue
    _aa_base=${_aa_file##*/}
    case "$_aa_base" in
      ''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*|*.json.json) continue ;;
    esac
    rm -f "$_aa_file" 2>/dev/null || :
  done
  return 0
}

_action_ack_publish_json() {
  _aa_source="$1"
  _aa_token="$2"
  [ -f "$_aa_source" ] || return 1
  action_ack_token_valid "$_aa_token" || return 2
  mkdir -p "$ACTION_ACK_DIR" "${ACTION_ACK_FILE%/*}" "${ACTION_ACK_INTERNAL_FILE%/*}" 2>/dev/null || return 1
  _action_ack_atomic_copy "$_aa_source" "$ACTION_ACK_DIR/${_aa_token}.json" 644 || return 1
  _action_ack_atomic_copy "$_aa_source" "$ACTION_ACK_FILE" 644 || return 1
  _action_ack_atomic_copy "$_aa_source" "$ACTION_ACK_INTERNAL_FILE" 600 || return 1
  _action_ack_prune
  MERV_ACTION_ACK_PUBLISHED=1
  return 0
}

# action_ack_write <token> <action> <status> <result-json> <message> <warnings-json> [error-code]
action_ack_write() {
  _aa_token="$1"
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
  action_ack_token_valid "$_aa_token" || return 2
  [ -n "$_aa_action" ] || _aa_action="unknown"
  case "$_aa_status" in ok|partial|busy|ssh_trust_required|ssh_trust_pending|expired|error) ;; *) return 2 ;; esac
  case "$_aa_result" in \{*\}|\[*\]) ;; *) return 2 ;; esac
  case "$_aa_warnings" in \[*\]) ;; *) return 2 ;; esac

  mkdir -p "$MERV_STATE_ROOT/action_ack_tmp" 2>/dev/null || return 1
  _aa_tmp="$MERV_STATE_ROOT/action_ack_tmp/ack.$$.$(date +%s 2>/dev/null || printf '0')"
  _action_ack_render "$_aa_token" "$_aa_action" "$_aa_status" "$_aa_result" "$_aa_message" "$_aa_warnings" "$_aa_error_code" > "$_aa_tmp" 2>/dev/null || {
    rm -f "$_aa_tmp" 2>/dev/null
    return 1
  }
  _action_ack_publish_json "$_aa_tmp" "$_aa_token"
  _aa_publish_rc=$?
  rm -f "$_aa_tmp" 2>/dev/null
  return "$_aa_publish_rc"
}

# Stage a Save result privately. The service-event dispatcher publishes it only
# after it has released the event/global locks, so a terminal Save ack cannot
# invite the browser to start a follow-up while the previous owner remains.
action_ack_stage_write() {
  _aa_token="$1"
  _aa_action=$(action_ack_sanitize_action "$2")
  _aa_status="$3"
  _aa_result="$4"; [ -n "$_aa_result" ] || _aa_result='{}'
  _aa_message="$5"
  _aa_warnings="$6"; [ -n "$_aa_warnings" ] || _aa_warnings='[]'
  _aa_error_code="${7:-}"
  [ -n "$_aa_token" ] || return 0
  action_ack_token_valid "$_aa_token" || return 2
  case "$_aa_status" in ok|partial|busy|ssh_trust_required|ssh_trust_pending|expired|error) ;; *) return 2 ;; esac
  case "$_aa_result" in \{*\}|\[*\]) ;; *) return 2 ;; esac
  case "$_aa_warnings" in \[*\]) ;; *) return 2 ;; esac
  mkdir -p "$ACTION_ACK_PENDING_DIR" 2>/dev/null || return 1
  _aa_stage_tmp="$ACTION_ACK_PENDING_DIR/.${_aa_token}.tmp.$$.$(date +%s 2>/dev/null || printf '0')"
  _aa_stage_file="$ACTION_ACK_PENDING_DIR/${_aa_token}.json"
  ( umask 077; _action_ack_render "$_aa_token" "$_aa_action" "$_aa_status" "$_aa_result" "$_aa_message" "$_aa_warnings" "$_aa_error_code" > "$_aa_stage_tmp" ) 2>/dev/null || {
    rm -f "$_aa_stage_tmp" 2>/dev/null
    return 1
  }
  chmod 600 "$_aa_stage_tmp" 2>/dev/null || { rm -f "$_aa_stage_tmp" 2>/dev/null; return 1; }
  mv -f "$_aa_stage_tmp" "$_aa_stage_file" 2>/dev/null || { rm -f "$_aa_stage_tmp" 2>/dev/null; return 1; }
  MERV_ACTION_ACK_STAGED=1
  return 0
}

action_ack_stage_ok() {
  _aa_wrapper_result="$3"; _aa_wrapper_warnings="$5"
  [ -n "$_aa_wrapper_result" ] || _aa_wrapper_result='{}'
  [ -n "$_aa_wrapper_warnings" ] || _aa_wrapper_warnings='[]'
  action_ack_stage_write "$1" "$2" ok "$_aa_wrapper_result" "$4" "$_aa_wrapper_warnings"
}

action_ack_stage_partial() {
  _aa_wrapper_result="$3"; _aa_wrapper_warnings="$5"
  [ -n "$_aa_wrapper_result" ] || _aa_wrapper_result='{}'
  [ -n "$_aa_wrapper_warnings" ] || _aa_wrapper_warnings='[]'
  action_ack_stage_write "$1" "$2" partial "$_aa_wrapper_result" "$4" "$_aa_wrapper_warnings"
}

action_ack_stage_error() {
  _aa_wrapper_result="$3"; _aa_wrapper_warnings="$5"
  [ -n "$_aa_wrapper_result" ] || _aa_wrapper_result='{}'
  [ -n "$_aa_wrapper_warnings" ] || _aa_wrapper_warnings='[]'
  action_ack_stage_write "$1" "$2" error "$_aa_wrapper_result" "$4" "$_aa_wrapper_warnings" "$6"
}

action_ack_publish_staged() {
  _aa_token="$1"
  action_ack_token_valid "$_aa_token" || return 2
  _aa_stage_file="$ACTION_ACK_PENDING_DIR/${_aa_token}.json"
  [ -f "$_aa_stage_file" ] || return 3
  _action_ack_publish_json "$_aa_stage_file" "$_aa_token"
  _aa_publish_rc=$?
  [ "$_aa_publish_rc" -eq 0 ] && rm -f "$_aa_stage_file" 2>/dev/null
  return "$_aa_publish_rc"
}

action_ack_discard_staged() {
  _aa_token="$1"
  action_ack_token_valid "$_aa_token" || return 2
  rm -f "$ACTION_ACK_PENDING_DIR/${_aa_token}.json" 2>/dev/null
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

action_ack_busy() {
  _aa_wrapper_result="${3-}"; _aa_wrapper_warnings="${5-}"
  [ -n "$_aa_wrapper_result" ] || _aa_wrapper_result='{}'
  [ -n "$_aa_wrapper_warnings" ] || _aa_wrapper_warnings='[]'
  action_ack_write "$1" "$2" busy "$_aa_wrapper_result" "${4:-Another action is already running.}" "$_aa_wrapper_warnings" busy
}

action_ack_ssh_trust_required() {
  _aa_wrapper_result="${3-}"; _aa_wrapper_warnings="${5-}"
  [ -n "$_aa_wrapper_result" ] || _aa_wrapper_result='{}'
  [ -n "$_aa_wrapper_warnings" ] || _aa_wrapper_warnings='[]'
  action_ack_write "$1" "$2" ssh_trust_required "$_aa_wrapper_result" "${4:-SSH host-key verification is required before node changes.}" "$_aa_wrapper_warnings" ssh-trust-required
}

LIB_ACTION_ACK_LOADED=1
