#!/bin/sh
#
# ──────────────────────────────────────────────────────────────────────────── #
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
# ──────────────────────────────────────────────────────────────────────────── #
#                  - File: heal_event.sh || version: 0.45                      #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Automated healing of VLAN configurations called by with        #
#               cooldown to avoid rapid retriggers. Called if invoked by       #
#               the service-event wrapper.                                     #
# ──────────────────────────────────────────────────────────────────────────── #
#                                                                              #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
# =========================================== End of MerVLAN environment setup #


# make sure locks directory exists
mkdir -p "$LOCKDIR" 2>/dev/null

# Simple lock to avoid concurrent runs
LOCK="$LOCKDIR/vlan_event.lock"
if mkdir "$LOCK" 2>/dev/null; then
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM
else
  exit 0
fi

# --- heal cooldown (only for vlan_manager.sh) ---
COOLDOWN_FILE="$LOCKDIR/vlan_heal.last"
COOLDOWN_SEC=90
VLAN_SETTLE_DELAY="${VLAN_SETTLE_DELAY:-3}"

heal_allowed() {
  now=$(date +%s)
  last=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
  [ $((now - last)) -ge $COOLDOWN_SEC ]
}

mark_heal() {
  date +%s > "$COOLDOWN_FILE"
}

EVENT_DEBOUNCE="$LOCKDIR/vlan_event.last"
if [ -f "$EVENT_DEBOUNCE" ] && [ $(( $(date +%s) - $(cat "$EVENT_DEBOUNCE" 2>/dev/null || echo 0) )) -lt 2 ]; then
  info -c vlan "Event suppressed by debounce: [$*]"
  exit 0
fi
date +%s > "$EVENT_DEBOUNCE"

actual_vlans_from_kernel() {
  ls /sys/class/net 2>/dev/null \
    | grep -E '^br[0-9]+$' \
    | grep -v '^br0$' \
    | sed 's/^br//' \
    | sort -n
}

expected_vlans_from_settings() {
  {
    grep -Eo '"VLAN_[0-9][0-9]"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" 2>/dev/null
    grep -Eo '"ETH[0-9]+_VLAN"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" 2>/dev/null
  } | sed -n 's/.*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | grep -E '^[0-9]+$' \
    | awk '{n=$1+0; if (n>=2 && n<=4096) print n}' \
    | sort -n \
    | uniq
}

check_vlan_config() {
  local exp cur exp_str cur_str missing extra attempt max_attempts

  exp=$(expected_vlans_from_settings)
  if [ -z "$exp" ]; then
    info -c vlan "VLAN check OK: no VLANs configured in settings"
    return 0
  fi
  exp_str=$(printf '%s\n' "$exp" | xargs 2>/dev/null)

  max_attempts=2
  attempt=1
  while [ $attempt -le $max_attempts ]; do
    cur=$(actual_vlans_from_kernel)
    cur_str=$(printf '%s\n' "$cur" | xargs 2>/dev/null)
    if [ "$(printf '%s\n' "$exp")" = "$(printf '%s\n' "$cur")" ]; then
      if [ $attempt -gt 1 ]; then
        info -c vlan "VLANs restored after settle (${VLAN_SETTLE_DELAY}s): ${cur_str:-none}"
      else
        info -c vlan "VLAN check OK: expected=${exp_str:-none} actual=${cur_str:-none}"
      fi
      return 0
    fi
    [ $attempt -lt $max_attempts ] || break
    sleep "$VLAN_SETTLE_DELAY"
    attempt=$((attempt + 1))
  done

  missing=""
  for vid in $exp; do
    printf '%s\n' "$cur" | grep -Fx "$vid" >/dev/null 2>&1 || missing="$missing $vid"
  done
  missing=${missing# }

  extra=""
  for vid in $cur; do
    printf '%s\n' "$exp" | grep -Fx "$vid" >/dev/null 2>&1 || extra="$extra $vid"
  done
  extra=${extra# }

  warn -c vlan "VLAN mismatch after settle: expected{${exp_str:-none}} actual{${cur_str:-none}} missing{${missing:-none}} extra{${extra:-none}}"
  return 1
}

ensure_process() {
  # $1 label, $2 binary, $3 pidfile
  _label="$1"; _bin="$2"; _pidfile="$3"
  [ -x "$_bin" ] || return 0

  if [ -f "$_pidfile" ] && pid=$(cat "$_pidfile" 2>/dev/null) && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  "$_bin" >/dev/null 2>&1 &
  newpid=$!
  echo "$newpid" > "$_pidfile"
  info -c cli,vlan "Restarted $_label (pid $newpid)"
}

#check_services() {
#        ensure_process watchdog "$WATCHDOG" "$WATCHDOG_PIDFILE"
#        ensure_process actions "$ACTIONS" "$ACTIONS_PIDFILE"
#}

if [ "$1" = "--test" ] || [ "$1" = "test" ]; then
  info -c vlan "Manual VLAN check triggered via --test"
  if ! check_vlan_config; then
    if heal_allowed; then
      info -c cli,vlan "Manual check detected mismatch — invoking vlan_manager (cooldown ${COOLDOWN_SEC}s)"
      mark_heal
      "$VLAN_MANAGER" >/dev/null 2>&1 &
    else
      info -c cli,vlan "Manual check mismatch but heal suppressed (within ${COOLDOWN_SEC}s cooldown)"
    fi
  fi
  exit 0
fi

EVENT="$*"

case "$EVENT" in
  *restart*|*wireless*|*httpd*|*wan-start*|*wan-restart*)
    if ! check_vlan_config; then
      if heal_allowed; then
        info -c cli,vlan "VLAN config missing after [$EVENT] — healing (cooldown ${COOLDOWN_SEC}s)"
        mark_heal          # mark first to prevent rapid re-triggers
        "$VLAN_MANAGER" >/dev/null 2>&1 &
      else
        info -c cli,vlan "Heal suppressed (within ${COOLDOWN_SEC}s cooldown)"
      fi
    fi
    # These are NOT rate-limited:
    #check_services
    ;;
esac

exit 0