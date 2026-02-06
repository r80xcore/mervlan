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
#                - File: update_mervlan.sh || version="0.53"                   #
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
# GLOBAL UPDATE STATE FLAGS                                                  #
# ========================================================================== #

# Original boot enabled state before teardown (0/1)
PRE_BOOT_ENABLED="0"

# Set to 1 once pre-update teardown of hooks has been performed
TEARDOWN_DONE="0"

# Set to 1 once a full backup of $MERV_BASE has been created at $CURRENT_BACKUP_DIR
BACKUP_READY="0"

# Set to 1 once we start performing destructive operations on $MERV_BASE
DESTRUCTIVE_TOUCHED="0"

# ========================================================================== #
# CENTRAL FAILURE / ROLLBACK HANDLER                                         #
# ========================================================================== #
fail_update() {
	block="$1"
	shift
	detail="$*"

	# Ensure temporary user-data backup is cleared on failure paths
	[ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] && rm -rf "$BACKUP_DIR" 2>/dev/null || :

	restored_tree="0"
	restore_attempted="0"

	[ -n "$detail" ] && error -c cli,vlan "$detail"

	if [ "$DESTRUCTIVE_TOUCHED" = "1" ] && [ "$BACKUP_READY" = "1" ] && \
	   [ -n "${CURRENT_BACKUP_DIR:-}" ] && [ -d "$CURRENT_BACKUP_DIR" ]; then
		restore_attempted="1"
		info -c cli,vlan "Restoring MerVLAN from backup at $CURRENT_BACKUP_DIR"
		[ -d "$MERV_BASE" ] && rm -rf "$MERV_BASE" 2>/dev/null || :
		if mv "$CURRENT_BACKUP_DIR" "$MERV_BASE" 2>/dev/null; then
			restored_tree="1"
		fi
	fi

	if [ "$TEARDOWN_DONE" = "1" ] && [ -n "${BOOT_SCRIPT:-}" ] && [ -x "$BOOT_SCRIPT" ]; then
		info -c cli,vlan "Re-applying MerVLAN hooks to original state"
		sh "$BOOT_SCRIPT" setupenable >/dev/null 2>&1 || :
		if [ "$PRE_BOOT_ENABLED" = "1" ]; then
			sh "$BOOT_SCRIPT" enable >/dev/null 2>&1 || :
			if ssh_keys_effectively_installed && has_configured_nodes; then
				sh "$BOOT_SCRIPT" nodeenable >/dev/null 2>&1 || :
			fi
		fi
	fi

	if [ "$restored_tree" = "1" ]; then
		error -c cli,vlan "Update failed in stage: $block (backup restored)"
	elif [ "$restore_attempted" = "1" ]; then
		rm -rf "$CURRENT_BACKUP_DIR" 2>/dev/null || :
		error -c cli,vlan "Update failed in stage: $block (backup restore failed)"
	else
		error -c cli,vlan "Update failed in stage: $block (no backup restore needed)"
	fi
	exit 1
}
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
# SETTINGS.JSON MERGE HELPERS                                                #
# ========================================================================== #

# merge_settings_json — Merge old settings into new defaults (skip Hardware)
# Args: $1=old_settings_file, $2=new_settings_file
# Behavior: Preserves user values from old file, keeps new keys from updated
#           defaults, and skips all keys under Hardware.
merge_settings_json() {
	old_file="$1"
	new_file="$2"
	tmp_kv="$TMP_BASE/merge_kv.$$"

	[ -f "$old_file" ] || return 0
	[ -f "$new_file" ] || return 1

	: > "$tmp_kv"

	if ! awk -v out="$tmp_kv" '
		function net_braces(s,   t, o, c) {
			t = s
			o = gsub(/\{/, "", t)
			c = gsub(/\}/, "", t)
			return o - c
		}
		function get_name(line,   t) {
			t = line
			sub(/^[[:space:]]*"/, "", t)
			sub(/".*$/, "", t)
			return t
		}
		BEGIN {
			depth=-1
			sec=""; subsec=""
			sec_depth=0; sub_depth=0
			in_hw=0; hw_depth=0
		}
		{
			line=$0

			# Enter top-level section only when at depth 0
			if (depth==0 && line ~ /^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*\{/) {
				sec = get_name(line)
				sec_depth = depth + net_braces(line)
				if (sec == "Hardware") {
					in_hw = 1
					hw_depth = sec_depth
				} else {
					in_hw = 0
				}
				subsec = ""
				sub_depth = 0
			}

			# Enter subsection only when inside a section at depth 1 (not Hardware)
			if (!in_hw && sec != "" && depth==1 &&
			    line ~ /^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*\{/) {
				subsec = get_name(line)
				sub_depth = depth + net_braces(line)
			}

			# Capture quoted scalar values only (no arrays/objects)
			if (!in_hw && sec != "" &&
			    line ~ /^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*$/) {
				k = get_name(line)
				v = line
				sub(/^[^:]*:[[:space:]]*"/, "", v)
				sub(/".*$/, "", v)
				if (k !~ /^_/ && k !~ /^BACKUP_[123]$/) {
					if (depth==1) {
						printf "%s|%s|%s|%s\n", sec, "", k, v >> out
					} else if (subsec != "") {
						printf "%s|%s|%s|%s\n", sec, subsec, k, v >> out
					}
				}
			}

			# Update depth AFTER processing line
			depth += net_braces(line)

			# Exit Hardware
			if (in_hw && depth < hw_depth) {
				in_hw = 0
				sec = ""
				subsec = ""
			}

			# Exit subsection
			if (subsec != "" && depth < sub_depth) {
				subsec = ""
			}

			# Exit section
			if (sec != "" && depth < sec_depth) {
				sec = ""
				subsec = ""
			}
		}
	' "$old_file"; then
		return 1
	fi

	if [ -s "$tmp_kv" ]; then
		cnt="$(wc -l < "$tmp_kv" 2>/dev/null | tr -d '[:space:]')"
		[ -n "$cnt" ] || cnt="?"
		info -c cli,vlan "settings.json merge: extracted $cnt scalar values"
	else
		warn -c cli,vlan "settings.json merge: extracted 0 values (old file format mismatch?)"
		rm -f "$tmp_kv" 2>/dev/null || :
		return 0
	fi

	while IFS='|' read -r section subsection key value || [ -n "$section" ]; do
		[ -n "$section" ] || continue
		[ -n "$key" ] || continue
		if [ -n "$subsection" ]; then
			json_set_section2_value "$section" "$subsection" "$key" "$value" "$new_file" || { rm -f "$tmp_kv" 2>/dev/null || :; return 1; }
		else
			json_set_section_value "$section" "$key" "$value" "$new_file" || { rm -f "$tmp_kv" 2>/dev/null || :; return 1; }
		fi
	done < "$tmp_kv"

	rm -f "$tmp_kv" 2>/dev/null || :
}

# ========================================================================== #
# BACKUP METADATA → settings.json                                            #
# ========================================================================== #

# ========================================================================== #
# BACKUP METADATA → settings.json                                            #
# ========================================================================== #

update_backup_metadata() {
    # Always reset all three slots so the JSON shape is stable
    json_set_array "BACKUP_1" "none none none"
    json_set_array "BACKUP_2" "none none none"
    json_set_array "BACKUP_3" "none none none"

    # No backup directory or no archives → nothing to record
    [ -d "$MERVLAN_BACKUP_DIR" ] || return 0
    set -- "$MERVLAN_BACKUP_DIR"/mervlan.backup.*.tar.gz
    [ -e "$1" ] || return 0

    BACKUPS_LIST="$(ls "$MERVLAN_BACKUP_DIR"/mervlan.backup.*.tar.gz 2>/dev/null | sort -r)"

    # Temporary working directory for extracting changelog.txt only
    META_TMP="$TMP_DIR/backup_meta.$$"
    mkdir -p "$META_TMP" 2>/dev/null || META_TMP=""

    idx=0
    for b in $BACKUPS_LIST; do
        idx=$((idx + 1))
        [ "$idx" -gt 3 ] && break

        base="$(basename "$b" .tar.gz)"    # mervlan.backup.YYYYMMDD-HHMMSS
        ts="${base#mervlan.backup.}"       # YYYYMMDD-HHMMSS

        # ----- date: YYYY-MM-DD -----
        date_part="${ts%%-*}"             # YYYYMMDD
        time_part="${ts#*-}"              # HHMMSS (or HHMM)

        yyyy=${date_part%????}            # 2025
        mmdd=${date_part#????}            # 1213
        mm=${mmdd%??}                     # 12
        dd=${mmdd#??}                     # 13
        date_fmt="$yyyy-$mm-$dd"

        # ----- time: HH:MM -----
        hh=${time_part%${time_part#??}}
        mm_rest=${time_part#??}
        mm2=${mm_rest%${mm_rest#??}}
        [ -z "$hh" ] && hh="00"
        [ -z "$mm2" ] && mm2="00"
        time_fmt="$hh:$mm2"

        version="none"

        if [ -n "$META_TMP" ]; then
            # Find changelog.txt inside the archive (path will be like mervlan.backup.YYYY.../changelog.txt)
            cl_path="$(tar -tzf "$b" 2>/dev/null | grep '/changelog\.txt$' | head -n 1)"

            if [ -n "$cl_path" ]; then
                # Make sure directory exists for extraction
                cl_dir="$META_TMP/$(dirname "$cl_path")"
                mkdir -p "$cl_dir" 2>/dev/null || :

                # Extract ONLY changelog.txt into META_TMP
                tar -xzf "$b" -C "$META_TMP" "$cl_path" >/dev/null 2>&1 || :

                if [ -f "$META_TMP/$cl_path" ]; then
                    # First non-empty line
                    first_line="$(sed -n '1{/^[[:space:]]*$/d;p;q}' "$META_TMP/$cl_path" 2>/dev/null)"

                    # Expecting:  "mervlan vX.XX"
                    # Grab the last whitespace-separated field as candidate version
                    candidate="${first_line##* }"

                    case "$candidate" in
                        v*)
                            version="$candidate"
                            ;;
                        *)
                            # If it doesn't start with v, keep "none"
                            :
                            ;;
                    esac
                fi
            fi
        fi

        case "$idx" in
            1) json_set_array "BACKUP_1" "$version $date_fmt $time_fmt" ;;
            2) json_set_array "BACKUP_2" "$version $date_fmt $time_fmt" ;;
            3) json_set_array "BACKUP_3" "$version $date_fmt $time_fmt" ;;
        esac
    done

    # Clean up extracted changelog files so nothing lingers
    [ -n "$META_TMP" ] && [ -d "$META_TMP" ] && rm -rf "$META_TMP" 2>/dev/null || :
}


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
		RESTORE_SELECTION="${2:-}"
		RESTORE_CONFIRM="${3:-}"
		;;
	update)
		MODE="update"
		CHANNEL="${2:-main}"
		;;
	*)
		echo "Usage: $0 [update [branch]|restore|main|dev|refs/<ref>]" >&2
		fail_update cli "Unknown mode/channel: $1"
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

		sel_arg="${RESTORE_SELECTION:-}"
		confirm_arg="${RESTORE_CONFIRM:-}"

		RESTORE_CURRENT_VERSION=""
		if [ -f "$MERV_BASE/changelog.txt" ]; then
			RESTORE_CURRENT_VERSION=$(sed -n '1{/^[[:space:]]*$/d;p;q}' "$MERV_BASE/changelog.txt" 2>/dev/null)
		fi

		if [ ! -d "$MERVLAN_BACKUP_DIR" ]; then
			warning_msg="No backup directory found at $MERVLAN_BACKUP_DIR"
			if merv_has error; then
				error -c cli,vlan "$warning_msg"
			else
				echo "$warning_msg" >&2
			fi
			return 1
		fi

		set -- "$MERVLAN_BACKUP_DIR"/mervlan.backup.*.tar.gz
		if [ ! -e "$1" ]; then
			warning_msg="No backup archives found in $MERVLAN_BACKUP_DIR"
			if merv_has error; then
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
			if merv_has error; then
				error -c cli,vlan "$warning_msg"
			else
				echo "$warning_msg" >&2
			fi
			return 1
		fi

		if [ -n "$sel_arg" ]; then
			sel="$sel_arg"
		else
			printf "Select backup to restore [1-%d]: " "$idx"
			read sel
		fi

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
			if merv_has error; then
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

		if [ -n "$confirm_arg" ]; then
			ans="$confirm_arg"
		else
			printf "Continue? [y/N]: "
			read ans
		fi

		case "$ans" in
			y|Y|yes|YES) ;;
			*)
				info -c cli,vlan "Restore aborted by user"
				return 2
				;;
		esac

		RESTORE_BASE="$TMP_DIR/restore.$$"
		mkdir -p "$RESTORE_BASE" 2>/dev/null || {
			warning_msg="Failed to create restore workdir: $RESTORE_BASE"
			if merv_has error; then
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
			if merv_has error; then
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
			if merv_has error; then
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
				if merv_has error; then
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
			if merv_has error; then
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
	CURL_PATH=$(merv_cmd curl 2>/dev/null) || CURL_PATH=""
	if [ -n "$CURL_PATH" ]; then
		printf '%s\n' "$CURL_PATH"
	elif [ -x /usr/sbin/curl ]; then
		printf '%s\n' "/usr/sbin/curl"
	else
		return 1
	fi
}

# resolve curl once, fail with a helpful error if missing
CURL_BIN="$(find_curl)" || \
	fail_update curl "curl not found (tried PATH and /usr/sbin/curl); cannot update MerVLAN."

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
	fail_update cli "MerVLAN base directory missing at $MERV_BASE"
fi

mkdir -p "$TMP_BASE" "$STAGE_DIR" "$BACKUP_DIR" 2>/dev/null || \
	fail_update workspace "Failed to prepare temporary workspace at $TMP_BASE"

# ========================================================================== #
# CAPTURE CURRENT VERSION (BEFORE UPDATE)                                    #
# ========================================================================== #

OLD_VERSION=""
if [ -f "$MERV_BASE/changelog.txt" ]; then
	OLD_VERSION=$(sed -n '1{/^[[:space:]]*$/d;p;q}' "$MERV_BASE/changelog.txt" 2>/dev/null)
fi

# ========================================================================== #
# CAPTURE ORIGINAL BOOT STATE (BEFORE TEARDOWN)                              #
# ========================================================================== #
if [ -f "$MERV_BASE/settings/settings.json" ]; then
	if merv_has json_get_section_value; then
		PRE_BOOT_ENABLED="$(json_get_section_value "General" "BOOT_ENABLED" "$MERV_BASE/settings/settings.json" 2>/dev/null)"
	elif merv_has json_get_flag; then
		PRE_BOOT_ENABLED="$(json_get_flag "BOOT_ENABLED" "0" "$MERV_BASE/settings/settings.json" 2>/dev/null)"
	elif grep -q '"BOOT_ENABLED"[[:space:]]*:[[:space:]]*"1"' "$MERV_BASE/settings/settings.json" 2>/dev/null; then
		PRE_BOOT_ENABLED="1"
	fi
fi
[ "$PRE_BOOT_ENABLED" = "1" ] || PRE_BOOT_ENABLED="0"

# ========================================================================== #
# NODE/SSH HELPERS                                                           #
# ========================================================================== #

list_configured_nodes() {
	[ -f "$SETTINGS_FILE" ] || return 1
	grep -o '"NODE[1-5]"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" 2>/dev/null | \
		sed -n 's/"NODE\([1-5]\)"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1 \2/p' | \
		awk '$2 != "none" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $1, $2 }'
}

has_configured_nodes() {
	nodes=$(list_configured_nodes)
	[ -n "$nodes" ]
}

clean_remote_addon_dirs() {
    nodes=$(list_configured_nodes)
    if [ -z "$nodes" ]; then
        info -c cli,vlan "Remote cleanup skipped (no nodes configured)"
        return 0
    fi

    # If keys are missing, skip cleanly (no freeze, no failure)
    if ! ssh_keys_effectively_installed; then
        warn -c cli,vlan "Remote cleanup skipped (SSH keys not installed)"
        return 0
    fi

    while read -r node_id node_ip; do
        [ -n "$node_ip" ] || continue

        if merv_ssh_exec "$node_id" "$node_ip" "rm -rf /jffs/addons/mervlan" >/dev/null 2>&1; then
            info -c cli,vlan "Cleared remote addon directory on NODE${node_id} ($node_ip)"
        else
            merv_ssh_skip_log "$node_id" "$node_ip" "remote cleanup"
            # IMPORTANT: do not fail the update; just warn and continue
        fi
    done <<EOF
$nodes
EOF

    return 0
}

# ========================================================================== #
# BACKUP ORIGINAL FILES                                                      #
# ========================================================================== #

info -c cli,vlan "Backing up user configuration files"
for rel_path in $BACKUP_LIST; do
	src="$MERV_BASE/$rel_path"
	if [ -f "$src" ]; then
		dest="$BACKUP_DIR/$rel_path"
		mkdir -p "$(dirname "$dest")" 2>/dev/null || \
			fail_update backup_user_files "Failed to create backup directory for $rel_path"
		cp -p "$src" "$dest" 2>/dev/null || \
			fail_update backup_user_files "Failed to back up $rel_path"
	fi
done

# ========================================================================== #

info -c cli,vlan "Downloading latest MerVLAN snapshot using: $CURL_BIN"
"$CURL_BIN" -fsL --retry 3 --connect-timeout 15 --max-time 300 "$GITHUB_URL" -o "$ARCHIVE"
if [ ! -s "$ARCHIVE" ]; then
	fail_update downloading "Download failed or archive empty"
fi

info -c cli,vlan "Extracting archive into staging area"
if tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
	tar -xzf "$ARCHIVE" -C "$TMP_BASE" || \
		fail_update extracting "Failed to extract archive"
else
	gzip -dc "$ARCHIVE" | tar -x -C "$TMP_BASE" || \
		fail_update extracting "Failed to extract archive via gzip fallback"
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
	fail_update extracting "Unable to determine extracted directory"
fi

cp -a "$topdir"/. "$STAGE_DIR"/ 2>/dev/null || \
	fail_update extracting "Failed to copy extracted files into staging"

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
	fail_update validating "Validation failed; downloaded archive does not look like a valid MerVLAN package"
fi
info -c cli,vlan "Staged content validated successfully"

# Temporarily tear down boot/service-event hooks so refreshed templates can be applied cleanly
if [ -x "$BOOT_SCRIPT" ]; then
	TEARDOWN_DONE="1"
	info -c cli,vlan "Disabling MerVLAN hooks on main router before swap"

	# Always tear down hooks on the main router
	if ! sh "$BOOT_SCRIPT" setupdisable >/dev/null 2>&1; then
		warn -c cli,vlan "mervlan_boot.sh setupdisable returned non-zero (continuing)"
	fi

	if ! sh "$BOOT_SCRIPT" disable >/dev/null 2>&1; then
		warn -c cli,vlan "mervlan_boot.sh disable returned non-zero (continuing)"
	fi

	# Optionally tear down hooks on nodes when SSH + nodes are configured
	if ssh_keys_effectively_installed && has_configured_nodes; then
		info -c cli,vlan "Disabling MerVLAN hooks on nodes before swap"
		if ! sh "$BOOT_SCRIPT" nodedisable >/dev/null 2>&1; then
			warn -c cli,vlan "mervlan_boot.sh nodedisable returned non-zero (continuing)"
		fi
	else
		info -c cli,vlan "nodedisable skipped (no nodes configured or SSH keys absent)"
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
		fail_update backing_up "Failed to create backup root: $MERVLAN_BACKUP_DIR"
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
	fail_update backing_up "Failed to copy current installation to $CURRENT_BACKUP_DIR"
fi
BACKUP_READY="1"

info -c cli,vlan "Building updated tree at $MERVLAN_UPDATED_TREE_DIR"
rm -rf "$MERVLAN_UPDATED_TREE_DIR" 2>/dev/null || :

mkdir -p "$MERVLAN_UPDATED_TREE_DIR" 2>/dev/null || \
	fail_update building_tree "Failed to create temporary install directory"

if ! cp -a "$STAGE_DIR"/. "$MERVLAN_UPDATED_TREE_DIR"/ 2>/dev/null; then
	rm -rf "$MERVLAN_UPDATED_TREE_DIR" 2>/dev/null || :
	fail_update building_tree "Failed to copy staged files into $MERVLAN_UPDATED_TREE_DIR"
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
		if [ "$rel_path" = "settings/settings.json" ]; then
			info -c cli,vlan "Merging settings.json (preserve user keys, keep new defaults, skip Hardware)"
			if ! merge_settings_json "$backup_file" "$target"; then
				rm -rf "$MERVLAN_UPDATED_TREE_DIR" 2>/dev/null || :
				fail_update restoring_user_data "Failed to merge settings.json"
			fi
			continue
		fi
		if ! mkdir -p "$(dirname "$target")" 2>/dev/null; then
			rm -rf "$MERVLAN_UPDATED_TREE_DIR" 2>/dev/null || :
			fail_update restoring_user_data "Failed to recreate directory for $rel_path"
		fi
		if ! cp -p "$backup_file" "$target" 2>/dev/null; then
			rm -rf "$MERVLAN_UPDATED_TREE_DIR" 2>/dev/null || :
			fail_update restoring_user_data "Failed to restore $rel_path"
		fi
		if [ -n "$SSH_KEY_RELATIVE" ] && [ "$rel_path" = "$SSH_KEY_RELATIVE" ]; then
			chmod 600 "$target" 2>/dev/null || :
		elif [ -n "$SSH_PUBKEY_RELATIVE" ] && [ "$rel_path" = "$SSH_PUBKEY_RELATIVE" ]; then
			chmod 644 "$target" 2>/dev/null || :
		fi
	fi
done

info -c cli,vlan "Swapping active installation"
DESTRUCTIVE_TOUCHED="1"
rm -rf "$MERV_BASE" 2>/dev/null || \
	fail_update swapping_installation "Failed to clear existing MerVLAN directory"

if ! mv "$MERVLAN_UPDATED_TREE_DIR" "$MERV_BASE" 2>/dev/null; then
	fail_update swapping_installation "Failed to activate new installation"
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

# Ensure the public install view reflects the refreshed files before re-adding hooks
refresh_public_install

# Reapply boot/service-event hooks from the refreshed installation
if [ -x "$BOOT_SCRIPT" ]; then
	info -c cli,vlan "Re-applying MerVLAN hooks on the main router"

	# Always refresh the setup hooks on the main router
	if ! sh "$BOOT_SCRIPT" setupenable >/dev/null 2>&1; then
		warn -c cli,vlan "mervlan_boot.sh setupenable returned non-zero (continuing)"
	fi

	# Use PRE_BOOT_ENABLED (captured before teardown) instead of BOOT_ENABLED_FROM_RESTORE
	# The teardown phase writes BOOT_ENABLED=0 to settings.json before backup, so
	# BOOT_ENABLED_FROM_RESTORE will always be 0. PRE_BOOT_ENABLED holds the original state.
	if [ "$PRE_BOOT_ENABLED" = "1" ]; then
		info -c cli,vlan "PRE_BOOT_ENABLED=1; enabling MerVLAN boot on main router"
		if ! sh "$BOOT_SCRIPT" enable >/dev/null 2>&1; then
			warn -c cli,vlan "mervlan_boot.sh enable returned non-zero (continuing)"
		fi

		# Optionally re-enable hooks on nodes when SSH + nodes are configured
		if ssh_keys_effectively_installed && has_configured_nodes; then
			info -c cli,vlan "Enabling MerVLAN boot on nodes"
			if ! sh "$BOOT_SCRIPT" nodeenable >/dev/null 2>&1; then
				warn -c cli,vlan "mervlan_boot.sh nodeenable returned non-zero (continuing)"
			fi
		else
			info -c cli,vlan "Node enable skipped (no nodes configured or SSH keys absent)"
		fi
	else
		info -c cli,vlan "PRE_BOOT_ENABLED!=1; leaving MerVLAN boot disabled"
	fi
else
	warn -c cli,vlan "mervlan_boot.sh not executable; skipping post-update hook setup"
fi

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

# Update backup metadata in settings.json to reflect newest 3 backups
update_backup_metadata

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

if [ -f "$MERV_BASE/changelog.txt" ]; then
	info -c cli,vlan "Changelog (current version):"
	awk '
		/^#####/ { exit }
		{ print }
	' "$MERV_BASE/changelog.txt"
fi

info -c cli,vlan "MerVLAN update completed successfully"

exit 0
