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
#            - File: mervlan_boot_wrap.sh || version="0.48"                    #
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
#   - Hard ceiling: MERV_BOOT_SHIELD_MAX_SEC (default 360s) — even if no one  #
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
  local _max="${MERV_BOOT_SHIELD_MAX_SEC:-360}"
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
      ebt_mac_shield_init_and_apply "$_db" >/dev/null 2>&1 || true
      info -c boot,vlan "Shield: MERV_MAC pre-armed from persistent db ($_db)"
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
_mode_shield_watchdog() {
  local _shield_marker="$2" _ready_file="$3" _context_file="$4" _max="$5"
  local _pid_file="$6" _run_id _handoff_id _token _elapsed=0 _verification
  case "$_max" in ''|*[!0-9]*) _max=360 ;; esac
  _run_id="boot-$(date +%s 2>/dev/null || echo 0)-$$"
  if ! merv_dhcp_hold_acquire boot-watchdog "$_run_id"; then
    warn -c boot,vlan "Shield: watchdog could not acquire boot lease"
    return 1
  fi
  _token="$MERV_DHCP_HOLD_TOKEN"
  if ! merv_dhcp_handoff_request "$_token" manager; then
    merv_dhcp_hold_abandon "$_token" boot-handoff-request-failed >/dev/null 2>&1 || :
    return 1
  fi
  _handoff_id="$MERV_DHCP_HANDOFF_ID"
  if ! merv_dhcp_hold_mark_handoff_wait "$_token" "$_handoff_id"; then
    merv_dhcp_hold_abandon "$_token" boot-handoff-wait-failed >/dev/null 2>&1 || :
    return 1
  fi
  {
    printf 'parent_run_id=%s\n' "$_run_id"
    printf 'handoff_id=%s\n' "$_handoff_id"
  } > "${_context_file}.tmp.$$" 2>/dev/null &&
    mv "${_context_file}.tmp.$$" "$_context_file" 2>/dev/null || {
      merv_dhcp_hold_abandon "$_token" boot-context-publish-failed >/dev/null 2>&1 || :
      return 1
    }
  printf '%s\n' "$$" > "${_ready_file}.tmp.$$" 2>/dev/null &&
    mv "${_ready_file}.tmp.$$" "$_ready_file" 2>/dev/null || {
      merv_dhcp_hold_abandon "$_token" boot-ready-publish-failed >/dev/null 2>&1 || :
      return 1
    }

  while [ -f "$_shield_marker" ] && [ "$_elapsed" -lt "$_max" ]; do
    merv_dhcp_hold_enforce >/dev/null 2>&1 || :
    sleep 1
    _elapsed=$((_elapsed + 1))
  done

  # Boot ownership may retire only after the exact successor published its
  # verified completion. A timeout or failed manager remains fail-closed.
  if merv_dhcp_handoff_parent_release "$_token" "$_handoff_id"; then
    _token=""
    info -c boot,vlan "Shield: verified boot handoff completed ($_handoff_id)"
  else
    [ "$_elapsed" -lt "$_max" ] || warn -c boot,vlan "Shield: boot handoff timed out after ${_max}s"
    merv_dhcp_handoff_fail "$_handoff_id" "$_token" boot-handoff-incomplete >/dev/null 2>&1 || :
    merv_dhcp_hold_abandon "$_token" boot-handoff-incomplete >/dev/null 2>&1 || :
    _token=""
  fi
  rm -f "$_shield_marker" "$_ready_file" "$_context_file" "$_pid_file" 2>/dev/null || :
  return 0
}

_mode_shield() {
  local _shield_marker="$LOCKDIR/merv_boot_shield.active"
  local _shield_pidf="$LOCKDIR/merv_boot_shield.pid"
  local _shield_ready="$LOCKDIR/merv_boot_shield.ready"
  local _shield_context="$LOCKDIR/merv_boot_shield.handoff"
  local _max="${MERV_BOOT_SHIELD_MAX_SEC:-360}" _oldpid _wait=0
  case "$_max" in ''|*[!0-9]*) _max=360 ;; esac

  [ "${DRY_RUN:-no}" != yes ] || return 0
  type ebtables >/dev/null 2>&1 || return 0
  type merv_dhcp_hold_acquire >/dev/null 2>&1 || return 1
  type merv_boot_shield_lan_configured >/dev/null 2>&1 &&
    merv_boot_shield_lan_configured "$SETTINGS_FILE" || return 0
  mkdir -p "$LOCKDIR" 2>/dev/null || return 1

  if [ -f "$_shield_pidf" ]; then
    _oldpid=$(cat "$_shield_pidf" 2>/dev/null || printf '')
    case "$_oldpid" in ''|*[!0-9]*) _oldpid="" ;; esac
    [ -z "$_oldpid" ] || ! kill -0 "$_oldpid" 2>/dev/null || {
      info -c boot,vlan "Shield: token watchdog already active (pid=$_oldpid)"
      return 0
    }
  fi
  rm -f "$_shield_pidf" "$_shield_ready" "$_shield_context" 2>/dev/null || :
  date +%s > "$_shield_marker" 2>/dev/null || return 1
  "$0" shield-watchdog "$_shield_marker" "$_shield_ready" "$_shield_context" "$_max" "$_shield_pidf" \
    </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$_shield_pidf" 2>/dev/null || return 1

  while [ "$_wait" -lt "${MERV_BOOT_SHIELD_READY_SEC:-10}" ]; do
    if [ -s "$_shield_ready" ] && [ -s "$_shield_context" ]; then
      info -c boot,vlan "Shield: token watchdog ready (pid=$(cat "$_shield_ready" 2>/dev/null))"
      return 0
    fi
    kill -0 "$(cat "$_shield_pidf" 2>/dev/null)" 2>/dev/null || break
    sleep 1
    _wait=$((_wait + 1))
  done
  warn -c boot,vlan "Shield: watchdog readiness acknowledgement failed"
  rm -f "$_shield_marker" 2>/dev/null || :
  return 1
}

# ============================================================================ #
# MODE: install                                                                #
# ============================================================================ #
_mode_install() {
  if _flag_exists; then
    info -c boot "install.sh already executed (flag present). Skipped."
    return 0
  fi

  if _is_node_runtime; then
    info -c boot "Node runtime detected — installer bootstrap is not required"
    _write_flag
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

  return 0
}

# ============================================================================ #
# MODE: cron                                                                   #
# ============================================================================ #
_mode_cron() {
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
