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
#                - File: update_mervlan.sh || version="0.47"                   #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Update the MerVLAN addon in-place while preserving user data.  #
#                                                                              #
# ──────────────────────────────────────────────────────────────────────────── #

. /usr/sbin/helper.sh

# ========================================================================== #
# PATHS & CONSTANTS                                                          #
# ========================================================================== #

GITHUB_URL="https://codeload.github.com/r80xcore/mervlan/tar.gz/refs/heads/main"
ADDON_DIR="/jffs/addons"
ADDON="mervlan"
MERV_BASE="$ADDON_DIR/$ADDON"
TMP_BASE="/tmp/mervlan_update.$$"
ARCHIVE="$TMP_BASE/mervlan.tar.gz"
STAGE_DIR="$TMP_BASE/stage"
BACKUP_DIR="$TMP_BASE/backup"

SETTINGS_FILE="$MERV_BASE/settings/settings.json"
GENERAL_SETTINGS_FILE="$MERV_BASE/settings/general.json"
SSH_KEY_FILE="$MERV_BASE/.ssh/mervlan_manager"

BOOT_SCRIPT="$MERV_BASE/functions/mervlan_boot.sh"
SYNC_SCRIPT="$MERV_BASE/functions/sync_nodes.sh"

BACKUP_LIST="settings/general.json
settings/settings.json
settings/hw_settings.json
.ssh/mervlan_manager"

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
# LOG HELPERS                                                                #
# ========================================================================== #

info() { echo "[update] $*"; }
warn() { echo "[update] WARNING: $*" >&2; }
error() { echo "[update] ERROR: $*" >&2; }

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
	error "MerVLAN base directory missing at $MERV_BASE"
	exit 1
fi

mkdir -p "$TMP_BASE" "$STAGE_DIR" "$BACKUP_DIR" 2>/dev/null || {
	error "Failed to prepare temporary workspace at $TMP_BASE"
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
	local port="22"
	if [ -f "$MERV_BASE/settings/var_settings.sh" ]; then
		port=$(grep -E '^export SSH_PORT="?[0-9]+"?' "$MERV_BASE/settings/var_settings.sh" 2>/dev/null | \
			tail -n 1 | sed -n 's/.*SSH_PORT="\?\([0-9]\+\)"\?/\1/p')
		[ -n "$port" ] || port="22"
	fi
	printf '%s\n' "$port"
}

clean_remote_addon_dirs() {
	local nodes user ssh_bin impl port node
	nodes=$(list_configured_nodes)
	[ -n "$nodes" ] || return 0

	if command -v dbclient >/dev/null 2>&1; then
		ssh_bin=$(command -v dbclient)
		impl="dbclient"
	elif command -v ssh >/dev/null 2>&1; then
		ssh_bin=$(command -v ssh)
		impl="ssh"
	else
		warn "No SSH client available; skipping remote cleanup"
		return 1
	fi

	if [ ! -f "$SSH_KEY_FILE" ]; then
		warn "SSH key not found at $SSH_KEY_FILE; skipping remote cleanup"
		return 1
	fi

	user=$(get_node_ssh_user)
	port=$(get_node_ssh_port)

	for node in $nodes; do
		if [ "$impl" = "dbclient" ]; then
			if "$ssh_bin" -p "$port" -y -i "$SSH_KEY_FILE" -o ConnectTimeout=5 -o PasswordAuthentication=no \
				"$user@$node" "rm -rf /jffs/addons/mervlan" >/dev/null 2>&1; then
				info "Remote addon directory cleared on $node"
			else
				warn "Failed to clean remote addon directory on $node"
			fi
		else
			if "$ssh_bin" -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
				-i "$SSH_KEY_FILE" "$user@$node" "rm -rf /jffs/addons/mervlan" >/dev/null 2>&1; then
				info "Remote addon directory cleared on $node"
			else
				warn "Failed to clean remote addon directory on $node"
			fi
		fi
	done
}

# ========================================================================== #
# BACKUP ORIGINAL FILES                                                      #
# ========================================================================== #

info "Backing up user configuration files"
for rel_path in $BACKUP_LIST; do
	src="$MERV_BASE/$rel_path"
	if [ -f "$src" ]; then
		dest="$BACKUP_DIR/$rel_path"
		mkdir -p "$(dirname "$dest")" 2>/dev/null || {
			error "Failed to create backup directory for $rel_path"
			exit 1
		}
		cp "$src" "$dest" 2>/dev/null || {
			error "Failed to back up $rel_path"
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

info "Downloading latest MerVLAN snapshot"
/usr/sbin/curl -fsL --retry 3 "$GITHUB_URL" -o "$ARCHIVE"
if [ ! -s "$ARCHIVE" ]; then
	error "Download failed or archive empty"
	exit 1
fi

info "Extracting archive into staging area"
if tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
	tar -xzf "$ARCHIVE" -C "$TMP_BASE" || {
		error "Failed to extract archive"
		exit 1
	}
else
	gzip -dc "$ARCHIVE" | tar -x -C "$TMP_BASE" || {
		error "Failed to extract archive via gzip fallback"
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
	error "Unable to determine extracted directory"
	exit 1
fi

cp -a "$topdir"/. "$STAGE_DIR"/ 2>/dev/null || {
	error "Failed to copy extracted files into staging"
	exit 1
}

# ========================================================================== #
# VALIDATE STAGED CONTENT                                                    #
# ========================================================================== #

info "Validating staged files"
missing=0
for required in $REQUIRED_STAGE_FILES; do
	if [ ! -f "$STAGE_DIR/$required" ]; then
		warn "Missing required file in stage: $required"
		missing=1
	fi
done
if [ "$missing" -ne 0 ]; then
	error "Validation failed; aborting update"
	exit 1
fi
# Temporarily tear down boot/service-event hooks so refreshed templates can be applied cleanly
if [ -x "$BOOT_SCRIPT" ]; then
	info "Temporarily disabling MerVLAN hooks before swap"
	if ! sh "$BOOT_SCRIPT" disable >/dev/null 2>&1; then
		warn "mervlan_boot.sh disable failed during pre-update teardown"
	fi
	if ! sh "$BOOT_SCRIPT" setupdisable >/dev/null 2>&1; then
		warn "mervlan_boot.sh setupdisable failed during pre-update teardown"
	fi
else
	warn "mervlan_boot.sh not executable; skipping pre-update teardown"
fi

# ========================================================================== #
# REPLACE INSTALLATION                                                       #
# ========================================================================== #

OLD_DIR=""
timestamp="$(date +%s 2>/dev/null | tr -d '\n')"
[ -n "$timestamp" ] || timestamp="backup"

OLD_DIR="$MERV_BASE.old.$timestamp"

info "Swapping current installation"
if mv "$MERV_BASE" "$OLD_DIR" 2>/dev/null; then
	:
else
	error "Failed to move existing installation to $OLD_DIR"
	exit 1
fi

mkdir -p "$MERV_BASE" 2>/dev/null || {
	error "Failed to recreate MerVLAN base directory"
	mv "$OLD_DIR" "$MERV_BASE" 2>/dev/null
	exit 1
}

cp -a "$STAGE_DIR"/. "$MERV_BASE"/ 2>/dev/null || {
	error "Failed to copy staged files into $MERV_BASE"
	rm -rf "$MERV_BASE" 2>/dev/null
	mv "$OLD_DIR" "$MERV_BASE" 2>/dev/null
	exit 1
}

# Adjust permissions to match installer expectations
for depth in "" "*/" "*/*/"; do
	for f in $MERV_BASE/${depth}*.sh; do
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

info "Restoring preserved files"
for rel_path in $BACKUP_LIST; do
	backup_file="$BACKUP_DIR/$rel_path"
	target="$MERV_BASE/$rel_path"
	if [ -f "$backup_file" ]; then
		mkdir -p "$(dirname "$target")" 2>/dev/null || {
			error "Failed to recreate directory for $rel_path"
			rm -rf "$MERV_BASE" 2>/dev/null
			mv "$OLD_DIR" "$MERV_BASE" 2>/dev/null
			exit 1
		}
		cp "$backup_file" "$target" 2>/dev/null || {
			error "Failed to restore $rel_path"
			rm -rf "$MERV_BASE" 2>/dev/null
			mv "$OLD_DIR" "$MERV_BASE" 2>/dev/null
			exit 1
		}
		if [ "$rel_path" = ".ssh/mervlan_manager" ]; then
			chmod 600 "$target" 2>/dev/null || :
		fi
	fi
done

# ========================================================================== #
# OPTIONAL POST-UPDATE TASKS                                                 #
# ========================================================================== #

# Refresh node files when SSH keys and nodes are configured
if ssh_keys_installed && has_configured_nodes; then
	clean_remote_addon_dirs
	if [ -x "$SYNC_SCRIPT" ]; then
		info "Syncing nodes via sync_nodes.sh"
		if ! sh "$SYNC_SCRIPT" >/dev/null 2>&1; then
			warn "sync_nodes.sh reported errors"
		fi
	else
		warn "sync_nodes.sh not executable; skipping node sync"
	fi
else
	info "Node sync skipped (no nodes configured or SSH keys absent)"
fi

# Reapply boot/service-event hooks from the refreshed installation
if [ -x "$BOOT_SCRIPT" ]; then
	info "Re-applying MerVLAN hooks from updated build"
	if ! sh "$BOOT_SCRIPT" setupenable >/dev/null 2>&1; then
		warn "mervlan_boot.sh setupenable failed during post-update setup"
	fi
	if [ "$BOOT_WAS_ENABLED" -eq 1 ]; then
		if ! sh "$BOOT_SCRIPT" enable >/dev/null 2>&1; then
			warn "mervlan_boot.sh enable failed during post-update setup"
		fi
	else
		info "Boot was disabled before update; leaving MerVLAN boot disabled"
	fi
else
	warn "mervlan_boot.sh not executable; skipping post-update hook setup"
fi

# ========================================================================== #
# FINALIZATION                                                               #
# ========================================================================== #

# Remove old directory after successful update
rm -rf "$OLD_DIR" 2>/dev/null

info "MerVLAN update completed successfully"

if [ -f "$MERV_BASE/changelog.txt" ]; then
	printf '\n[update] changelog.txt contents:\n'
	cat "$MERV_BASE/changelog.txt"
fi

exit 0