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
#                - File: update_mervlan.sh || version="0.51"                   #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Update the MerVLAN addon in-place while preserving user data.  #
#                                                                              #
# ──────────────────────────────────────────────────────────────────────────── #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED LIB_SSH_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_SSH_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh.sh"
# =========================================== End of MerVLAN environment setup #
cd /tmp 2>/dev/null || cd / || :
. /usr/sbin/helper.sh
SSH_NODE_USER=$(get_node_ssh_user)
SSH_NODE_PORT=$(get_node_ssh_port)
# ========================================================================== #
# PATHS & CONSTANTS                                                          #
# ========================================================================== #

# Central temporary root for MerVLAN operations (RAM)
readonly TMP_DIR="/tmp/mervlan_tmp"
readonly TMP_BASE="$TMP_DIR/updates.$$"

readonly ARCHIVE="$TMP_BASE/mervlan.tar.gz"
readonly STAGE_DIR="$TMP_BASE/stage"
readonly BACKUP_DIR="$TMP_BASE/backup"
readonly SYNC_SCRIPT="$FUNCDIR/sync_nodes.sh"

# Persistent backup root on flash (for rollback archives)
# Example (default): /jffs/addons/mervlan_backups
MERVLAN_BACKUP_DIR="${MERV_BASE%/*}/mervlan_backups"

BACKUP_LIST="settings/settings.json"

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

REQUIRED_STAGE_FILES="install.sh
uninstall.sh
changelog.txt
README.md
mervlan.asp
functions/mervlan_boot.sh
functions/mervlan_manager.sh
functions/heal_event.sh
functions/service-event-handler.sh
functions/sync_nodes.sh
functions/collect_clients.sh
functions/collect_local_clients.sh
functions/dropbear_sshkey_gen.sh
functions/hw_probe.sh
functions/mervlan_trunk.sh
functions/save_settings.sh
functions/update_mervlan.sh
settings/settings.json
settings/var_settings.sh
settings/log_settings.sh
settings/lib_debug.sh
settings/lib_json.sh
settings/lib_ssh.sh
templates/mervlan_templates.sh
www/index.html
www/help.html
www/view_logs.html
www/vlan_form_style.css
www/vlan_index_style.css"

# required directories in a valid package
REQUIRED_STAGE_DIRS="functions settings templates www"

# ========================================================================== #
# CLEANUP HANDLER                                                            #
# ========================================================================== #

cleanup_tmp() {
	[ -n "$TMP_BASE" ] && [ -d "$TMP_BASE" ] && rm -rf "$TMP_BASE" 2>/dev/null
}

trap cleanup_tmp EXIT


# ========================================================================== #
# MODE / CHANNEL PARSING                                                     #
# ========================================================================== #

#
#   update_mervlan.sh                  -> MODE=update, CHANNEL=main
#   update_mervlan.sh dev              -> MODE=update, CHANNEL=dev
#   update_mervlan.sh update dev       -> MODE=update, CHANNEL=dev
#   update_mervlan.sh restore          -> MODE=restore
#   update_mervlan.sh refs/tags/vX.Y.Z -> MODE=update, CHANNEL=refs/tags/vX.Y.Z
#

MODE="update"
CHANNEL="main"

case "$1" in
	""|main|dev|refs/*)
		# old/simple usage: first arg is the channel directly
		if [ -n "$1" ]; then
			CHANNEL="$1"
		fi
		;;
	restore)
		MODE="restore"
		;;
	update)
		MODE="update"
		CHANNEL="${2:-main}"
		;;
	*)
		error -c cli,vlan "Unknown mode/channel: $1"
		echo "Usage: $0 [update [branch]|restore|main|dev|refs/<ref>]" >&2
		exit 1
		;;
esac

# For restore, we do not need curl or temp download setup
if [ "$MODE" = "restore" ]; then
	# BASIC VALIDATION (for restore path as well)
	if [ ! -d "$MERV_BASE" ]; then
		error -c cli,vlan "MerVLAN base directory missing at $MERV_BASE"
		exit 1
	fi
	restore_mervlan() {
		info -c cli,vlan "MerVLAN restore mode: restoring from on-device backups"

		RESTORE_CURRENT_VERSION=""
		if [ -f "$MERV_BASE/changelog.txt" ]; then
			RESTORE_CURRENT_VERSION=$(sed -n '1{/^[[:space:]]*$/d;p;q}' "$MERV_BASE/changelog.txt" 2>/dev/null)
		fi

		if [ ! -d "$MERVLAN_BACKUP_DIR" ]; then
			warning_msg="No backup directory found at $MERVLAN_BACKUP_DIR"
			if command -v error >/dev/null 2>&1; then
				error -c cli,vlan "$warning_msg"
			else
				echo "$warning_msg" >&2
			fi
			return 1
		fi

		set -- "$MERVLAN_BACKUP_DIR"/mervlan.backup.*.tar.gz
		if [ ! -e "$1" ]; then
			warning_msg="No backup archives found in $MERVLAN_BACKUP_DIR"
			if command -v error >/dev/null 2>&1; then
				error -c cli,vlan "$warning_msg"
			else
				echo "$warning_msg" >&2
			fi
			return 1
		fi

		BACKUPS_LIST="$(ls "$MERVLAN_BACKUP_DIR"/mervlan.backup.*.tar.gz 2>/dev/null | sort -r)"
		idx=0
		echo "Available restore points:"
		for b in $BACKUPS_LIST; do
			idx=$((idx + 1))
			base="$(basename "$b")"
			printf '  %d) %s\n' "$idx" "$base"
			eval "BACKUP_$idx=\"$b\""
			[ "$idx" -ge 3 ] && break
		done

		if [ "$idx" -eq 0 ]; then
			warning_msg="No backup archives available to restore"
			if command -v error >/dev/null 2>&1; then
				error -c cli,vlan "$warning_msg"
			else
				echo "$warning_msg" >&2
			fi
			return 1
		fi

		printf "Select backup to restore [1-%d]: " "$idx"
		read sel

		case "$sel" in
			1|2|3)
				eval "chosen=\$BACKUP_$sel"
				;;
			*)
				info -c cli,vlan "Restore aborted: invalid selection"
				return 1
				;;
		esac

		if [ -z "$chosen" ]; then
			warning_msg="No backup selected"
			if command -v error >/dev/null 2>&1; then
				error -c cli,vlan "$warning_msg"
			else
				echo "$warning_msg" >&2
			fi
			return 1
		fi

		echo ""
		echo "WARNING: This will replace the current MerVLAN installation and settings with:" 
		echo "  $(basename "$chosen")"
		echo ""
		printf "Continue? [y/N]: "
		read ans

		case "$ans" in
			y|Y|yes|YES) ;;
			*)
				info -c cli,vlan "Restore aborted by user"
				return 0
				;;
		esac

		RESTORE_BASE="$TMP_DIR/restore.$$"
		mkdir -p "$RESTORE_BASE" 2>/dev/null || {
			warning_msg="Failed to create restore workdir: $RESTORE_BASE"
			if command -v error >/dev/null 2>&1; then
				error -c cli,vlan "$warning_msg"
			else
				echo "$warning_msg" >&2
			fi
			return 1
		}

		BACKUP_BASENAME="$(basename "$chosen" .tar.gz)"
		info -c cli,vlan "Extracting backup $BACKUP_BASENAME"
		if ! tar -xzf "$chosen" -C "$RESTORE_BASE" 2>/dev/null; then
			warning_msg="Failed to extract backup archive"
			if command -v error >/dev/null 2>&1; then
				error -c cli,vlan "$warning_msg"
			else
				echo "$warning_msg" >&2
			fi
			rm -rf "$RESTORE_BASE" 2>/dev/null
			return 1
		fi

		RESTORE_TREE="$RESTORE_BASE/$BACKUP_BASENAME"
		if [ ! -d "$RESTORE_TREE" ]; then
			warning_msg="Restore tree not found at $RESTORE_TREE"
			if command -v error >/dev/null 2>&1; then
				error -c cli,vlan "$warning_msg"
			else
				echo "$warning_msg" >&2
			fi
			rm -rf "$RESTORE_BASE" 2>/dev/null
			return 1
		fi

		RESTORE_TARGET_VERSION=""
		if [ -f "$RESTORE_TREE/changelog.txt" ]; then
			RESTORE_TARGET_VERSION=$(sed -n '1{/^[[:space:]]*$/d;p;q}' "$RESTORE_TREE/changelog.txt" 2>/dev/null)
		fi

		info -c cli,vlan "Swapping current MerVLAN installation with selected backup"
		if [ -d "$MERV_BASE" ]; then
			if ! rm -rf "$MERV_BASE" 2>/dev/null; then
				warning_msg="Failed to remove existing MerVLAN directory"
				if command -v error >/dev/null 2>&1; then
					error -c cli,vlan "$warning_msg"
				else
					echo "$warning_msg" >&2
				fi
				rm -rf "$RESTORE_BASE" 2>/dev/null
				return 1
			fi
		fi

		if ! mv "$RESTORE_TREE" "$MERV_BASE" 2>/dev/null; then
			warning_msg="Failed to move restored tree into place"
			if command -v error >/dev/null 2>&1; then
				error -c cli,vlan "$warning_msg"
			else
				echo "$warning_msg" >&2
			fi
			rm -rf "$RESTORE_BASE" 2>/dev/null
			return 1
		fi

		rm -rf "$RESTORE_BASE" 2>/dev/null || :

		info -c cli,vlan "Restore completed successfully from $(basename "$chosen")"
		info -c cli,vlan "Current installation now matches the selected backup archive"
		if [ -n "$RESTORE_CURRENT_VERSION" ] || [ -n "$RESTORE_TARGET_VERSION" ]; then
			info -c cli,vlan "MerVLAN version summary (restore):"
			[ -n "$RESTORE_CURRENT_VERSION" ] && info -c cli,vlan "  From: $RESTORE_CURRENT_VERSION"
			[ -n "$RESTORE_TARGET_VERSION" ] && info -c cli,vlan "  To:   $RESTORE_TARGET_VERSION"
		fi
		return 0
	}

	restore_mervlan
	exit $?
fi

# ========================================================================== #
# CURL RESOLUTION (update mode only)                                         #
# ========================================================================== #

# find curl binary in PATH or fallback to /usr/sbin/curl
find_curl() {
	if command -v curl >/dev/null 2>&1; then
		printf '%s\n' "$(command -v curl)"
	elif [ -x /usr/sbin/curl ]; then
		printf '%s\n' "/usr/sbin/curl"
	else
		return 1
	fi
}

# resolve curl once, fail with a helpful error if missing
CURL_BIN="$(find_curl)" || {
	error -c cli,vlan "curl not found (tried PATH and /usr/sbin/curl); cannot update MerVLAN."
	exit 1
}

# channel/ref selection
case "$CHANNEL" in
	""|main)
		GITHUB_REF="refs/heads/main"
		;;
	dev)
		GITHUB_REF="refs/heads/dev"
		;;
	refs/*)
		GITHUB_REF="$CHANNEL"
		;;
	*)
		GITHUB_REF="refs/heads/$CHANNEL"
		;;
esac

readonly GITHUB_URL="https://codeload.github.com/r80xcore/mervlan/tar.gz/$GITHUB_REF"
info -c cli,vlan "Using Git ref: $GITHUB_REF"

# ========================================================================== #
# BASIC VALIDATION (update mode)                                             #
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
# CAPTURE CURRENT VERSION (BEFORE UPDATE)                                    #
# ========================================================================== #

OLD_VERSION=""
if [ -f "$MERV_BASE/changelog.txt" ]; then
	OLD_VERSION=$(sed -n '1{/^[[:space:]]*$/d;p;q}' "$MERV_BASE/changelog.txt" 2>/dev/null)
fi

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

clean_remote_addon_dirs() {
    local nodes node
    nodes=$(list_configured_nodes)
    if [ -z "$nodes" ]; then
        info -c cli,vlan "Remote cleanup skipped (no nodes configured)"
        return 0
    fi

    if [ ! -f "$SSH_KEY" ]; then
        info -c cli,vlan "Remote cleanup skipped (SSH key not found)"
        return 0
    fi

    for node in $nodes; do
        if dbclient -p "$SSH_NODE_PORT" -y -i "$SSH_KEY" \
            "$SSH_NODE_USER@$node" "rm -rf /jffs/addons/mervlan" >/dev/null 2>&1; then
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

# Track previous boot state from backed-up settings.json snapshot
BOOT_WAS_ENABLED=0
if command -v json_get_flag >/dev/null 2>&1; then
	if [ "$(json_get_flag "BOOT_ENABLED" "0" "$BACKUP_DIR/settings/settings.json" 2>/dev/null)" = "1" ]; then
		BOOT_WAS_ENABLED=1
	fi
elif [ -f "$BACKUP_DIR/settings/settings.json" ]; then
	if grep -q '"BOOT_ENABLED"[[:space:]]*:[[:space:]]*"1"' "$BACKUP_DIR/settings/settings.json" 2>/dev/null; then
		BOOT_WAS_ENABLED=1
	fi
fi

# ========================================================================== #

info -c cli,vlan "Downloading latest MerVLAN snapshot using: $CURL_BIN"
"$CURL_BIN" -fsL --retry 3 --connect-timeout 15 --max-time 300 "$GITHUB_URL" -o "$ARCHIVE"
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

# ensure required top-level directories are present too (clearer messages)
for d in $REQUIRED_STAGE_DIRS; do
	if [ ! -d "$STAGE_DIR/$d" ]; then
		warn -c cli,vlan "Missing required directory in stage: $d/"
		missing=1
	fi
done

if [ "$missing" -ne 0 ]; then
	error -c cli,vlan "Validation failed; downloaded archive does not look like a valid MerVLAN package"
	exit 1
fi
info -c cli,vlan "Staged content validated successfully"
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

# ensure persistent backup root exists
if [ ! -d "$MERVLAN_BACKUP_DIR" ]; then
	if ! mkdir -p "$MERVLAN_BACKUP_DIR" 2>/dev/null; then
		error -c cli,vlan "Failed to create backup root: $MERVLAN_BACKUP_DIR"
		exit 1
	fi
fi

timestamp="$(date +%Y%m%d-%H%M%S 2>/dev/null | tr -d '\n')"
[ -n "$timestamp" ] || timestamp="backup"

CURRENT_BACKUP_NAME="mervlan.backup.$timestamp"
CURRENT_BACKUP_DIR="$MERVLAN_BACKUP_DIR/$CURRENT_BACKUP_NAME"
MERVLAN_UPDATED_TREE_DIR="$TMP_BASE/updated_tree"

info -c cli,vlan "Creating backup of current installation at $CURRENT_BACKUP_DIR"
if [ -d "$CURRENT_BACKUP_DIR" ]; then
	rm -rf "$CURRENT_BACKUP_DIR" 2>/dev/null || :
fi

if ! cp -pR "$MERV_BASE" "$CURRENT_BACKUP_DIR" 2>/dev/null; then
	error -c cli,vlan "Failed to copy current installation to $CURRENT_BACKUP_DIR"
	exit 1
fi

info -c cli,vlan "Building updated tree at $MERVLAN_UPDATED_TREE_DIR"
rm -rf "$MERVLAN_UPDATED_TREE_DIR" 2>/dev/null || :

mkdir -p "$MERVLAN_UPDATED_TREE_DIR" 2>/dev/null || {
	error -c cli,vlan "Failed to create temporary install directory"
	exit 1
}

if ! cp -a "$STAGE_DIR"/. "$MERVLAN_UPDATED_TREE_DIR"/ 2>/dev/null; then
	error -c cli,vlan "Failed to copy staged files into $MERVLAN_UPDATED_TREE_DIR"
	rm -rf "$MERVLAN_UPDATED_TREE_DIR" 2>/dev/null
	exit 1
fi

# CHMOD: normalize script permissions in new tree
info -c cli,vlan "Normalizing script permissions in new tree"

# 1) Default: make all .sh files under MERVLAN_UPDATED_TREE_DIR executable (755)
for depth in "" "*/" "*/*/"; do
	for f in "$MERVLAN_UPDATED_TREE_DIR"/${depth}*.sh; do
		[ -f "$f" ] 2>/dev/null || continue
		chmod 755 "$f" 2>/dev/null || :
	done
done

# 2) Override: specific .sh files that must *not* be executable → 644
for rel_path in \
	"settings/var_settings.sh" \
	"settings/log_settings.sh" \
	"templates/mervlan_templates.sh" \
	"settings/lib_debug.sh" \
	"settings/lib_json.sh" \
	"settings/lib_ssh.sh"
do
	target="$MERVLAN_UPDATED_TREE_DIR/$rel_path"
	[ -f "$target" ] && chmod 644 "$target" 2>/dev/null || :
done


# ========================================================================== #
# RESTORE USER DATA                                                          #
# ========================================================================== #

info -c cli,vlan "Restoring preserved files"
for rel_path in $BACKUP_LIST; do
	backup_file="$BACKUP_DIR/$rel_path"
	target="$MERVLAN_UPDATED_TREE_DIR/$rel_path"
	if [ -f "$backup_file" ]; then
		mkdir -p "$(dirname "$target")" 2>/dev/null || {
			error -c cli,vlan "Failed to recreate directory for $rel_path"
			rm -rf "$MERVLAN_UPDATED_TREE_DIR" 2>/dev/null
			exit 1
		}
		cp -p "$backup_file" "$target" 2>/dev/null || {
			error -c cli,vlan "Failed to restore $rel_path"
			rm -rf "$MERVLAN_UPDATED_TREE_DIR" 2>/dev/null
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

if ! mv "$MERVLAN_UPDATED_TREE_DIR" "$MERV_BASE" 2>/dev/null; then
	error -c cli,vlan "Failed to activate new installation"
	mv "$CURRENT_BACKUP_DIR" "$MERV_BASE" 2>/dev/null
	exit 1
fi

# ========================================================================== #
# OPTIONAL POST-UPDATE TASKS                                                 #
# ========================================================================== #

refresh_public_install() {
	local uninstall_script="$MERV_BASE/uninstall.sh"
	local install_script="$MERV_BASE/install.sh"

	info -c cli,vlan "Refreshing public install directory via uninstall/install"

	if [ ! -x "$uninstall_script" ]; then
		warn -c cli,vlan "Skipping public refresh: $uninstall_script not executable"
		return 1
	fi
	if [ ! -x "$install_script" ]; then
		warn -c cli,vlan "Skipping public refresh: $install_script not executable"
		return 1
	fi

	if ! sh "$uninstall_script" >/dev/null 2>&1; then
		warn -c cli,vlan "Public uninstall failed; install may be stale"
		return 1
	fi

	if ! sh "$install_script" >/dev/null 2>&1; then
		warn -c cli,vlan "Public install refresh failed"
		return 1
	fi

	info -c cli,vlan "Public install refreshed"
}


# Optionally refresh hardware profile on the upgraded installation
if [ -x "$HW_PROBE" ]; then
	info -c cli,vlan "Refreshing hardware profile via hw_probe.sh"
	if ! sh "$HW_PROBE" >/dev/null 2>&1; then
		warn -c cli,vlan "hw_probe.sh reported errors; hardware profile may be stale"
	fi
else
	warn -c cli,vlan "hw_probe.sh not executable; skipping hardware probe refresh"
fi

# Refresh node files when SSH keys and nodes are configured
if ssh_keys_effectively_installed && has_configured_nodes; then
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

refresh_public_install


# ========================================================================== #
# COMPRESS BACKUP AND PRUNE OLD ARCHIVES                                     #
# ========================================================================== #

# Compress the just-created backup directory to save space
if [ -d "$CURRENT_BACKUP_DIR" ]; then
	info -c cli,vlan "Compressing backup $CURRENT_BACKUP_NAME (gzip)"
	if tar -czf "$MERVLAN_BACKUP_DIR/$CURRENT_BACKUP_NAME.tar.gz" \
		-C "$MERVLAN_BACKUP_DIR" "$CURRENT_BACKUP_NAME" 2>/dev/null; then
		rm -rf "$CURRENT_BACKUP_DIR" 2>/dev/null || :
	else
		warn -c cli,vlan "Failed to compress backup $CURRENT_BACKUP_DIR; leaving directory uncompressed"
	fi
fi

# Keep only the 3 newest compressed backups
if [ -d "$MERVLAN_BACKUP_DIR" ]; then
	set -- "$MERVLAN_BACKUP_DIR"/mervlan.backup.*.tar.gz
	if [ -e "$1" ]; then
		BACKUPS_LIST="$(ls "$MERVLAN_BACKUP_DIR"/mervlan.backup.*.tar.gz 2>/dev/null | sort -r)"
		count=0
		for b in $BACKUPS_LIST; do
			count=$((count + 1))
			if [ "$count" -le 3 ]; then
				continue
			fi
			info -c cli,vlan "Removing old backup: $b"
			rm -f "$b" 2>/dev/null || :
		done
	fi
fi

# ========================================================================== #
# FINALIZATION                                                               #
# ========================================================================== #

NEW_VERSION=""
if [ -f "$MERV_BASE/changelog.txt" ]; then
	NEW_VERSION=$(sed -n '1{/^[[:space:]]*$/d;p;q}' "$MERV_BASE/changelog.txt" 2>/dev/null)
fi

if [ -n "$OLD_VERSION" ] || [ -n "$NEW_VERSION" ]; then
	info -c cli,vlan "MerVLAN version summary (update):"
	[ -n "$OLD_VERSION" ] && info -c cli,vlan "  From: $OLD_VERSION"
	[ -n "$NEW_VERSION" ] && info -c cli,vlan "  To:   $NEW_VERSION"
fi

info -c cli,vlan "MerVLAN update completed successfully"

if [ -f "$MERV_BASE/changelog.txt" ]; then
	info -c cli "Changelog (current version):"
	awk '
		/^#####/ { exit }
		{ print }
	' "$MERV_BASE/changelog.txt"
fi

exit 0