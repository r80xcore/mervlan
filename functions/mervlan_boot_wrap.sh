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
#            - File: mervlan_boot_wrap.sh || version="0.45"                    #
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

# ============================================================================ #
# MODE: install                                                                #
# ============================================================================ #
_mode_install() {
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
  if ! _flag_exists; then
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
  if "$VLAN_MANAGER" boot >> "$LOG_chan_boot" 2>&1; then
    info -c boot "mervlan_manager.sh boot completed (rc=0)"
  else
    warn -c boot "mervlan_manager.sh boot returned non-zero"
  fi

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
case "$1" in
  install)
    _mode_install
    ;;
  manager)
    _mode_manager
    ;;
  cron)
    _mode_cron
    ;;
  *)
    warn -c boot "Unknown mode: '$1' — expected install|manager|cron"
    ;;
esac

info -c boot "=== boot_wrap finished: mode=$1 ==="
exit 0
