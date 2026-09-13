#!/bin/sh
# Contract coverage for RAM-backed temporary workspaces used by supported
# installer, update, Sync Nodes, Execute, collection, repair, backup, and
# recovery flows. User-selected tarball staging is intentionally excluded:
# that archive is retained by contract for a later install/update.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
require() { grep -Fq "$2" "$MERV_BASE/$1" || fail "$3"; }

require install.sh 'cleanup_install_download_work()' 'installer-owned tarball workspace cleanup helper missing'
require install.sh "trap 'installer_tarball_exit_handler' EXIT" 'tarball install lacks EXIT cleanup'
require install.sh 'cleanup_install_download_work >/dev/null 2>&1 || :' 'tarball EXIT handler does not clean internal workspace'
require functions/update_mervlan.sh 'trap cleanup_tmp EXIT' 'Update lacks temporary workspace EXIT cleanup'
require functions/update_mervlan.sh 'rm -rf "$TMP_BASE"' 'Update does not remove its temporary workspace'
require functions/update_mervlan.sh 'UPDATE_PRESERVE_TMP' 'Update does not retain failed cleanup evidence explicitly'
require functions/sync_nodes.sh "trap '_cleanup_sync_tmp' EXIT" 'Sync Nodes lacks temporary breadcrumb cleanup'
require functions/sync_nodes.sh '_sync_endpoint_map' 'Sync Nodes does not own endpoint-map cleanup'
require functions/execute_nodes.sh "trap 'execute_nodes_progress_cleanup' EXIT" 'Execute Nodes lacks EXIT cleanup'
require functions/collect_clients.sh "trap 'cleanup_collect' EXIT" 'client collection lacks EXIT cleanup'
require functions/ssh_hostkey_probe.sh "trap '_shkp_cleanup' EXIT" 'SSH probe lacks EXIT cleanup'
require functions/update_mervlan_repair.sh 'trap cleanup EXIT HUP INT TERM' 'repair lacks private temporary workspace cleanup'
require functions/mervlan_backup.sh 'trap mb_cleanup EXIT' 'backup lacks workspace cleanup'
require functions/mervlan_recover.sh 'trap recovery_cleanup EXIT' 'recovery lacks workspace cleanup'
require settings/log_settings.sh 'LOG_MAX_BYTES:=1048576' 'runtime log byte bound missing'
require settings/log_settings.sh 'LOG_MAX_LINES:=2000' 'runtime log line bound missing'
require settings/lib_progress.sh 'MERV_PROGRESS_MAX_FILES:=64' 'progress artifact retention bound missing'
require settings/lib_progress.sh 'merv_progress_prune()' 'progress artifact pruning helper missing'
require settings/lib_action_ack.sh '_aa_keep=64' 'action acknowledgement retention bound missing'
require functions/mervlan_boot.sh 'Could not remove temporary rendered template' 'boot template cleanup failure is not surfaced'
require templates/mervlan_templates.sh 'rm -f "$tmp" "$tmp_raw"' 'template renderer temporary cleanup missing'

printf 'TMP_LIFECYCLE_CONTRACT_OK\n'
