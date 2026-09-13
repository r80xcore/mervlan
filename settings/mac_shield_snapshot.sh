#!/bin/sh
# ============================================================================ #
#                                                                              #
#   /$$      /$$                     /$$    /$$ /$$        /$$$$$$  /$$   /$$  #
#  | $$$    /$$$                    | $$   | $$| $$       /$$__  $$| $$$ | $$  #
#  | $$$$  /$$$$  /$$$$$$   /$$$$$$ | $$   | $$| $$      | $$  \ $$| $$$$| $$  #
#  | $$ $$/$$ $$ /$$__  $$ /$$__  $$|  $$ / $$/| $$      | $$$$$$$$| $$ $$ $$  #
#  | $$  $$$| $$| $$$$$$$$| $$  \__/ \  $$ $$/ | $$      | $$__  $$| $$  $$$$  #
#  | $$\  $ | $$| $$_____/| $$        \  $$$/  | $$      | $$  | $$| $$\  $$$  #
#  | $$ \/  | $$|  $$$$$$$| $$         \  $/   | $$$$$$$$| $$  | $$| $$ \  $$  #
#  |__/     |__/ \_______/|__/          \_/    |________/|__/  |__/|__/  \__/  #
#                                                                              #
# ============================================================================ #
#               - File: mac_shield_snapshot.sh || version="0.37"                #
# ============================================================================ #
# Purpose: MERV_MAC persistent db management.
#   Builds a post-apply snapshot of known client MAC→iface→VID state,
#   merges into a persistent db (latest-per-MAC semantics), and checkpoints
#   to JFFS only when content changes.
#
# Load contract (in callers):
#   [ -n "${LIB_MAC_SHIELD_SNAPSHOT_LOADED:-}" ] || \
#     . "$MERV_BASE/settings/mac_shield_snapshot.sh"
#
# Dependencies:
#   lib_mervqt.sh          — ebt_mac_shield_* functions, mervqt_valid_* validators,
#                            mervqt_mac_lower, merv_mac_best_db
#   lib_ssid_filter.sh     — get_ssid_slot_value, get_vlan_slot_value
#   lib_ssh.sh             — merv_ssh_exec, merv_ssh_precheck, ssh_keys_effectively_installed,
#                            _merv_timeout_run, merv_has, MERV_SSH_TIMEOUT
#   lib_node_jobs.sh       — bounded 1–5 node pool and validated terminal results
#   var_settings.sh        — MERV_MAC_DB_ACTIVE, MERV_MAC_DB_JFFS,
#                            MERV_MAC_MAX_AGE_SEC, SETTINGS_FILE, MAX_SSIDS
#   log_settings.sh        — info, warn
#
# Subinterface scope (this version):
#   merv_mac_build_expected_iface_vid resolves wl*.* (Broadcom) only.
#   ra*.* and ath*.* support requires separate NVRAM key extension and is
#   deferred. Validators in lib_mervqt.sh already accept those prefixes in
#   db/rule handling for forward compatibility.
# ============================================================================ #
if [ -n "${LIB_MAC_SHIELD_SNAPSHOT_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

: "${MERV_BASE:=/jffs/addons/mervlan}"
[ -n "${LIB_OWNER_LOCK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_owner_lock.sh" 2>/dev/null || true
[ -n "${LIB_SSH_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh.sh"
# The shared bounded node pool is the only parallelism boundary for remote
# observation and Shield propagation.  Keep this optional at source time so
# older fixture callers can still load the library; the MAIN path below fails
# closed (as an incomplete observation/push) when the pool is unavailable.
[ -n "${LIB_NODE_JOBS_LOADED:-}" ] || . "$MERV_BASE/settings/lib_node_jobs.sh" 2>/dev/null || true

# ============================================================================
# Snapshot behaviour flags (caller-overridable via env)
# ----------------------------------------------------------------------------
# Back-compat: MAC_SHIELD_VERBOSE was the prior verbose knob; honor it as the
# fallback default so existing callers that set it keep verbose behaviour.
# ============================================================================
: "${MERV_MAC_SNAPSHOT_VERBOSE:=${MAC_SHIELD_VERBOSE:-0}}"
: "${MERV_MAC_SNAPSHOT_LOG_CHANNELS:=vlan}"
: "${MERV_MAC_SNAPSHOT_LOG_UNCHANGED:=0}"
: "${MERV_MAC_SNAPSHOT_RESET:=0}"
: "${MERV_MAC_SNAPSHOT_FORCE_RELOAD:=0}"
: "${MERV_MAC_SNAPSHOT_ALLOW_EMPTY:=0}"
: "${MERV_NVRAM_READ_TIMEOUT:=10}"

# ============================================================================
# Bounded NVRAM inventory
# ----------------------------------------------------------------------------
# A number of manager and Shield paths need the same small subset of NVRAM
# state.  Reading that subset through separate `nvram get`/`nvram show`
# invocations makes a firmware-side NVRAM stall multiply across every guard
# tick.  Keep one validated inventory per process scope instead.  The cache is
# deliberately file-backed: POSIX command substitutions run functions in a
# child shell, so an in-memory cache assignment made there cannot be observed
# by the parent or by the next guard tick.
#
# The cache contains only validated wl*_ssid/wl*_ifname records and an
# explicit valid/error state.  A successful empty inventory is therefore
# distinguishable from a failed read, and a failed read is memoized for the
# current process so a guard loop never retries a hanging NVRAM command.
# ============================================================================

# Clear process-visible inventory state before an identity or cache-path
# validation failure can leave a previous successful snapshot looking current.
# This only resets shell variables; cache artifacts are removed only by the
# explicit invalidate/disable paths after their root has passed validation.
merv_nvram_inventory_clear_state() {
  MERV_NVRAM_INVENTORY_FILE=""
  MERV_NVRAM_INVENTORY_STATUS=""
  MERV_NVRAM_INVENTORY_REASON=""
  MERV_NVRAM_INVENTORY_RC=""
}

merv_nvram_inventory_set_error() {
  MERV_NVRAM_INVENTORY_FILE=""
  MERV_NVRAM_INVENTORY_STATUS=error
  MERV_NVRAM_INVENTORY_REASON="${1:-read-failed}"
  MERV_NVRAM_INVENTORY_RC="${2:-65}"
  return 2
}

# The inventory file is intentionally narrower than the complete NVRAM key
# grammar.  Keep this check exact; a shell glob such as wl[0-9]* also accepts
# wl0garbage_ssid and would let an unrelated key reach manager callers.
merv_nvram_inventory_target_key_valid() {
  local _mnitk_key="${1:-}" _mnitk_base _mnitk_digits
  local _mnitk_radio _mnitk_slot
  case "$_mnitk_key" in
    wl*_ssid) _mnitk_base=${_mnitk_key%_ssid} ;;
    wl*_ifname) _mnitk_base=${_mnitk_key%_ifname} ;;
    *) return 1 ;;
  esac
  case "$_mnitk_base" in
    wl[0-9]*) ;;
    *) return 1 ;;
  esac
  _mnitk_digits=${_mnitk_base#wl}
  case "$_mnitk_digits" in
    *.*)
      _mnitk_radio=${_mnitk_digits%%.*}
      _mnitk_slot=${_mnitk_digits#*.}
      case "$_mnitk_radio" in ''|*[!0-9]*) return 1 ;; esac
      case "$_mnitk_slot" in ''|*[!0-9]*|*.*) return 1 ;; esac
      ;;
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

merv_nvram_inventory_artifacts_safe() {
  local _mnias_path="$1" _mnias_file
  for _mnias_file in "$_mnias_path.state" "$_mnias_path.data" \
    "$_mnias_path.raw" "$_mnias_path.filtered.tmp" "$_mnias_path.state.tmp"; do
    [ ! -L "$_mnias_file" ] || return 1
  done
  return 0
}

# Validate an already-filtered cache before accepting a cached success marker.
# This keeps a replacement/edited regular cache file from bypassing the same
# key, value, duplicate, record, byte, and control-character checks used for
# fresh nvram output.
merv_nvram_inventory_validate_records() {
  local _mnivr_file="$1" _mnivr_max_bytes _mnivr_max_records _mnivr_bytes
  local _mnivr_max_line _mnivr_max_value
  [ -n "$_mnivr_file" ] || return 1
  [ -f "$_mnivr_file" ] && [ ! -L "$_mnivr_file" ] || return 1
  merv_nvram_inventory_process_start "${_mnivr_file%/*}" >/dev/null 2>&1 || return 1
  _mnivr_max_bytes="${MERV_NVRAM_INVENTORY_MAX_SELECTED_BYTES:-32768}"
  case "$_mnivr_max_bytes" in ''|*[!0-9]*) _mnivr_max_bytes=32768 ;; esac
  [ "$_mnivr_max_bytes" -gt 0 ] 2>/dev/null || _mnivr_max_bytes=32768
  _mnivr_bytes=$(
    exec 3< "$_mnivr_file" 2>/dev/null || exit 1
    [ ! -L "$_mnivr_file" ] || { exec 3<&-; exit 1; }
    wc -c <&3
    exec 3<&-
  ) || return 1
  case "$_mnivr_bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_mnivr_bytes" -le "$_mnivr_max_bytes" ] 2>/dev/null || return 1
  _mnivr_max_records="${MERV_NVRAM_INVENTORY_MAX_SELECTED_RECORDS:-128}"
  case "$_mnivr_max_records" in ''|*[!0-9]*) _mnivr_max_records=128 ;; esac
  [ "$_mnivr_max_records" -gt 0 ] 2>/dev/null || _mnivr_max_records=128
  _mnivr_max_line="${MERV_NVRAM_INVENTORY_MAX_SELECTED_LINE_BYTES:-256}"
  case "$_mnivr_max_line" in ''|*[!0-9]*) _mnivr_max_line=256 ;; esac
  [ "$_mnivr_max_line" -gt 0 ] 2>/dev/null || _mnivr_max_line=256
  _mnivr_max_value="${MERV_NVRAM_INVENTORY_MAX_SELECTED_VALUE_BYTES:-128}"
  case "$_mnivr_max_value" in ''|*[!0-9]*) _mnivr_max_value=128 ;; esac
  [ "$_mnivr_max_value" -gt 0 ] 2>/dev/null || _mnivr_max_value=128
  (
    exec 3< "$_mnivr_file" 2>/dev/null || exit 1
    [ ! -L "$_mnivr_file" ] || { exec 3<&-; exit 1; }
    awk -v max_records="$_mnivr_max_records" \
      -v max_line="$_mnivr_max_line" -v max_value="$_mnivr_max_value" '
      {
        if (length($0) > max_line || length($0) > 1024 ||
            $0 ~ /^[[:space:]]*$/ || index($0, "=") == 0) {
          bad=1; next
        }
        eq=index($0, "=")
        key=substr($0, 1, eq-1)
        val=substr($0, eq+1)
        if (length(val) > max_value ||
            key !~ /^wl[0-9]+(\.[0-9]+)?_(ssid|ifname)$/ ||
            val ~ /[[:cntrl:]]/ || seen[key]++ || ++records > max_records) {
          bad=1; next
        }
        if (key ~ /_ifname$/) {
          clean=val
          sub(/^[[:space:]]+/, "", clean)
          sub(/[[:space:]]+$/, "", clean)
          if (clean ~ /^\".*\"$/)
            clean=substr(clean, 2, length(clean)-2)
          if (clean != "" && clean !~ /^[A-Za-z0-9_.:-]+$/)
            bad=1
        }
      }
      END { exit bad ? 65 : 0 }
    ' <&3
    _mnivr_rc=$?
    exec 3<&-
    exit "$_mnivr_rc"
  )
}

merv_nvram_inventory_process_start() {
  local _mnips_start _mnips_root _mnips_path _mnips_rest _mnips_part _mnips_stat
  if [ -n "${1:-}" ]; then
    _mnips_root="$1"
    case "$_mnips_root" in
      /tmp|/tmp/*) ;;
      *)
        MERV_NVRAM_INVENTORY_FILE=""
        MERV_NVRAM_INVENTORY_STATUS=""
        MERV_NVRAM_INVENTORY_REASON=""
        MERV_NVRAM_INVENTORY_RC=""
        return 1
        ;;
    esac
    [ -d /tmp ] && [ ! -L /tmp ] || {
      MERV_NVRAM_INVENTORY_FILE=""
      MERV_NVRAM_INVENTORY_STATUS=""
      MERV_NVRAM_INVENTORY_REASON=""
      MERV_NVRAM_INVENTORY_RC=""
      return 1
    }
    [ "$_mnips_root" = /tmp ] || {
      _mnips_path=/tmp
      _mnips_rest=${_mnips_root#/tmp/}
      while [ -n "$_mnips_rest" ]; do
        case "$_mnips_rest" in
          */*)
            _mnips_part=${_mnips_rest%%/*}
            _mnips_rest=${_mnips_rest#*/}
            ;;
          *)
            _mnips_part=$_mnips_rest
            _mnips_rest=
            ;;
        esac
        [ -n "$_mnips_part" ] || continue
        case "$_mnips_part" in
          .|..|*[!A-Za-z0-9._-]*)
            MERV_NVRAM_INVENTORY_FILE=""
            MERV_NVRAM_INVENTORY_STATUS=""
            MERV_NVRAM_INVENTORY_REASON=""
            MERV_NVRAM_INVENTORY_RC=""
            return 1
            ;;
        esac
        _mnips_path="$_mnips_path/$_mnips_part"
        [ ! -L "$_mnips_path" ] || {
          MERV_NVRAM_INVENTORY_FILE=""
          MERV_NVRAM_INVENTORY_STATUS=""
          MERV_NVRAM_INVENTORY_REASON=""
          MERV_NVRAM_INVENTORY_RC=""
          return 1
        }
        if [ -e "$_mnips_path" ] && [ ! -d "$_mnips_path" ]; then
          MERV_NVRAM_INVENTORY_FILE=""
          MERV_NVRAM_INVENTORY_STATUS=""
          MERV_NVRAM_INVENTORY_REASON=""
          MERV_NVRAM_INVENTORY_RC=""
          return 1
        fi
      done
    }
  fi

  if type merv_identity_current_start >/dev/null 2>&1; then
    _mnips_start=$(merv_identity_current_start 2>/dev/null) || {
      MERV_NVRAM_INVENTORY_FILE=""
      MERV_NVRAM_INVENTORY_STATUS=""
      MERV_NVRAM_INVENTORY_REASON=""
      MERV_NVRAM_INVENTORY_RC=""
      return 1
    }
  else
    # Keep the standalone inventory contract usable by lightweight callers
    # that do not load lib_identity, while retaining the same strict /proc
    # start-time proof.  Missing/malformed identity remains a hard failure.
    _mnips_stat=$(cat "/proc/$$/stat" 2>/dev/null) || {
      MERV_NVRAM_INVENTORY_FILE=""
      MERV_NVRAM_INVENTORY_STATUS=""
      MERV_NVRAM_INVENTORY_REASON=""
      MERV_NVRAM_INVENTORY_RC=""
      return 1
    }
    case "$_mnips_stat" in
      *") "*) _mnips_stat=${_mnips_stat##*) } ;;
      *)
        MERV_NVRAM_INVENTORY_FILE=""
        MERV_NVRAM_INVENTORY_STATUS=""
        MERV_NVRAM_INVENTORY_REASON=""
        MERV_NVRAM_INVENTORY_RC=""
        return 1
        ;;
    esac
    _mnips_start=$(printf '%s\n' "$_mnips_stat" | awk '{print $20}') || {
      MERV_NVRAM_INVENTORY_FILE=""
      MERV_NVRAM_INVENTORY_STATUS=""
      MERV_NVRAM_INVENTORY_REASON=""
      MERV_NVRAM_INVENTORY_RC=""
      return 1
    }
  fi
  case "$_mnips_start" in
    ''|*[!0-9]*|0)
      MERV_NVRAM_INVENTORY_FILE=""
      MERV_NVRAM_INVENTORY_STATUS=""
      MERV_NVRAM_INVENTORY_REASON=""
      MERV_NVRAM_INVENTORY_RC=""
      return 1
      ;;
  esac
  printf '%s\n' "$_mnips_start"
}

merv_nvram_inventory_path() {
  local _mnip_root _mnip_scope _mnip_start
  _mnip_root="${MERV_NVRAM_INVENTORY_ROOT:-${TMPDIR:-/tmp/mervlan_tmp}}"
  # Inventory state is volatile.  Permit /tmp descendants only; invalid or
  # inherited paths fall back to the normal MerVLAN temporary root.
  case "$_mnip_root" in
    /tmp|/tmp/*) ;;
    *) _mnip_root="/tmp/mervlan_tmp" ;;
  esac
  case "$_mnip_root" in
    *..*|*[!A-Za-z0-9_./-]*) _mnip_root="/tmp/mervlan_tmp" ;;
  esac
  _mnip_scope="${MERV_NVRAM_INVENTORY_SCOPE:-pid}"
  case "$_mnip_scope" in
    ''|*[!A-Za-z0-9._-]*) _mnip_scope=pid ;;
  esac
  [ "${#_mnip_scope}" -le 64 ] || _mnip_scope=pid
  _mnip_start=$(merv_nvram_inventory_process_start "$_mnip_root") || {
    MERV_NVRAM_INVENTORY_FILE=""
    MERV_NVRAM_INVENTORY_STATUS=""
    MERV_NVRAM_INVENTORY_REASON=""
    MERV_NVRAM_INVENTORY_RC=""
    return 1
  }
  printf '%s/nvram_inventory.%s.%s.%s\n' \
    "$_mnip_root" "$_mnip_scope" "$$" "$_mnip_start"
}

merv_nvram_inventory_publish_state() {
  local _mnips_path="$1" _mnips_state="$2" _mnips_tmp _mnips_root
  _mnips_root=${_mnips_path%/*}
  merv_nvram_inventory_process_start "$_mnips_root" >/dev/null 2>&1 || return 1
  _mnips_tmp="${_mnips_path}.state.tmp"
  [ ! -L "$_mnips_tmp" ] || return 1
  [ ! -L "${_mnips_path}.state" ] || return 1
  [ ! -e "$_mnips_tmp" ] || rm -f "$_mnips_tmp" 2>/dev/null || return 1
  (
    set -C
    printf '%s\n' "$_mnips_state" > "$_mnips_tmp" 2>/dev/null
  ) || return 1
  chmod 600 "$_mnips_tmp" 2>/dev/null || {
    rm -f "$_mnips_tmp" 2>/dev/null
    return 1
  }
  [ ! -L "${_mnips_path}.state" ] || {
    rm -f "$_mnips_tmp" 2>/dev/null
    return 1
  }
  mv -f "$_mnips_tmp" "${_mnips_path}.state" 2>/dev/null || {
    rm -f "$_mnips_tmp" 2>/dev/null
    return 1
  }
}

merv_nvram_inventory_mark_error() {
  local _mnie_path="$1" _mnie_rc="$2" _mnie_reason="$3"
  local _mnie_start _mnie_pid _mnie_state
  _mnie_start=$(merv_nvram_inventory_process_start "${_mnie_path%/*}") || {
    MERV_NVRAM_INVENTORY_FILE=""
    MERV_NVRAM_INVENTORY_STATUS=error
    MERV_NVRAM_INVENTORY_REASON=identity-unavailable
    MERV_NVRAM_INVENTORY_RC=65
    return 2
  }
  _mnie_pid="$$"
  case "$_mnie_rc" in ''|*[!0-9]*) _mnie_rc=1 ;; esac
  case "$_mnie_reason" in
    ''|*[!A-Za-z0-9._-]*) _mnie_reason=read-failed ;;
  esac
  _mnie_state="error|$_mnie_pid|$_mnie_start|$_mnie_rc|$_mnie_reason"
  rm -f "${_mnie_path}.data" "${_mnie_path}.raw" \
    "${_mnie_path}.filtered.tmp" 2>/dev/null
  MERV_NVRAM_INVENTORY_FILE=""
  MERV_NVRAM_INVENTORY_STATUS=error
  MERV_NVRAM_INVENTORY_REASON="$_mnie_reason"
  MERV_NVRAM_INVENTORY_RC="$_mnie_rc"
  if ! merv_nvram_inventory_publish_state "$_mnie_path" "$_mnie_state"; then
    MERV_NVRAM_INVENTORY_REASON=cache-state-publish-failed
  fi
  return 2
}

merv_nvram_inventory_invalidate() {
  local _mnii_path _mnii_root _mnii_file _mnii_failed=0
  MERV_NVRAM_INVENTORY_FILE=""
  MERV_NVRAM_INVENTORY_STATUS=""
  MERV_NVRAM_INVENTORY_REASON=""
  MERV_NVRAM_INVENTORY_RC=""
  _mnii_root="${MERV_NVRAM_INVENTORY_ROOT:-${TMPDIR:-/tmp/mervlan_tmp}}"
  case "$_mnii_root" in
    /tmp|/tmp/*) ;;
    *) _mnii_root=/tmp/mervlan_tmp ;;
  esac
  case "$_mnii_root" in
    *..*|*[!A-Za-z0-9_./-]*) _mnii_root=/tmp/mervlan_tmp ;;
  esac
  merv_nvram_inventory_process_start "$_mnii_root" >/dev/null 2>&1 || return 1
  if [ ! -e "$_mnii_root" ] && [ ! -L "$_mnii_root" ]; then
    MERV_NVRAM_INVENTORY_FILE=""
    MERV_NVRAM_INVENTORY_STATUS=""
    MERV_NVRAM_INVENTORY_REASON=""
    MERV_NVRAM_INVENTORY_RC=""
    return 0
  fi
  _mnii_path=$(merv_nvram_inventory_path 2>/dev/null) || return 1
  merv_nvram_inventory_process_start "${_mnii_path%/*}" >/dev/null 2>&1 || return 1
  for _mnii_file in "$_mnii_path" "${_mnii_path}.state" "${_mnii_path}.data" \
    "${_mnii_path}.raw" "${_mnii_path}.filtered.tmp" "${_mnii_path}.state.tmp"; do
    rm -f "$_mnii_file" 2>/dev/null || _mnii_failed=1
  done
  for _mnii_file in "$_mnii_path" "${_mnii_path}.state" "${_mnii_path}.data" \
    "${_mnii_path}.raw" "${_mnii_path}.filtered.tmp" "${_mnii_path}.state.tmp"; do
    if [ -e "$_mnii_file" ] || [ -L "$_mnii_file" ]; then
      _mnii_failed=1
    fi
  done
  [ "$_mnii_failed" -eq 0 ] || return 1
  MERV_NVRAM_INVENTORY_FILE=""
  MERV_NVRAM_INVENTORY_STATUS=""
  MERV_NVRAM_INVENTORY_REASON=""
  MERV_NVRAM_INVENTORY_RC=""
  return 0
}

# merv_nvram_inventory_read
#   Return 0 for a valid inventory (including an empty valid inventory).
#   Return 2 for an unavailable, malformed, or otherwise untrusted read.
#   MERV_NVRAM_INVENTORY_FILE points at the validated record file on success.
merv_nvram_inventory_read() {
  local _mnir_path _mnir_state _mnir_data _mnir_raw _mnir_filtered
  local _mnir_kind _mnir_pid _mnir_start _mnir_rc _mnir_reason
  local _mnir_current_start _mnir_timeout _mnir_bytes _mnir_max_bytes
  local _mnir_max_records _mnir_max_lines _mnir_max_line _mnir_max_selected_bytes
  local _mnir_max_selected_records _mnir_max_selected_line _mnir_max_selected_value
  local _mnir_selected_bytes _mnir_root

  # Start each read from a neutral state so a path/identity failure cannot
  # expose a previous valid file to manager or Shield callers.
  MERV_NVRAM_INVENTORY_FILE=""
  MERV_NVRAM_INVENTORY_STATUS=""
  MERV_NVRAM_INVENTORY_REASON=""
  MERV_NVRAM_INVENTORY_RC=""
  _mnir_path=$(merv_nvram_inventory_path 2>/dev/null) || {
    merv_nvram_inventory_set_error cache-path-untrusted 65
    return $?
  }
  _mnir_state="${_mnir_path}.state"
  _mnir_data="${_mnir_path}.data"
  merv_nvram_inventory_artifacts_safe "$_mnir_path" || {
    merv_nvram_inventory_set_error cache-path-untrusted 65
    return $?
  }
  _mnir_current_start=$(merv_nvram_inventory_process_start) || {
    merv_nvram_inventory_set_error identity-unavailable 65
    return $?
  }

  # State is published atomically, but still parse every field as untrusted
  # text before accepting it.  A matching cached error is intentionally
  # returned without retrying the underlying NVRAM command.
  if [ -f "$_mnir_state" ] && [ ! -L "$_mnir_state" ]; then
    _mnir_kind=""; _mnir_pid=""; _mnir_start=""; _mnir_rc=""; _mnir_reason=""
    [ ! -L "$_mnir_state" ] || {
      merv_nvram_inventory_set_error cache-path-untrusted 65
      return $?
    }
    IFS='|' read -r _mnir_kind _mnir_pid _mnir_start _mnir_rc _mnir_reason < "$_mnir_state" || :
    case "$_mnir_kind" in
      valid)
        if [ "$_mnir_pid" = "$$" ] && [ "$_mnir_start" = "$_mnir_current_start" ] &&
           [ "$_mnir_rc" = 0 ] && [ "$_mnir_reason" = ok ] &&
           [ -f "$_mnir_data" ] && [ ! -L "$_mnir_data" ] &&
           merv_nvram_inventory_validate_records "$_mnir_data"; then
          MERV_NVRAM_INVENTORY_FILE="$_mnir_data"
          MERV_NVRAM_INVENTORY_STATUS=valid
          MERV_NVRAM_INVENTORY_REASON=ok
          MERV_NVRAM_INVENTORY_RC=0
          return 0
        fi
        ;;
      error)
        if [ "$_mnir_pid" = "$$" ] && [ "$_mnir_start" = "$_mnir_current_start" ]; then
          case "$_mnir_rc" in ''|*[!0-9]*) _mnir_rc=1 ;; esac
          case "$_mnir_reason" in ''|*[!A-Za-z0-9._-]*) _mnir_reason=read-failed ;; esac
          MERV_NVRAM_INVENTORY_FILE=""
          MERV_NVRAM_INVENTORY_STATUS=error
          MERV_NVRAM_INVENTORY_REASON="$_mnir_reason"
          MERV_NVRAM_INVENTORY_RC="$_mnir_rc"
          return 2
        fi
        ;;
    esac
    # The path is process-scoped.  A stale or malformed marker can be
    # discarded and rebuilt, but never treated as a successful empty result.
    rm -f "$_mnir_state" "$_mnir_data" 2>/dev/null || return 2
  fi

  _mnir_root=${_mnir_path%/*}
  mkdir -p "$_mnir_root" 2>/dev/null || {
    merv_nvram_inventory_mark_error "$_mnir_path" 1 cache-root-unavailable
    return $?
  }
  merv_nvram_inventory_process_start "$_mnir_root" >/dev/null 2>&1 || {
    merv_nvram_inventory_set_error cache-root-untrusted 65
    return $?
  }
  _mnir_raw="${_mnir_path}.raw"
  _mnir_filtered="${_mnir_path}.filtered.tmp"
  merv_nvram_inventory_artifacts_safe "$_mnir_path" || {
    merv_nvram_inventory_set_error cache-path-untrusted 65
    return $?
  }
  rm -f "$_mnir_raw" "$_mnir_filtered" "$_mnir_data" 2>/dev/null || {
    merv_nvram_inventory_set_error cache-artifact-remove-failed 1
    return $?
  }

  _mnir_timeout="${MERV_NVRAM_READ_TIMEOUT:-10}"
  case "$_mnir_timeout" in ''|*[!0-9]*) _mnir_timeout=10 ;; esac
  [ "$_mnir_timeout" -gt 0 ] 2>/dev/null || _mnir_timeout=10
  MERV_NVRAM_READ_TIMEOUT="$_mnir_timeout"
  if ! type _merv_timeout_run >/dev/null 2>&1; then
    merv_nvram_inventory_mark_error "$_mnir_path" 127 timeout-helper-unavailable
    return $?
  fi
  (
    set -C
    exec 3> "$_mnir_raw" 2>/dev/null || exit 126
    [ ! -L "$_mnir_raw" ] || { exec 3>&-; exit 127; }
    _merv_timeout_run "$MERV_NVRAM_READ_TIMEOUT" nvram show >&3 2>/dev/null
    _mnir_rc=$?
    exec 3>&-
    exit "$_mnir_rc"
  )
  _mnir_rc=$?
  if [ "$_mnir_rc" -ne 0 ]; then
    case "$_mnir_rc" in
      124) _mnir_reason=timeout ;;
      125) _mnir_reason=timeout-cleanup-failed ;;
      *) _mnir_reason=read-failed ;;
    esac
    merv_nvram_inventory_mark_error "$_mnir_path" "$_mnir_rc" "$_mnir_reason"
    return $?
  fi

  _mnir_max_bytes="${MERV_NVRAM_INVENTORY_MAX_RAW_BYTES:-${MERV_NVRAM_INVENTORY_MAX_BYTES:-1048576}}"
  case "$_mnir_max_bytes" in ''|*[!0-9]*) _mnir_max_bytes=1048576 ;; esac
  [ "$_mnir_max_bytes" -gt 0 ] 2>/dev/null || _mnir_max_bytes=1048576
  [ -f "$_mnir_raw" ] && [ ! -L "$_mnir_raw" ] || {
    merv_nvram_inventory_mark_error "$_mnir_path" 65 cache-input-untrusted
    return $?
  }
  _mnir_bytes=$(
    exec 3< "$_mnir_raw" 2>/dev/null || exit 1
    [ ! -L "$_mnir_raw" ] || { exec 3<&-; exit 1; }
    wc -c <&3
    exec 3<&-
  ) || _mnir_bytes=""
  case "$_mnir_bytes" in ''|*[!0-9]*)
    merv_nvram_inventory_mark_error "$_mnir_path" 65 inventory-size-unreadable
    return $? ;;
  esac
  if ! [ "$_mnir_bytes" -le "$_mnir_max_bytes" ] 2>/dev/null; then
    merv_nvram_inventory_mark_error "$_mnir_path" 65 inventory-too-large
    return $?
  fi

  _mnir_max_records="${MERV_NVRAM_INVENTORY_MAX_RAW_RECORDS:-${MERV_NVRAM_INVENTORY_MAX_RECORDS:-32768}}"
  case "$_mnir_max_records" in ''|*[!0-9]*) _mnir_max_records=32768 ;; esac
  [ "$_mnir_max_records" -gt 0 ] 2>/dev/null || _mnir_max_records=32768
  _mnir_max_lines="${MERV_NVRAM_INVENTORY_MAX_RAW_LINES:-32768}"
  case "$_mnir_max_lines" in ''|*[!0-9]*) _mnir_max_lines=32768 ;; esac
  [ "$_mnir_max_lines" -gt 0 ] 2>/dev/null || _mnir_max_lines=32768
  _mnir_max_line="${MERV_NVRAM_INVENTORY_MAX_RAW_LINE_BYTES:-8192}"
  case "$_mnir_max_line" in ''|*[!0-9]*) _mnir_max_line=8192 ;; esac
  [ "$_mnir_max_line" -gt 0 ] 2>/dev/null || _mnir_max_line=8192
  _mnir_max_selected_bytes="${MERV_NVRAM_INVENTORY_MAX_SELECTED_BYTES:-32768}"
  case "$_mnir_max_selected_bytes" in ''|*[!0-9]*) _mnir_max_selected_bytes=32768 ;; esac
  [ "$_mnir_max_selected_bytes" -gt 0 ] 2>/dev/null || _mnir_max_selected_bytes=32768
  _mnir_max_selected_records="${MERV_NVRAM_INVENTORY_MAX_SELECTED_RECORDS:-128}"
  case "$_mnir_max_selected_records" in ''|*[!0-9]*) _mnir_max_selected_records=128 ;; esac
  [ "$_mnir_max_selected_records" -gt 0 ] 2>/dev/null || _mnir_max_selected_records=128
  _mnir_max_selected_line="${MERV_NVRAM_INVENTORY_MAX_SELECTED_LINE_BYTES:-256}"
  case "$_mnir_max_selected_line" in ''|*[!0-9]*) _mnir_max_selected_line=256 ;; esac
  [ "$_mnir_max_selected_line" -gt 0 ] 2>/dev/null || _mnir_max_selected_line=256
  _mnir_max_selected_value="${MERV_NVRAM_INVENTORY_MAX_SELECTED_VALUE_BYTES:-128}"
  case "$_mnir_max_selected_value" in ''|*[!0-9]*) _mnir_max_selected_value=128 ;; esac
  [ "$_mnir_max_selected_value" -gt 0 ] 2>/dev/null || _mnir_max_selected_value=128
  [ -f "$_mnir_raw" ] && [ ! -L "$_mnir_raw" ] || {
    merv_nvram_inventory_mark_error "$_mnir_path" 65 cache-input-untrusted
    return $?
  }
  (
    set -C
    [ ! -e "$_mnir_filtered" ] || exit 126
    exec 3< "$_mnir_raw" 2>/dev/null || exit 127
    [ ! -L "$_mnir_raw" ] || { exec 3<&-; exit 127; }
    awk -v max_raw_records="$_mnir_max_records" \
      -v max_raw_lines="$_mnir_max_lines" \
      -v max_raw_line="$_mnir_max_line" \
      -v max_selected_records="$_mnir_max_selected_records" \
      -v max_selected_line="$_mnir_max_selected_line" \
      -v max_selected_value="$_mnir_max_selected_value" '
    {
      if (NR > max_raw_lines) { bad=1; next }
      if (length($0) > max_raw_line) { bad=1; next }
      if ($0 ~ /^[[:space:]]*$/) next
      if (index($0, "=") > 0) records++
      if (records > max_raw_records) { bad=1; next }
      if (index($0, "=") == 0) {
        # Broadcom nvram applets append a human-readable size summary.
        if ($0 ~ /^size:[[:space:]]*/) next
        # Only an exact selected key without its separator is malformed;
        # near-match namespaces remain unrelated input and are ignored.
        if ($0 ~ /^wl[0-9]+(\.[0-9]+)?_(ssid|ifname)$/) bad=1
        next
      }
      eq=index($0, "=")
      key=substr($0, 1, eq-1)
      val=substr($0, eq+1)
      if (key !~ /^wl[0-9]+(\.[0-9]+)?_(ssid|ifname)$/) {
        # NVRAM contains unrelated keys with colons, slashes, and other
        # firmware-specific punctuation.  They are not inventory targets.
        next
      }
      if (length($0) > max_selected_line || length(val) > max_selected_value ||
          val ~ /[[:cntrl:]]/ || seen[key]++ || ++selected_records > max_selected_records) {
        bad=1; next
      }
      if (key ~ /_ifname$/) {
        clean=val
        sub(/^[[:space:]]+/, "", clean)
        sub(/[[:space:]]+$/, "", clean)
        if (clean ~ /^\".*\"$/)
          clean=substr(clean, 2, length(clean)-2)
        if (clean != "" && clean !~ /^[A-Za-z0-9_.:-]+$/) { bad=1; next }
      }
      print key "=" val
    }
    END { exit bad ? 65 : 0 }
    ' <&3 > "$_mnir_filtered" 2>/dev/null
    _mnir_rc=$?
    exec 3<&-
    exit "$_mnir_rc"
  )
  _mnir_rc=$?
  if [ "$_mnir_rc" -ne 0 ]; then
    merv_nvram_inventory_mark_error "$_mnir_path" 65 inventory-malformed
    return $?
  fi

  [ -f "$_mnir_filtered" ] && [ ! -L "$_mnir_filtered" ] || {
    merv_nvram_inventory_mark_error "$_mnir_path" 65 cache-input-untrusted
    return $?
  }
  _mnir_selected_bytes=$(
    exec 3< "$_mnir_filtered" 2>/dev/null || exit 1
    [ ! -L "$_mnir_filtered" ] || { exec 3<&-; exit 1; }
    wc -c <&3
    exec 3<&-
  ) || _mnir_selected_bytes=""
  case "$_mnir_selected_bytes" in ''|*[!0-9]*)
    merv_nvram_inventory_mark_error "$_mnir_path" 65 inventory-size-unreadable
    return $? ;;
  esac
  if ! [ "$_mnir_selected_bytes" -le "$_mnir_max_selected_bytes" ] 2>/dev/null; then
    merv_nvram_inventory_mark_error "$_mnir_path" 65 inventory-selected-too-large
    return $?
  fi

  if ! mv -f "$_mnir_filtered" "$_mnir_data" 2>/dev/null; then
    merv_nvram_inventory_mark_error "$_mnir_path" 1 inventory-cache-write-failed
    return $?
  fi
  if ! chmod 600 "$_mnir_data" 2>/dev/null; then
    merv_nvram_inventory_mark_error "$_mnir_path" 1 inventory-cache-mode-failed
    return $?
  fi
  rm -f "$_mnir_raw" 2>/dev/null || :
  _mnir_start="$_mnir_current_start"
  if ! merv_nvram_inventory_publish_state "$_mnir_path" \
       "valid|$$|$_mnir_start|0|ok"; then
    merv_nvram_inventory_mark_error "$_mnir_path" 1 inventory-state-write-failed
    return $?
  fi
  MERV_NVRAM_INVENTORY_FILE="$_mnir_data"
  MERV_NVRAM_INVENTORY_STATUS=valid
  MERV_NVRAM_INVENTORY_REASON=ok
  MERV_NVRAM_INVENTORY_RC=0
  return 0
}

# merv_nvram_inventory_value <key>
# Print one validated value from the current inventory.  This is intentionally
# a file read rather than `nvram get`: all manager/Shield lookups then share
# the one bounded inventory read and retain its failure classification.
merv_nvram_inventory_value() {
  local _mniv_key="$1" _mniv_file="${MERV_NVRAM_INVENTORY_FILE:-}"
  local _mniv_name _mniv_value _mniv_found=0 _mniv_result=""
  merv_nvram_inventory_target_key_valid "$_mniv_key" || return 1
  if [ -z "$_mniv_file" ]; then
    _mniv_file=$(merv_nvram_inventory_path 2>/dev/null) || return 1
    _mniv_file="${_mniv_file}.data"
  fi
  [ -f "$_mniv_file" ] && [ ! -L "$_mniv_file" ] || return 1
  exec 3< "$_mniv_file" 2>/dev/null || return 1
  [ ! -L "$_mniv_file" ] || {
    exec 3<&-
    return 1
  }
  while IFS='=' read -r _mniv_name _mniv_value; do
    merv_nvram_inventory_target_key_valid "$_mniv_name" || {
      exec 3<&-
      return 1
    }
    [ "$_mniv_name" = "$_mniv_key" ] || continue
    [ "$_mniv_found" -eq 0 ] || {
      exec 3<&-
      return 1
    }
    _mniv_found=1
    _mniv_result="$_mniv_value"
  done <&3
  exec 3<&-
  [ "$_mniv_found" -eq 1 ] || return 1
  printf '%s\n' "$_mniv_result"
  return 0
}

# ============================================================================
# Snapshot status output globals
# ----------------------------------------------------------------------------
# Set as side effects by merv_mac_snapshot. Readable by INLINE callers ONLY
# (e.g. mac_refresh.sh). They are NOT propagated through subshells: callers
# that wrap snapshot in ( merv_mac_snapshot ) & (heal_event.sh cron tick,
# mervlan_manager.sh post-apply) will see only the zero-initialized values
# below — never read these from such callers.
# ============================================================================
MERV_MAC_LAST_STATUS=""
MERV_MAC_LAST_REASON=""
MERV_MAC_LAST_LOCAL_COUNT=0
MERV_MAC_LAST_NODE_COUNT=0
MERV_MAC_LAST_TOTAL_COUNT=0
MERV_MAC_LAST_DB_COUNT=0
MERV_MAC_LAST_CHANGED=0
MERV_MAC_LAST_NODES_TOTAL=0
MERV_MAC_LAST_NODES_OK=0
MERV_MAC_LAST_NODES_FAILED=0
MERV_MAC_LAST_PUSH_TOTAL=0
MERV_MAC_LAST_PUSH_OK=0
MERV_MAC_LAST_PUSH_FAILED=0

# ============================================================================
# _merv_mac_log <level> <message>
# Route a log line to the caller-configured channel set so manual refresh hits
# cli,vlan while cron/manager stay on vlan only. level: info | warn
# ============================================================================
_merv_mac_log() {
  local _lvl="$1"; shift
  case "$_lvl" in
    warn) warn -c "${MERV_MAC_SNAPSHOT_LOG_CHANNELS:-vlan}" "$@" ;;
    *)    info -c "${MERV_MAC_SNAPSHOT_LOG_CHANNELS:-vlan}" "$@" ;;
  esac
}

# ============================================================================
# _merv_mac_logv <level> <message>
# Verbose-only variant: logs only when MERV_MAC_SNAPSHOT_VERBOSE=1 (manual
# refresh step trace). Stays silent for cron/manager default runs.
# ============================================================================
_merv_mac_logv() {
  [ "${MERV_MAC_SNAPSHOT_VERBOSE:-0}" = "1" ] || return 0
  _merv_mac_log "$@"
}

# ============================================================================
# _merv_mac_refresh_progress <phase> <percent> <message>
# Publish detailed progress only for an explicitly requested manual
# macrefresh_vlanmgr action. Periodic/background snapshots remain silent.
# ============================================================================
_merv_mac_refresh_progress() {
  local _mmrp_phase="$1"
  local _mmrp_percent="$2"
  local _mmrp_message="$3"

  [ "${MERV_MAC_REFRESH_PROGRESS:-0}" = "1" ] || return 0

  case "${MERV_PROGRESS_TOKEN:-}" in
    ''|*[!A-Za-z0-9._-]*) return 0 ;;
  esac

  type merv_progress_update >/dev/null 2>&1 || return 0

  merv_progress_update \
    "$MERV_PROGRESS_TOKEN" \
    macrefresh_vlanmgr \
    "Rebuild MAC Shield" \
    running \
    determinate \
    "$_mmrp_phase" \
    0 \
    0 \
    "$_mmrp_percent" \
    "$_mmrp_message" \
    "" >/dev/null 2>&1 || :
}

# ============================================================================
# merv_mac_boot_init
# Called once in boot mode before first manager apply.
#   - If /tmp db is missing and JFFS checkpoint exists: copy to /tmp
#   - Arm MERV_MAC chain from /tmp db
# Ensures clients known from the last reboot are protected during the boot gap
# before any clients re-associate.
# ============================================================================
merv_mac_boot_init() {
  mkdir -p "$(dirname "$MERV_MAC_DB_ACTIVE")" 2>/dev/null || true

  if [ ! -f "$MERV_MAC_DB_ACTIVE" ] && [ -f "$MERV_MAC_DB_JFFS" ]; then
    cp "$MERV_MAC_DB_JFFS" "$MERV_MAC_DB_ACTIVE" 2>/dev/null || true
    local n
    n=$(wc -l < "$MERV_MAC_DB_ACTIVE" 2>/dev/null | tr -d ' ')
    info -c vlan "MERV_MAC: restored ${n:-0} entries from JFFS checkpoint to active db"
  fi

  ebt_mac_shield_init_and_apply "$MERV_MAC_DB_ACTIVE"
}

# ============================================================================
# merv_mac_build_expected_iface_vid
# Derive expected wl subinterface → VID map from settings + NVRAM.
# This is the single canonical implementation shared by both manager and heal.
# Do NOT duplicate this logic elsewhere.
#
# Source of truth:
#   - SSID slots via get_ssid_slot_value / get_vlan_slot_value
#     (respects node assignment and SSID filter)
#   - NVRAM wl*_ssid / wl*_ifname for interface resolution
#
# Output: lines of "<iface> <vid>" (one per resolved wl subinterface per slot)
#
# Rules:
#   - Skips unconfigured/placeholder SSID slots
#   - Skips VLAN = none, trunk, or out of valid range
#   - Only emits wl*.* subinterfaces (not base radios wl0/wl1, not eth*)
#   - Uses a single cached `nvram show` to avoid repeated NVRAM calls
#   - Output is deduplicated: same iface appearing in multiple slots emitted once
# ============================================================================
merv_mac_build_expected_iface_vid() {
  local max_ssids i ssid vlan key rawval val base iface
  local nvram_file ifname_key ifname_raw

  # Use merv_cap_ssids to get a safe, cap-bounded slot count.
  # Falls back to 12 if MAX_SSIDS is 0/unset, and never exceeds Limits.MAX_SSID_CAP.
  if type merv_cap_ssids >/dev/null 2>&1; then
    max_ssids=$(merv_cap_ssids "${MAX_SSIDS:-0}" "${SETTINGS_FILE:-}")
  else
    max_ssids="${MAX_SSIDS:-12}"
    [ "$max_ssids" -gt 16 ] 2>/dev/null && max_ssids=16
  fi

  # Single cached NVRAM read across all slot iterations. Some ASUS firmware
  # builds can leave `nvram show` asleep indefinitely; the inventory helper
  # bounds and memoizes that failure instead of repeating it per guard tick.
  merv_nvram_inventory_read || {
    _mmb_nvram_rc=$?
    _merv_mac_log warn "MERV_MAC: NVRAM SSID inventory unavailable (reason=${MERV_NVRAM_INVENTORY_REASON:-read-failed}, rc=${MERV_NVRAM_INVENTORY_RC:-$_mmb_nvram_rc})"
    return 1
  }
  nvram_file="${MERV_NVRAM_INVENTORY_FILE:-}"
  [ -f "$nvram_file" ] && [ ! -L "$nvram_file" ] || return 1

  i=1
  while [ "$i" -le "$max_ssids" ]; do
    ssid=$(get_ssid_slot_value "$i" "$SETTINGS_FILE")
    vlan=$(get_vlan_slot_value "$i" "$SETTINGS_FILE")
    i=$((i + 1))

    # Skip unconfigured or placeholder slots
    [ -z "$ssid" ] || [ "$ssid" = "unused-placeholder" ] && continue

    # Skip non-VLAN assignments
    case "$vlan" in ''|none|trunk) continue ;; esac
    mervqt_valid_vid "$vlan" || continue

    # Scan cached NVRAM for wl subinterfaces matching this SSID
    [ -f "$nvram_file" ] && [ ! -L "$nvram_file" ] || return 1
    while IFS='=' read -r key rawval; do
      case "$key" in
        wl[0-9]*_ssid) ;;
        *) continue ;;
      esac
      # Strip quotes and surrounding whitespace from NVRAM value
      val=$(printf '%s' "$rawval" \
        | sed "s/^[[:space:]]*['\"]//;s/['\"][[:space:]]*\$//;s/^[[:space:]]*//;s/[[:space:]]*\$//")
      [ "$val" = "$ssid" ] || continue

      base="${key%_ssid}"

      # Only process wl subinterface NVRAM keys (wl0.1_ssid, wl10.1_ssid etc.) — skip base radios.
      # Use merv_is_wl_vap_iface for strict validation (rejects trailing garbage like wl0.1abc).
      if type merv_is_wl_vap_iface >/dev/null 2>&1; then
        merv_is_wl_vap_iface "$base" || continue
      else
        case "$base" in
          wl[0-9].[0-9]*|wl[0-9][0-9].[0-9]*) ;;
          *) continue ;;
        esac
      fi

      # Resolve ifname from the same validated inventory; fall back to the
      # base key name when firmware omitted the optional mapping, matching the
      # historical builder's fallback without another unbounded NVRAM call.
      ifname_key="${base}_ifname"
      ifname_raw=""
      [ -f "$nvram_file" ] && [ ! -L "$nvram_file" ] || return 1
      while IFS='=' read -r _mmb_name _mmb_value; do
        [ "$_mmb_name" = "$ifname_key" ] || continue
        ifname_raw="$_mmb_value"
        break
      done < "$nvram_file"
      iface=$(printf '%s' "$ifname_raw" \
        | sed 's/^[[:space:]]*[\"]//;s/[\"][[:space:]]*$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -n "$iface" ] || iface="$base"

      # Emit only wl subinterfaces (strict check)
      if type merv_is_wl_vap_iface >/dev/null 2>&1; then
        merv_is_wl_vap_iface "$iface" && printf '%s %s\n' "$iface" "$vlan"
      else
        case "$iface" in
          wl[0-9].*|wl[0-9][0-9].*) printf '%s %s\n' "$iface" "$vlan" ;;
        esac
      fi

    done < "$nvram_file"

  done | awk '
    NF == 0 { next }
    NF != 2 || $1 !~ /^wl[0-9]+\.[0-9]+$/ ||
      $2 !~ /^[0-9]+$/ || $2 < 2 || $2 > 4094 { bad=1; next }
    !seen[$1]++ { print }
    END { exit bad ? 65 : 0 }
  '
}

merv_iface_vid_pairs_validate() {
  local _mipv_pairs="$1" _mipv_iface _mipv_vid _mipv_extra
  while IFS=' ' read -r _mipv_iface _mipv_vid _mipv_extra; do
    [ -n "$_mipv_iface" ] || {
      [ -z "$_mipv_vid" ] && [ -z "$_mipv_extra" ] && continue
      return 1
    }
    [ -n "$_mipv_vid" ] && [ -z "$_mipv_extra" ] || return 1
    if type mervqt_valid_wl_subif >/dev/null 2>&1; then
      mervqt_valid_wl_subif "$_mipv_iface" || return 1
    else
      case "$_mipv_iface" in wl[0-9]*.*) ;; *) return 1 ;; esac
    fi
    if type mervqt_valid_vid >/dev/null 2>&1; then
      mervqt_valid_vid "$_mipv_vid" || return 1
    else
      case "$_mipv_vid" in ''|*[!0-9]*) return 1 ;; esac
      [ "$_mipv_vid" -ge 2 ] 2>/dev/null && [ "$_mipv_vid" -le 4094 ] 2>/dev/null || return 1
    fi
  done <<_MERV_IFACE_VID_PAIRS_
$_mipv_pairs
_MERV_IFACE_VID_PAIRS_
  return 0
}

# ============================================================================
# merv_iface_vid_list — cached wrapper for merv_mac_build_expected_iface_vid
#
# Returns the same output as the underlying builder. When the cache is enabled
# (merv_iface_vid_cache_enable) the result is computed once and reused until
# either the cache is invalidated (merv_iface_vid_cache_invalidate) or
# disabled (merv_iface_vid_cache_disable).
#
# Cache scope: the derived iface/VID output remains an in-memory optimization,
# while the underlying NVRAM inventory is file-backed and process-scoped.  The
# latter is required because subshells (pipelines/command substitutions) do
# NOT mutate the parent's shell variables.
#
# Callers that MUST see fresh state (final security check, snapshot
# preconditions) should call merv_mac_build_expected_iface_vid directly and
# bypass this wrapper.
# ============================================================================
_MERV_IFACE_VID_CACHE=""
_MERV_IFACE_VID_CACHE_ON=0
_MERV_IFACE_VID_CACHE_STATUS="unset"

merv_iface_vid_cache_path() {
  local _mivcp_path
  _mivcp_path=$(merv_nvram_inventory_path 2>/dev/null) || {
    merv_nvram_inventory_clear_state
    return 1
  }
  printf '%s.iface\n' "$_mivcp_path"
}

merv_iface_vid_cache_remove_files() {
  local _mivrf_path="$1" _mivrf_file _mivrf_failed=0
  [ -n "$_mivrf_path" ] || return 1
  merv_nvram_inventory_process_start "${_mivrf_path%/*}" >/dev/null 2>&1 || {
    merv_nvram_inventory_clear_state
    return 1
  }
  for _mivrf_file in "${_mivrf_path}.data" "${_mivrf_path}.state" \
    "${_mivrf_path}.tmp" "${_mivrf_path}.state.tmp"; do
    rm -f "$_mivrf_file" 2>/dev/null || _mivrf_failed=1
  done
  for _mivrf_file in "${_mivrf_path}.data" "${_mivrf_path}.state" \
    "${_mivrf_path}.tmp" "${_mivrf_path}.state.tmp"; do
    if [ -e "$_mivrf_file" ] || [ -L "$_mivrf_file" ]; then
      _mivrf_failed=1
    fi
  done
  [ "$_mivrf_failed" -eq 0 ]
}

merv_iface_vid_cache_enable() {
  local _mivce_path
  merv_nvram_inventory_clear_state
  _MERV_IFACE_VID_CACHE_ON=1
  _MERV_IFACE_VID_CACHE=""
  _MERV_IFACE_VID_CACHE_STATUS="unset"
  _mivce_path=$(merv_iface_vid_cache_path 2>/dev/null) || {
    _MERV_IFACE_VID_CACHE_ON=0
    _MERV_IFACE_VID_CACHE_STATUS=error
    return 1
  }
  if ! merv_iface_vid_cache_remove_files "$_mivce_path"; then
    _MERV_IFACE_VID_CACHE_ON=0
    _MERV_IFACE_VID_CACHE_STATUS=error
    return 1
  fi
  return 0
}

merv_iface_vid_cache_invalidate() {
  local _mivci_path
  merv_nvram_inventory_clear_state
  _MERV_IFACE_VID_CACHE_ON=1
  _MERV_IFACE_VID_CACHE=""
  _MERV_IFACE_VID_CACHE_STATUS="error"
  _mivci_path=$(merv_iface_vid_cache_path 2>/dev/null) || return 1
  merv_iface_vid_cache_remove_files "$_mivci_path" || return 1
  type merv_nvram_inventory_invalidate >/dev/null 2>&1 || return 1
  merv_nvram_inventory_invalidate || return 1
  _MERV_IFACE_VID_CACHE_STATUS="unset"
  return 0
}

merv_iface_vid_cache_disable() {
  local _mivcd_path
  merv_nvram_inventory_clear_state
  _MERV_IFACE_VID_CACHE_ON=0
  _MERV_IFACE_VID_CACHE=""
  _MERV_IFACE_VID_CACHE_STATUS="error"
  _mivcd_path=$(merv_iface_vid_cache_path 2>/dev/null) || return 1
  merv_iface_vid_cache_remove_files "$_mivcd_path" || return 1
  type merv_nvram_inventory_invalidate >/dev/null 2>&1 || return 1
  merv_nvram_inventory_invalidate || return 1
  _MERV_IFACE_VID_CACHE_STATUS="unset"
  return 0
}

merv_iface_vid_list() {
  local _mivl_path _mivl_state _mivl_data _mivl_start _mivl_tmp
  local _mivl_kind _mivl_pid _mivl_cached_start _mivl_rc _mivl_reason
  if [ "${_MERV_IFACE_VID_CACHE_ON:-0}" = "1" ]; then
    case "${_MERV_IFACE_VID_CACHE_STATUS:-unset}" in
      valid)
        [ -n "$_MERV_IFACE_VID_CACHE" ] && printf '%s\n' "$_MERV_IFACE_VID_CACHE"
        return 0
        ;;
      error) return 1 ;;
    esac

    # merv_iface_vid_list is commonly consumed through command substitution
    # by the QT verifier.  Rehydrate the derived cache from a process-scoped
    # file before rebuilding so that the parent/child shell boundary cannot
    # turn one inventory read into one read per guard tick.
    _mivl_path=$(merv_iface_vid_cache_path 2>/dev/null) || {
      merv_nvram_inventory_clear_state
      _MERV_IFACE_VID_CACHE=""
      _MERV_IFACE_VID_CACHE_STATUS=error
      return 1
    }
    _mivl_state="${_mivl_path}.state"
    _mivl_data="${_mivl_path}.data"
    _mivl_start=$(merv_nvram_inventory_process_start) || {
      merv_nvram_inventory_clear_state
      _MERV_IFACE_VID_CACHE=""
      _MERV_IFACE_VID_CACHE_STATUS=error
      return 1
    }
    if [ -n "$_mivl_path" ] && [ -f "$_mivl_state" ] && [ ! -L "$_mivl_state" ]; then
      _mivl_kind=""; _mivl_pid=""; _mivl_cached_start=""; _mivl_rc=""; _mivl_reason=""
      [ ! -L "$_mivl_state" ] || {
        _MERV_IFACE_VID_CACHE=""
        _MERV_IFACE_VID_CACHE_STATUS=error
        return 1
      }
      IFS='|' read -r _mivl_kind _mivl_pid _mivl_cached_start _mivl_rc _mivl_reason < "$_mivl_state" || :
      if [ "$_mivl_pid" = "$$" ] && [ "$_mivl_cached_start" = "$_mivl_start" ]; then
        case "$_mivl_kind" in
          valid)
            if [ "$_mivl_rc" = 0 ] && [ "$_mivl_reason" = ok ] &&
               [ -f "$_mivl_data" ] && [ ! -L "$_mivl_data" ]; then
              [ ! -L "$_mivl_data" ] || {
                _MERV_IFACE_VID_CACHE=""
                _MERV_IFACE_VID_CACHE_STATUS=error
                return 1
              }
              _MERV_IFACE_VID_CACHE=$(cat "$_mivl_data" 2>/dev/null) || return 1
              merv_iface_vid_pairs_validate "$_MERV_IFACE_VID_CACHE" || {
                _MERV_IFACE_VID_CACHE=""
                _MERV_IFACE_VID_CACHE_STATUS=error
                return 1
              }
              _MERV_IFACE_VID_CACHE_STATUS=valid
              [ -n "$_MERV_IFACE_VID_CACHE" ] && printf '%s\n' "$_MERV_IFACE_VID_CACHE"
              return 0
            fi
            ;;
          error)
            _MERV_IFACE_VID_CACHE=""
            _MERV_IFACE_VID_CACHE_STATUS=error
            return 1
            ;;
        esac
      fi
      rm -f "$_mivl_state" "$_mivl_data" 2>/dev/null || return 1
    fi

    if _MERV_IFACE_VID_CACHE=$(merv_mac_build_expected_iface_vid 2>/dev/null) &&
       merv_iface_vid_pairs_validate "$_MERV_IFACE_VID_CACHE"; then
      if ! merv_nvram_inventory_process_start "${_mivl_path%/*}" >/dev/null 2>&1; then
        _MERV_IFACE_VID_CACHE=""
        _MERV_IFACE_VID_CACHE_STATUS=error
        return 1
      fi
      if [ -n "$_mivl_path" ]; then
        _mivl_tmp="${_mivl_path}.tmp"
        [ ! -L "$_mivl_tmp" ] || return 1
        [ ! -e "$_mivl_tmp" ] || rm -f "$_mivl_tmp" 2>/dev/null || return 1
        [ ! -L "$_mivl_data" ] || return 1
        (
          set -C
          printf '%s\n' "$_MERV_IFACE_VID_CACHE" > "$_mivl_tmp" 2>/dev/null
        ) || return 1
        [ ! -L "$_mivl_tmp" ] || {
          rm -f "$_mivl_tmp" 2>/dev/null
          return 1
        }
        chmod 600 "$_mivl_tmp" 2>/dev/null || { rm -f "$_mivl_tmp" 2>/dev/null; return 1; }
        mv -f "$_mivl_tmp" "$_mivl_data" 2>/dev/null || { rm -f "$_mivl_tmp" 2>/dev/null; return 1; }
        merv_nvram_inventory_publish_state "$_mivl_path" \
          "valid|$$|$_mivl_start|0|ok" || return 1
      fi
      _MERV_IFACE_VID_CACHE_STATUS="valid"
      [ -n "$_MERV_IFACE_VID_CACHE" ] && printf '%s\n' "$_MERV_IFACE_VID_CACHE"
      return 0
    else
      _MERV_IFACE_VID_CACHE=""
      _MERV_IFACE_VID_CACHE_STATUS="error"
      if [ -n "$_mivl_path" ]; then
        merv_nvram_inventory_publish_state "$_mivl_path" \
          "error|$$|$_mivl_start|1|derived-rows-invalid" || :
      fi
      return 1
    fi
  fi
  merv_mac_build_expected_iface_vid 2>/dev/null
}

# ============================================================================
# merv_mac_snapshot_preconditions_ok
# Returns 0 only if ALL config-expected wl subinterfaces are:
#   - present in sysfs
#   - members of their expected bridge br<vid>
#   - NOT simultaneously members of br0
#
# If any expected interface is absent from sysfs: treated as "not yet settled"
# → precondition FAILS. Do not snapshot a partially-up wireless stack.
#
# If no VLAN-bearing SSID interfaces are configured: returns 0 (vacuous pass).
# ============================================================================
merv_mac_snapshot_preconditions_ok() {
  local pairs iface vid ok=1 checked=0

  pairs=$(merv_iface_vid_list)
  if [ $? -ne 0 ]; then
    warn -c vlan "MAC precondition: expected managed VAP state is unknown"
    return 1
  fi
  [ -n "$pairs" ] || return 0

  while IFS=' ' read -r iface vid; do
    [ -n "$iface" ] && [ -n "$vid" ] || continue

    if [ ! -d "/sys/class/net/$iface" ]; then
      warn -c vlan "MAC precondition: $iface not in sysfs — wireless not yet settled"
      ok=0
      continue
    fi

    checked=$((checked + 1))

    if [ -e "/sys/class/net/br${vid}/brif/$iface" ]; then
      if [ -e "/sys/class/net/br0/brif/$iface" ]; then
        warn -c vlan "MAC precondition: $iface is in both br${vid} and br0 — inconsistent state"
        ok=0
      fi
      continue
    fi

    if [ -e "/sys/class/net/br0/brif/$iface" ]; then
      warn -c vlan "MAC precondition: $iface expected br${vid} but found in br0"
    else
      warn -c vlan "MAC precondition: $iface expected br${vid} but found in neither bridge"
    fi
    ok=0
  done <<_PAIRS_
$pairs
_PAIRS_

  [ "$checked" -eq 0 ] && [ "$ok" -eq 1 ] && return 0
  [ "$ok" -eq 1 ]
}

# ============================================================================
# merv_mac_append_own_candidate <mac> <output>
# Add one exact local interface identity and its exact IEEE U/L-bit pair.
# ============================================================================
merv_mac_append_own_candidate() {
  local _mmaoc_mac _mmaoc_out="$2" _mmaoc_pair
  _mmaoc_mac=$(mervqt_mac_lower "$1" 2>/dev/null || printf '')
  mervqt_valid_mac "$_mmaoc_mac" || return 0

  printf '%s\n' "$_mmaoc_mac" >> "$_mmaoc_out" || return 1
  _mmaoc_pair=$(printf '%s\n' "$_mmaoc_mac" | awk -F: '
    BEGIN { OFS=":"; h="0123456789abcdef" }
    function hv(c){ return index(h,c)-1 }
    function hd(n){ return substr(h,n+1,1) }
    {
      v=hv(substr($1,1,1))*16 + hv(substr($1,2,1))
      if (int(v/2)%2) v-=2; else v+=2
      $1=hd(int(v/16)) hd(v%16)
      print
    }')
  [ -n "$_mmaoc_pair" ] && printf '%s\n' "$_mmaoc_pair" >> "$_mmaoc_out"
  return 0
}

# ============================================================================
# merv_mac_build_own_exclude <output>
# Build the exact local interface/VAP exclusion set once per collector call.
# ============================================================================
merv_mac_build_own_exclude() {
  local _mmboc_out="$1" _mmboc_root="${MERV_SYS_CLASS_NET_ROOT:-/sys/class/net}"
  local _mmboc_tmp="${_mmboc_out}.tmp.$$" _mmboc_path _mmboc_br_path
  local _mmboc_br _mmboc_mac _mmboc_iface
  local _mmboc_rc=0

  : > "$_mmboc_tmp" || return 1

  # Kernel interface addresses are the primary authoritative source.
  for _mmboc_path in "$_mmboc_root"/*/address; do
    [ -f "$_mmboc_path" ] || continue
    _mmboc_mac=$(cat "$_mmboc_path" 2>/dev/null || printf '')
    merv_mac_append_own_candidate "$_mmboc_mac" "$_mmboc_tmp" || _mmboc_rc=1
  done

  # Bridge-local FDB entries cover firmware identities not exposed consistently
  # through sysfs on every ASUS/Broadcom build.
  if type brctl >/dev/null 2>&1; then
    for _mmboc_br_path in "$_mmboc_root"/br[0-9]*/brif; do
      [ -d "$_mmboc_br_path" ] || continue
      _mmboc_br="${_mmboc_br_path%/brif}"
      _mmboc_br="${_mmboc_br##*/}"
      brctl showmacs "$_mmboc_br" 2>/dev/null |
        while IFS=' ' read -r _mmboc_pno _mmboc_mac _mmboc_local _mmboc_rest; do
          [ "$_mmboc_local" = yes ] || continue
          merv_mac_append_own_candidate "$_mmboc_mac" "$_mmboc_tmp" || :
        done
    done
  fi

  # Broadcom VAP commands can expose an identity that differs from sysfs.
  # Query them once while building the cached set.
  if type wl >/dev/null 2>&1; then
    for _mmboc_path in "$_mmboc_root"/wl[0-9]*.*; do
      [ -d "$_mmboc_path" ] || continue
      _mmboc_iface="${_mmboc_path##*/}"
      {
        cat "$_mmboc_path/address" 2>/dev/null
        wl -i "$_mmboc_iface" cur_etheraddr 2>/dev/null
        wl -i "$_mmboc_iface" perm_etheraddr 2>/dev/null
        wl -i "$_mmboc_iface" bssid 2>/dev/null
      } | awk '{
        for (i=1;i<=NF;i++) {
          m=tolower($i)
          if (m ~ /^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$/) print m
        }
      }' | while IFS= read -r _mmboc_mac; do
        merv_mac_append_own_candidate "$_mmboc_mac" "$_mmboc_tmp" || :
      done
    done
  fi

  sort -u "$_mmboc_tmp" > "$_mmboc_out" 2>/dev/null || {
    cp "$_mmboc_tmp" "$_mmboc_out" 2>/dev/null || _mmboc_rc=1
  }
  rm -f "$_mmboc_tmp" 2>/dev/null || _mmboc_rc=1
  return "$_mmboc_rc"
}

merv_mac_is_own_interface() {
  local _mmio_mac="$1" _mmio_file="$2"
  [ -f "$_mmio_file" ] || return 1
  _mmio_mac=$(mervqt_mac_lower "$_mmio_mac" 2>/dev/null || printf '')
  awk -v m="$_mmio_mac" '$0 == m { found=1; exit } END { exit found ? 0 : 1 }' "$_mmio_file"
}

# ============================================================================
# merv_mac_build_snapshot <tmpfile>
# Scan all VLAN bridges (br<VID>) for wl*.* members, run wl assoclist on
# each, write client records to <tmpfile>.
# Format: <epoch_ts> <mac_lowercase> <wl_iface> <vid>
# Prints the number of client records written to stdout (may be 0).
# ============================================================================
merv_mac_build_snapshot() {
  local tmpfile="$1"
  local br_path br_name vid iface_path iface mac now rep_iface _fdb_path _fdb_pno _fdb_iface
  local _mmbs_root="${MERV_SYS_CLASS_NET_ROOT:-/sys/class/net}" _mmbs_own_file _mmbs_count

  now=$(date +%s)
  : > "$tmpfile" || return 1
  _mmbs_own_file="${tmpfile}.own.$$"
  merv_mac_build_own_exclude "$_mmbs_own_file" || {
    rm -f "$_mmbs_own_file" 2>/dev/null || :
    return 1
  }

  for br_path in "$_mmbs_root"/br[1-9]*/brif; do
    [ -d "$br_path" ] || continue
    br_name="${br_path%/brif}"
    br_name="${br_name##*/}"
    vid="${br_name#br}"
    mervqt_valid_vid "$vid" || continue

    rep_iface=""
    for iface_path in "$br_path"/wl*.* "$br_path"/ra*.* "$br_path"/ath*.*; do
      [ -e "$iface_path" ] || continue
      iface="${iface_path##*/}"
      mervqt_valid_wl_subif "$iface" || continue
      [ -n "$rep_iface" ] || rep_iface="$iface"

      wl -i "$iface" assoclist 2>/dev/null | while IFS=' ' read -r _kw mac; do
        [ "$_kw" = "assoclist" ] || continue
        [ -n "$mac" ] || continue
        mac=$(mervqt_mac_lower "$mac")
        mervqt_valid_mac "$mac" || continue
        merv_mac_is_own_interface "$mac" "$_mmbs_own_file" && continue
        printf '%s %s %s %s\n' "$now" "$mac" "$iface" "$vid"
      done
    done

    # Supplement assoclist with the bridge forwarding database, but only for
    # MACs actually learned on a wireless VAP port. A VLAN bridge also learns
    # upstream/trunk MACs on eth*.VID; treating every non-local FDB entry as a
    # wireless client can shield the upstream gateway itself on native br0.
    if [ -n "$rep_iface" ] && merv_has brctl; then
      brctl showmacs "$br_name" 2>/dev/null | while read -r _pno mac _islocal _rest; do
        case "$mac" in
          [0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:*) ;;
          *) continue ;;
        esac
        [ "$_islocal" = "no" ] || continue

        _fdb_iface=""
        for _fdb_path in "$_mmbs_root/$br_name/brif/"*; do
          [ -e "$_fdb_path/port_no" ] || continue
          _fdb_pno=$(cat "$_fdb_path/port_no" 2>/dev/null) || continue
          _fdb_pno=$((_fdb_pno))
          [ "$_fdb_pno" -eq "$_pno" ] 2>/dev/null || continue
          _fdb_iface="${_fdb_path##*/}"
          break
        done

        [ -n "$_fdb_iface" ] || continue

        # Only FDB entries actually learned on a wireless VAP belong in MERV_MAC.
        mervqt_valid_wl_subif "$_fdb_iface" || continue

        mac=$(mervqt_mac_lower "$mac")
        mervqt_valid_mac "$mac" || continue
        merv_mac_is_own_interface "$mac" "$_mmbs_own_file" && continue
        printf '%s %s %s %s\n' "$now" "$mac" "$_fdb_iface" "$vid"
      done
    fi
  done >> "$tmpfile"

  _mmbs_count=$(wc -l < "$tmpfile" 2>/dev/null | tr -d ' ')
  rm -f "$_mmbs_own_file" 2>/dev/null || :
  printf '%s\n' "$_mmbs_count"
}

# ============================================================================
# merv_mac_is_main
# Returns 0 when this unit is the main router (safe to drive cluster sync),
# 1 when running as a node or in node context. Mirrors the guard used by
# mac_refresh.sh so node-side runs never attempt outbound SSH.
# ============================================================================
merv_mac_is_main() {
  [ "${MERV_NODE_CONTEXT:-0}" != "1" ] || return 1
  [ ! -f "$MERV_BASE/.is_node" ] || return 1
  if type json_get_flag >/dev/null 2>&1; then
    [ "$(json_get_flag "IS_NODE" "0" "$SETTINGS_FILE" 2>/dev/null)" != "1" ] || return 1
  fi
  return 0
}

# ============================================================================
# merv_mac_node_list
# Emit "<node_id> <node_ip>" for each configured, valid node from settings.json.
# Standalone parser (this script does NOT source lib_json): NODE1..NODE<max>,
# skipping "none" and any non-IPv4 value. Empty output when no nodes configured.
# ============================================================================
merv_mac_node_list() {
  [ -n "$SETTINGS_FILE" ] && [ -f "$SETTINGS_FILE" ] || return 0
  grep -o '"NODE[0-9][0-9]*"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" 2>/dev/null | \
    sed -n 's/"NODE\([0-9][0-9]*\)"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1 \2/p' | \
    awk -v max="${MERV_MAX_NODES:-10}" \
      '$1>=1 && $1<=max && $2 != "none" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $1, $2 }'
}

# Shield is not allowed to observe, merge, enforce, or push while a generic
# node-operation pool still has any unresolved ownership metadata.  Prefer the
# shared predicate; retain a strict local fallback for legacy fixture callers
# that intentionally omit lib_node_jobs.sh.
merv_mac_pool_state_unresolved() {
  if type mnj_pool_state_unresolved >/dev/null 2>&1; then
    mnj_pool_state_unresolved
    _mmpsu_rc=$?
    case "$_mmpsu_rc" in 0) return 0 ;; 1) return 1 ;; *) return 0 ;; esac
  fi
  case "${MNJ_POOL_ACTIVE:-0}" in ''|0) ;; *) return 0 ;; esac
  [ -n "${MNJ_POOL_PENDING_PID:-}${MNJ_POOL_PENDING_START:-}${MNJ_POOL_PENDING_DIR:-}${MNJ_POOL_PENDING_NODE:-}" ] && return 0
  [ -n "${MNJ_S1_PID:-}${MNJ_S1_START:-}${MNJ_S1_DIR:-}${MNJ_S1_NODE:-}${MNJ_S1_DEADLINE:-}" ] && return 0
  [ -n "${MNJ_S2_PID:-}${MNJ_S2_START:-}${MNJ_S2_DIR:-}${MNJ_S2_NODE:-}${MNJ_S2_DEADLINE:-}" ] && return 0
  [ -n "${MNJ_S3_PID:-}${MNJ_S3_START:-}${MNJ_S3_DIR:-}${MNJ_S3_NODE:-}${MNJ_S3_DEADLINE:-}" ] && return 0
  [ -n "${MNJ_S4_PID:-}${MNJ_S4_START:-}${MNJ_S4_DIR:-}${MNJ_S4_NODE:-}${MNJ_S4_DEADLINE:-}" ] && return 0
  [ -n "${MNJ_S5_PID:-}${MNJ_S5_START:-}${MNJ_S5_DIR:-}${MNJ_S5_NODE:-}${MNJ_S5_DEADLINE:-}" ] && return 0
  return 1
}

# ============================================================================
# merv_mac_collect_from_node <node_id> <node_ip>
# Run a self-contained remote collector over one SSH connection and emit
# normalized "<now> <mac> <iface> <vid>" records on stdout (one per known
# client on the node's VLAN bridges). Uses the same assoclist + brctl FDB
# sources as the local snapshot. The remote script is passed verbatim (the
# here-doc is single-quoted so all $ expansion happens on the node), and all
# returned fields are re-validated locally before being trusted.
# Returns non-zero only on SSH failure; empty (clean) output is success.
# ============================================================================
merv_mac_collect_from_node() {
  local nid="$1" nip="$2" out now rcmd m i v
  now=$(date +%s)

rcmd=$(cat <<'REMOTE'
_remote_root="${MERV_SYS_CLASS_NET_ROOT:-/sys/class/net}"

_remote_append_own_candidate() {
  local _roac_mac _roac_pair
  _roac_mac=$(printf '%s' "$1" | tr 'A-F' 'a-f')
  case "$_roac_mac" in
    [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;;
    *) return 0 ;;
  esac
  printf '%s\n' "$_roac_mac"
  _roac_pair=$(printf '%s\n' "$_roac_mac" | awk -F: '
    BEGIN { OFS=":"; h="0123456789abcdef" }
    function hv(c){ return index(h,c)-1 }
    function hd(n){ return substr(h,n+1,1) }
    {
      v=hv(substr($1,1,1))*16 + hv(substr($1,2,1))
      if (int(v/2)%2) v-=2; else v+=2
      $1=hd(int(v/16)) hd(v%16)
      print
    }')
  [ -n "$_roac_pair" ] && printf '%s\n' "$_roac_pair"
}

_remote_build_own_macs() {
  _remote_own_macs=$(
    {
      for _rop in "$_remote_root"/*/address; do
        [ -f "$_rop" ] || continue
        cat "$_rop" 2>/dev/null
      done
      if type brctl >/dev/null 2>&1; then
        for _robp in "$_remote_root"/br[0-9]*/brif; do
          [ -d "$_robp" ] || continue
          _rob="${_robp%/brif}"; _rob="${_rob##*/}"
          brctl showmacs "$_rob" 2>/dev/null | awk '$3=="yes"{print $2}'
        done
      fi
      if type wl >/dev/null 2>&1; then
        for _rop in "$_remote_root"/wl[0-9]*.*; do
          [ -d "$_rop" ] || continue
          _roi="${_rop##*/}"
          cat "$_rop/address" 2>/dev/null
          wl -i "$_roi" cur_etheraddr 2>/dev/null
          wl -i "$_roi" perm_etheraddr 2>/dev/null
          wl -i "$_roi" bssid 2>/dev/null
        done
      fi
    } | awk '{
      for (i=1;i<=NF;i++) {
        m=tolower($i)
        if (m ~ /^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$/) print m
      }
    }' | while IFS= read -r _romac; do
      _remote_append_own_candidate "$_romac"
    done | sort -u
  )
}

_remote_mac_is_own() {
  printf '%s\n' "$_remote_own_macs" |
    awk -v m="$1" '$0 == m { found=1; exit } END { exit found ? 0 : 1 }'
}

_remote_build_own_macs

for b in "$_remote_root"/br[1-9]*/brif; do
  [ -d "$b" ] || continue
  n=${b%/brif}; n=${n##*/}; v=${n#br}
  case "$v" in ''|*[!0-9]*) continue ;; esac
  rep=""
  for p in "$b"/wl*.* "$b"/ra*.* "$b"/ath*.*; do
    [ -e "$p" ] || continue
    i=${p##*/}
    [ -n "$rep" ] || rep="$i"
    wl -i "$i" assoclist 2>/dev/null | while read -r k m; do
      [ "$k" = assoclist ] || continue
      [ -n "$m" ] || continue
      m=$(printf '%s' "$m" | tr 'A-F' 'a-f')
      case "$m" in
        [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;;
        *) continue ;;
      esac
      _remote_mac_is_own "$m" && continue
      echo "$m $i $v"
    done
  done
  [ -n "$rep" ] || continue
  type brctl >/dev/null 2>&1 || continue
  brctl showmacs "$n" 2>/dev/null | while read -r po m loc rest; do
    case "$m" in
      [0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]) ;;
      *) continue ;;
    esac
    [ "$loc" = no ] || continue
    m=$(printf '%s' "$m" | tr 'A-F' 'a-f')
    _remote_mac_is_own "$m" && continue

    src=""
    for pd in "$b"/*; do
      [ -e "$pd/port_no" ] || continue
      pn=$(cat "$pd/port_no" 2>/dev/null) || continue
      pn=$((pn))
      [ "$pn" -eq "$po" ] 2>/dev/null || continue
      src=${pd##*/}
      break
    done

    # Ignore uplink/trunk FDB entries. Only wireless VAP-learned MACs are clients.
    case "$src" in
      wl*.*|ra*.*|ath*.*) ;;
      *) continue ;;
    esac

    echo "$m $src $v"
  done
done
REMOTE
)

  out=$(merv_ssh_exec "$nid" "$nip" "$rcmd" 2>/dev/null) || return 1
  [ -n "$out" ] || return 0

  printf '%s\n' "$out" | while read -r m i v; do
    [ -n "$m" ] && [ -n "$i" ] && [ -n "$v" ] || continue
    m=$(mervqt_mac_lower "$m")
    mervqt_valid_mac "$m"       || continue
    mervqt_valid_wl_subif "$i"  || continue
    mervqt_valid_vid "$v"       || continue
    printf '%s %s %s %s\n' "$now" "$m" "$i" "$v"
  done
}

# ============================================================================
# merv_mac_collect_node_job <node_id> <node_ip>
# Pool worker wrapper.  A worker owns only its isolated payload; the parent
# validates the terminal result and every record before merging it into the
# authoritative snapshot file.
# ============================================================================
merv_mac_collect_node_job() {
  [ -n "${MERV_NODE_JOB_DIR:-}" ] || return 2
  _mmcnj_payload="$MERV_NODE_JOB_DIR/payload"
  : > "$_mmcnj_payload" || return 2
  merv_mac_collect_from_node "$1" "$2" > "$_mmcnj_payload"
}

# Validate and normalize one worker payload in the parent shell.  Invalid
# records make that node observation incomplete; no valid subset is merged.
# MERV_MAC_PAYLOAD_COUNT is intentionally parent-owned state.
merv_mac_validate_node_payload() {
  _mmvnp_payload="$1" _mmvnp_out="$2"
  [ -f "$_mmvnp_payload" ] || return 1
  : > "$_mmvnp_out" || return 1
  MERV_MAC_PAYLOAD_COUNT=0
  _mmvnp_valid=1
  while IFS=' ' read -r _mmvnp_ts _mmvnp_mac _mmvnp_iface _mmvnp_vid _mmvnp_extra ||
        [ -n "$_mmvnp_ts$_mmvnp_mac$_mmvnp_iface$_mmvnp_vid$_mmvnp_extra" ]; do
    [ -n "$_mmvnp_ts$_mmvnp_mac$_mmvnp_iface$_mmvnp_vid$_mmvnp_extra" ] || continue
    case "$_mmvnp_ts" in ''|*[!0-9]*) _mmvnp_valid=0; continue ;; esac
    [ -z "$_mmvnp_extra" ] || { _mmvnp_valid=0; continue; }
    _mmvnp_mac=$(mervqt_mac_lower "$_mmvnp_mac" 2>/dev/null || printf '')
    mervqt_valid_mac "$_mmvnp_mac" || { _mmvnp_valid=0; continue; }
    mervqt_valid_wl_subif "$_mmvnp_iface" || { _mmvnp_valid=0; continue; }
    mervqt_valid_vid "$_mmvnp_vid" || { _mmvnp_valid=0; continue; }
    printf '%s %s %s %s\n' "$_mmvnp_ts" "$_mmvnp_mac" "$_mmvnp_iface" "$_mmvnp_vid" >> "$_mmvnp_out" || return 1
    MERV_MAC_PAYLOAD_COUNT=$((MERV_MAC_PAYLOAD_COUNT + 1))
  done < "$_mmvnp_payload"
  [ "$_mmvnp_valid" -eq 1 ] || { rm -f "$_mmvnp_out" 2>/dev/null; return 1; }
  return 0
}

# Parent-only progress hook for either MAC node-pool phase.  Workers never
# mutate counters or public progress; they publish only isolated terminal
# state and payload files.
merv_mac_node_pool_progress() {
  _mmnpp_root="$1" _mmnpp_phase="$2"
  _mmnpp_total=${MERV_MAC_NODE_POOL_TOTAL:-0}; _mmnpp_done=0
  case "$_mmnpp_phase" in collect) _mmnpp_ui_phase=node_collect; _mmnpp_percent=45; _mmnpp_label="Collecting MAC clients from nodes" ;; push) _mmnpp_ui_phase=push; _mmnpp_percent=86; _mmnpp_label="Pushing MAC Shield to nodes" ;; *) return 0 ;; esac
  case "$_mmnpp_total" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_mmnpp_total" -gt 0 ] 2>/dev/null || return 0
  for _mmnpp_dir in "$_mmnpp_root"/node_*; do
    [ -d "$_mmnpp_dir" ] || continue
    _mmnpp_node=${_mmnpp_dir##*/node_}
    if type mnj_result_validate >/dev/null 2>&1 &&
       mnj_result_validate "$_mmnpp_dir/result" "$_mmnpp_node" "$_mmnpp_phase"; then
      _mmnpp_done=$((_mmnpp_done + 1))
    fi
  done
  _merv_mac_refresh_progress "$_mmnpp_ui_phase" "$_mmnpp_percent" "$_mmnpp_label — ${_mmnpp_done} of ${_mmnpp_total} complete."
}

# Pool worker for one node's atomic DB/override stream and remote Shield reload.
# All SSH scratch state is redirected by mnj_worker to this node's isolated job
# directory; the worker never mutates parent counters or public progress.
merv_mac_push_node() {
  _mmpp_nid="$1" _mmpp_configured_ip="$2"
  _mmpp_nip=$(merv_node_resolve_endpoint "$_mmpp_nid" "$_mmpp_configured_ip" 2>/dev/null) || {
    _merv_mac_log warn "MERV_MAC: node ${_mmpp_nid} endpoint resolution failed — db not pushed"
    return 1
  }
  [ -n "$_mmpp_nip" ] || return 1

  if ! merv_ssh_precheck "$_mmpp_nid" "$_mmpp_nip" >/dev/null 2>&1; then
    _merv_mac_log warn "MERV_MAC: node ${_mmpp_nip} precheck failed — db not pushed"
    return 1
  fi
  if ! merv_ssh_exec "$_mmpp_nid" "$_mmpp_nip" "mkdir -p '${MERV_MAC_DB_ACTIVE%/*}' '${MERV_MAC_OVERRIDE_DB%/*}'" >/dev/null 2>&1; then
    return 1
  fi
  if ! merv_ssh_stream_file "$_mmpp_nid" "$_mmpp_nip" "$MERV_MAC_DB_ACTIVE" "$MERV_MAC_DB_ACTIVE"; then
    _merv_mac_log warn "MERV_MAC: ✗ db push failed to node ${_mmpp_nip}"
    return 1
  fi

  # Push overrides before reload.  An empty override file clears stale node
  # state; a failed override stream remains best-effort as in the serial path.
  _mmpp_ovr_src="${MERV_MAC_OVERRIDE_DB:-/dev/null}"
  [ -f "$_mmpp_ovr_src" ] || _mmpp_ovr_src="/dev/null"
  if ! merv_ssh_stream_file "$_mmpp_nid" "$_mmpp_nip" "$_mmpp_ovr_src" "$MERV_MAC_OVERRIDE_DB"; then
    _merv_mac_log warn "MERV_MAC: override db push failed to node ${_mmpp_nip} (reloading anyway)"
  fi
  if ! merv_ssh_exec "$_mmpp_nid" "$_mmpp_nip" \
       "MERV_BASE='$MERV_BASE'; MERV_NODE_CONTEXT=1; "'. "$MERV_BASE/settings/var_settings.sh" 2>/dev/null; . "$MERV_BASE/settings/log_settings.sh" 2>/dev/null; . "$MERV_BASE/settings/lib_mervqt.sh" 2>/dev/null; ebt_mac_shield_init_and_apply "$MERV_MAC_DB_ACTIVE"' \
       >/dev/null 2>&1; then
    _merv_mac_log warn "MERV_MAC: db pushed but shield reload failed on node ${_mmpp_nip}"
    return 1
  fi
  _merv_mac_logv info "MERV_MAC: ✓ db pushed + shield reloaded on node ${_mmpp_nip}"
  return 0
}

merv_mac_push_node_job() {
  [ -n "${MERV_NODE_JOB_DIR:-}" ] || return 2
  merv_mac_push_node "$1" "$2"
}

# merv_mac_push_db_to_nodes "<node_id node_ip\n...>"
# Complete-set trust preflight remains serial.  The shared bounded pool then
# owns one isolated DB/override push+reload worker per node; this parent
# validates terminal results and aggregates counters/progress serially.
merv_mac_push_db_to_nodes() {
  _mmdp_nodes="$1"
  MERV_MAC_LAST_PUSH_TOTAL=0
  MERV_MAC_LAST_PUSH_OK=0
  MERV_MAC_LAST_PUSH_FAILED=0
  if merv_mac_pool_state_unresolved; then
    MERV_MAC_LAST_REASON="node_pool_unresolved"
    _merv_mac_log warn "MERV_MAC: node push blocked — prior node-operation pool state is unresolved"
    return 1
  fi
  ssh_keys_effectively_installed || return 1
  [ -n "${SSH_KEY:-}" ] && [ -f "$SSH_KEY" ] || return 1
  merv_has "${MERV_SSH_CLIENT:-dbclient}" || return 1
  [ -f "$MERV_MAC_DB_ACTIVE" ] || return 0

  _mmdp_preflight_ok=0
  if [ -n "${MERV_MAC_SNAPSHOT_PREFLIGHT_DIGEST:-}" ] && type merv_node_list_digest >/dev/null 2>&1; then
    _mmdp_current_digest=$(merv_node_list_digest 2>/dev/null || printf '')
    [ "$_mmdp_current_digest" = "$MERV_MAC_SNAPSHOT_PREFLIGHT_DIGEST" ] && _mmdp_preflight_ok=1
  fi
  if [ "$_mmdp_preflight_ok" -ne 1 ]; then
    type merv_ssh_preflight_node_lines >/dev/null 2>&1 || return 1
    merv_ssh_preflight_node_lines "$_mmdp_nodes" "$SETTINGS_FILE" || return 1
  fi

  _mmdp_now=$(date +%s 2>/dev/null || printf '%s' "$$")
  _mmdp_root="$TMPDIR/node_jobs/mac_push.$$.$_mmdp_now"
  _mmdp_nodes_file="$_mmdp_root/nodes"
  mkdir -p "$_mmdp_root" || return 1
  printf '%s\n' "$_mmdp_nodes" > "$_mmdp_nodes_file" || { rm -rf "$_mmdp_root" 2>/dev/null; return 1; }
  MERV_MAC_NODE_POOL_TOTAL=$(printf '%s\n' "$_mmdp_nodes" | awk 'NF { n++ } END { print n + 0 }')
  MNJ_POOL_PROGRESS_HOOK=merv_mac_node_pool_progress
  if type mnj_pool_run >/dev/null 2>&1; then
    mnj_pool_run "$_mmdp_root" push "${MERV_NODE_PARALLELISM:-}" "${MERV_MAC_NODE_PUSH_MAX_SEC:-720}" "$_mmdp_nodes_file" merv_mac_push_node_job
    _mmdp_pool_rc=$?
  else
    _mmdp_pool_rc=2
  fi
  MNJ_POOL_PROGRESS_HOOK=""
  # A setup/identity error can make the pool return before draining slots.
  # Reconcile pending and published workers through the shared identity-safe
  # abort path before reading results or removing the private root.
  if [ "${_mmdp_pool_rc:-2}" -ne 0 ] && type mnj_pool_abort_active >/dev/null 2>&1; then
    mnj_pool_abort_active failed parent-pool-error || :
  fi

  MERV_MAC_LAST_PUSH_TOTAL=0
  MERV_MAC_LAST_PUSH_OK=0
  MERV_MAC_LAST_PUSH_FAILED=0
  while IFS=' ' read -r _mmdp_nid _mmdp_nip _mmdp_extra || [ -n "$_mmdp_nid" ]; do
    [ -n "$_mmdp_nip" ] || continue
    MERV_MAC_LAST_PUSH_TOTAL=$((MERV_MAC_LAST_PUSH_TOTAL + 1))
    if [ -z "$_mmdp_extra" ] && type mnj_result_validate >/dev/null 2>&1 &&
       mnj_result_validate "$_mmdp_root/node_${_mmdp_nid}/result" "$_mmdp_nid" push &&
       [ "$MNJ_RESULT_STATE" = ok ]; then
      MERV_MAC_LAST_PUSH_OK=$((MERV_MAC_LAST_PUSH_OK + 1))
    else
      MERV_MAC_LAST_PUSH_FAILED=$((MERV_MAC_LAST_PUSH_FAILED + 1))
      _merv_mac_log warn "MERV_MAC: node ${_mmdp_nip} push/reload failed"
    fi
  done <<_MMDP_NODES_
$_mmdp_nodes
_MMDP_NODES_
  # An identity failure leaves MNJ_POOL_ACTIVE set and its private tree
  # retained for a safe retry; never remove a directory that may still contain
  # an authenticated child.
  if ! merv_mac_pool_state_unresolved; then
    rm -rf "$_mmdp_root" 2>/dev/null || :
  else
    _mmdp_pool_rc=1
    _merv_mac_log warn "MERV_MAC: retaining node push workspace while worker identity cleanup is pending"
  fi
  [ "$MERV_MAC_LAST_PUSH_FAILED" -eq 0 ] && [ "$_mmdp_pool_rc" -eq 0 ]
}

# ============================================================================
# merv_mac_merge_db <snapshot_tmpfile>
# Merge new snapshot into the existing active db.
#
# Semantics:
#   - Validates all 4 fields during merge
#   - One entry per MAC: latest timestamp wins
#   - Prunes entries older than MERV_MAC_MAX_AGE_SEC
#   - Atomic write to MERV_MAC_DB_ACTIVE (tmp + mv)
#   - Updates JFFS checkpoint only when content differs (md5 comparison)
#   - If merged result is empty: JFFS is also updated to empty so stale
#     checkpoints do not repopulate after reboot when all entries expired.
# ============================================================================
merv_mac_merge_db() {
  local snapshot="$1"
  local reset="${2:-0}"
  local work_tmp="${MERV_MAC_DB_ACTIVE}.merge.$$"
  local jffs_tmp="${MERV_MAC_DB_JFFS}.tmp.$$"
  local entry_count cksum_new cksum_old

  mkdir -p "$(dirname "$MERV_MAC_DB_ACTIVE")" 2>/dev/null || true

  {
    # Reset mode: snapshot only → new db. Normal mode: old db + snapshot → merge.
    [ "$reset" != "1" ] && [ -f "$MERV_MAC_DB_ACTIVE" ] && cat "$MERV_MAC_DB_ACTIVE" 2>/dev/null
    cat "$snapshot" 2>/dev/null
  } | awk \
      -v now="$(date +%s)" \
      -v max_age="$MERV_MAC_MAX_AGE_SEC" '
    NF == 4 {
      ts=$1; mac=$2; iface=$3; vid=$4

      if (ts !~ /^[0-9]+$/)          next
      if ((now - ts+0) > max_age+0)  next
      if (mac !~ /^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$/) next
      if (iface !~ /^(wl|ra|ath)[0-9]+\.[0-9]/) next
      if (vid !~ /^[0-9]+$/)         next
      if (vid+0 < 2 || vid+0 > 4094) next

      if (!(mac in best_ts) || ts+0 > best_ts[mac]+0) {
        best_ts[mac]  = ts
        best_rec[mac] = ts " " mac " " iface " " vid
      }
    }
    END { for (mac in best_rec) print best_rec[mac] }
  ' | sort -n > "$work_tmp" 2>/dev/null

  entry_count=$(wc -l < "$work_tmp" 2>/dev/null | tr -d ' ')

  mv "$work_tmp" "$MERV_MAC_DB_ACTIVE" 2>/dev/null || {
    rm -f "$work_tmp" 2>/dev/null
    warn -c vlan "MERV_MAC: merge failed — could not write active db"
    return 1
  }

  [ "${MERV_MAC_SNAPSHOT_VERBOSE:-0}" = "1" ] && _merv_mac_logv info "MERV_MAC: db merged — ${entry_count} entries"

  # JFFS checkpoint: compare structural fingerprint (mac+iface+vid) only.
  # Timestamps are refreshed on every snapshot, so a raw md5 would always
  # differ even when the same clients are on the same VLANs. We write to
  # JFFS only when the MAC set or their iface/VID assignments actually change.
  mkdir -p "$(dirname "$MERV_MAC_DB_JFFS")" 2>/dev/null || true
  cksum_new=$(awk '{print $2, $3, $4}' "$MERV_MAC_DB_ACTIVE" 2>/dev/null | sort | md5sum 2>/dev/null | cut -d' ' -f1)
  cksum_old=$(awk '{print $2, $3, $4}' "$MERV_MAC_DB_JFFS"   2>/dev/null | sort | md5sum 2>/dev/null | cut -d' ' -f1)
  if [ "$cksum_new" != "$cksum_old" ]; then
    if cp "$MERV_MAC_DB_ACTIVE" "$jffs_tmp" 2>/dev/null && \
       mv "$jffs_tmp" "$MERV_MAC_DB_JFFS" 2>/dev/null; then
      _merv_mac_log info "MERV_MAC: JFFS checkpoint updated (${entry_count} entries)"
    else
      rm -f "$jffs_tmp" 2>/dev/null
      _merv_mac_log warn "MERV_MAC: JFFS checkpoint update failed; active db remains valid but reboot may restore an older checkpoint"
    fi
  fi
}

# ============================================================================
# merv_mac_maybe_trigger_heal_on_precondition_fail
# Self-recovery hook called when snapshot preconditions fail (an expected VAP
# is missing from its bridge, in the wrong bridge, or detached entirely).
#
# Without this, periodic snapshot ticks would only log the precondition
# warning and clients on the detached VAP stayed unreachable until a manual
# reboot or another service event. We now queue a heal — strictly gated to
# avoid recursion or storms:
#   - Skip if mervlan_manager is currently applying config
#   - Gate on canonical vlan_event.lock owner state, never raw directory presence
#   - Per-(LOCKDIR) debounce: at most one trigger per MERV_MAC_HEAL_TRIGGER_DEBOUNCE
#     seconds (default 60s) regardless of how many snapshot ticks fire
# Heal is launched fire-and-forget so the snapshot caller is never blocked.
# ============================================================================
merv_mac_maybe_trigger_heal_on_precondition_fail() {
  local now last age debounce stamp _heal_lock _heal_state _heal_recheck

  # Honour explicit opt-out for users who want logs only.
  [ "${MERV_MAC_HEAL_TRIGGER:-1}" = "0" ] && return 0

  # Required directories / binaries
  [ -n "$LOCKDIR" ] || return 0
  [ -n "$MERV_BASE" ] || return 0
  [ -x "$MERV_BASE/functions/heal_event.sh" ] || return 0

  # Don't pile on a running apply — but never let a CRASHED manager (stale lock
  # directory with a dead/absent PID) suppress MERV_MAC-triggered recovery
  # forever. Use the shared lock-state helper; fall back to the blunt check if
  # lib_mervqt is somehow not loaded in this context.
  if type merv_owner_lock_state >/dev/null 2>&1; then
    case "$(merv_owner_lock_state "$LOCKDIR/mervlan_manager.lock")" in
      live|unknown|malformed|incomplete-grace|incomplete-expired|incomplete-unknown)
        info -c vlan "MERV_MAC: precondition fail — heal not queued (mervlan_manager active)"
        return 0
        ;;
      dead|reused)
        warn -c vlan "MERV_MAC: mervlan_manager.lock stale — ignoring for heal trigger"
        ;;
    esac
  elif [ -d "$LOCKDIR/mervlan_manager.lock" ]; then
    info -c vlan "MERV_MAC: precondition fail — heal not queued (mervlan_manager active)"
    return 0
  fi

  # Canonical owner-v2 state governs event recovery.  Reclaim only a complete
  # dead/reused owner through its quarantine path; malformed, incomplete, and
  # unverifiable claims block healing rather than looking absent.
  _heal_lock="$LOCKDIR/vlan_event.lock"
  if ! type merv_owner_lock_state >/dev/null 2>&1; then
    warn -c vlan "MERV_MAC: precondition fail - recovery blocked (canonical event-owner state unavailable)"
    return 1
  fi
  _heal_state=$(merv_owner_lock_state "$_heal_lock" 2>/dev/null || printf 'unknown')
  case "$_heal_state" in
    absent)
      ;;
    live|incomplete-grace)
      info -c vlan "MERV_MAC: precondition fail - heal not queued (event owner=$_heal_state)"
      return 0
      ;;
    dead|reused)
      # A replacement between state read and reconciliation remains protected.
      _heal_recheck=$(merv_owner_lock_state "$_heal_lock" 2>/dev/null || printf 'unknown')
      if [ "$_heal_recheck" != "$_heal_state" ]; then
        case "$_heal_recheck" in
          absent) ;;
          live|incomplete-grace)
            info -c vlan "MERV_MAC: precondition fail - heal not queued (event owner replaced=$_heal_recheck)"
            return 0
            ;;
          *)
            warn -c vlan "MERV_MAC: precondition fail - recovery blocked (event owner changed to $_heal_recheck)"
            return 1
            ;;
        esac
      else
        if ! merv_owner_lock_quarantine "$_heal_lock" "$_heal_state"; then
          warn -c vlan "MERV_MAC: precondition fail - recovery blocked (could not reconcile stale event owner=$_heal_state)"
          return 1
        fi
        _heal_recheck=$(merv_owner_lock_state "$_heal_lock" 2>/dev/null || printf 'unknown')
        if [ "$_heal_recheck" != absent ]; then
          warn -c vlan "MERV_MAC: precondition fail - recovery blocked (event owner reconciliation left $_heal_recheck)"
          return 1
        fi
      fi
      ;;
    incomplete-expired|incomplete-unknown|malformed|unknown|*)
      warn -c vlan "MERV_MAC: precondition fail - recovery blocked (event owner=$_heal_state; manual reconciliation required)"
      return 1
      ;;
  esac

  debounce="${MERV_MAC_HEAL_TRIGGER_DEBOUNCE:-60}"
  case "$debounce" in ''|*[!0-9]*) debounce=60 ;; esac
  stamp="$LOCKDIR/mac_precondition_heal.last"
  now=$(date +%s 2>/dev/null || echo 0)
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  last=$(cat "$stamp" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  age=$(( now - last ))
  if [ "$last" -gt 0 ] && [ "$age" -lt "$debounce" ]; then
    info -c vlan "MERV_MAC: precondition fail — heal trigger debounced (last=${age}s ago, window=${debounce}s)"
    return 0
  fi

  printf '%s\n' "$now" > "$stamp" 2>/dev/null || :
  info -c vlan "MERV_MAC: precondition fail — queueing heal_event [mac_precondition_orphan]"
  ( sh "$MERV_BASE/functions/heal_event.sh" "mac_precondition_orphan" ) >/dev/null 2>&1 &
  return 0
}

# ============================================================================
# _merv_mac_set_counts
# Stamp all count-style status globals from the current merv_mac_snapshot
# locals. MUST be called only from within merv_mac_snapshot (it reads that
# function's locals via POSIX dynamic scope) and immediately before any return
# that occurs AFTER the local/node counts are known, so inline callers
# (mac_refresh.sh) always read a coherent snapshot of what happened.
# Not meaningful from any other caller.
# ============================================================================
_merv_mac_set_counts() {
  MERV_MAC_LAST_LOCAL_COUNT=${client_count:-0}
  MERV_MAC_LAST_NODE_COUNT=${_node_total:-0}
  MERV_MAC_LAST_TOTAL_COUNT=${total_count:-0}
  MERV_MAC_LAST_NODES_TOTAL=${_nodes_total:-0}
  MERV_MAC_LAST_NODES_OK=${_nodes_ok:-0}
  MERV_MAC_LAST_NODES_FAILED=${_nodes_failed:-0}
  MERV_MAC_LAST_DB_COUNT=$(wc -l < "$MERV_MAC_DB_ACTIVE" 2>/dev/null | tr -d ' ')
  MERV_MAC_LAST_DB_COUNT=${MERV_MAC_LAST_DB_COUNT:-0}
}

# ============================================================================
# merv_mac_snapshot
# Full snapshot orchestration. Called from an async subshell after the
# post_rc_watchdog correction window closes (cron/manager), or inline from the
# manual MAC Refresh (mac_refresh.sh) which reads the MERV_MAC_LAST_* globals.
#
# Behaviour flags (env, normalized once at entry):
#   MERV_MAC_SNAPSHOT_RESET        — rebuild db from snapshot only (no old fold-in)
#   MERV_MAC_SNAPSHOT_ALLOW_EMPTY  — allow committing an intentionally empty db
#   MERV_MAC_SNAPSHOT_FORCE_RELOAD — reapply shield even when MAC set unchanged
#                                    (implied by RESET)
#   MERV_MAC_SNAPSHOT_VERBOSE      — step-trace logging
#   MERV_MAC_SNAPSHOT_LOG_CHANNELS — log channel set (default vlan; manual cli,vlan)
#   MERV_MAC_SNAPSHOT_LOG_UNCHANGED— log even on unchanged cron ticks
#
# Safety: destructive reset (snapshot-only rebuild / intentional empty clear)
# happens ONLY on a complete cluster observation — all configured nodes
# collected, SSH toolchain present, zero collection failures. Any incompleteness
# downgrades to a non-destructive merge while still honouring the reload intent.
#
# Steps:
#   1. Lock + precondition check
#   2. Build local snapshot
#   3. Cluster collect (track ok/failed/incomplete)
#   4. Derive effective reset (downgrade to merge if observation incomplete)
#   5. Empty handling (intentional clear vs preserve)
#   6. Merge (reset or fold-in) + fingerprint diff
#   7. Reload local shield on change OR force-reload; push to nodes
#   8. Set MERV_MAC_LAST_* status globals + summary log
# ============================================================================
merv_mac_snapshot() {
  [ "${DRY_RUN:-no}" = "yes" ] && return 0

  # An unresolved pool is a hard stop.  In particular, do this before the
  # Shield lock, local collection, database merge, or any replacement pool
  # setup so retained worker metadata/workspaces remain authoritative.
  if merv_mac_pool_state_unresolved; then
    MERV_MAC_LAST_STATUS="pool_unresolved"; MERV_MAC_LAST_REASON="node_pool_unresolved"
    MERV_MAC_LAST_LOCAL_COUNT=0; MERV_MAC_LAST_NODE_COUNT=0
    MERV_MAC_LAST_TOTAL_COUNT=0; MERV_MAC_LAST_DB_COUNT=0
    MERV_MAC_LAST_CHANGED=0
    MERV_MAC_LAST_NODES_TOTAL=0; MERV_MAC_LAST_NODES_OK=0; MERV_MAC_LAST_NODES_FAILED=0
    MERV_MAC_LAST_PUSH_TOTAL=0; MERV_MAC_LAST_PUSH_OK=0; MERV_MAC_LAST_PUSH_FAILED=0
    _merv_mac_log warn "MERV_MAC: snapshot blocked — prior node-operation pool state is unresolved"
    return 1
  fi

  _merv_mac_refresh_progress preflight 15 \
    "Verifying MAC Shield interfaces and node access..."

  # --- Snapshot mutual-exclusion (unified lock primitives) -----------------
  # A single mac_snapshot.lock serializes every MAC snapshot path: the cron
  # tick (heal_event.sh), the post-apply async snapshot (mervlan_manager.sh)
  # and the manual MAC Refresh (mac_refresh.sh). This function now owns the
  # entire destructive critical section (reset/empty clear happen here), so
  # callers no longer pre-acquire this lock — we take it non-blocking and skip
  # the tick on contention. Best-effort: if the lock primitives are unavailable
  # we proceed unguarded rather than block a security-relevant rebuild.
  local _snap_lock="${LOCKDIR:-/tmp/mervlan_tmp/locks}/mac_snapshot.lock"
  local _snap_owned=0
  local _snap_nonce=""
  if type merv_owner_lock_acquire >/dev/null 2>&1; then
    if merv_owner_lock_acquire "$_snap_lock" "${MERV_MAC_SNAPSHOT_LOCK_STALE_SEC:-60}" 0 "mac_snapshot"; then
      _snap_owned=1
      _snap_nonce="${MERV_LOCK_NONCE:-}"
    else
      # Pre-build return: counts legitimately stay at their zero-init values —
      # nothing was observed. Do NOT call _merv_mac_set_counts here.
      MERV_MAC_LAST_STATUS="busy"
      _merv_mac_logv info "MERV_MAC: snapshot skipped — another snapshot/refresh in progress"
      return 0
    fi
  fi

  # --- Reset per-run status globals ----------------------------------------
  MERV_MAC_LAST_STATUS="";  MERV_MAC_LAST_REASON=""
  MERV_MAC_LAST_LOCAL_COUNT=0; MERV_MAC_LAST_NODE_COUNT=0
  MERV_MAC_LAST_TOTAL_COUNT=0; MERV_MAC_LAST_DB_COUNT=0
  MERV_MAC_SNAPSHOT_PREFLIGHT_DIGEST=""
  MERV_MAC_LAST_CHANGED=0
  MERV_MAC_LAST_NODES_TOTAL=0; MERV_MAC_LAST_NODES_OK=0; MERV_MAC_LAST_NODES_FAILED=0
  MERV_MAC_LAST_PUSH_TOTAL=0;  MERV_MAC_LAST_PUSH_OK=0;  MERV_MAC_LAST_PUSH_FAILED=0

  # --- Normalize boolean flags once (use _snap_* locals throughout) --------
  local _snap_reset _snap_allow_empty _snap_verbose _snap_log_unchanged _snap_force_reload
  case "${MERV_MAC_SNAPSHOT_RESET:-0}"         in 1|yes|true|on) _snap_reset=1         ;; *) _snap_reset=0         ;; esac
  case "${MERV_MAC_SNAPSHOT_ALLOW_EMPTY:-0}"   in 1|yes|true|on) _snap_allow_empty=1   ;; *) _snap_allow_empty=0   ;; esac
  case "${MERV_MAC_SNAPSHOT_VERBOSE:-0}"       in 1|yes|true|on) _snap_verbose=1       ;; *) _snap_verbose=0       ;; esac
  case "${MERV_MAC_SNAPSHOT_LOG_UNCHANGED:-0}" in 1|yes|true|on) _snap_log_unchanged=1 ;; *) _snap_log_unchanged=0 ;; esac
  # RESET implies FORCE_RELOAD (user clicked refresh → reapply regardless of
  # whether the rebuilt MAC set differs). Otherwise honour the explicit flag.
  if [ "$_snap_reset" = "1" ]; then
    _snap_force_reload=1
  else
    case "${MERV_MAC_SNAPSHOT_FORCE_RELOAD:-0}" in 1|yes|true|on) _snap_force_reload=1 ;; *) _snap_force_reload=0 ;; esac
  fi

  if ! merv_mac_snapshot_preconditions_ok; then
    # Pre-build return: counts stay zero-init (no observation occurred).
    MERV_MAC_LAST_STATUS="precondition_failed"
    MERV_MAC_LAST_REASON="interfaces_not_settled"
    _merv_mac_log warn "MERV_MAC: snapshot skipped — interfaces not fully settled (db unchanged)"
    merv_mac_maybe_trigger_heal_on_precondition_fail
    if [ "$_snap_owned" = 1 ]; then
      merv_owner_lock_release "$_snap_lock" "$_snap_nonce" || return 1
      _snap_owned=0
    fi
    return 0
  fi

  # Resolve and verify the complete configured node set before capturing the
  # local snapshot or changing local MAC-shield state. A node list that cannot
  # be fully probed is a hard preflight failure, not an incomplete observation
  # that can be silently merged.
  local _nodes="" _nodes_total=0 _nodes_ok=0 _nodes_failed=0 _node_total=0
  local _node_collect_incomplete=0 _node_pool_root="" _node_pool_nodes="" _node_pool_rc=2
  local _nid _nip _node_extra _node_dir _node_candidate _node_combined _rc _node_result_ok
  if [ "${MERV_MAC_NODE_SYNC:-1}" = "1" ] && merv_mac_is_main; then
    _nodes=$(merv_mac_node_list)
    if [ -n "$_nodes" ]; then
      if type merv_ssh_preflight_grant_fresh >/dev/null 2>&1 && merv_ssh_preflight_grant_fresh; then
        _merv_mac_logv info "MERV_MAC: reusing the current SSH host-key preflight"
      elif ! merv_ssh_preflight_node_lines "$_nodes" "$SETTINGS_FILE"; then
        MERV_MAC_LAST_STATUS="preflight_failed"
        MERV_MAC_LAST_REASON="ssh_trust_required"
        _merv_mac_log warn "MERV_MAC: snapshot blocked — complete SSH trust preflight failed"
        if [ "$_snap_owned" = 1 ]; then
          merv_owner_lock_release "$_snap_lock" "$_snap_nonce" || :
          _snap_owned=0
        fi
        return 1
      fi
      if type merv_node_list_digest >/dev/null 2>&1; then
        MERV_MAC_SNAPSHOT_PREFLIGHT_DIGEST=$(merv_node_list_digest 2>/dev/null || printf '')
      fi
    fi
  fi

  local snap_tmp="${MERV_MAC_DB_ACTIVE}.snap.$$"
  local client_count

  _merv_mac_refresh_progress local_collect 25 \
    "Collecting MAC clients from MAIN..."

  client_count=$(merv_mac_build_snapshot "$snap_tmp")

  _merv_mac_refresh_progress local_collect 35 \
    "MAIN collection complete — ${client_count:-0} record(s)."
    _merv_mac_logv info "MERV_MAC: local snapshot captured ${client_count:-0} record(s)"

  # --- Cluster collection --------------------------------------------------
  # When running on the main with node sync enabled, gather client MACs from
  # every configured node and fold them into this snapshot. Node failures are
  # non-fatal for protection but DO mark the observation incomplete, which
  # blocks any destructive reset below.
  if [ "${MERV_MAC_NODE_SYNC:-1}" = "1" ] && merv_mac_is_main; then
    if [ -n "$_nodes" ]; then
      # Nodes are configured (read from settings.json, no SSH needed). If the
      # SSH toolchain is unavailable we cannot observe them at all — treat that
      # as an incomplete cluster observation, NOT as "zero failures".
      if ! ssh_keys_effectively_installed || [ -z "${SSH_KEY:-}" ] || [ ! -f "${SSH_KEY:-}" ]; then
        _node_collect_incomplete=1
        _merv_mac_log warn "MERV_MAC: node sync on with configured node(s) but SSH keys unavailable — cluster observation incomplete"
      else
        # Remote observations run through the shared bounded pool.  Workers
        # write only their isolated payload/result; this parent validates and
        # merges each complete node payload serially.
        _node_pool_root="$TMPDIR/node_jobs/mac_collect.$$.$(date +%s 2>/dev/null || printf '%s' "$$")"
        _node_pool_nodes="$_node_pool_root/nodes"
        if ! mkdir -p "$_node_pool_root" || ! printf '%s\n' "$_nodes" > "$_node_pool_nodes"; then
          _node_collect_incomplete=1
          _merv_mac_log warn "MERV_MAC: could not create isolated node collection workspace"
        else
          MERV_MAC_NODE_POOL_TOTAL=$(printf '%s\n' "$_nodes" | awk 'NF { n++ } END { print n + 0 }')
          MNJ_POOL_PROGRESS_HOOK=merv_mac_node_pool_progress
          if type mnj_pool_run >/dev/null 2>&1; then
            mnj_pool_run "$_node_pool_root" collect "${MERV_NODE_PARALLELISM:-}" "${MERV_MAC_NODE_COLLECT_MAX_SEC:-180}" "$_node_pool_nodes" merv_mac_collect_node_job
            _node_pool_rc=$?
          else
            _node_pool_rc=2
          fi
          MNJ_POOL_PROGRESS_HOOK=""
          if [ "${_node_pool_rc:-2}" -ne 0 ] && type mnj_pool_abort_active >/dev/null 2>&1; then
            mnj_pool_abort_active failed parent-pool-error || :
          fi
          [ "${_node_pool_rc:-2}" -eq 0 ] || _node_collect_incomplete=1

          while IFS=' ' read -r _nid _nip _node_extra || [ -n "$_nid" ]; do
            [ -n "$_nip" ] || continue
            _nodes_total=$(( _nodes_total + 1 ))
            _node_dir="$_node_pool_root/node_${_nid}"
            _node_candidate="$_node_pool_root/candidate_${_nid}"
            _node_combined="${snap_tmp}.node_${_nid}.$$"
            _node_result_ok=0
            if [ -z "$_node_extra" ] && type mnj_result_validate >/dev/null 2>&1 &&
               mnj_result_validate "$_node_dir/result" "$_nid" collect &&
               [ "$MNJ_RESULT_STATE" = ok ] &&
               merv_mac_validate_node_payload "$_node_dir/payload" "$_node_candidate"; then
              _node_result_ok=1
            fi
            if [ "$_node_result_ok" -eq 1 ]; then
              _rc=$(wc -l < "$_node_candidate" 2>/dev/null | tr -d ' ')
              _rc=${_rc:-0}
              # Publish the parent snapshot append atomically so a disk/write
              # failure cannot leave a partial subset from an otherwise failed
              # node observation.
              if cat "$snap_tmp" "$_node_candidate" > "$_node_combined" &&
                 mv "$_node_combined" "$snap_tmp" 2>/dev/null; then
                _nodes_ok=$((_nodes_ok + 1))
              else
                rm -f "$_node_combined" 2>/dev/null || :
                _node_result_ok=0
              fi
              if [ "$_node_result_ok" -eq 1 ]; then
                _node_total=$((_node_total + _rc))
                _merv_mac_logv info "MERV_MAC: node ${_nip} — ${_rc} record(s)"
                _merv_mac_refresh_progress node_collect 45 "NODE${_nid} collection complete — ${_rc} record(s)."
              fi
            fi
            if [ "$_node_result_ok" -ne 1 ]; then
              _nodes_failed=$((_nodes_failed + 1))
              _node_collect_incomplete=1
              _merv_mac_logv warn "MERV_MAC: node ${_nip} — SSH/collector/payload validation failed"
            fi
            rm -f "$_node_candidate" 2>/dev/null || :
            rm -f "$_node_combined" 2>/dev/null || :
          done <<_NODES_
$_nodes
_NODES_
        fi
        if ! merv_mac_pool_state_unresolved; then
          rm -rf "${_node_pool_root:-}" 2>/dev/null || :
          _node_pool_root=""
          _node_pool_nodes=""
        else
          _node_collect_incomplete=1
          _merv_mac_log warn "MERV_MAC: retaining node collection workspace while worker identity cleanup is pending"
        fi
      fi
    fi
  fi

  # A pool setup/identity failure may retain active ownership even after the
  # parent has collected what it can.  Do not merge/build or proceed to local
  # enforcement while that generic state remains unresolved.
  if merv_mac_pool_state_unresolved; then
    MERV_MAC_LAST_STATUS="pool_unresolved"; MERV_MAC_LAST_REASON="node_pool_unresolved"
    _merv_mac_log warn "MERV_MAC: snapshot blocked — node-operation cleanup remains unresolved"
    rm -f "$snap_tmp" 2>/dev/null || :
    # Keep the Shield lock owned while generic worker state is unresolved;
    # releasing it would permit a competing snapshot to race retained workers.
    return 1
  fi

  # --- Derive effective reset ----------------------------------------------
  # User intent is _snap_reset, but destructive (snapshot-only) behaviour only
  # executes on a COMPLETE cluster observation. Any node collection failure or
  # an unobservable cluster downgrades to merge mode so older cluster MACs from
  # the existing db are preserved. _snap_force_reload stays tied to _snap_reset
  # so the shield is still reapplied at the user's request.
  local _effective_reset=0
  if [ "$_snap_reset" = "1" ]; then
    if [ "${_nodes_failed:-0}" -gt 0 ] || [ "${_node_collect_incomplete:-0}" -eq 1 ]; then
      _effective_reset=0
      MERV_MAC_LAST_REASON="incomplete_node_observation"
      _merv_mac_log warn "MERV_MAC: reset requested but cluster observation incomplete — falling back to merge mode to preserve cluster MACs"
    else
      _effective_reset=1
    fi
  fi

  local total_count
  total_count=$(wc -l < "$snap_tmp" 2>/dev/null | tr -d ' ')
  _merv_mac_refresh_progress merge 55 \
    "Combining ${total_count:-0} observed MAC record(s)..."

  # --- Empty snapshot handling ---------------------------------------------
  if [ "${total_count:-0}" -eq 0 ]; then
    if [ "$_effective_reset" = "1" ] && [ "$_snap_allow_empty" = "1" ]; then
      # Complete observation (effective reset survived the completeness gate),
      # zero clients found, and the caller permits an empty commit. Clear both
      # active db and JFFS checkpoint so a reboot does not resurrect old MACs.
      # Active-db clear is enforcement-critical → hard failure path. JFFS clear
      # is reboot persistence only → warning on failure.
      local _ae_act _ae_jffs _jffs_clear_ok
      _ae_act="${MERV_MAC_DB_ACTIVE}.empty.$$"
      mkdir -p "$(dirname "$MERV_MAC_DB_ACTIVE")" 2>/dev/null || true
      if : > "$_ae_act" && mv "$_ae_act" "$MERV_MAC_DB_ACTIVE" 2>/dev/null; then
        mkdir -p "$(dirname "$MERV_MAC_DB_JFFS")" 2>/dev/null || true
        _ae_jffs="${MERV_MAC_DB_JFFS}.empty.$$"
        _jffs_clear_ok=0
        if : > "$_ae_jffs" && mv "$_ae_jffs" "$MERV_MAC_DB_JFFS" 2>/dev/null; then
          _jffs_clear_ok=1
        else
          rm -f "$_ae_jffs" 2>/dev/null
          _merv_mac_log warn "MERV_MAC: reset — JFFS checkpoint clear failed; active db remains valid but reboot may restore an older checkpoint"
        fi
        if ! ebt_mac_shield_init_and_apply "$MERV_MAC_DB_ACTIVE"; then
          MERV_MAC_LAST_STATUS="apply_failed"; MERV_MAC_LAST_REASON="reset_local_enforcement_failed"
          _merv_mac_set_counts
          MERV_MAC_LAST_DB_COUNT=0
          _merv_mac_log warn "MERV_MAC: reset committed but local shield enforcement failed (reason=$MERV_MAC_LAST_REASON); recovery is required"
          rm -f "$snap_tmp" 2>/dev/null
          if [ "$_snap_owned" = 1 ]; then
            merv_owner_lock_release "$_snap_lock" "$_snap_nonce" || return 1
            _snap_owned=0
          fi
          return 1
        fi
        # The empty active database is still an authoritative Shield state.
        # Propagate it only after MAIN enforcement succeeds, using the same
        # bounded push/reload pool as non-empty snapshots.  Push failures remain
        # reflected in the push counters and per-node warnings, matching the
        # existing normal-path best-effort propagation contract.
        if [ -n "$_nodes" ]; then
          _merv_mac_refresh_progress push 82 \
            "Pushing empty MAC Shield database and rules to nodes..."
          if ! merv_mac_push_db_to_nodes "$_nodes"; then
            if merv_mac_pool_state_unresolved; then
              MERV_MAC_LAST_STATUS="push_failed"; MERV_MAC_LAST_REASON="node_pool_unresolved"
              _merv_mac_log warn "MERV_MAC: empty Shield push blocked — node-operation cleanup remains unresolved"
              rm -f "$snap_tmp" 2>/dev/null || :
              # Retain Shield ownership and the push workspace until the
              # generic pool can be reconciled by its owning parent.
              return 1
            fi
          fi
        fi
        MERV_MAC_LAST_STATUS="empty"; MERV_MAC_LAST_REASON="reset_no_clients"
        _merv_mac_set_counts
        MERV_MAC_LAST_DB_COUNT=0
        if [ "$_jffs_clear_ok" = "1" ]; then
          _merv_mac_log info "MERV_MAC: reset — no clients present; active db and JFFS checkpoint cleared"
        else
          _merv_mac_log info "MERV_MAC: reset — no clients present; active db cleared; JFFS checkpoint not updated"
        fi
      else
        rm -f "$_ae_act" 2>/dev/null
        MERV_MAC_LAST_STATUS="clear_failed"; MERV_MAC_LAST_REASON="active_db_write_error"
        _merv_mac_set_counts
        _merv_mac_log warn "MERV_MAC: reset — failed to clear active db; existing db preserved"
      fi
    elif [ "$_snap_reset" = "1" ] && [ "$_snap_allow_empty" = "1" ]; then
      # Reset+allow-empty requested but observation incomplete (effective reset
      # was downgraded): zero records is not proof the cluster is empty. Preserve.
      MERV_MAC_LAST_STATUS="empty"; MERV_MAC_LAST_REASON="incomplete_node_observation"
      _merv_mac_set_counts
      _merv_mac_log warn "MERV_MAC: reset — zero records but cluster observation incomplete; db preserved"
    else
      # Cron/normal: zero records may be sleeping/roaming clients. Preserve db.
      MERV_MAC_LAST_STATUS="empty"; MERV_MAC_LAST_REASON="preserved_db"
      _merv_mac_set_counts
      _merv_mac_log info "MERV_MAC: snapshot empty — preserving existing db (entries age out naturally)"
    fi
    rm -f "$snap_tmp" 2>/dev/null
    if [ "$_snap_owned" = 1 ]; then
      merv_owner_lock_release "$_snap_lock" "$_snap_nonce" || return 1
      _snap_owned=0
    fi
    return 0
  fi

  # --- Merge + fingerprint diff --------------------------------------------
  # Compare structural fingerprint (mac+iface+vid only, timestamps excluded).
  # Raw md5 would always differ because timestamps refresh on every snapshot.
  local _pre_fp _post_fp
  _merv_mac_refresh_progress merge 65 \
  "Rebuilding MAC Shield database..."
  _pre_fp=$(awk '{print $2, $3, $4}' "$MERV_MAC_DB_ACTIVE" 2>/dev/null | sort | md5sum 2>/dev/null | cut -d' ' -f1)
  merv_mac_merge_db "$snap_tmp" "$_effective_reset" || {
    MERV_MAC_LAST_STATUS="merge_failed"
    _merv_mac_set_counts
    rm -f "$snap_tmp" 2>/dev/null
    if [ "$_snap_owned" = 1 ]; then
      merv_owner_lock_release "$_snap_lock" "$_snap_nonce" || return 1
      _snap_owned=0
    fi
    return 1
  }
  rm -f "$snap_tmp" 2>/dev/null
  _post_fp=$(awk '{print $2, $3, $4}' "$MERV_MAC_DB_ACTIVE" 2>/dev/null | sort | md5sum 2>/dev/null | cut -d' ' -f1)

  # --- Status: honest distinction between changed / reloaded / unchanged ----
  if [ "$_pre_fp" != "$_post_fp" ]; then
    MERV_MAC_LAST_CHANGED=1
    MERV_MAC_LAST_STATUS="changed"
  elif [ "$_snap_force_reload" = "1" ]; then
    MERV_MAC_LAST_CHANGED=0
    MERV_MAC_LAST_STATUS="reloaded"   # shield reapplied, MAC set identical
  else
    MERV_MAC_LAST_CHANGED=0
    MERV_MAC_LAST_STATUS="unchanged"
  fi

  # Reload fires for a real change OR an explicit force-reload. Push to nodes
  # whenever we reload, so every unit's shield is reapplied/repaired.
  if [ "$MERV_MAC_LAST_CHANGED" = "1" ] || [ "$_snap_force_reload" = "1" ]; then
  _merv_mac_refresh_progress apply 75 \
    "Replacing MAC Shield rules on MAIN..."

  if ! ebt_mac_shield_init_and_apply "$MERV_MAC_DB_ACTIVE"; then
      MERV_MAC_LAST_STATUS="apply_failed"
      MERV_MAC_LAST_REASON="local_enforcement_failed"
      _merv_mac_set_counts
      _merv_mac_log warn "MERV_MAC: database updated but local shield enforcement failed (reason=$MERV_MAC_LAST_REASON); node push suppressed and recovery is required"
      if [ "$_snap_owned" = 1 ]; then
        merv_owner_lock_release "$_snap_lock" "$_snap_nonce" || return 1
        _snap_owned=0
      fi
      return 1
    fi
    if [ -n "$_nodes" ]; then
    _merv_mac_refresh_progress push 82 \
    "Pushing MAC Shield database and rules to nodes..."

    MERV_MAC_LAST_PUSH_TOTAL=0; MERV_MAC_LAST_PUSH_OK=0; MERV_MAC_LAST_PUSH_FAILED=0
      if ! merv_mac_push_db_to_nodes "$_nodes"; then
        if merv_mac_pool_state_unresolved; then
          MERV_MAC_LAST_STATUS="push_failed"; MERV_MAC_LAST_REASON="node_pool_unresolved"
          _merv_mac_log warn "MERV_MAC: Shield push blocked — node-operation cleanup remains unresolved"
          # Retain Shield ownership and the push workspace until the generic
          # pool can be reconciled by its owning parent.
          return 1
        fi
      fi
    fi
  else
    _merv_mac_logv info "MERV_MAC: MAC set unchanged — ebtables rules not rebuilt"
  fi

  _merv_mac_set_counts

  # --- Summary log: meaningful events only ---------------------------------
  # Log on change, any node collection failure, or when explicitly requested
  # (LOG_UNCHANGED / verbose). Keeps stable cron ticks silent.
  if [ "${MERV_MAC_LAST_CHANGED:-0}" = "1" ] || \
     [ "${MERV_MAC_LAST_NODES_FAILED:-0}" -gt 0 ] || \
     [ "$_snap_log_unchanged" = "1" ] || \
     [ "$_snap_verbose" = "1" ]; then
    _merv_mac_log info "MERV_MAC: snapshot ${MERV_MAC_LAST_STATUS} — local=${MERV_MAC_LAST_LOCAL_COUNT} node=${MERV_MAC_LAST_NODE_COUNT} total=${MERV_MAC_LAST_TOTAL_COUNT} db=${MERV_MAC_LAST_DB_COUNT} nodes=${MERV_MAC_LAST_NODES_OK}/${MERV_MAC_LAST_NODES_TOTAL} push=${MERV_MAC_LAST_PUSH_OK}/${MERV_MAC_LAST_PUSH_TOTAL}"
  fi

  if [ "$_snap_owned" = 1 ]; then
    merv_owner_lock_release "$_snap_lock" "$_snap_nonce" || return 1
    _snap_owned=0
  fi
}

LIB_MAC_SHIELD_SNAPSHOT_LOADED=1
