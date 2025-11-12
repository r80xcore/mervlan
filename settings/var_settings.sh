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
#                - File: var_settings.sh || version="0.46"                     #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Define folder paths and environment variables used             #
#               throughout the MerVLAN addon.                                  #
# ──────────────────────────────────────────────────────────────────────────── #
[ -n "${VAR_SETTINGS_LOADED:-}" ] && return 0 2>/dev/null
# Only set if not already set (allows override for testing)
: "${MERV_BASE:?MERV_BASE must be set before sourcing folder_settings.sh}"



# Folders
readonly SCRIPTS_DIR="/jffs/scripts"
readonly TMPDIR="/tmp/mervlan_tmp"
readonly LOGDIR="$TMPDIR/logs"
readonly FUNCDIR="$MERV_BASE/functions"
readonly SETTINGSDIR="$MERV_BASE/settings"
readonly FLAGDIR="$MERV_BASE/flags"
readonly PUBLIC_MERV_BASE="/www/user/mervlan"
readonly PUBLIC_SETTINGS_DIR="${PUBLIC_MERV_BASE}/settings"
readonly PUBLIC_SETTINGS_FILE="${PUBLIC_SETTINGS_DIR}/settings.json"
readonly LOCKDIR="$TMPDIR/locks"
readonly RESULTDIR="$TMPDIR/results"
readonly CHANGES="$TMPDIR/results/vlan_changes"
readonly COLLECTDIR="$TMPDIR/client_collection"

# Scripts & Configs
readonly BOOT_SCRIPT="$FUNCDIR/mervlan_boot.sh"
readonly HW_PROBE="$FUNCDIR/hw_probe.sh"
readonly LOG_SETTINGS="$SETTINGSDIR/log_settings.sh"
readonly SSH_KEY="$MERV_BASE/.ssh/vlan_manager"
readonly SSH_PUBKEY="$MERV_BASE/.ssh/vlan_manager.pub"
readonly DROPBEARKEY="/usr/bin/dropbearkey"
readonly SETTINGS_FILE="$SETTINGSDIR/settings.json"
readonly HW_SETTINGS_FILE="$SETTINGSDIR/hw_settings.json"
readonly GENERAL_SETTINGS_FILE="$SETTINGSDIR/general.json"
readonly OUT_FINAL="$RESULTDIR/vlan_clients.json"
readonly VLAN_MANAGER="$FUNCDIR/mervlan_manager.sh"
readonly SERVICE_EVENT="$FUNCDIR/heal_event.sh"
readonly CUSTOM_SETTINGS_FILE="/jffs/addons/custom_settings.txt"
readonly SERVICE_EVENT_HANDLER="$FUNCDIR/service-event-handler.sh"
readonly TEMPLATE_LIB="$MERV_BASE/templates/mervlan_templates.sh"
readonly TEMPLATE_SERVICES="services-start"
readonly TEMPLATE_SERVICE_EVENT="service-event"
readonly TEMPLATE_SERVICE_EVENT_NODES="service-event-nodes"
readonly TEMPLATE_SERVICES_ADDON="services-start-addon"
readonly SERVICES_START="$SCRIPTS_DIR/services-start"
readonly SERVICE_EVENT_WRAPPER="$SCRIPTS_DIR/service-event"


# SSH Port Override
export SSH_PORT="22"



# Logs
readonly LOGFILE="$LOGDIR/mervlan.log"
readonly CLI_LOG="$LOGDIR/cli_output.log"

# Flag: settings loaded
VAR_SETTINGS_LOADED=1
