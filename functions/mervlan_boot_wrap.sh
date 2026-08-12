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
#          - File: mervlan_boot_wrap.sh || version="0.72.4"                  #
# ============================================================================ #
# - Purpose:    Boot-time wrapper that gates install/manager/cron execution.   #
#               All ordering and flag logic lives here — core scripts are      #
#               never modified for boot-time safety.                           #
# ============================================================================ #
#                                                                              #
# Usage (from services-start templates):                                       #
#   mervlan_boot_wrap.sh install   — run install.sh if not already done        #
#   mervlan_boot_wrap.sh manager   — ensure install, then run manager boot     #
#   mervlan_boot_wrap.sh cron      — enable cron jobs                          #
# ============================================================================ #

# ============================================================================ #
# EARLY BOOTSTRAP — guarantee log dir exists before sourcing anything          #
# ============================================================================ #
: "${MERV_BASE:=/jffs/addons/mervlan}"
mkdir -p /tmp/mervlan_tmp/logs 2>/dev/null || :

# ================================================== MerVLAN environment setup #
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
# lib_json + lib_mervqt are needed for shield mode (LAN-configured probe, DHCP
# hold helpers, persistent MAC apply). Sourced graceful-best-effort so non-shield
# modes never abort if a lib is temporarily missing.
[ -n "${LIB_JSON_LOADED:-}" ]   || . "$MERV_BASE/settings/lib_json.sh"   2>/dev/null || true
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh" 2>/dev/null || true
[ -n "${LIB_UPDATE_STATE_LOADED:-}" ] || . "$MERV_BASE/settings/lib_update_state.sh" 2>/dev/null || true
# =========================================== End of MerVLAN environment setup #

# Route "boot" channel to boot_wrap.log
LOG_chan_boot="$LOGDIR/boot_wrap.log"

info -c boot "=== boot_wrap invoked: mode=$1 ==="

# ============================================================================ #
# FLAG PATHS — tmp-based so the flag resets each reboot (desired behavior)     #
# ============================================================================ #
_FLAG_DIR="$TMPDIR/flags"
_FLAG_FILE="$_FLAG_DIR/.install_ok"

_flag_exists() {
  [ -f "$_FLAG_FILE" ]
}

_write_flag() {
  mkdir -p "$_FLAG_DIR" 2>/dev/null || :
  : > "$_FLAG_FILE" 2>/dev/null || :
  info -c boot "Flag written: $_FLAG_FILE"
}

_is_node_runtime() {
  type json_get_flag >/dev/null 2>&1 || return 1
  [ "$(json_get_flag IS_NODE 0 "$SETTINGS_FILE" 2>/dev/null)" = 1 ]
}

# ============================================================================ #
# MODE: shield                                                                 #
# ----------------------------------------------------------------------------#
# Arms the L2 boot shield BEFORE install/manager run, closing the DHCP escape #
# window that exists from the moment rc brings up br0 + dnsmasq until the     #
# manager finishes restart_wireless + two bind passes (5–60s on slow models). #
#                                                                              #
# Layers armed:                                                                #
#   1. MERV_DHCP_HOLD chain — blocks DHCP DISCOVER/REQUEST on br0 entirely.   #
#      Without DHCP a misrouted guest VAP cannot get a native lease.          #
#   2. MERV_MAC chain — replayed from the persistent JFFS snapshot, so any    #
#      previously known per-client MAC DROP rules are in place from second 1. #
#                                                                              #
# Safety:                                                                      #
#   - Skips when DRY_RUN=yes.                                                  #
#   - Skips when no VLAN VID >= 2 is configured (fresh install protection —   #
#     never block DHCP on a router that has no VLANs to enforce).             #
#   - Skips when ebtables is missing.                                          #
#   - Skips when another shield watchdog is already alive (kill -0 on pid).   #
#                                                                              #
# Self-healing watchdog (detached background loop):                            #
#   - Re-arms the DHCP hold every 1s so an rc-driven ebtables flush during    #
#     boot can never leave the gate open.                                      #
#   - Exits as soon as $LOCKDIR/merv_boot_shield.active is removed (manager  #
#     mode does this immediately after the manager run returns).              #
#   - Hard ceiling: MERV_BOOT_SHIELD_MAX_SEC (default 480s) — even if no one  #
#     ever clears the marker, the hold tears down so DHCP comes back.         #
#   - On teardown, releases the DHCP hold ONLY if the manager/heal-owned     #
#     marker ($LOCKDIR/merv_dhcp_hold.active) is also absent. This prevents   #
#     the boot watchdog from yanking the rug out from under a manager that    #
#     is still inside its own critical section.                               #
# ============================================================================ #
_mode_shield_legacy() {
  local _shield_marker="$LOCKDIR/merv_boot_shield.active"
  local _shield_pidf="$LOCKDIR/merv_boot_shield.pid"
  local _hold_marker="$LOCKDIR/merv_dhcp_hold.active"
  local _max="${MERV_BOOT_SHIELD_MAX_SEC:-480}"
  local _oldpid

  case "$_max" in ''|*[!0-9]*) _max=360 ;; esac

  if [ "${DRY_RUN:-no}" = "yes" ]; then
    info -c boot,vlan "Shield: DRY_RUN=yes — boot shield skipped"
    return 0
  fi

  if ! type ebtables >/dev/null 2>&1; then
    info -c boot,vlan "Shield: ebtables not available — boot shield skipped"
    return 0
  fi

  if ! type merv_dhcp_hold_arm >/dev/null 2>&1; then
    warn -c boot,vlan "Shield: lib_mervqt not loaded — boot shield skipped (DHCP hold unavailable)"
    return 0
  fi

  if ! type merv_boot_shield_lan_configured >/dev/null 2>&1 || \
     ! merv_boot_shield_lan_configured "$SETTINGS_FILE"; then
    info -c boot,vlan "Shield: no VLAN configured in settings.json — boot shield skipped (fresh-install safety)"
    return 0
  fi

  mkdir -p "$LOCKDIR" 2>/dev/null || :

  # Refuse to spawn a second watchdog if one is already alive. Stale pid files
  # (process gone) are silently superseded so a crashed previous run never
  # blocks this one — the same stale-safe pattern used by the manager lock.
  if [ -f "$_shield_pidf" ]; then
    _oldpid=$(cat "$_shield_pidf" 2>/dev/null || echo "")
    case "$_oldpid" in *[!0-9]*) _oldpid="" ;; esac
    if [ -n "$_oldpid" ] && kill -0 "$_oldpid" 2>/dev/null; then
      info -c boot,vlan "Shield: watchdog already active (pid=$_oldpid) — skipping"
      return 0
    fi
    rm -f "$_shield_pidf" 2>/dev/null || :
  fi

  # Step 1: arm the DHCP hold up-front so the window is closed before the
  # watchdog even forks.  The boot shield owns a separate marker, so it must
  # not create merv_dhcp_hold.active here: otherwise a final watchdog tick can
  # recreate that shared manager/heal marker after the manager releases it.
  merv_dhcp_hold_arm quiet no-marker
  info -c boot,vlan "Shield: MERV_DHCP_HOLD armed (boot critical section)"

  # Step 2: replay the persistent MERV_MAC snapshot if we have one. Best-effort;
  # the watchdog and the manager will rebuild this anyway, but pre-arming here
  # means previously-known clients are L2-blocked from second 1 of boot.
  if type ebt_mac_shield_init_and_apply >/dev/null 2>&1; then
    local _db=""
    [ -s "${MERV_MAC_DB_JFFS:-}" ]  && _db="$MERV_MAC_DB_JFFS"
    [ -z "$_db" ] && [ -s "${MERV_MAC_DB_ACTIVE:-}" ] && _db="$MERV_MAC_DB_ACTIVE"
    if [ -n "$_db" ]; then
      if ebt_mac_shield_init_and_apply "$_db" >/dev/null 2>&1; then
        info -c boot,vlan "Shield: MERV_MAC pre-armed from persistent db ($_db)"
      else
        warn -c boot,vlan "Shield: MERV_MAC pre-arm failed; DHCP hold remains active and manager enforcement is required"
      fi
    else
      info -c boot,vlan "Shield: no persistent MERV_MAC db yet — first-boot/empty state"
    fi
  fi

  # Step 3: write the boot marker (epoch). Manager mode removes this file
  # after the manager call returns; watchdog polls for its absence.
  date +%s > "$_shield_marker" 2>/dev/null || : > "$_shield_marker" 2>/dev/null || :

  # Step 4: fork the self-healing watchdog. Fully detached so this script
  # (services-start context) can finish and let rc continue.
  (
    # Detach from parent's stdio so a closing tty cannot kill us.
    _started=$(date +%s 2>/dev/null || echo 0)
    case "$_started" in ''|*[!0-9]*) _started=0 ;; esac
    _elapsed=0
    while :; do
      # Exit cleanly when the marker is gone (manager finished) or when we
      # exceed the hard ceiling (manager failed or never ran).
      if [ ! -f "$_shield_marker" ]; then
        info -c boot,vlan "Shield: marker cleared — tearing down boot shield"
        break
      fi
      if [ "$_elapsed" -ge "$_max" ]; then
        warn -c boot,vlan "Shield: max lifetime ${_max}s reached — tearing down (manager may have failed)"
        break
      fi

      # Re-arm DHCP hold against any rc-driven ebtables flush during the boot
      # storm. Keep ownership on the boot marker only. A manager/heal caller
      # that needs a durable hold writes merv_dhcp_hold.active itself.
      merv_dhcp_hold_arm quiet no-marker 2>/dev/null || true

      sleep 1
      _now=$(date +%s 2>/dev/null || echo 0)
      case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
      if [ "$_now" -gt 0 ] && [ "$_started" -gt 0 ]; then
        _elapsed=$(( _now - _started ))
      else
        _elapsed=$(( _elapsed + 1 ))
      fi
    done

    # Teardown: release the DHCP hold ONLY if no other actor (manager / heal)
    # still owns it. Both write merv_dhcp_hold.active when they arm; our boot
    # marker is separate (merv_boot_shield.active) so we can distinguish.
    if [ -f "$_hold_marker" ]; then
      info -c boot,vlan "Shield: another actor still holds DHCP — leaving hold in place"
    else
      type merv_dhcp_hold_release >/dev/null 2>&1 && merv_dhcp_hold_release || true
    fi

    rm -f "$_shield_marker" "$_shield_pidf" 2>/dev/null || :
  ) </dev/null >/dev/null 2>&1 &

  echo "$!" > "$_shield_pidf" 2>/dev/null || :
  info -c boot,vlan "Shield: watchdog forked (pid=$(cat "$_shield_pidf" 2>/dev/null), max=${_max}s)"
  return 0
}

# Token-owned boot watchdog. This is a separate script process (not a shell
# subshell) so its lease identity is bound to its own PID and /proc start time.
# Catchable interruption is handled here rather than relying on EXIT timing:
# the durable DHCP owner/handoff record remains authoritative if this process
# is killed uncatchably (SIGKILL/OOM).
_merv_boot_watchdog_publish_state() {
  local _mbwps_state="$1" _mbwps_tmp
  [ -n "${_context_file:-}" ] || return 1
  _mbwps_tmp="${_context_file}.tmp.$$"
  {
    printf 'parent_run_id=%s\n' "${_run_id:-}"
    printf 'handoff_id=%s\n' "${_handoff_id:-}"
    printf 'watchdog_state=%s\n' "$_mbwps_state"
  } > "$_mbwps_tmp" 2>/dev/null &&
    mv "$_mbwps_tmp" "$_context_file" 2>/dev/null
}

_merv_boot_watchdog_claim_marker() {
  local _mbwcm_tmp="${_shield_marker}.tmp.$$"
  printf 'run_id=%s\n' "${_run_id:-}" > "$_mbwcm_tmp" 2>/dev/null &&
    mv "$_mbwcm_tmp" "$_shield_marker" 2>/dev/null
}

_merv_boot_watchdog_transient_matches() {
  local _mbwtm_path="$1" _mbwtm_kind="$2" _mbwtm_start _mbwtm_pid
  [ -e "$_mbwtm_path" ] || return 1
  case "$_mbwtm_kind" in
    marker)
      [ "$(sed -n 's/^run_id=//p' "$_mbwtm_path" 2>/dev/null | head -n 1)" = "${_run_id:-}" ]
      ;;
    context)
      [ "$(sed -n 's/^parent_run_id=//p' "$_mbwtm_path" 2>/dev/null | head -n 1)" = "${_run_id:-}" ] &&
        [ "$(sed -n 's/^handoff_id=//p' "$_mbwtm_path" 2>/dev/null | head -n 1)" = "${_handoff_id:-}" ]
      ;;
    pid)
      _mbwtm_pid=$(cat "$_mbwtm_path" 2>/dev/null || printf '')
      [ "$_mbwtm_pid" = "$$" ]
      ;;
    pid-start)
      _mbwtm_start=$(cat "$_mbwtm_path" 2>/dev/null || printf '')
      type merv_proc_start_time >/dev/null 2>&1 || return 1
      [ "$_mbwtm_start" = "$(merv_proc_start_time "$$" 2>/dev/null || printf '')" ]
      ;;
    ready)
      _mbwtm_pid=$(cat "$_mbwtm_path" 2>/dev/null || printf '')
      [ "$_mbwtm_pid" = "$$" ]
      ;;
    *) return 1 ;;
  esac
}

_merv_boot_watchdog_cleanup_one() {
  local _mbwco_path="$1" _mbwco_kind="$2" _mbwco_tomb
  [ -e "$_mbwco_path" ] || return 0
  _merv_boot_watchdog_transient_matches "$_mbwco_path" "$_mbwco_kind" || return 1
  _mbwco_tomb="${_mbwco_path}.cleanup.$$"
  [ ! -e "$_mbwco_tomb" ] || return 1
  # Rename first, then verify the renamed inode.  A replacement watchdog that
  # atomically republishes the original path is left untouched at that path;
  # the old inode is either removed or retained as a private tombstone.
  mv "$_mbwco_path" "$_mbwco_tomb" 2>/dev/null || return 1
  if _merv_boot_watchdog_transient_matches "$_mbwco_tomb" "$_mbwco_kind"; then
    rm -f "$_mbwco_tomb" 2>/dev/null || return 1
    return 0
  fi
  warn -c boot,vlan "Shield: watchdog transient replacement detected; retaining $_mbwco_path"
  # Never overwrite a replacement at the public path.  Keep the mismatched
  # old inode quarantined for the next reconciliation pass.
  return 1
}

_merv_boot_watchdog_transient_lock_enter() {
  type merv_owner_lock_acquire >/dev/null 2>&1 || return 1
  [ -n "${_watchdog_transient_lock:-}" ] || return 1
  merv_owner_lock_acquire "$_watchdog_transient_lock" 30 30 boot-shield-transient
}

_merv_boot_watchdog_transient_lock_leave() {
  type merv_owner_lock_release >/dev/null 2>&1 || return 1
  [ -n "${_watchdog_transient_lock:-}" ] || return 1
  merv_owner_lock_release "$_watchdog_transient_lock" "${MERV_LOCK_NONCE:-}"
}

_merv_boot_watchdog_cleanup_transients() {
  local _mbwct_rc=0 _mbwct_locked=0
  if [ "${_watchdog_transient_lock_held:-0}" -ne 1 ]; then
    _merv_boot_watchdog_transient_lock_enter || return 1
    _mbwct_locked=1
  fi
  _merv_boot_watchdog_cleanup_one "${_context_file:-}" context || _mbwct_rc=1
  _merv_boot_watchdog_cleanup_one "${_ready_file:-}" ready || _mbwct_rc=1
  _merv_boot_watchdog_cleanup_one "${_pid_file:-}" pid || _mbwct_rc=1
  _merv_boot_watchdog_cleanup_one "${_pid_start_file:-}" pid-start || _mbwct_rc=1
  _merv_boot_watchdog_cleanup_one "${_shield_marker:-}" marker || _mbwct_rc=1
  [ "$_mbwct_locked" -eq 0 ] || _merv_boot_watchdog_transient_lock_leave || _mbwct_rc=1
  return "$_mbwct_rc"
}

_merv_boot_watchdog_publish_state_if_owned() {
  # The publication lock serializes this check with a replacement _mode_shield
  # startup.  Never overwrite a context/pid publication that no longer proves
  # this run; cleanup will retain that replacement for its owner.
  if [ -e "${_context_file:-}" ] &&
     ! _merv_boot_watchdog_transient_matches "$_context_file" context; then
    return 1
  fi
  if [ -e "${_pid_file:-}" ] &&
     ! _merv_boot_watchdog_transient_matches "$_pid_file" pid; then
    return 1
  fi
  if [ -e "${_pid_start_file:-}" ] &&
     ! _merv_boot_watchdog_transient_matches "$_pid_start_file" pid-start; then
    return 1
  fi
  _merv_boot_watchdog_publish_state "$1"
}

_merv_boot_watchdog_cleanup() {
  local _mbwc_reason="${1:-watchdog-cleanup}" _mbwc_rc=0
  [ "${_watchdog_cleanup_done:-0}" -eq 0 ] || return "${_watchdog_cleanup_rc:-0}"
  _watchdog_cleanup_done=1
  # The DHCP helper publishes its handoff ID before returning.  If TERM lands
  # in the caller's assignment window, consume that durable value rather than
  # treating a requested handoff as a pre-handoff lease.
  [ -n "${_handoff_id:-}" ] || _handoff_id="${MERV_DHCP_HANDOFF_ID:-}"

  if [ -n "${_token:-}" ]; then
    if [ -n "${_handoff_id:-}" ]; then
      # This helper authenticates the parent while holding the DHCP state lock
      # and serializes successor verification with parent retirement.  It never
      # removes a successor owner.
      if merv_dhcp_handoff_parent_abort "$_token" "$_handoff_id" "$_mbwc_reason" >/dev/null 2>&1; then
        case "${MERV_DHCP_HANDOFF_ABORT_STATE:-uncertain}" in
          successor-verified)
            _watchdog_state=successor-verified
            ;;
          abandoned)
            _watchdog_state=abandoned
            ;;
          *)
            _watchdog_state=uncertain
            _mbwc_rc=1
            ;;
        esac
        case "${MERV_DHCP_HANDOFF_ABORT_STATE:-uncertain}" in
          successor-verified|abandoned)
            _token=""
            ;;
          *)
            # A successful helper must still report a recognized terminal
            # state before this process forgets its token.
            _mbwc_rc=1
            ;;
        esac
      else
        # Identity, publication, or state-lock failure is not evidence that
        # this process still owns the lease.  Leave durable state and marker
        # files for fail-closed reconciliation rather than deleting a possible
        # replacement claim.
        _watchdog_state=uncertain
        _mbwc_rc=1
        warn -c boot,vlan "Shield: watchdog cleanup could not authenticate handoff ownership; DHCP state retained for reconciliation"
      fi
    elif [ "${_watchdog_handoff_inflight:-0}" -eq 1 ]; then
      # The request may have created a durable handoff record, but its ID is
      # not yet visible in this shell.  Preserve the exact owner/marker for
      # reconciliation instead of abandoning an unknown handoff.
      _watchdog_state=uncertain
      _mbwc_rc=1
      warn -c boot,vlan "Shield: watchdog interrupted during DHCP handoff publication; state retained for reconciliation"
    elif merv_dhcp_hold_abandon "$_token" "$_mbwc_reason" >/dev/null 2>&1; then
      _token=""
      _watchdog_state=abandoned
    else
      _watchdog_state=uncertain
      _mbwc_rc=1
      warn -c boot,vlan "Shield: watchdog cleanup could not authenticate DHCP ownership; lease retained for reconciliation"
    fi
  elif [ "${_watchdog_owner_established:-0}" -eq 1 ]; then
    # Acquisition returned success but did not publish a valid token.  The
    # owner may still exist durably; do not delete its marker or claim that it
    # was safely abandoned.
    _watchdog_state=uncertain
    _mbwc_rc=1
    warn -c boot,vlan "Shield: watchdog acquired DHCP protection without a valid token; state retained for reconciliation"
  fi

  _watchdog_cleanup_rc="$_mbwc_rc"
  if [ "$_mbwc_rc" -eq 0 ]; then
    if _merv_boot_watchdog_transient_lock_enter; then
      _watchdog_transient_lock_held=1
      _merv_boot_watchdog_publish_state_if_owned "${_watchdog_state:-terminal-complete}" >/dev/null 2>&1 || _watchdog_cleanup_rc=1
      _merv_boot_watchdog_cleanup_transients || _watchdog_cleanup_rc=1
      _watchdog_transient_lock_held=0
      _merv_boot_watchdog_transient_lock_leave || _watchdog_cleanup_rc=1
    else
      _watchdog_cleanup_rc=1
    fi
  else
    # Unknown ownership is deliberately left durable.  The next boot/manager
    # reconciliation pass will classify the exact stale claim and keep DHCP
    # blocked until recovery is proven.
    if _merv_boot_watchdog_transient_lock_enter; then
      _watchdog_transient_lock_held=1
      _merv_boot_watchdog_publish_state_if_owned uncertain >/dev/null 2>&1 || :
      # Even when DHCP ownership is uncertain, remove only transient files that
      # still prove this exact run and identity under the publication lock.
      _merv_boot_watchdog_cleanup_transients || :
      _watchdog_transient_lock_held=0
      _merv_boot_watchdog_transient_lock_leave || :
    fi
  fi
  _mbwc_rc="${_watchdog_cleanup_rc:-$_mbwc_rc}"
  return "$_mbwc_rc"
}

_merv_boot_watchdog_signal() {
  local _mbws_signal="$1" _mbws_rc=143
  [ "$_mbws_signal" = INT ] && _mbws_rc=130
  # Disable re-entry while cleanup authenticates and reconciles the exact
  # owner.  This is only for catchable INT/TERM; SIGKILL/OOM remain covered by
  # durable reconciliation, not by a claimed shell trap.
  trap - INT TERM
  _merv_boot_watchdog_cleanup "interrupted-${_mbws_signal}" >/dev/null 2>&1 || :
  exit "$_mbws_rc"
}

_mode_shield_watchdog() {
  local _shield_marker="$2" _ready_file="$3" _context_file="$4" _max="$5"
  local _pid_file="$6" _pid_start_file="${6}.start" _run_id _handoff_id _token _elapsed=0 _verification
  local _watchdog_state=starting _watchdog_cleanup_done=0 _watchdog_cleanup_rc=0 _watchdog_owner_established=1 _watchdog_handoff_inflight=0
  local _watchdog_transient_lock="${LOCKDIR:-/tmp/mervlan_tmp/locks}/merv_boot_shield.transient.lock"
  local _watchdog_transient_lock_held=0
  case "$_max" in ''|*[!0-9]*) _max=480 ;; esac
  trap '_merv_boot_watchdog_signal INT' INT
  trap '_merv_boot_watchdog_signal TERM' TERM
  _run_id="boot-$(date +%s 2>/dev/null || echo 0)-$$"
  _watchdog_state=owner-active
  if ! _merv_boot_watchdog_transient_lock_enter; then
    _watchdog_state=uncertain
    trap - INT TERM
    return 1
  fi
  if ! _merv_boot_watchdog_claim_marker; then
    _merv_boot_watchdog_transient_lock_leave || :
    _watchdog_state=uncertain
    trap - INT TERM
    return 1
  fi
  _merv_boot_watchdog_transient_lock_leave || {
    _watchdog_state=uncertain
    trap - INT TERM
    return 1
  }
  if ! merv_dhcp_hold_acquire boot-watchdog "$_run_id"; then
    warn -c boot,vlan "Shield: watchdog could not acquire boot lease"
    _merv_boot_watchdog_cleanup acquire-failed >/dev/null 2>&1 || :
    trap - INT TERM
    return 1
  fi
  _token="$MERV_DHCP_HOLD_TOKEN"
  _merv_boot_watchdog_publish_state owner-active >/dev/null 2>&1 || :
  _watchdog_handoff_inflight=1
  if ! merv_dhcp_handoff_request "$_token" manager; then
    _merv_boot_watchdog_cleanup boot-handoff-request-failed >/dev/null 2>&1 || :
    trap - INT TERM
    return 1
  fi
  _handoff_id="$MERV_DHCP_HANDOFF_ID"
  _watchdog_handoff_inflight=0
  _watchdog_state=handoff-published
  _merv_boot_watchdog_publish_state handoff-published >/dev/null 2>&1 || :
  if ! merv_dhcp_hold_mark_handoff_wait "$_token" "$_handoff_id"; then
    _merv_boot_watchdog_cleanup boot-handoff-wait-failed >/dev/null 2>&1 || :
    trap - INT TERM
    return 1
  fi
  {
    printf 'parent_run_id=%s\n' "$_run_id"
    printf 'handoff_id=%s\n' "$_handoff_id"
    printf 'watchdog_state=%s\n' "$_watchdog_state"
  } > "${_context_file}.tmp.$$" 2>/dev/null &&
    mv "${_context_file}.tmp.$$" "$_context_file" 2>/dev/null || {
      _merv_boot_watchdog_cleanup boot-context-publish-failed >/dev/null 2>&1 || :
      trap - INT TERM
      return 1
    }
  printf '%s\n' "$$" > "${_ready_file}.tmp.$$" 2>/dev/null &&
    mv "${_ready_file}.tmp.$$" "$_ready_file" 2>/dev/null || {
      _merv_boot_watchdog_cleanup boot-ready-publish-failed >/dev/null 2>&1 || :
      trap - INT TERM
      return 1
    }

  while [ -f "$_shield_marker" ] && [ "$_elapsed" -lt "$_max" ]; do
    merv_dhcp_hold_enforce >/dev/null 2>&1 || :
    sleep 1
    _elapsed=$((_elapsed + 1))
  done

  # Retire only through the atomic parent-abort helper.  A timeout or failed
  # manager is converted to a durable failsafe; a verified successor retires
  # only this watchdog's parent claim.
  [ "$_elapsed" -lt "$_max" ] || warn -c boot,vlan "Shield: boot handoff timed out after ${_max}s"
  _merv_boot_watchdog_cleanup boot-handoff-complete >/dev/null 2>&1 || :
  [ "${_watchdog_state:-uncertain}" = successor-verified ] &&
    info -c boot,vlan "Shield: verified boot handoff completed ($_handoff_id)"
  trap - INT TERM
  return "${_watchdog_cleanup_rc:-1}"
}

_mode_shield() {
  local _shield_marker="$LOCKDIR/merv_boot_shield.active"
  local _shield_pidf="$LOCKDIR/merv_boot_shield.pid"
  local _shield_pid_startf="${_shield_pidf}.start"
  local _shield_ready="$LOCKDIR/merv_boot_shield.ready"
  local _shield_context="$LOCKDIR/merv_boot_shield.handoff"
  local _max="${MERV_BOOT_SHIELD_MAX_SEC:-480}" _oldpid _oldstart _shield_pid _shield_start _ready_pid _ready_start _wait=0
  local _watchdog_transient_lock="${LOCKDIR:-/tmp/mervlan_tmp/locks}/merv_boot_shield.transient.lock"
  case "$_max" in ''|*[!0-9]*) _max=480 ;; esac

  if type merv_update_quiesce_active >/dev/null 2>&1 && merv_update_quiesce_active; then
    info -c boot,vlan "Shield suppressed: Update maintenance quiesce is active"
    return 0
  fi
  if type merv_update_journal_requires_safe_boot >/dev/null 2>&1 && merv_update_journal_requires_safe_boot; then
    warn -c boot,vlan "Shield suppressed: interrupted Update requires safe recovery"
    return 0
  fi

  [ "${DRY_RUN:-no}" != yes ] || return 0
  type ebtables >/dev/null 2>&1 || return 0
  type merv_dhcp_hold_acquire >/dev/null 2>&1 || return 1
  type merv_boot_shield_lan_configured >/dev/null 2>&1 &&
    merv_boot_shield_lan_configured "$SETTINGS_FILE" || return 0
  mkdir -p "$LOCKDIR" 2>/dev/null || return 1
  _merv_boot_watchdog_transient_lock_enter || return 1

  if [ -f "$_shield_pidf" ]; then
    _oldpid=$(cat "$_shield_pidf" 2>/dev/null || printf '')
    _oldstart=$(cat "$_shield_pid_startf" 2>/dev/null || printf '')
    case "$_oldpid" in ''|*[!0-9]*) _oldpid="" ;; esac
    case "$_oldstart" in ''|*[!0-9]*) _oldstart="" ;; esac
    if [ -n "$_oldpid" ] && [ -n "$_oldstart" ] &&
       merv_process_identity_matches "$_oldpid" "$_oldstart"; then
      info -c boot,vlan "Shield: token watchdog already active (pid=$_oldpid)"
      _merv_boot_watchdog_transient_lock_leave || :
      return 0
    fi
    rm -f "$_shield_pidf" "$_shield_pid_startf" 2>/dev/null || :
  fi
  rm -f "$_shield_pidf" "$_shield_ready" "$_shield_context" 2>/dev/null || :
  if ! date +%s > "$_shield_marker" 2>/dev/null; then
    _merv_boot_watchdog_transient_lock_leave || :
    return 1
  fi
  "$0" shield-watchdog "$_shield_marker" "$_shield_ready" "$_shield_context" "$_max" "$_shield_pidf" \
    </dev/null >/dev/null 2>&1 &
  _shield_pid=$!
  _shield_start=$(merv_proc_start_time "$_shield_pid" 2>/dev/null || printf '')
  case "$_shield_start" in ''|*[!0-9]*)
    kill -TERM "$_shield_pid" 2>/dev/null || :
    rm -f "$_shield_marker" "$_shield_pidf" "$_shield_pid_startf" 2>/dev/null || :
    _merv_boot_watchdog_transient_lock_leave || :
    return 1
    ;;
  esac
  if ! printf '%s\n' "$_shield_pid" > "$_shield_pidf" 2>/dev/null ||
     ! printf '%s\n' "$_shield_start" > "$_shield_pid_startf" 2>/dev/null; then
    kill -TERM "$_shield_pid" 2>/dev/null || :
    rm -f "$_shield_marker" "$_shield_pidf" "$_shield_pid_startf" 2>/dev/null || :
    _merv_boot_watchdog_transient_lock_leave || :
    return 1
  fi
  if ! _merv_boot_watchdog_transient_lock_leave; then
    kill -TERM "$_shield_pid" 2>/dev/null || :
    return 1
  fi

  while [ "$_wait" -lt "${MERV_BOOT_SHIELD_READY_SEC:-10}" ]; do
    if [ -s "$_shield_ready" ] && [ -s "$_shield_context" ]; then
      info -c boot,vlan "Shield: token watchdog ready (pid=$(cat "$_shield_ready" 2>/dev/null))"
      return 0
    fi
    _ready_pid=$(cat "$_shield_pidf" 2>/dev/null || printf '')
    _ready_start=$(cat "$_shield_pid_startf" 2>/dev/null || printf '')
    merv_process_identity_matches "$_ready_pid" "$_ready_start" || break
    sleep 1
    _wait=$((_wait + 1))
  done
  warn -c boot,vlan "Shield: watchdog readiness acknowledgement failed"
  if _merv_boot_watchdog_transient_lock_enter; then
    _ready_pid=$(cat "$_shield_pidf" 2>/dev/null || printf '')
    _ready_start=$(cat "$_shield_pid_startf" 2>/dev/null || printf '')
    if [ "$_ready_pid" = "$_shield_pid" ] && [ "$_ready_start" = "$_shield_start" ]; then
      rm -f "$_shield_marker" 2>/dev/null || :
    fi
    _merv_boot_watchdog_transient_lock_leave || :
  fi
  return 1
}

# ============================================================================ #
# MODE: install                                                                #
# ============================================================================ #
_mode_install() {
  if _is_node_runtime; then
    info -c boot "Node runtime detected — installer bootstrap is not required"
    _write_flag
    return 0
  fi

  if type merv_update_journal_requires_safe_boot >/dev/null 2>&1 && merv_update_journal_requires_safe_boot; then
    if [ -f "$LOCKDIR/mervlan_maintenance.lock" ] && type merv_lock_state >/dev/null 2>&1 &&
       [ "$(merv_lock_state "$LOCKDIR/mervlan_maintenance.lock" 2>/dev/null)" = active ]; then
      warn -c boot "Incomplete Update state detected while the Update owner is still active; deferring recovery"
      return 75
    fi
    warn -c boot "Incomplete Update journal detected; running installer projection recovery without starting the manager"
    _update_recovery_run=$(merv_update_journal_get run_id '' 2>/dev/null || printf '')
    _update_recovery_start=$(merv_identity_current_start 2>/dev/null || printf '')
    if [ -z "$_update_recovery_run" ] || [ -z "$_update_recovery_start" ] ||
       ! merv_update_state_value "$_update_recovery_run" >/dev/null; then
      warn -c boot "Interrupted Update recovery context could not be authenticated; manager startup remains suppressed"
      return 75
    fi
    MERV_UPDATE_RECOVERY=1
    MERV_UPDATE_RECOVERY_RUN_ID="$_update_recovery_run"
    MERV_UPDATE_RECOVERY_PARENT_PID="$$"
    MERV_UPDATE_RECOVERY_PARENT_START="$_update_recovery_start"
    export MERV_UPDATE_RECOVERY MERV_UPDATE_RECOVERY_RUN_ID \
      MERV_UPDATE_RECOVERY_PARENT_PID MERV_UPDATE_RECOVERY_PARENT_START
    if ! merv_update_recovery_context_valid; then
      warn -c boot "Interrupted Update recovery context could not be authenticated; manager startup remains suppressed"
      return 75
    fi
    if "$MERV_BASE/install.sh" reinstall >> "$LOG_chan_boot" 2>&1; then
      if type merv_update_journal_active >/dev/null 2>&1 && merv_update_journal_active; then
        if [ "$(merv_update_journal_get activation_started 0)" != "1" ]; then
          merv_update_journal_clear || warn -c boot "Projection recovery succeeded but the pre-activation Update journal could not be cleared"
          merv_update_quiesce_clear || warn -c boot "Projection recovery succeeded but the Update quiesce marker could not be cleared"
          info -c boot "Interrupted Update was before activation; safe recovery state cleared"
        else
          info -c boot "Installer projection recovery completed; activation journal remains pending verification"
        fi
      else
        merv_update_quiesce_clear || warn -c boot "Projection recovery succeeded but the Update quiesce marker could not be cleared"
        info -c boot "Interrupted Update projection recovery completed"
      fi
    else
      warn -c boot "Installer projection recovery failed; manager startup remains suppressed"
    fi
    return 0
  fi

  if _flag_exists; then
    info -c boot "install.sh already executed (flag present). Skipped."
    return 0
  fi

  info -c boot "Flag not found — running install.sh"
  if "$MERV_BASE/install.sh" >> "$LOG_chan_boot" 2>&1; then
    info -c boot "install.sh completed successfully (rc=0)"
    _write_flag
  else
    warn -c boot "install.sh returned non-zero — flag NOT written"
  fi

  return 0
}

# ============================================================================ #
# MODE: manager                                                                #
# ============================================================================ #
_mode_manager() {
  local _boot_context="$LOCKDIR/merv_boot_shield.handoff"
  local _boot_parent_run="" _boot_handoff=""
  if type merv_update_quiesce_active >/dev/null 2>&1 && merv_update_quiesce_active ||
     type merv_update_journal_requires_safe_boot >/dev/null 2>&1 && merv_update_journal_requires_safe_boot; then
    warn -c boot "Manager startup suppressed: Update recovery/quiesce state is active"
    return 75
  fi
  # ======================================================================== #
  # PAUSE CLEAR — A reboot is always a clean slate. Clear any stale PAUSE   #
  # flag left from the previous session before the manager runs.            #
  # ======================================================================== #
  if type json_set_flag >/dev/null 2>&1 && [ -s "${SETTINGS_FILE:-$MERV_BASE/settings/settings.json}" ]; then
    _ms_sf="${SETTINGS_FILE:-$MERV_BASE/settings/settings.json}"
    case "$(json_get_flag PAUSE off "$_ms_sf" 2>/dev/null)" in
      on|1|yes)
        json_set_flag PAUSE off "$_ms_sf" 2>/dev/null && \
          info -c boot "Cleared stale PAUSE flag (session ended by reboot)" || \
          warn -c boot "Could not clear PAUSE flag — continuing"
        # Mirror to public web path so the UI reads the cleared state
        [ -s "${PUBLIC_SETTINGS_FILE:-}" ] && \
          json_set_flag PAUSE off "$PUBLIC_SETTINGS_FILE" 2>/dev/null || true
        ;;
    esac
  fi

  if ! _flag_exists && _is_node_runtime; then
    info -c boot "Node runtime detected — marking curated structure ready"
    _write_flag
  elif ! _flag_exists; then
    info -c boot "Flag not found — running install.sh first (best-effort)"
    if "$MERV_BASE/install.sh" >> "$LOG_chan_boot" 2>&1; then
      info -c boot "install.sh completed successfully (rc=0)"
      _write_flag
    else
      warn -c boot "install.sh returned non-zero — continuing anyway"
    fi
  else
    info -c boot "Flag present — install structure confirmed"
  fi

  info -c boot "Running mervlan_manager.sh boot"
  if [ -s "$_boot_context" ]; then
    _boot_parent_run=$(sed -n 's/^parent_run_id=//p' "$_boot_context" 2>/dev/null | head -n 1)
    _boot_handoff=$(sed -n 's/^handoff_id=//p' "$_boot_context" 2>/dev/null | head -n 1)
  fi
  if [ -n "$_boot_parent_run" ] && [ -n "$_boot_handoff" ]; then
    "$VLAN_MANAGER" boot "--parent-run-id=$_boot_parent_run" "--handoff-id=$_boot_handoff" >> "$LOG_chan_boot" 2>&1
    _manager_rc=$?
  else
    "$VLAN_MANAGER" boot >> "$LOG_chan_boot" 2>&1
    _manager_rc=$?
  fi
  if [ "$_manager_rc" -eq 0 ]; then
    info -c boot "mervlan_manager.sh boot completed (rc=0)"
  else
    warn -c boot "mervlan_manager.sh boot returned non-zero"
  fi

  # Tear down the boot shield as soon as the manager run returns (success or
  # not). The shield watchdog polls for this marker's absence and will release
  # the DHCP hold on its next 1s tick — unless manager/heal still owns its own
  # merv_dhcp_hold.active marker, in which case the watchdog leaves the hold
  # in place to avoid disrupting an in-flight critical section.
  rm -f "$LOCKDIR/merv_boot_shield.active" 2>/dev/null || :

  # Boot mode queues observation before returning. Start its bounded worker
  # only after the shield marker is gone so the boot handoff can retire first.
  if [ "$_manager_rc" -eq 0 ] && [ -x "$MERV_BASE/functions/post_apply_worker.sh" ]; then
    info -c boot "Running queued post-apply observation after boot shield teardown"
    MERV_OBS_NO_AUTOSTART=1 sh "$MERV_BASE/functions/post_apply_worker.sh" \
      run-wait "${MERV_OBS_AUTOSTART_WAIT_SEC:-120}" >> "$LOG_chan_boot" 2>&1
    _boot_observation_rc=$?
    case "$_boot_observation_rc" in
      0) info -c boot "Queued post-apply observation completed (rc=0)" ;;
      75) warn -c boot "Queued post-apply observation remains pending (rc=75)" ;;
      *) warn -c boot "Queued post-apply observation failed (rc=$_boot_observation_rc)" ;;
    esac
  fi

  return 0
}

# ============================================================================ #
# MODE: cron                                                                   #
# ============================================================================ #
_mode_cron() {
  if type merv_update_quiesce_active >/dev/null 2>&1 && merv_update_quiesce_active ||
     type merv_update_journal_requires_safe_boot >/dev/null 2>&1 && merv_update_journal_requires_safe_boot; then
    warn -c boot "Cron enable suppressed: Update recovery/quiesce state is active"
    return 75
  fi
  info -c boot "Running mervlan_boot.sh cronenable"
  if "$BOOT_SCRIPT" cronenable >> "$LOG_chan_boot" 2>&1; then
    info -c boot "mervlan_boot.sh cronenable completed (rc=0)"
  else
    warn -c boot "mervlan_boot.sh cronenable returned non-zero"
  fi

  return 0
}

# ============================================================================ #
# DISPATCH                                                                     #
# ============================================================================ #
_wrap_rc=0
case "$1" in
  install)
    _mode_install || _wrap_rc=$?
    ;;
  shield)
    _mode_shield || _wrap_rc=$?
    ;;
  shield-watchdog)
    _mode_shield_watchdog "$@" || _wrap_rc=$?
    ;;
  manager)
    _mode_manager || _wrap_rc=$?
    ;;
  cron)
    _mode_cron || _wrap_rc=$?
    ;;
  *)
    warn -c boot "Unknown mode: '$1' — expected install|shield|manager|cron"
    ;;
esac

info -c boot "=== boot_wrap finished: mode=$1 ==="
exit "$_wrap_rc"
