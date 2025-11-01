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
#                - File: var_settings.sh || version: 0.45                      #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Define folder paths and environment variables used             #
#               throughout the MerVLAN addon.                                  #
# ──────────────────────────────────────────────────────────────────────────── #

# Only set if not already set (allows override for testing)
: "${MERV_BASE:?MERV_BASE must be set before sourcing folder_settings.sh}"

[ -n "${VAR_SETTINGS_LOADED:-}" ] && return 0 2>/dev/null

# Folders
export SCRIPTS_DIR="/jffs/scripts"
export TMPDIR="/tmp/mervlan"
export LOGDIR="$TMPDIR/logs"
export FUNCDIR="$MERV_BASE/functions"
export SETTINGSDIR="$MERV_BASE/settings"
export PUBLIC_MERV_BASE="/www/user/mervlan"
export PUBLIC_SETTINGS_DIR="${PUBLIC_MERV_BASE}/settings"
export PUBLIC_SETTINGS_FILE="${PUBLIC_SETTINGS_DIR}/settings.json"
export LOCKDIR="$TMPDIR/locks"
export RESULTDIR="$TMPDIR/results"
export CHANGES="$TMPDIR/results/vlan_changes"
export COLLECTDIR="$TMPDIR/client_collection"

# Scripts & Configs
export CLEANUP="$FUNCDIR/clean-up.sh"
export HW_PROBE="$FUNCDIR/hw_probe.sh"
export LOG_SETTINGS="$SETTINGSDIR/log_settings.sh"
export SSH_KEY="$MERV_BASE/.ssh/vlan_manager"
export SSH_PUBKEY="$MERV_BASE/.ssh/vlan_manager.pub"
export DROPBEARKEY="/usr/bin/dropbearkey"
export SETTINGS_FILE="$SETTINGSDIR/settings.json"
export HW_SETTINGS_FILE="$SETTINGSDIR/hw_settings.json"
export GENERAL_SETTINGS_FILE="$SETTINGSDIR/general.json"
export OUT_FINAL="$RESULTDIR/vlan_clients.json"
export VLAN_MANAGER="$FUNCDIR/mervlan_manager.sh"
export SERVICE_EVENT="$FUNCDIR/vlan_boot_event.sh"
export CUSTOM_SETTINGS_FILE="/jffs/addons/custom_settings.txt"
# Central event handler script (referenced by wrapper in /jffs/scripts/service-event)
export SERVICE_EVENT_HANDLER="$FUNCDIR/vlan_boot_event.sh"
export TPL_SERVICES="$SETTINGSDIR/services-start.tpl"
export TPL_EVENT="$SETTINGSDIR/service-event.tpl"
export SERVICES_START="$SCRIPTS_DIR/services-start"
export SERVICE_EVENT_WRAPPER="$SCRIPTS_DIR/service-event"



# Logs
export LOGFILE="$LOGDIR/mervlan.log"
export CLI_LOG="$LOGDIR/cli_output.log"

# Where the UI is served from (first existing wins)
export PUBLIC_CANDIDATES="/www/user/mervlan /tmp/var/wwwext/mervlan"

# Flag: settings loaded
VAR_SETTINGS_LOADED=1
