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
#          - File: mervlan_boot_wrap.sh || version="0.72.8"                  #
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
[ -n "${LIB_IDENTITY_LOADED:-}" ]     || . "$MERV_BASE/settings/lib_identity.sh"     2>/dev/null || true
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
  local _mbwps_state="$1" _mbwps_handoff _mbwps_body
  [ -n "${_context_file:-}" ] || return 1
  case "$_mbwps_state" in
    starting|owner-active|handoff-published|uncertain|abandoned|successor-verified|terminal-complete) ;;
    *) return 1 ;;
  esac
  _mbwps_handoff="${_handoff_id:-pending}"
  _merv_boot_watchdog_valid_id "${_run_id:-}" || return 1
  _merv_boot_watchdog_valid_id "$_mbwps_handoff" || return 1
  case "$_mbwps_state" in
    handoff-published|successor-verified|terminal-complete)
      [ "$_mbwps_handoff" != pending ] || return 1
      ;;
    *)
      _mbwps_handoff=pending
      ;;
  esac
  _mbwps_body=$(printf 'parent_run_id=%s\nhandoff_id=%s\nwatchdog_state=%s' \
    "$_run_id" "$_mbwps_handoff" "$_mbwps_state")
  _merv_boot_watchdog_publish_atomic "$_context_file" "$_mbwps_body" context
}

_merv_boot_watchdog_claim_marker() {
  local _mbwcm_run="${_run_id:-}"
  _merv_boot_watchdog_valid_id "$_mbwcm_run" || return 1
  _merv_boot_watchdog_publish_atomic "$_shield_marker" "run_id=$_mbwcm_run" marker
}

# Validate the small identifier grammar used by boot publications.  These
# values are untrusted text once they are read back from /tmp, so no value is
# ever forwarded to a command or used in a path before this check succeeds.
_merv_boot_watchdog_valid_id() {
  case "${1:-}" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Generate a same-directory temporary name that is not predictable from $$.
# The legacy .tag.$$ name is rejected when it is obstructed so a stale test or
# attacker-created symlink cannot become an alternate write target.
_merv_boot_watchdog_temp_begin() {
  local _mbwtb_base="$1" _mbwtb_tag="$2" _mbwtb_legacy _mbwtb_now
  local _mbwtb_seq _mbwtb_suffix
  [ -n "$_mbwtb_base" ] && [ -n "$_mbwtb_tag" ] || return 1
  _mbwtb_legacy="${_mbwtb_base}.${_mbwtb_tag}.$$"
  [ ! -L "$_mbwtb_legacy" ] || return 1
  if type merv_identity_nonce_next >/dev/null 2>&1; then
    merv_identity_nonce_next || return 1
    _mbwtb_suffix="${MERV_IDENTITY_NONCE:-}"
  else
    case "${MERV_BOOT_WATCHDOG_TMP_SEQ:-0}" in
      ''|*[!0-9]*) MERV_BOOT_WATCHDOG_TMP_SEQ=0 ;;
    esac
    MERV_BOOT_WATCHDOG_TMP_SEQ=$((MERV_BOOT_WATCHDOG_TMP_SEQ + 1))
    _mbwtb_now=$(date +%s 2>/dev/null || printf '0')
    case "$_mbwtb_now" in ''|*[!0-9]*) _mbwtb_now=0 ;; esac
    _mbwtb_suffix="$_mbwtb_now.$$.$MERV_BOOT_WATCHDOG_TMP_SEQ"
  fi
  case "$_mbwtb_suffix" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  _MERV_BOOT_WATCHDOG_TMP="${_mbwtb_base}.${_mbwtb_tag}.${_mbwtb_suffix}"
  [ ! -e "$_MERV_BOOT_WATCHDOG_TMP" ] &&
    [ ! -L "$_MERV_BOOT_WATCHDOG_TMP" ]
}

# Publish one complete text value with a same-directory rename.  The caller
# holds the transient publication lock for shared boot state.  Both the
# destination and generated temporary path are checked without following
# symlinks before and after the write.
_merv_boot_watchdog_publish_atomic() {
  local _mbwpa_path="$1" _mbwpa_body="$2" _mbwpa_tag="${3:-state}" _mbwpa_tmp
  [ -n "$_mbwpa_path" ] || return 1
  [ ! -L "$_mbwpa_path" ] || return 1
  _merv_boot_watchdog_temp_begin "$_mbwpa_path" "$_mbwpa_tag" || return 1
  _mbwpa_tmp="$_MERV_BOOT_WATCHDOG_TMP"
  ( umask 077
    printf '%s\n' "$_mbwpa_body" > "$_mbwpa_tmp"
  ) 2>/dev/null || {
    [ ! -L "$_mbwpa_tmp" ] && rm -f "$_mbwpa_tmp" 2>/dev/null || :
    return 1
  }
  [ ! -L "$_mbwpa_tmp" ] && [ -f "$_mbwpa_tmp" ] || {
    [ ! -L "$_mbwpa_tmp" ] && rm -f "$_mbwpa_tmp" 2>/dev/null || :
    return 1
  }
  [ ! -L "$_mbwpa_path" ] || {
    [ ! -L "$_mbwpa_tmp" ] && rm -f "$_mbwpa_tmp" 2>/dev/null || :
    return 1
  }
  mv "$_mbwpa_tmp" "$_mbwpa_path" 2>/dev/null || {
    [ ! -L "$_mbwpa_tmp" ] && rm -f "$_mbwpa_tmp" 2>/dev/null || :
    return 1
  }
  return 0
}

_merv_boot_watchdog_read_lines() {
  local _mbwrl_path="$1" _mbwrl_expected="$2" _mbwrl_lines
  [ ! -L "$_mbwrl_path" ] && [ -f "$_mbwrl_path" ] || return 1
  _mbwrl_lines=$(wc -l < "$_mbwrl_path" 2>/dev/null | awk '{print $1}') || return 1
  [ "$_mbwrl_lines" = "$_mbwrl_expected" ] || return 1
  _MERV_BOOT_WATCHDOG_BODY=$(cat "$_mbwrl_path" 2>/dev/null) || return 1
  return 0
}

_merv_boot_watchdog_marker_read() {
  local _mbwmr_path="$1" _mbwmr_run
  _merv_boot_watchdog_read_lines "$_mbwmr_path" 1 || return 1
  _mbwmr_run="${_MERV_BOOT_WATCHDOG_BODY#run_id=}"
  [ "$_MERV_BOOT_WATCHDOG_BODY" = "run_id=$_mbwmr_run" ] || return 1
  _merv_boot_watchdog_valid_id "$_mbwmr_run" || return 1
  MERV_BOOT_WATCHDOG_MARKER_RUN="$_mbwmr_run"
  return 0
}

_merv_boot_watchdog_uint_read() {
  local _mbwur_path="$1" _mbwur_value
  _merv_boot_watchdog_read_lines "$_mbwur_path" 1 || return 1
  _mbwur_value="$_MERV_BOOT_WATCHDOG_BODY"
  case "$_mbwur_value" in ''|*[!0-9]*) return 1 ;; esac
  case "$_mbwur_value" in *[1-9]*) ;; *) return 1 ;; esac
  MERV_BOOT_WATCHDOG_UINT="$_mbwur_value"
  return 0
}

_merv_boot_watchdog_context_read() {
  local _mbwcr_path="$1" _mbwcr_expected_run="${2:-}"
  local _mbwcr_parent _mbwcr_handoff _mbwcr_state _mbwcr_expected
  _merv_boot_watchdog_read_lines "$_mbwcr_path" 3 || return 1
  _mbwcr_parent=$(printf '%s\n' "$_MERV_BOOT_WATCHDOG_BODY" | sed -n 's/^parent_run_id=//p' | head -n 1)
  _mbwcr_handoff=$(printf '%s\n' "$_MERV_BOOT_WATCHDOG_BODY" | sed -n 's/^handoff_id=//p' | head -n 1)
  _mbwcr_state=$(printf '%s\n' "$_MERV_BOOT_WATCHDOG_BODY" | sed -n 's/^watchdog_state=//p' | head -n 1)
  _merv_boot_watchdog_valid_id "$_mbwcr_parent" || return 1
  _merv_boot_watchdog_valid_id "$_mbwcr_handoff" || return 1
  [ -n "$_mbwcr_state" ] || return 1
  case "$_mbwcr_state" in
    starting|owner-active|handoff-published|uncertain|abandoned|successor-verified|terminal-complete) ;;
    *) return 1 ;;
  esac
  [ -z "$_mbwcr_expected_run" ] || [ "$_mbwcr_parent" = "$_mbwcr_expected_run" ] || return 1
  case "$_mbwcr_state" in
    handoff-published|successor-verified|terminal-complete)
      [ "$_mbwcr_handoff" != pending ] || return 1
      ;;
    *) [ "$_mbwcr_handoff" = pending ] || return 1 ;;
  esac
  _mbwcr_expected=$(printf 'parent_run_id=%s\nhandoff_id=%s\nwatchdog_state=%s' \
    "$_mbwcr_parent" "$_mbwcr_handoff" "$_mbwcr_state")
  [ "$_MERV_BOOT_WATCHDOG_BODY" = "$_mbwcr_expected" ] || return 1
  MERV_BOOT_WATCHDOG_CONTEXT_RUN="$_mbwcr_parent"
  MERV_BOOT_WATCHDOG_CONTEXT_HANDOFF="$_mbwcr_handoff"
  MERV_BOOT_WATCHDOG_CONTEXT_STATE="$_mbwcr_state"
  return 0
}

_merv_boot_watchdog_transient_matches() {
  local _mbwtm_path="$1" _mbwtm_kind="$2" _mbwtm_start _mbwtm_pid
  [ ! -L "$_mbwtm_path" ] || return 1
  [ -f "$_mbwtm_path" ] || return 1
  case "$_mbwtm_kind" in
    marker)
      _merv_boot_watchdog_marker_read "$_mbwtm_path" || return 1
      [ "${MERV_BOOT_WATCHDOG_MARKER_RUN:-}" = "${_run_id:-}" ]
      ;;
    context)
      _merv_boot_watchdog_context_read "$_mbwtm_path" "${_run_id:-}" || return 1
      [ "${MERV_BOOT_WATCHDOG_CONTEXT_HANDOFF:-pending}" = "${_handoff_id:-pending}" ]
      ;;
    pid)
      _merv_boot_watchdog_uint_read "$_mbwtm_path" || return 1
      _mbwtm_pid="${MERV_BOOT_WATCHDOG_UINT:-}"
      [ "$_mbwtm_pid" = "$$" ]
      ;;
    pid-start)
      _merv_boot_watchdog_uint_read "$_mbwtm_path" || return 1
      _mbwtm_start="${MERV_BOOT_WATCHDOG_UINT:-}"
      type merv_proc_start_time >/dev/null 2>&1 || return 1
      [ "$_mbwtm_start" = "$(merv_proc_start_time "$$" 2>/dev/null || printf '')" ]
      ;;
    ready)
      _merv_boot_watchdog_uint_read "$_mbwtm_path" || return 1
      _mbwtm_pid="${MERV_BOOT_WATCHDOG_UINT:-}"
      [ "$_mbwtm_pid" = "$$" ]
      ;;
    *) return 1 ;;
  esac
}

_merv_boot_watchdog_expected_matches() {
  local _mbwem_path="$1" _mbwem_kind="$2" _mbwem_run="$3"
  local _mbwem_pid="$4" _mbwem_start="$5" _mbwem_handoff="$6"
  local _mbwem_state="$7" _mbwem_value
  [ ! -L "$_mbwem_path" ] || return 1
  [ -f "$_mbwem_path" ] || return 1
  case "$_mbwem_kind" in
    marker)
      _merv_boot_watchdog_marker_read "$_mbwem_path" || return 1
      [ "${MERV_BOOT_WATCHDOG_MARKER_RUN:-}" = "$_mbwem_run" ]
      ;;
    context)
      _merv_boot_watchdog_context_read "$_mbwem_path" "$_mbwem_run" || return 1
      [ "${MERV_BOOT_WATCHDOG_CONTEXT_HANDOFF:-}" = "$_mbwem_handoff" ] || return 1
      [ -z "$_mbwem_state" ] || [ "${MERV_BOOT_WATCHDOG_CONTEXT_STATE:-}" = "$_mbwem_state" ]
      ;;
    pid|ready)
      _merv_boot_watchdog_uint_read "$_mbwem_path" || return 1
      _mbwem_value="${MERV_BOOT_WATCHDOG_UINT:-}"
      [ "$_mbwem_value" = "$_mbwem_pid" ]
      ;;
    pid-start)
      _merv_boot_watchdog_uint_read "$_mbwem_path" || return 1
      _mbwem_value="${MERV_BOOT_WATCHDOG_UINT:-}"
      [ "$_mbwem_value" = "$_mbwem_start" ]
      ;;
    *) return 1 ;;
  esac
}

# Classify the complete boot publication while the caller owns the transient
# lock.  `dead-exact` is the only reclaimable state.  Every incomplete,
# malformed, mismatched, or symlink publication is intentionally ambiguous.
_merv_boot_watchdog_classify_publication() {
  local _mbwcp_marker="$1" _mbwcp_pidf="$2" _mbwcp_startf="$3"
  local _mbwcp_context="$4" _mbwcp_ready="$5" _mbwcp_path _mbwcp_any=0
  MERV_BOOT_WATCHDOG_CLASS=absent
  MERV_BOOT_WATCHDOG_RUN=''; MERV_BOOT_WATCHDOG_PID=''
  MERV_BOOT_WATCHDOG_START=''; MERV_BOOT_WATCHDOG_HANDOFF=''
  MERV_BOOT_WATCHDOG_STATE=''
  for _mbwcp_path in "$_mbwcp_marker" "$_mbwcp_pidf" "$_mbwcp_startf" \
    "$_mbwcp_context" "$_mbwcp_ready"; do
    if [ -L "$_mbwcp_path" ]; then
      MERV_BOOT_WATCHDOG_CLASS=ambiguous
      return 0
    fi
    if [ -e "$_mbwcp_path" ]; then
      _mbwcp_any=1
      [ -f "$_mbwcp_path" ] || {
        MERV_BOOT_WATCHDOG_CLASS=ambiguous
        return 0
      }
    fi
  done
  [ "$_mbwcp_any" -eq 1 ] || return 0
  [ -e "$_mbwcp_marker" ] && [ -e "$_mbwcp_pidf" ] &&
    [ -e "$_mbwcp_startf" ] && [ -e "$_mbwcp_context" ] || {
      MERV_BOOT_WATCHDOG_CLASS=ambiguous
      return 0
    }
  _merv_boot_watchdog_marker_read "$_mbwcp_marker" || {
    MERV_BOOT_WATCHDOG_CLASS=ambiguous
    return 0
  }
  MERV_BOOT_WATCHDOG_RUN="$MERV_BOOT_WATCHDOG_MARKER_RUN"
  _merv_boot_watchdog_uint_read "$_mbwcp_pidf" || {
    MERV_BOOT_WATCHDOG_CLASS=ambiguous
    return 0
  }
  MERV_BOOT_WATCHDOG_PID="$MERV_BOOT_WATCHDOG_UINT"
  _merv_boot_watchdog_uint_read "$_mbwcp_startf" || {
    MERV_BOOT_WATCHDOG_CLASS=ambiguous
    return 0
  }
  MERV_BOOT_WATCHDOG_START="$MERV_BOOT_WATCHDOG_UINT"
  _merv_boot_watchdog_context_read "$_mbwcp_context" "$MERV_BOOT_WATCHDOG_RUN" || {
    MERV_BOOT_WATCHDOG_CLASS=ambiguous
    return 0
  }
  MERV_BOOT_WATCHDOG_HANDOFF="$MERV_BOOT_WATCHDOG_CONTEXT_HANDOFF"
  MERV_BOOT_WATCHDOG_STATE="$MERV_BOOT_WATCHDOG_CONTEXT_STATE"
  if [ -e "$_mbwcp_ready" ] && {
    ! _merv_boot_watchdog_expected_matches "$_mbwcp_ready" ready \
      "$MERV_BOOT_WATCHDOG_RUN" "$MERV_BOOT_WATCHDOG_PID" \
      "$MERV_BOOT_WATCHDOG_START" "$MERV_BOOT_WATCHDOG_HANDOFF" \
      "$MERV_BOOT_WATCHDOG_STATE"; }; then
    MERV_BOOT_WATCHDOG_CLASS=ambiguous
    return 0
  fi
  if type merv_process_identity_matches >/dev/null 2>&1 &&
     merv_process_identity_matches "$MERV_BOOT_WATCHDOG_PID" \
       "$MERV_BOOT_WATCHDOG_START" 2>/dev/null; then
    MERV_BOOT_WATCHDOG_CLASS=live-exact
  elif kill -0 "$MERV_BOOT_WATCHDOG_PID" 2>/dev/null; then
    MERV_BOOT_WATCHDOG_CLASS=live-reused
  else
    MERV_BOOT_WATCHDOG_CLASS=dead-exact
  fi
  return 0
}

_merv_boot_watchdog_quarantine_expected() {
  local _mbwqe_run="$1" _mbwqe_pid="$2" _mbwqe_start="$3"
  local _mbwqe_handoff="$4" _mbwqe_state="$5" _mbwqe_path _mbwqe_kind _mbwqe_tomb
  for _mbwqe_path in "${_shield_marker:-}" "${_context_file:-}" \
    "${_ready_file:-}" "${_pid_file:-}" "${_pid_start_file:-}"; do
    [ -n "$_mbwqe_path" ] || continue
    if [ -L "$_mbwqe_path" ]; then return 1; fi
    [ -e "$_mbwqe_path" ] || continue
    case "$_mbwqe_path" in
      "${_shield_marker:-}") _mbwqe_kind=marker ;;
      "${_context_file:-}") _mbwqe_kind=context ;;
      "${_ready_file:-}") _mbwqe_kind=ready ;;
      "${_pid_file:-}") _mbwqe_kind=pid ;;
      *) _mbwqe_kind=pid-start ;;
    esac
    _merv_boot_watchdog_expected_matches "$_mbwqe_path" "$_mbwqe_kind" \
      "$_mbwqe_run" "$_mbwqe_pid" "$_mbwqe_start" \
      "$_mbwqe_handoff" "$_mbwqe_state" || return 1
  done
  for _mbwqe_path in "${_shield_marker:-}" "${_context_file:-}" \
    "${_ready_file:-}" "${_pid_file:-}" "${_pid_start_file:-}"; do
    [ -n "$_mbwqe_path" ] || continue
    [ -e "$_mbwqe_path" ] || continue
    case "$_mbwqe_path" in
      "${_shield_marker:-}") _mbwqe_kind=marker ;;
      "${_context_file:-}") _mbwqe_kind=context ;;
      "${_ready_file:-}") _mbwqe_kind=ready ;;
      "${_pid_file:-}") _mbwqe_kind=pid ;;
      *) _mbwqe_kind=pid-start ;;
    esac
    _merv_boot_watchdog_temp_begin "$_mbwqe_path" cleanup || return 1
    _mbwqe_tomb="$_MERV_BOOT_WATCHDOG_TMP"
    mv "$_mbwqe_path" "$_mbwqe_tomb" 2>/dev/null || return 1
    if _merv_boot_watchdog_expected_matches "$_mbwqe_tomb" "$_mbwqe_kind" \
      "$_mbwqe_run" "$_mbwqe_pid" "$_mbwqe_start" \
      "$_mbwqe_handoff" "$_mbwqe_state"; then
      [ ! -L "$_mbwqe_tomb" ] || return 1
      rm -f "$_mbwqe_tomb" 2>/dev/null || return 1
    else
      if [ ! -e "$_mbwqe_path" ] && [ ! -L "$_mbwqe_path" ]; then
        mv "$_mbwqe_tomb" "$_mbwqe_path" 2>/dev/null || :
      fi
      return 1
    fi
  done
  return 0
}

_merv_boot_watchdog_reclaim_publication() {
  local _mbwrp_marker="$1" _mbwrp_pidf="$2" _mbwrp_startf="$3"
  local _mbwrp_context="$4" _mbwrp_ready="$5"
  local _shield_marker="$_mbwrp_marker" _pid_file="$_mbwrp_pidf"
  local _pid_start_file="$_mbwrp_startf" _context_file="$_mbwrp_context"
  local _ready_file="$_mbwrp_ready"
  _merv_boot_watchdog_classify_publication "$_mbwrp_marker" "$_mbwrp_pidf" \
    "$_mbwrp_startf" "$_mbwrp_context" "$_mbwrp_ready" || return 1
  [ "${MERV_BOOT_WATCHDOG_CLASS:-}" = dead-exact ] || return 1
  _merv_boot_watchdog_quarantine_expected "$MERV_BOOT_WATCHDOG_RUN" \
    "$MERV_BOOT_WATCHDOG_PID" "$MERV_BOOT_WATCHDOG_START" \
    "$MERV_BOOT_WATCHDOG_HANDOFF" "$MERV_BOOT_WATCHDOG_STATE"
}

# Roll back a parent publication that failed before the watchdog could take
# ownership.  The caller still holds the transient lock.  Only the exact
# partial publication for this parent may be retired; any symlink, malformed
# artifact, replacement, or lost lock ownership remains for reconciliation.
_merv_boot_watchdog_parent_rollback_matches() {
  local _mbwprm_stage="$1" _mbwprm_pid="$2" _mbwprm_start="$3"
  local _mbwprm_check_process="${4:-yes}" _mbwprm_path
  type merv_owner_lock_owner_matches >/dev/null 2>&1 || return 1
  [ -n "${_watchdog_transient_lock:-}" ] && [ -n "${MERV_LOCK_NONCE:-}" ] || return 1
  merv_owner_lock_owner_matches "$_watchdog_transient_lock" "$MERV_LOCK_NONCE" || return 1
  _merv_boot_watchdog_valid_id "${_run_id:-}" || return 1
  case "$_mbwprm_pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$_mbwprm_start" in ''|*[!0-9]*) return 1 ;; esac
  for _mbwprm_path in "${_shield_marker:-}" "${_pid_file:-}" \
    "${_pid_start_file:-}" "${_context_file:-}" "${_ready_file:-}"; do
    [ -n "$_mbwprm_path" ] && [ ! -L "$_mbwprm_path" ] || return 1
  done
  _merv_boot_watchdog_expected_matches "$_shield_marker" marker "$_run_id" \
    "$_mbwprm_pid" "$_mbwprm_start" pending starting || return 1
  [ ! -e "$_ready_file" ] || return 1
  case "$_mbwprm_stage" in
    marker)
      [ ! -e "$_pid_file" ] && [ ! -e "$_pid_start_file" ] && [ ! -e "$_context_file" ] || return 1
      ;;
    pid)
      _merv_boot_watchdog_expected_matches "$_pid_file" pid "$_run_id" \
        "$_mbwprm_pid" "$_mbwprm_start" pending starting || return 1
      [ ! -e "$_pid_start_file" ] && [ ! -e "$_context_file" ] || return 1
      ;;
    pid-start)
      _merv_boot_watchdog_expected_matches "$_pid_file" pid "$_run_id" \
        "$_mbwprm_pid" "$_mbwprm_start" pending starting || return 1
      _merv_boot_watchdog_expected_matches "$_pid_start_file" pid-start "$_run_id" \
        "$_mbwprm_pid" "$_mbwprm_start" pending starting || return 1
      [ ! -e "$_context_file" ] || return 1
      ;;
    *) return 1 ;;
  esac
  if [ "$_mbwprm_check_process" = yes ]; then
    type merv_process_identity_matches >/dev/null 2>&1 || return 1
    merv_process_identity_matches "$_mbwprm_pid" "$_mbwprm_start" 2>/dev/null || return 1
  fi
  return 0
}

_merv_boot_watchdog_parent_rollback_after_term() {
  local _mbwprat_stage="$1" _mbwprat_pid="$2" _mbwprat_start="$3" _mbwprat_term_rc="$4"
  local _mbwprat_attempt=0 _mbwprat_stat
  # TERM can briefly leave the authenticated child live or zombied in /proc.
  # A successful TERM receives a bounded same-identity wait; a failed TERM
  # never waits out a live child.  In both cases retirement requires exact
  # publication/lock reinspection plus authoritative stat disappearance.
  while [ "$_mbwprat_attempt" -lt 3 ]; do
    _merv_boot_watchdog_parent_rollback_matches "$_mbwprat_stage" \
      "$_mbwprat_pid" "$_mbwprat_start" no || return 1
    if merv_process_identity_matches "$_mbwprat_pid" "$_mbwprat_start" 2>/dev/null; then
      [ "$_mbwprat_term_rc" -eq 0 ] || return 1
      sleep 1
      _mbwprat_attempt=$((_mbwprat_attempt + 1))
      continue
    fi
    # A surviving PID is either reused or cannot be authenticated.  Preserve
    # it rather than acting on PID evidence alone.
    kill -0 "$_mbwprat_pid" 2>/dev/null && return 1
    _mbwprat_stat="/proc/$_mbwprat_pid/stat"
    [ ! -e "$_mbwprat_stat" ] || return 1
    _merv_boot_watchdog_parent_rollback_matches "$_mbwprat_stage" \
      "$_mbwprat_pid" "$_mbwprat_start" no
    return $?
  done
  return 1
}

_merv_boot_watchdog_parent_rollback() {
  local _mbwpr_stage="$1" _mbwpr_pid="$2" _mbwpr_start="$3" _mbwpr_term_rc
  _merv_boot_watchdog_parent_rollback_matches "$_mbwpr_stage" \
    "$_mbwpr_pid" "$_mbwpr_start" yes || return 1
  # PID/start identity was just verified while the parent still owns the
  # publication lock; never signal a process on PID evidence alone.
  # A failed TERM can race a normal child exit.  Its result alone is not an
  # ownership decision: perform one bounded, authoritative reinspection under
  # the still-owned lock.  A live/reused PID, replacement, malformed state, or
  # lost owner record remains untouched; only the unchanged exact publication
  # for a now-absent PID may be quarantined.
  if kill -TERM "$_mbwpr_pid" 2>/dev/null; then
    _mbwpr_term_rc=0
  else
    _mbwpr_term_rc=1
  fi
  _merv_boot_watchdog_parent_rollback_after_term "$_mbwpr_stage" \
    "$_mbwpr_pid" "$_mbwpr_start" "$_mbwpr_term_rc" || return 1
  _merv_boot_watchdog_quarantine_expected "$_run_id" "$_mbwpr_pid" \
    "$_mbwpr_start" pending starting
}

_merv_boot_watchdog_readiness_valid() {
  local _mbwrv_run="$1" _mbwrv_pid="$2" _mbwrv_start="$3"
  local _mbwrv_marker="$4" _mbwrv_ready="$5" _mbwrv_context="$6"
  local _mbwrv_pid_file="$7" _mbwrv_start_file="$8"
  local _mbwrv_rc=1 _mbwrv_leave_rc
  _merv_boot_watchdog_transient_lock_enter || return 1
  if _merv_boot_watchdog_marker_read "$_mbwrv_marker" &&
     [ "${MERV_BOOT_WATCHDOG_MARKER_RUN:-}" = "$_mbwrv_run" ] &&
     _merv_boot_watchdog_expected_matches "$_mbwrv_pid_file" pid "$_mbwrv_run" \
       "$_mbwrv_pid" "$_mbwrv_start" pending pending &&
     _merv_boot_watchdog_expected_matches "$_mbwrv_start_file" pid-start "$_mbwrv_run" \
       "$_mbwrv_pid" "$_mbwrv_start" pending pending &&
     _merv_boot_watchdog_context_read "$_mbwrv_context" "$_mbwrv_run" &&
     [ "${MERV_BOOT_WATCHDOG_CONTEXT_STATE:-}" = handoff-published ] &&
     [ "${MERV_BOOT_WATCHDOG_CONTEXT_HANDOFF:-}" != pending ] &&
     _merv_boot_watchdog_expected_matches "$_mbwrv_ready" ready "$_mbwrv_run" \
       "$_mbwrv_pid" "$_mbwrv_start" "$MERV_BOOT_WATCHDOG_CONTEXT_HANDOFF" \
       handoff-published &&
     type merv_process_identity_matches >/dev/null 2>&1 &&
     merv_process_identity_matches "$_mbwrv_pid" "$_mbwrv_start" 2>/dev/null; then
    _mbwrv_rc=0
  fi
  _merv_boot_watchdog_transient_lock_leave
  _mbwrv_leave_rc=$?
  [ "$_mbwrv_leave_rc" -eq 0 ] || _mbwrv_rc=1
  return "$_mbwrv_rc"
}

_merv_boot_watchdog_cleanup_one() {
  local _mbwco_path="$1" _mbwco_kind="$2" _mbwco_tomb
  [ ! -L "$_mbwco_path" ] || return 1
  [ -e "$_mbwco_path" ] || return 0
  _merv_boot_watchdog_transient_matches "$_mbwco_path" "$_mbwco_kind" || return 1
  _merv_boot_watchdog_temp_begin "$_mbwco_path" cleanup || return 1
  _mbwco_tomb="$_MERV_BOOT_WATCHDOG_TMP"
  # Rename first, then verify the renamed inode.  A replacement watchdog that
  # atomically republishes the original path is left untouched at that path;
  # the old inode is either removed or retained as a private tombstone.
  mv "$_mbwco_path" "$_mbwco_tomb" 2>/dev/null || return 1
  if _merv_boot_watchdog_transient_matches "$_mbwco_tomb" "$_mbwco_kind"; then
    [ ! -L "$_mbwco_tomb" ] || return 1
    rm -f "$_mbwco_tomb" 2>/dev/null || return 1
    return 0
  fi
  warn -c boot,vlan "Shield: watchdog transient replacement detected; retaining $_mbwco_path"
  # Never overwrite a replacement at the public path.  Restore the old inode
  # only if the public path is still absent; otherwise keep the mismatched old
  # inode quarantined for the next reconciliation pass.
  if [ ! -e "$_mbwco_path" ] && [ ! -L "$_mbwco_path" ]; then
    mv "$_mbwco_tomb" "$_mbwco_path" 2>/dev/null || :
  fi
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

# Keep post-handoff diagnostics useful without exposing the DHCP token or
# handoff identity.  The publication lock is intentionally observed only;
# this helper never changes ownership or publication state.
_merv_boot_watchdog_log_stage_failure() {
  local _mbwls_stage="$1" _mbwls_rc="$2" _mbwls_start _mbwls_lock_st
  _mbwls_start=$(merv_identity_current_start 2>/dev/null ||
    merv_proc_start_time "$$" 2>/dev/null || printf 'unknown')
  _mbwls_lock_st=$(merv_owner_lock_state "${_watchdog_transient_lock:-}" \
    2>/dev/null || printf 'unavailable')
  warn -c boot,vlan "Shield: watchdog startup failure stage=$_mbwls_stage rc=$_mbwls_rc pid=$$ start=$_mbwls_start lock_state=$_mbwls_lock_st"
}

# Validate and publish the ready-side handoff state one predicate at a time.
# This is deliberately equivalent to the historical short-circuit expression:
# order and fail-closed behavior remain unchanged, while each failed predicate
# now identifies its exact stage and return code.
_merv_boot_watchdog_publish_ready_state() {
  local _mbwprs_marker="$1" _mbwprs_ready="$2" _mbwprs_context="$3"
  local _mbwprs_pid_file="$4" _mbwprs_start_file="$5" _mbwprs_run="$6"
  local _mbwprs_pid="$7" _mbwprs_start="$8" _mbwprs_handoff="$9" _mbwprs_rc

  _merv_boot_watchdog_marker_read "$_mbwprs_marker"
  _mbwprs_rc=$?
  if [ "$_mbwprs_rc" -ne 0 ]; then
    _merv_boot_watchdog_log_stage_failure ready-publication-marker-read "$_mbwprs_rc"
    return "$_mbwprs_rc"
  fi

  [ "${MERV_BOOT_WATCHDOG_MARKER_RUN:-}" = "$_mbwprs_run" ]
  _mbwprs_rc=$?
  if [ "$_mbwprs_rc" -ne 0 ]; then
    _merv_boot_watchdog_log_stage_failure ready-publication-marker-match "$_mbwprs_rc"
    return "$_mbwprs_rc"
  fi

  _merv_boot_watchdog_expected_matches "$_mbwprs_pid_file" pid "$_mbwprs_run" \
    "$_mbwprs_pid" "$_mbwprs_start" "$_mbwprs_handoff" owner-active
  _mbwprs_rc=$?
  if [ "$_mbwprs_rc" -ne 0 ]; then
    _merv_boot_watchdog_log_stage_failure ready-publication-pid "$_mbwprs_rc"
    return "$_mbwprs_rc"
  fi

  _merv_boot_watchdog_expected_matches "$_mbwprs_start_file" pid-start \
    "$_mbwprs_run" "$_mbwprs_pid" "$_mbwprs_start" "$_mbwprs_handoff" owner-active
  _mbwprs_rc=$?
  if [ "$_mbwprs_rc" -ne 0 ]; then
    _merv_boot_watchdog_log_stage_failure ready-publication-pid-start "$_mbwprs_rc"
    return "$_mbwprs_rc"
  fi

  merv_process_identity_matches "$_mbwprs_pid" "$_mbwprs_start" 2>/dev/null
  _mbwprs_rc=$?
  if [ "$_mbwprs_rc" -ne 0 ]; then
    _merv_boot_watchdog_log_stage_failure ready-publication-process "$_mbwprs_rc"
    return "$_mbwprs_rc"
  fi

  _merv_boot_watchdog_publish_state handoff-published
  _mbwprs_rc=$?
  if [ "$_mbwprs_rc" -ne 0 ]; then
    _merv_boot_watchdog_log_stage_failure ready-publication-context "$_mbwprs_rc"
    return "$_mbwprs_rc"
  fi

  _merv_boot_watchdog_publish_atomic "$_mbwprs_ready" "$_mbwprs_pid" ready
  _mbwprs_rc=$?
  if [ "$_mbwprs_rc" -ne 0 ]; then
    _merv_boot_watchdog_log_stage_failure ready-publication-ready "$_mbwprs_rc"
    return "$_mbwprs_rc"
  fi
  return 0
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
  local _mbwpo_path
  # The publication lock serializes this check with a replacement _mode_shield
  # startup.  Never overwrite a context/pid publication that no longer proves
  # this run; cleanup will retain that replacement for its owner.
  for _mbwpo_path in "${_shield_marker:-}" "${_ready_file:-}"; do
    if [ -L "$_mbwpo_path" ]; then
      return 1
    fi
  done
  if [ -L "${_context_file:-}" ]; then
    return 1
  fi
  if [ -e "${_context_file:-}" ] &&
     ! _merv_boot_watchdog_transient_matches "$_context_file" context; then
    return 1
  fi
  if [ -L "${_pid_file:-}" ]; then
    return 1
  fi
  if [ -e "${_pid_file:-}" ] &&
     ! _merv_boot_watchdog_transient_matches "$_pid_file" pid; then
    return 1
  fi
  if [ -L "${_pid_start_file:-}" ]; then
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
  local _pid_file="$6" _pid_start_file="${6}.start" _run_id="${7:-}"
  local _handoff_id _token _elapsed=0 _verification _mbwo_path _self_start
  local _watchdog_state=starting _watchdog_cleanup_done=0 _watchdog_cleanup_rc=0 _watchdog_owner_established=1 _watchdog_handoff_inflight=0
  local _watchdog_transient_lock="${LOCKDIR:-/tmp/mervlan_tmp/locks}/merv_boot_shield.transient.lock"
  local _watchdog_transient_lock_held=0
  case "$_max" in ''|*[!0-9]*) _max=480 ;; esac
  trap '_merv_boot_watchdog_signal INT' INT
  trap '_merv_boot_watchdog_signal TERM' TERM
  if ! _merv_boot_watchdog_valid_id "$_run_id"; then
    _run_id="boot-$(date +%s 2>/dev/null || echo 0)-$$"
  fi
  _watchdog_state=owner-active
  _merv_boot_watchdog_transient_lock_enter
  _mbw_rc=$?
  if [ "$_mbw_rc" -ne 0 ]; then
    _mbw_start=$(merv_identity_current_start 2>/dev/null || merv_proc_start_time "$$" 2>/dev/null || printf 'unknown')
    _mbw_lock_st=$(merv_owner_lock_state "$_watchdog_transient_lock" 2>/dev/null || printf 'unavailable')
    warn -c boot,vlan "Shield: watchdog startup failure stage=transient-lock-enter rc=$_mbw_rc pid=$$ start=$_mbw_start lock_state=$_mbw_lock_st"
    _watchdog_state=uncertain
    trap - INT TERM
    return 1
  fi
  for _mbwo_path in "$_shield_marker" "$_ready_file" "$_context_file" \
    "$_pid_file" "$_pid_start_file"; do
    if [ -L "$_mbwo_path" ]; then
      warn -c boot,vlan "Shield: watchdog state path is a symlink; preserving ambiguous state"
      _merv_boot_watchdog_transient_lock_leave || :
      _watchdog_state=uncertain
      trap - INT TERM
      return 1
    fi
  done
  if [ -e "$_shield_marker" ]; then
    _merv_boot_watchdog_marker_read "$_shield_marker"
    _mbw_rc=$?
    [ "$_mbw_rc" -eq 0 ] && [ "${MERV_BOOT_WATCHDOG_MARKER_RUN:-}" = "$_run_id" ] || _mbw_rc=1
  else
    _merv_boot_watchdog_claim_marker
    _mbw_rc=$?
  fi
  if [ "$_mbw_rc" -ne 0 ]; then
    _mbw_start=$(merv_identity_current_start 2>/dev/null || merv_proc_start_time "$$" 2>/dev/null || printf 'unknown')
    _mbw_lock_st=$(merv_owner_lock_state "$_watchdog_transient_lock" 2>/dev/null || printf 'unavailable')
    warn -c boot,vlan "Shield: watchdog startup failure stage=marker-claim rc=$_mbw_rc pid=$$ start=$_mbw_start lock_state=$_mbw_lock_st"
    _merv_boot_watchdog_transient_lock_leave || :
    _watchdog_state=uncertain
    trap - INT TERM
    return 1
  fi
  _self_start=$(merv_proc_start_time "$$" 2>/dev/null || printf '')
  case "$_self_start" in ''|*[!0-9]*|0) _self_start="" ;; esac
  [ -n "$_self_start" ] || {
    warn -c boot,vlan "Shield: watchdog startup failure stage=self-identity pid=$$"
    _merv_boot_watchdog_transient_lock_leave || :
    _watchdog_state=uncertain
    trap - INT TERM
    return 1
  }
  if [ -e "$_pid_file" ]; then
    _merv_boot_watchdog_uint_read "$_pid_file" || _mbw_rc=1
    [ "${MERV_BOOT_WATCHDOG_UINT:-}" = "$$" ] || _mbw_rc=1
  else
    _merv_boot_watchdog_publish_atomic "$_pid_file" "$$" pid || _mbw_rc=1
  fi
  if [ -e "$_pid_start_file" ]; then
    _merv_boot_watchdog_uint_read "$_pid_start_file" || _mbw_rc=1
    [ "${MERV_BOOT_WATCHDOG_UINT:-}" = "$_self_start" ] || _mbw_rc=1
  else
    _merv_boot_watchdog_publish_atomic "$_pid_start_file" "$_self_start" pid-start || _mbw_rc=1
  fi
  if [ "${_mbw_rc:-0}" -ne 0 ]; then
    warn -c boot,vlan "Shield: watchdog startup failure stage=identity-publication pid=$$"
    _merv_boot_watchdog_transient_lock_leave || :
    _watchdog_state=uncertain
    trap - INT TERM
    return 1
  fi
  _merv_boot_watchdog_publish_state owner-active
  _mbw_rc=$?
  if [ "$_mbw_rc" -ne 0 ]; then
    warn -c boot,vlan "Shield: watchdog startup failure stage=context-publication pid=$$"
    _merv_boot_watchdog_transient_lock_leave || :
    _watchdog_state=uncertain
    trap - INT TERM
    return 1
  fi
  _merv_boot_watchdog_transient_lock_leave
  _mbw_rc=$?
  if [ "$_mbw_rc" -ne 0 ]; then
    _mbw_start=$(merv_identity_current_start 2>/dev/null || merv_proc_start_time "$$" 2>/dev/null || printf 'unknown')
    _mbw_lock_st=$(merv_owner_lock_state "$_watchdog_transient_lock" 2>/dev/null || printf 'unavailable')
    warn -c boot,vlan "Shield: watchdog startup failure stage=transient-lock-leave rc=$_mbw_rc pid=$$ start=$_mbw_start lock_state=$_mbw_lock_st"
    _watchdog_state=uncertain
    trap - INT TERM
    return 1
  fi
  if ! merv_dhcp_hold_acquire boot-watchdog "$_run_id"; then
    warn -c boot,vlan "Shield: watchdog could not acquire boot lease"
    _merv_boot_watchdog_cleanup acquire-failed >/dev/null 2>&1 || :
    trap - INT TERM
    return 1
  fi
  _token="$MERV_DHCP_HOLD_TOKEN"
  _watchdog_handoff_inflight=1
  if ! merv_dhcp_handoff_request "$_token" manager; then
    _merv_boot_watchdog_cleanup boot-handoff-request-failed >/dev/null 2>&1 || :
    trap - INT TERM
    return 1
  fi
  _handoff_id="$MERV_DHCP_HANDOFF_ID"
  _watchdog_handoff_inflight=0
  _watchdog_state=handoff-published
  merv_dhcp_hold_mark_handoff_wait "$_token" "$_handoff_id"
  _mbw_rc=$?
  if [ "$_mbw_rc" -ne 0 ]; then
    _merv_boot_watchdog_log_stage_failure mark-handoff-wait "$_mbw_rc"
    _merv_boot_watchdog_cleanup boot-handoff-wait-failed >/dev/null 2>&1 || :
    trap - INT TERM
    return 1
  fi
  _merv_boot_watchdog_transient_lock_enter
  _mbw_rc=$?
  if [ "$_mbw_rc" -ne 0 ]; then
    _merv_boot_watchdog_log_stage_failure ready-lock-enter "$_mbw_rc"
    _merv_boot_watchdog_cleanup boot-ready-lock-enter-failed >/dev/null 2>&1 || :
    trap - INT TERM
    return 1
  fi
  _merv_boot_watchdog_publish_ready_state \
    "$_shield_marker" "$_ready_file" "$_context_file" \
    "$_pid_file" "$_pid_start_file" "$_run_id" "$$" \
    "$_self_start" "$_handoff_id"
  _mbw_rc=$?
  if [ "$_mbw_rc" -ne 0 ]; then
    _merv_boot_watchdog_transient_lock_leave || :
    _merv_boot_watchdog_cleanup boot-context-publish-failed >/dev/null 2>&1 || :
    trap - INT TERM
    return 1
  fi
  _merv_boot_watchdog_transient_lock_leave
  _mbw_rc=$?
  if [ "$_mbw_rc" -ne 0 ]; then
    _merv_boot_watchdog_log_stage_failure ready-lock-leave "$_mbw_rc"
    _merv_boot_watchdog_cleanup boot-ready-lock-leave-failed >/dev/null 2>&1 || :
    trap - INT TERM
    return 1
  fi

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
  local _max="${MERV_BOOT_SHIELD_MAX_SEC:-480}" _shield_pid _shield_start _wait=0 _shield_path
  local _run_id _handoff_id=pending _watchdog_state=starting _boot_pub_class
  local _context_file _ready_file _pid_file _pid_start_file
  local _watchdog_transient_lock="${LOCKDIR:-/tmp/mervlan_tmp/locks}/merv_boot_shield.transient.lock"
  case "$_max" in ''|*[!0-9]*) _max=480 ;; esac
  _context_file="$_shield_context"
  _ready_file="$_shield_ready"
  _pid_file="$_shield_pidf"
  _pid_start_file="$_shield_pid_startf"

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
  info -c boot,vlan "Shield: transient publication lock acquired (pid=$$)"

  _merv_boot_watchdog_classify_publication "$_shield_marker" "$_shield_pidf" \
    "$_shield_pid_startf" "$_shield_context" "$_shield_ready"
  _boot_pub_class="${MERV_BOOT_WATCHDOG_CLASS:-ambiguous}"
  case "$_boot_pub_class" in
    absent)
      ;;
    live-exact)
      info -c boot,vlan "Shield: token watchdog already active (pid=$MERV_BOOT_WATCHDOG_PID)"
      _merv_boot_watchdog_transient_lock_leave || return 1
      return 0
      ;;
    dead-exact)
      if ! _merv_boot_watchdog_reclaim_publication "$_shield_marker" "$_shield_pidf" \
        "$_shield_pid_startf" "$_shield_context" "$_shield_ready"; then
        warn -c boot,vlan "Shield: exact dead watchdog publication could not be reclaimed; preserving state"
        _merv_boot_watchdog_transient_lock_leave || :
        return 1
      fi
      info -c boot,vlan "Shield: reclaimed exact dead watchdog publication"
      ;;
    live-reused|ambiguous|*)
      warn -c boot,vlan "Shield: watchdog publication is ${_boot_pub_class}; preserving state"
      _merv_boot_watchdog_transient_lock_leave || :
      return 1
      ;;
  esac

  _run_id="boot-$(date +%s 2>/dev/null || echo 0)-$$"
  _merv_boot_watchdog_valid_id "$_run_id" || {
    _merv_boot_watchdog_transient_lock_leave || :
    return 1
  }
  _merv_boot_watchdog_claim_marker || {
    _merv_boot_watchdog_transient_lock_leave || :
    return 1
  }
  "$0" shield-watchdog "$_shield_marker" "$_shield_ready" "$_shield_context" "$_max" "$_shield_pidf" "$_run_id" \
    </dev/null >/dev/null 2>&1 &
  _shield_pid=$!
  _shield_start=$(merv_proc_start_time "$_shield_pid" 2>/dev/null || printf '')
  info -c boot,vlan "Shield: watchdog process forked (pid=$_shield_pid, start=$_shield_start)"
  case "$_shield_start" in ''|*[!0-9]*)
    # The initial /proc observation can fail transiently during early boot.
    # Retry while this parent still owns the publication lock; only a numeric
    # retry can authenticate PID/start for exact marker rollback. A persistent
    # failure remains durable rather than making a PID-only decision.
    _shield_start=$(merv_proc_start_time "$_shield_pid" 2>/dev/null || printf '')
    case "$_shield_start" in ''|*[!0-9]*)
      warn -c boot,vlan "Shield: parent rollback retained marker; watchdog identity could not be authenticated"
      ;;
    *)
      _merv_boot_watchdog_parent_rollback marker "$_shield_pid" "$_shield_start" ||
        warn -c boot,vlan "Shield: parent rollback retained an unverified marker publication"
      ;;
    esac
    _merv_boot_watchdog_transient_lock_leave || :
    return 1
    ;;
  esac
  if ! _merv_boot_watchdog_publish_atomic "$_shield_pidf" "$_shield_pid" pid; then
    _merv_boot_watchdog_parent_rollback marker "$_shield_pid" "$_shield_start" ||
      warn -c boot,vlan "Shield: parent rollback retained an unverified partial watchdog publication"
    _merv_boot_watchdog_transient_lock_leave || :
    return 1
  fi
  if ! _merv_boot_watchdog_publish_atomic "$_shield_pid_startf" "$_shield_start" pid-start; then
    _merv_boot_watchdog_parent_rollback pid "$_shield_pid" "$_shield_start" ||
      warn -c boot,vlan "Shield: parent rollback retained an unverified partial watchdog publication"
    _merv_boot_watchdog_transient_lock_leave || :
    return 1
  fi
  _merv_boot_watchdog_publish_state starting || {
    _merv_boot_watchdog_parent_rollback pid-start "$_shield_pid" "$_shield_start" ||
      warn -c boot,vlan "Shield: parent rollback retained an unverified partial watchdog publication"
    _merv_boot_watchdog_transient_lock_leave || :
    return 1
  }
  info -c boot,vlan "Shield: watchdog identity published (pid=$_shield_pid, start=$_shield_start)"
  if ! _merv_boot_watchdog_transient_lock_leave; then
    # A failed release loses authoritative publication ownership.  Even an
    # exact PID/start cannot prove that the current run still owns its marker
    # or that a successor has not replaced the publication, so never signal
    # here; retain watchdog and state for a later authoritative reconciliation.
    warn -c boot,vlan "Shield: retained watchdog after transient lock release failure"
    return 1
  fi
  info -c boot,vlan "Shield: transient publication lock released (pid=$$)"

  while [ "$_wait" -lt "${MERV_BOOT_SHIELD_READY_SEC:-10}" ]; do
    if _merv_boot_watchdog_readiness_valid "$_run_id" "$_shield_pid" "$_shield_start" \
      "$_shield_marker" "$_shield_ready" "$_shield_context" "$_shield_pidf" "$_shield_pid_startf"; then
      info -c boot,vlan "Shield: token watchdog ready (pid=$_shield_pid, wait=${_wait}s)"
      return 0
    fi
    sleep 1
    _wait=$((_wait + 1))
  done
  warn -c boot,vlan "Shield: watchdog readiness acknowledgement failed (pid=$_shield_pid, start=$_shield_start, elapsed=${_wait}s)"
  if _merv_boot_watchdog_transient_lock_enter; then
    _merv_boot_watchdog_classify_publication "$_shield_marker" "$_shield_pidf" \
      "$_shield_pid_startf" "$_shield_context" "$_shield_ready"
    if [ "${MERV_BOOT_WATCHDOG_CLASS:-}" = dead-exact ] &&
       [ "${MERV_BOOT_WATCHDOG_RUN:-}" = "$_run_id" ] &&
       [ "${MERV_BOOT_WATCHDOG_PID:-}" = "$_shield_pid" ] &&
       [ "${MERV_BOOT_WATCHDOG_START:-}" = "$_shield_start" ]; then
      _merv_boot_watchdog_quarantine_expected "$_run_id" "$_shield_pid" \
        "$_shield_start" "$MERV_BOOT_WATCHDOG_HANDOFF" "$MERV_BOOT_WATCHDOG_STATE" || :
    fi
    _merv_boot_watchdog_transient_lock_leave || :
  fi
  return 1
}

_is_update_recovery_or_safe_boot_active() {
  if type merv_update_quiesce_active >/dev/null 2>&1 && merv_update_quiesce_active; then
    return 0
  fi
  if type merv_update_journal_requires_safe_boot >/dev/null 2>&1 && merv_update_journal_requires_safe_boot; then
    return 0
  fi
  return 1
}

_merv_boot_maintenance_lock_state() {
  local _maint_lock _maint_parent _maint_state
  _maint_lock=$(type merv_update_maintenance_lock_path >/dev/null 2>&1 && merv_update_maintenance_lock_path || printf '%s/mervlan_maintenance.lock' "${LOCKDIR:-$TMPDIR/locks}")

  # Inspect the path itself before consulting compatibility classifiers.
  # `[ -e ]` follows symlinks and therefore turns a dangling maintenance
  # obstruction into apparent absence.  Only an unreadable-but-authoritatively
  # absent path may proceed; every file, symlink, or non-directory is
  # ambiguous and remains fail-closed.
  _maint_absent=0
  if ! ls -ld "$_maint_lock" >/dev/null 2>&1; then
    _maint_parent=${_maint_lock%/*}
    if [ -d "$_maint_parent" ] && [ -r "$_maint_parent" ] &&
       [ -x "$_maint_parent" ]; then
      _maint_absent=1
    else
      printf 'ambiguous'
      return 0
    fi
  fi
  if [ -L "$_maint_lock" ]; then
    printf 'ambiguous'
    return 0
  fi

  # The shared Update library knows the canonical owner-v2 states.  Keep the
  # compatibility fallback for boot test/legacy contexts that load only the
  # older wrapper surface.
  if type merv_update_maintenance_lock_state >/dev/null 2>&1; then
    _maint_state=$(merv_update_maintenance_lock_state 2>/dev/null || printf 'unknown')
    case "$_maint_state" in
      absent|dead|reused) printf 'absent' ;;
      live) printf 'active' ;;
      *) printf 'ambiguous' ;;
    esac
    return 0
  fi
  if type merv_lock_state >/dev/null 2>&1; then
    case "$(merv_lock_state "$_maint_lock" 2>/dev/null)" in
      absent|stale) printf 'absent' ;;
      active) printf 'active' ;;
      *)
        # Legacy test/firmware shims may return no compatibility state while
        # the path is truly absent.  Preserve that authoritative absence;
        # an existing non-directory still remains ambiguous below.
        [ "$_maint_absent" -eq 1 ] && printf 'absent' || printf 'ambiguous'
        ;;
    esac
  elif type merv_owner_lock_state >/dev/null 2>&1; then
    case "$(merv_owner_lock_state "$_maint_lock" 2>/dev/null)" in
      absent|dead|reused) printf 'absent' ;;
      live) printf 'active' ;;
      *) printf 'ambiguous' ;;
    esac
  elif [ "$_maint_absent" -eq 1 ]; then
    printf 'absent'
  else
    printf 'ambiguous'
  fi
}

_is_update_or_safe_boot_active() {
  if _is_update_recovery_or_safe_boot_active; then
    return 0
  fi
  if type merv_update_mutation_blocked >/dev/null 2>&1 && merv_update_mutation_blocked; then
    return 0
  fi
  case "$(_merv_boot_maintenance_lock_state)" in
    absent) return 1 ;;
    *) return 0 ;;
  esac
}

# ============================================================================ #
# MODE: install                                                                #
# ============================================================================ #
_mode_install() {
  # Install projection is also a mutating caller.  Preserve the dedicated
  # safe-boot recovery path for an authoritative absent/dead/reused owner, but
  # stop immediately on an active, malformed, or otherwise ambiguous lock.
  if type _merv_boot_maintenance_lock_state >/dev/null 2>&1; then
    case "$(_merv_boot_maintenance_lock_state)" in
      absent) ;;
      *)
        warn -c boot "Installer startup suppressed: maintenance lock state is not safely idle"
        return 75
        ;;
    esac
  fi
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

  _boot_enabled=1
  if type json_get_flag >/dev/null 2>&1; then
    _boot_enabled=$(json_get_flag BOOT_ENABLED 1 "${SETTINGS_FILE:-$MERV_BASE/settings/settings.json}" 2>/dev/null)
  fi

  if [ "$_boot_enabled" = "1" ]; then
    info -c boot "Boot enabled — deferring installation projection to boot manager"
    return 0
  fi

  info -c boot "Boot disabled — running install.sh reinstall projection"
  if "$MERV_BASE/install.sh" reinstall >> "$LOG_chan_boot" 2>&1; then
    info -c boot "install.sh reinstall completed successfully (rc=0)"
    _write_flag
    return 0
  else
    _inst_rc=$?
    warn -c boot "install.sh reinstall returned non-zero (rc=$_inst_rc) — flag NOT written"
    return "$_inst_rc"
  fi
}

# ============================================================================ #
# MODE: manager                                                                #
# ============================================================================ #
_mode_manager() {
  local _boot_context="$LOCKDIR/merv_boot_shield.handoff"
  local _boot_marker="$LOCKDIR/merv_boot_shield.active"
  local _watchdog_transient_lock="$LOCKDIR/merv_boot_shield.transient.lock"
  local _boot_parent_run="" _boot_handoff="" _manager_rc=0
  local _boot_parent_valid=0 _boot_handoff_valid=0
  local _boot_marker_run="" _boot_marker_body=""
  local _boot_marker_tomb="" _boot_marker_class=absent _boot_marker_leave_rc=0
  local _manager_teardown_rc=0 _boot_admission_ok=0 _boot_admission_leave_rc=0
  if _is_update_or_safe_boot_active; then
    warn -c boot "Manager startup suppressed: Update recovery/quiesce state is active"
    return 75
  fi

  # No boot-publication symlink is trustworthy.
  # Reject it before install or manager work can mutate the runtime, and leave
  # the obstruction for an authoritative reconciliation pass.
  if [ -L "$_boot_marker" ] || [ -L "$_boot_context" ] ||
     [ -L "$LOCKDIR/merv_boot_shield.pid" ] || [ -L "$LOCKDIR/merv_boot_shield.pid.start" ] ||
     [ -L "$LOCKDIR/merv_boot_shield.ready" ]; then
    warn -c boot "Manager startup suppressed: boot handoff state is an ambiguous symlink"
    return 1
  fi

  # Any boot publication artifact is a claimed handoff, not an optional hint.
  # Authenticate the complete marker/PID/start/context/ready publication
  # before clearing PAUSE, reinstalling, or invoking the manager. A partial,
  # malformed, dead, reused, or pre-handoff claim remains for reconciliation
  # and suppresses startup.
  if [ -e "$_boot_marker" ] || [ -e "$_boot_context" ] || [ -e "$LOCKDIR/merv_boot_shield.pid" ] ||
     [ -e "$LOCKDIR/merv_boot_shield.pid.start" ] || [ -e "$LOCKDIR/merv_boot_shield.ready" ] ||
     [ -L "$_boot_marker" ] || [ -L "$_boot_context" ] || [ -L "$LOCKDIR/merv_boot_shield.pid" ] ||
     [ -L "$LOCKDIR/merv_boot_shield.pid.start" ] || [ -L "$LOCKDIR/merv_boot_shield.ready" ]; then
    _merv_boot_watchdog_transient_lock_enter || {
      warn -c boot "Manager startup suppressed: boot handoff admission lock unavailable"
      return 1
    }
    if _merv_boot_watchdog_classify_publication "$_boot_marker" \
      "$LOCKDIR/merv_boot_shield.pid" "$LOCKDIR/merv_boot_shield.pid.start" \
      "$_boot_context" "$LOCKDIR/merv_boot_shield.ready" &&
       [ "${MERV_BOOT_WATCHDOG_CLASS:-}" = live-exact ] &&
       [ "${MERV_BOOT_WATCHDOG_CONTEXT_STATE:-}" = handoff-published ] &&
       [ "${MERV_BOOT_WATCHDOG_CONTEXT_HANDOFF:-}" != pending ] &&
       _merv_boot_watchdog_expected_matches "$LOCKDIR/merv_boot_shield.ready" ready \
         "$MERV_BOOT_WATCHDOG_RUN" "$MERV_BOOT_WATCHDOG_PID" \
         "$MERV_BOOT_WATCHDOG_START" "$MERV_BOOT_WATCHDOG_HANDOFF" \
         "$MERV_BOOT_WATCHDOG_STATE"; then
      _boot_parent_run="$MERV_BOOT_WATCHDOG_RUN"
      _boot_handoff="$MERV_BOOT_WATCHDOG_HANDOFF"
      _boot_parent_valid=1
      _boot_handoff_valid=1
      _boot_admission_ok=1
    fi
    _merv_boot_watchdog_transient_lock_leave
    _boot_admission_leave_rc=$?
    if [ "$_boot_admission_leave_rc" -ne 0 ]; then
      warn -c boot "Manager startup suppressed: boot handoff admission lock release failed"
      return 1
    fi
    if [ "$_boot_admission_ok" -ne 1 ]; then
      warn -c boot "Manager startup suppressed: malformed or incomplete boot handoff publication"
      return 1
    fi
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
    info -c boot "Flag not found — running install.sh reinstall projection first"
    if "$MERV_BASE/install.sh" reinstall >> "$LOG_chan_boot" 2>&1; then
      info -c boot "install.sh reinstall completed successfully (rc=0)"
      _write_flag
    else
      warn -c boot "install.sh reinstall failed; manager startup aborted"
      return 1
    fi
  else
    info -c boot "Flag present — install structure confirmed"
  fi

  info -c boot "Running mervlan_manager.sh boot"
  if [ -s "$_boot_context" ] && [ "$_boot_parent_valid" -eq 0 ]; then
    _boot_parent_run=$(sed -n 's/^parent_run_id=//p' "$_boot_context" 2>/dev/null | head -n 1)
    _boot_handoff=$(sed -n 's/^handoff_id=//p' "$_boot_context" 2>/dev/null | head -n 1)
  fi
  # Capture the exact handoff identity before launching the manager.  These
  # values are untrusted marker text, so validate them before forwarding them
  # as arguments or using the parent run to retire the active marker later.
  case "$_boot_parent_run" in
    ''|.|..|*[!A-Za-z0-9._-]*) ;;
    *) _boot_parent_valid=1 ;;
  esac
  case "$_boot_handoff" in
    ''|.|..|*[!A-Za-z0-9._-]*) ;;
    *) _boot_handoff_valid=1 ;;
  esac
  if [ "$_boot_parent_valid" -eq 1 ] && [ "$_boot_handoff_valid" -eq 1 ]; then
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
  # not), but serialize retirement with watchdog publication.  Re-read the
  # active marker under the existing transient lock and retire it only when a
  # complete, valid marker contains this manager's exact parent run.  A
  # replacement or absent marker is left for its owner/no-op respectively;
  # malformed state and lock failures are fail-closed.  A private tombstone
  # lets us restore the exact marker if lock release fails.
  if _merv_boot_watchdog_transient_lock_enter; then
    _boot_marker_class=absent
    _boot_marker_run=""
    _boot_marker_body=""
    if [ -L "$_boot_marker" ]; then
      _boot_marker_class=ambiguous
    elif [ -e "$_boot_marker" ]; then
      if [ ! -f "$_boot_marker" ]; then
        _boot_marker_class=ambiguous
      else
        _boot_marker_run=$(sed -n 's/^run_id=//p' "$_boot_marker" 2>/dev/null | head -n 1)
        _boot_marker_body=$(cat "$_boot_marker" 2>/dev/null || printf '')
        case "$_boot_marker_run" in
          ''|.|..|*[!A-Za-z0-9._-]*)
            _boot_marker_class=ambiguous
            ;;
          *)
            if [ "$_boot_marker_body" != "run_id=$_boot_marker_run" ] ||
               [ "$_boot_parent_valid" -ne 1 ]; then
              _boot_marker_class=ambiguous
            elif [ "$_boot_marker_run" = "$_boot_parent_run" ]; then
              _boot_marker_class=matched
            else
              _boot_marker_class=replacement
            fi
            ;;
        esac
      fi
    fi
    case "$_boot_marker_class" in
      matched)
        if ! _merv_boot_watchdog_temp_begin "$_boot_marker" retire; then
          _boot_marker_tomb=""
          _manager_teardown_rc=1
          warn -c boot "Boot shield marker retirement failed: unsafe temporary publication path"
        else
          _boot_marker_tomb="$_MERV_BOOT_WATCHDOG_TMP"
        fi
        if [ -z "$_boot_marker_tomb" ] ||
           ! mv "$_boot_marker" "$_boot_marker_tomb" 2>/dev/null; then
          _boot_marker_tomb=""
          _manager_teardown_rc=1
          warn -c boot "Boot shield marker retirement failed: could not quarantine exact marker"
        fi
        ;;
      replacement)
        info -c boot "Boot shield marker retained: successor run is active ($_boot_marker_run)"
        ;;
      ambiguous)
        _manager_teardown_rc=1
        warn -c boot "Boot shield marker retirement failed: malformed or ambiguous marker state"
        ;;
    esac
    _merv_boot_watchdog_transient_lock_leave
    _boot_marker_leave_rc=$?
    if [ "$_boot_marker_leave_rc" -ne 0 ]; then
      _manager_teardown_rc=1
      warn -c boot "Boot shield marker retirement lock release failed; state retained for reconciliation"
      if [ -n "$_boot_marker_tomb" ]; then
        if [ ! -e "$_boot_marker" ] && [ ! -L "$_boot_marker" ]; then
          mv "$_boot_marker_tomb" "$_boot_marker" 2>/dev/null ||
            warn -c boot "Boot shield marker restoration failed after lock release failure"
        else
          # A public marker appeared while release failed; never overwrite it.
          rm -f "$_boot_marker_tomb" 2>/dev/null || :
        fi
        _boot_marker_tomb=""
      fi
    elif [ -n "$_boot_marker_tomb" ]; then
      rm -f "$_boot_marker_tomb" 2>/dev/null || {
        _manager_teardown_rc=1
        warn -c boot "Boot shield marker tombstone cleanup failed; state retained for reconciliation"
      }
      _boot_marker_tomb=""
    fi
  else
    _manager_teardown_rc=1
    warn -c boot "Boot shield marker retirement skipped: transient publication lock unavailable"
  fi

  # Boot mode queues observation before returning. Start its bounded worker
  # only after the shield marker is gone so the boot handoff can retire first.
  if [ "$_manager_rc" -eq 0 ] && [ "$_manager_teardown_rc" -eq 0 ] &&
     [ -x "$MERV_BASE/functions/post_apply_worker.sh" ]; then
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

  if [ "$_manager_rc" -ne 0 ]; then
    return "$_manager_rc"
  fi
  return "${_manager_teardown_rc:-0}"
}

# ============================================================================ #
# MODE: cron                                                                   #
# ============================================================================ #
_mode_cron() {
  if _is_update_recovery_or_safe_boot_active; then
    warn -c boot "Cron enable suppressed: Update recovery/quiesce state is active"
    return 75
  fi

  local _maint_state
  _maint_state=$(_merv_boot_maintenance_lock_state)
  case "$_maint_state" in
    ambiguous)
      warn -c boot "Cron enable aborted: ambiguous or malformed maintenance lock state"
      return 1
      ;;
    active)
      local _cron_max="${MERV_BOOT_CRON_WAIT_SEC:-120}"
      local _cron_poll="${MERV_BOOT_CRON_POLL_SEC:-1}"
      local _cron_elapsed=0
      case "$_cron_max" in ''|*[!0-9]*) _cron_max=120 ;; esac
      case "$_cron_poll" in ''|*[!0-9]*) _cron_poll=1 ;; esac
      [ "$_cron_poll" -gt 0 ] 2>/dev/null || _cron_poll=1

      info -c boot "Cron waiting for temporary maintenance to clear (timeout=${_cron_max}s)"
      while [ "$_cron_elapsed" -lt "$_cron_max" ]; do
        sleep "$_cron_poll"
        _cron_elapsed=$((_cron_elapsed + _cron_poll))

        if _is_update_recovery_or_safe_boot_active; then
          warn -c boot "Cron enable suppressed: Update recovery/quiesce state is active"
          return 75
        fi

        _maint_state=$(_merv_boot_maintenance_lock_state)
        case "$_maint_state" in
          absent)
            info -c boot "Maintenance cleared; cron proceeding"
            break
            ;;
          ambiguous)
            warn -c boot "Cron enable aborted: ambiguous or malformed maintenance lock state"
            return 1
            ;;
          active)
            ;;
        esac
      done

      if [ "$_maint_state" = "active" ]; then
        warn -c boot "Cron wait timed out after ${_cron_elapsed}s while maintenance remained active"
        return 1
      fi
      ;;
    absent)
      ;;
  esac

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
