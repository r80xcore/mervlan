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
#                - File: update_mervlan.sh || version="0.48"                   #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Update the MerVLAN addon in-place while preserving user data.  #
#                                                                              #
# ──────────────────────────────────────────────────────────────────────────── #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
# =========================================== End of MerVLAN environment setup #
cd /tmp 2>/dev/null || cd / || :
. /usr/sbin/helper.sh

# ========================================================================== #
# PATHS & CONSTANTS                                                          #
# ========================================================================== #

readonly GITHUB_URL="https://codeload.github.com/r80xcore/mervlan/tar.gz/refs/heads/main"
readonly TMP_BASE="/tmp/mervlan_update.$$"
readonly ARCHIVE="$TMP_BASE/mervlan.tar.gz"
readonly STAGE_DIR="$TMP_BASE/stage"
readonly BACKUP_DIR="$TMP_BASE/backup"
readonly SYNC_SCRIPT="$FUNCDIR/sync_nodes.sh"

BACKUP_LIST="settings/general.json
settings/settings.json
settings/hw_settings.json"

SSH_KEY_RELATIVE=""
# Preserve the configured private key so we can restore it after the swap
case "$SSH_KEY" in
	"$MERV_BASE"/*) SSH_KEY_RELATIVE="${SSH_KEY#$MERV_BASE/}" ;;
esac

SSH_PUBKEY_RELATIVE=""
case "$SSH_PUBKEY" in
	"$MERV_BASE"/*) SSH_PUBKEY_RELATIVE="${SSH_PUBKEY#$MERV_BASE/}" ;;
esac

if [ -n "$SSH_KEY_RELATIVE" ]; then
	BACKUP_LIST="$BACKUP_LIST
$SSH_KEY_RELATIVE"
fi

if [ -n "$SSH_PUBKEY_RELATIVE" ]; then
	BACKUP_LIST="$BACKUP_LIST
$SSH_PUBKEY_RELATIVE"
fi

REQUIRED_STAGE_FILES="changelog.txt
functions/mervlan_boot.sh
functions/mervlan_manager.sh
functions/heal_event.sh
functions/service-event-handler.sh
functions/sync_nodes.sh
settings/settings.json
settings/general.json
templates/mervlan_templates.sh
www/index.html"

# ========================================================================== #
# CLEANUP HANDLER                                                            #
# ========================================================================== #

cleanup_tmp() {
	[ -n "$TMP_BASE" ] && [ -d "$TMP_BASE" ] && rm -rf "$TMP_BASE" 2>/dev/null
}

trap cleanup_tmp EXIT

# ========================================================================== #
# BASIC VALIDATION                                                           #
# ========================================================================== #

if [ ! -d "$MERV_BASE" ]; then
	error -c cli,vlan "MerVLAN base directory missing at $MERV_BASE"
	exit 1
fi

mkdir -p "$TMP_BASE" "$STAGE_DIR" "$BACKUP_DIR" 2>/dev/null || {
	error -c cli,vlan "Failed to prepare temporary workspace at $TMP_BASE"
	exit 1
}

# ========================================================================== #
# NODE/SSH HELPERS                                                           #
# ========================================================================== #

list_configured_nodes() {
	[ -f "$SETTINGS_FILE" ] || return 1
	grep -o '"NODE[1-5]"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" 2>/dev/null | \
		sed -n "s/.*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | \
		grep -v "none" | \
		grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

has_configured_nodes() {
	local nodes
	nodes=$(list_configured_nodes)
	[ -n "$nodes" ]
}

ssh_keys_installed() {
	[ -f "$GENERAL_SETTINGS_FILE" ] || return 1
	grep -q '"SSH_KEYS_INSTALLED"[[:space:]]*:[[:space:]]*"1"' "$GENERAL_SETTINGS_FILE" 2>/dev/null
}

get_node_ssh_user() {
	local user
	if [ -f "$GENERAL_SETTINGS_FILE" ]; then
		user=$(grep -o '"NODE_SSH_USER"[[:space:]]*:[[:space:]]*"[^"]*"' "$GENERAL_SETTINGS_FILE" 2>/dev/null | \
			sed -n "s/.*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1)
		[ -n "$user" ] || user=$(grep -o '"SSH_USER"[[:space:]]*:[[:space:]]*"[^"]*"' "$GENERAL_SETTINGS_FILE" 2>/dev/null | \
			sed -n "s/.*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1)
	fi
	[ -n "$user" ] || user="admin"
	printf '%s\n' "$user"
}

get_node_ssh_port() {
	case "${SSH_PORT:-}" in
		""|*[!0-9]*) printf '22\n' ;;
		*) printf '%s\n' "$SSH_PORT" ;;
	esac
}

clean_remote_addon_dirs() {
	local nodes user port node
	nodes=$(list_configured_nodes)
	if [ -z "$nodes" ]; then
		info -c cli,vlan "Remote cleanup skipped (no nodes configured)"
		return 0
	fi

	if [ ! -f "$SSH_KEY" ]; then
		info -c cli,vlan "Remote cleanup skipped (SSH key not found)"
		return 0
	fi

	user=$(get_node_ssh_user)
	port=$(get_node_ssh_port)

	for node in $nodes; do
		if dbclient -p "$port" -y -i "$SSH_KEY" \
			"$user@$node" "rm -rf /jffs/addons/mervlan" >/dev/null 2>&1; then
			info -c cli,vlan "Cleared remote addon directory on $node"
		else
			warn -c cli,vlan "Failed to clean remote addon directory on $node"
		fi
	done
}

# ========================================================================== #
# BACKUP ORIGINAL FILES                                                      #
# ========================================================================== #

info -c cli,vlan "Backing up user configuration files"
for rel_path in $BACKUP_LIST; do
	src="$MERV_BASE/$rel_path"
	if [ -f "$src" ]; then
		dest="$BACKUP_DIR/$rel_path"
		mkdir -p "$(dirname "$dest")" 2>/dev/null || {
			error -c cli,vlan "Failed to create backup directory for $rel_path"
			exit 1
		}
		cp -p "$src" "$dest" 2>/dev/null || {
			error -c cli,vlan "Failed to back up $rel_path"
			exit 1
		}
	fi
done

# Track previous boot state from backed-up general.json
BOOT_WAS_ENABLED=0
if [ -f "$BACKUP_DIR/settings/general.json" ]; then
	if grep -q '"BOOT_ENABLED"[[:space:]]*:[[:space:]]*"1"' "$BACKUP_DIR/settings/general.json" 2>/dev/null; then
		BOOT_WAS_ENABLED=1
	fi
fi

# ========================================================================== #
# DOWNLOAD LATEST SNAPSHOT                                                   #
# ========================================================================== #

info -c cli,vlan "Downloading latest MerVLAN snapshot"
/usr/sbin/curl -fsL --retry 3 "$GITHUB_URL" -o "$ARCHIVE"
if [ ! -s "$ARCHIVE" ]; then
	error -c cli,vlan "Download failed or archive empty"
	exit 1
fi

info -c cli,vlan "Extracting archive into staging area"
if tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
	tar -xzf "$ARCHIVE" -C "$TMP_BASE" || {
		error -c cli,vlan "Failed to extract archive"
		exit 1
	}
else
	gzip -dc "$ARCHIVE" | tar -x -C "$TMP_BASE" || {
		error -c cli,vlan "Failed to extract archive via gzip fallback"
		exit 1
	}
fi

# Detect top directory from archive
topdir=""
topname="$(tar -tzf "$ARCHIVE" 2>/dev/null | head -1 | cut -d/ -f1)"
if [ -n "$topname" ] && [ -d "$TMP_BASE/$topname" ]; then
	topdir="$TMP_BASE/$topname"
else
	for d in "$TMP_BASE"/mervlan-*; do
		[ -d "$d" ] && { topdir="$d"; break; }
	done
fi

if [ -z "$topdir" ]; then
	error -c cli,vlan "Unable to determine extracted directory"
	exit 1
fi

cp -a "$topdir"/. "$STAGE_DIR"/ 2>/dev/null || {
	error -c cli,vlan "Failed to copy extracted files into staging"
	exit 1
}

# ========================================================================== #
# VALIDATE STAGED CONTENT                                                    #
# ========================================================================== #

info -c cli,vlan "Validating staged files"
missing=0
for required in $REQUIRED_STAGE_FILES; do
	if [ ! -f "$STAGE_DIR/$required" ]; then
		warn -c cli,vlan "Missing required file in stage: $required"
		missing=1
	fi
done
if [ "$missing" -ne 0 ]; then
	error -c cli,vlan "Validation failed; aborting update"
	exit 1
fi
# Temporarily tear down boot/service-event hooks so refreshed templates can be applied cleanly
if [ -x "$BOOT_SCRIPT" ]; then
	if [ "$BOOT_WAS_ENABLED" -eq 1 ]; then
		info -c cli,vlan "Temporarily disabling MerVLAN hooks before swap"
		if ! MERV_SKIP_NODE_SYNC=1 sh "$BOOT_SCRIPT" disable >/dev/null 2>&1; then
			warn -c cli,vlan "mervlan_boot.sh disable returned non-zero (continuing)"
		fi
	else
		info -c cli,vlan "Boot already disabled; skipping disable step"
	fi
	if ! MERV_SKIP_NODE_SYNC=1 sh "$BOOT_SCRIPT" setupdisable >/dev/null 2>&1; then
		warn -c cli,vlan "mervlan_boot.sh setupdisable returned non-zero (continuing)"
	fi
else
	warn -c cli,vlan "mervlan_boot.sh not executable; skipping pre-update teardown"
fi

# ========================================================================== #
# REPLACE INSTALLATION                                                       #
# ========================================================================== #

OLD_DIR=""
timestamp="$(date +%s 2>/dev/null | tr -d '\n')"
[ -n "$timestamp" ] || timestamp="backup"

OLD_DIR="$MERV_BASE.backup.$timestamp"
NEW_DIR="$TMP_BASE/new_install"

info -c cli,vlan "Creating snapshot backup at $OLD_DIR"
if [ -d "$OLD_DIR" ]; then
	rm -rf "$OLD_DIR" 2>/dev/null || :
fi

if ! cp -pR "$MERV_BASE" "$OLD_DIR" 2>/dev/null; then
	error -c cli,vlan "Failed to copy current installation to $OLD_DIR"
	exit 1
fi

info -c cli,vlan "Building updated tree at $NEW_DIR"
rm -rf "$NEW_DIR" 2>/dev/null || :

mkdir -p "$NEW_DIR" 2>/dev/null || {
	error -c cli,vlan "Failed to create temporary install directory"
	exit 1
}

if ! cp -a "$STAGE_DIR"/. "$NEW_DIR"/ 2>/dev/null; then
	error -c cli,vlan "Failed to copy staged files into $NEW_DIR"
	rm -rf "$NEW_DIR" 2>/dev/null
	exit 1
fi

# Adjust permissions to match installer expectations
for depth in "" "*/" "*/*/"; do
	for f in $NEW_DIR/${depth}*.sh; do
		[ -f "$f" ] 2>/dev/null || continue
		base="$(basename "$f")"
		if [ "$base" = "log_settings.sh" ] || [ "$base" = "var_settings.sh" ]; then
			chmod 644 "$f" 2>/dev/null || :
		else
			chmod 755 "$f" 2>/dev/null || :
		fi
	done
done

# ========================================================================== #
# RESTORE USER DATA                                                          #
# ========================================================================== #

info -c cli,vlan "Restoring preserved files"
for rel_path in $BACKUP_LIST; do
	backup_file="$BACKUP_DIR/$rel_path"
	target="$NEW_DIR/$rel_path"
	if [ -f "$backup_file" ]; then
		mkdir -p "$(dirname "$target")" 2>/dev/null || {
			error -c cli,vlan "Failed to recreate directory for $rel_path"
			rm -rf "$NEW_DIR" 2>/dev/null
			exit 1
		}
		cp -p "$backup_file" "$target" 2>/dev/null || {
			error -c cli,vlan "Failed to restore $rel_path"
			rm -rf "$NEW_DIR" 2>/dev/null
			exit 1
		}
		if [ -n "$SSH_KEY_RELATIVE" ] && [ "$rel_path" = "$SSH_KEY_RELATIVE" ]; then
			chmod 600 "$target" 2>/dev/null || :
		elif [ -n "$SSH_PUBKEY_RELATIVE" ] && [ "$rel_path" = "$SSH_PUBKEY_RELATIVE" ]; then
			chmod 644 "$target" 2>/dev/null || :
		fi
	fi
done

info -c cli,vlan "Swapping active installation"
rm -rf "$MERV_BASE" 2>/dev/null || {
	error -c cli,vlan "Failed to clear existing MerVLAN directory"
	exit 1
}

if ! mv "$NEW_DIR" "$MERV_BASE" 2>/dev/null; then
	error -c cli,vlan "Failed to activate new installation"
	mv "$OLD_DIR" "$MERV_BASE" 2>/dev/null
	exit 1
fi

# ========================================================================== #
# OPTIONAL POST-UPDATE TASKS                                                 #
# ========================================================================== #

# Refresh node files when SSH keys and nodes are configured
if ssh_keys_installed && has_configured_nodes; then
	clean_remote_addon_dirs
	if [ -x "$SYNC_SCRIPT" ]; then
		info -c cli,vlan "Syncing nodes via sync_nodes.sh"
		if ! sh "$SYNC_SCRIPT"; then
			warn -c cli,vlan "sync_nodes.sh reported errors"
		fi
	else
		warn -c cli,vlan "sync_nodes.sh not executable; skipping node sync"
	fi
else
	info -c cli,vlan "Node sync skipped (no nodes configured or SSH keys absent)"
fi

# Reapply boot/service-event hooks from the refreshed installation
if [ -x "$BOOT_SCRIPT" ]; then
	info -c cli,vlan "Re-applying MerVLAN hooks on the main router"
	if ! MERV_SKIP_NODE_SYNC=1 sh "$BOOT_SCRIPT" setupenable >/dev/null 2>&1; then
		warn -c cli,vlan "mervlan_boot.sh setupenable returned non-zero (continuing)"
	fi
	if [ "$BOOT_WAS_ENABLED" -eq 1 ]; then
		if ! MERV_SKIP_NODE_SYNC=1 sh "$BOOT_SCRIPT" enable >/dev/null 2>&1; then
			warn -c cli,vlan "mervlan_boot.sh enable returned non-zero (continuing)"
		fi
	else
		info -c cli,vlan "Boot was disabled before update; leaving MerVLAN boot disabled"
	fi
else
	warn -c cli,vlan "mervlan_boot.sh not executable; skipping post-update hook setup"
fi

# ========================================================================== #
# FINALIZATION                                                               #
# ========================================================================== #

# Remove old directory after successful update
rm -rf "$OLD_DIR" 2>/dev/null

info -c cli,vlan "MerVLAN update completed successfully"

if [ -f "$MERV_BASE/changelog.txt" ]; then
	info -c cli "changelog.txt contents:"
	cat "$MERV_BASE/changelog.txt"
fi

exit 0