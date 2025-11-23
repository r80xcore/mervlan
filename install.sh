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
#                    - File: install.sh || version="0.45"                      #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Enable the MerVLAN addon and set up necessary files            #
#                                                                              #
# ──────────────────────────────────────────────────────────────────────────── #

source /usr/sbin/helper.sh

# ========================================================================== #
# CONFIGURATION PATHS & CONSTANTS — Source locations and workspace defaults  #
# ========================================================================== #

# GITHUB_URL — Tarball endpoint for fetching latest MerVLAN release snapshot
# ADDON_DIR/ADDON/MERV_BASE — Install root beneath /jffs/addons
# PUBLIC_DIR — Files exposed to web UI for SPA assets and JSON data
# TMP_DIR/TMP — Workspace for transient downloads and log files
# SETTINGS_FILE — JSON configs used during install
# BOOT_SCRIPT — Helper used for setupenable/nodeenable orchestration

GITHUB_URL="https://codeload.github.com/r80xcore/mervlan/tar.gz/refs/heads/main"
ADDON_DIR="/jffs/addons"
ADDON="mervlan"
MERV_BASE="$ADDON_DIR/$ADDON"
PUBLIC_DIR="/www/user/mervlan"
TMP_DIR="/tmp/mervlan_tmp"
TMP="${TMP_DIR:-$(mktemp -d)}"
SETTINGS_FILE="$MERV_BASE/settings/settings.json"
BOOT_SCRIPT="$MERV_BASE/functions/mervlan_boot.sh"
SSH_KEY="$MERV_BASE/.ssh/vlan_manager"
SSH_PUBKEY="$MERV_BASE/.ssh/vlan_manager.pub"

# ========================================================================== #
# EMBEDDED JSON HELPERS — Minimal subset required during install            #
# ========================================================================== #

ensure_json_store() {
    # ensure_json_store [file] [defaults]
    # Create containing directory and seed JSON file if missing/empty.
    local file="${1:-$SETTINGS_FILE}" defaults="${2:-}" dir

    dir=$(dirname "$file")
    mkdir -p "$dir" 2>/dev/null || return 1

    if [ ! -s "$file" ]; then
        if [ -n "$defaults" ]; then
            printf '%s\n' "$defaults" > "$file" || return 1
        else
            printf '{\n}\n' > "$file" || return 1
        fi
    fi

    return 0
}

json_escape_string() {
    # json_escape_string <value>
    local value="$1"
    printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'
}

json_set_flag() {
    # json_set_flag <key> <value> [file] [defaults]
    local key="$1"
    local value="$2"
    local file="${3:-$SETTINGS_FILE}"
    local defaults="${4:-}"
    local json_value sed_value script tmp

    [ -n "$key" ] || return 1

    ensure_json_store "$file" "$defaults" || return 1

    json_value=$(json_escape_string "$value")
    sed_value=$(printf '%s' "$json_value" | sed 's/\\/\\\\/g; s/&/\\&/g')

    if grep -q "\"$key\""[[:space:]]*: "$file" 2>/dev/null; then
        script="${file}.sed.$$"
        printf 's/"%s"[[:space:]]*:[[:space:]]*"[^"]*"/"%s": "%s"/\n' "$key" "$key" "$sed_value" > "$script" || {
            rm -f "$script"
            return 1
        }
        if ! sed -i -f "$script" "$file" 2>/dev/null; then
            rm -f "$script"
            return 1
        fi
        rm -f "$script"
        return 0
    fi

    if grep -q '"[^"]\+"' "$file" 2>/dev/null; then
        tmp="${file}.tmp.$$"
        JSON_SET_FLAG_VALUE="$json_value" \
        awk -v key="$key" '
            BEGIN {
                value = ENVIRON["JSON_SET_FLAG_VALUE"]
                last_prop = -1
            }
            {
                lines[NR] = $0
                if ($0 ~ /"[^"]+"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*(,)?[[:space:]]*$/) {
                    last_prop = NR
                }
            }
            END {
                if (last_prop == -1) {
                    printf "{\n  \"%s\": \"%s\"\n}\n", key, value
                    exit
                }

                for (i = 1; i < last_prop; i++) {
                    print lines[i]
                }

                line = lines[last_prop]
                sub(/[[:space:]]*$/, "", line)
                if (line !~ /,$/) {
                    line = line ","
                }
                print line

                printf "  \"%s\": \"%s\"\n", key, value

                for (i = last_prop + 1; i <= NR; i++) {
                    print lines[i]
                }
            }
        ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

        mv "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
        return 0
    fi

    printf '{\n  "%s": "%s"\n}\n' "$key" "$json_value" > "$file" || return 1
    return 0
}

json_get_flag() {
    # json_get_flag <key> [default] [file]
    local key="$1"
    local default_value="${2:-}"
    local file="${3:-$SETTINGS_FILE}"

    [ -n "$key" ] || { printf '%s\n' "$default_value"; return 1; }

    if [ ! -s "$file" ]; then
        printf '%s\n' "$default_value"
        return 0
    fi

    # Extract "VALUE" from a line like:  "KEY": "VALUE",
    # - ignores leading spaces
    # - allows spaces around colon
    # - ignores trailing comma and spaces
    local value
    value="$(sed -n "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\"[[:space:]]*,\{0,1\}[[:space:]]*$/\\1/p" "$file")"

    if [ -n "$value" ]; then
        printf '%s\n' "$value"
    else
        printf '%s\n' "$default_value"
    fi
}


# ========================================================================== #
# EMBEDDED SSH HELPERS — Node credential prompts and key state detection    #
# ========================================================================== #

prompt_ssh_port_override() {
    # Configure SSH port for node connections, stored in settings.json.
    local current_port reply port

    echo ""
    echo "[install] Configure SSH port for node connections."

    current_port=$(json_get_flag "NODE_SSH_PORT" "__MISSING__" "$SETTINGS_FILE" 2>/dev/null)
    if [ "$current_port" = "__MISSING__" ] || [ -z "$current_port" ]; then
        current_port=$(json_get_flag "SSH_PORT" "22" "$SETTINGS_FILE" 2>/dev/null)
    fi
    [ -n "$current_port" ] || current_port="22"

    while :; do
        printf '[install] Use SSH port %s? [Y/n]: ' "$current_port"
        IFS= read -r reply || reply=""
        case "$reply" in
            ""|Y|y|YES|yes|Yes)
                echo "[install] Keeping SSH port $current_port."
                json_set_flag "NODE_SSH_PORT" "$current_port" "$SETTINGS_FILE" >/dev/null 2>&1
                json_set_flag "SSH_PORT" "$current_port" "$SETTINGS_FILE" >/dev/null 2>&1
                return 0
                ;;
            N|n|NO|no|No)
                while :; do
                    printf '[install] Enter SSH port (1-65535): '
                    IFS= read -r port || port=""
                    case "$port" in
                        ''|*[^0-9]*)
                            echo "[install] Invalid entry; please enter digits only."
                            continue
                            ;;
                    esac
                    if [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                        if json_set_flag "NODE_SSH_PORT" "$port" "$SETTINGS_FILE" >/dev/null 2>&1; then
                            json_set_flag "SSH_PORT" "$port" "$SETTINGS_FILE" >/dev/null 2>&1
                            echo "[install] SSH port updated to $port in settings.json."
                        else
                            echo "[install] Failed to update SSH port in settings.json."
                        fi
                        return 0
                    else
                        echo "[install] Port out of range (1-65535)."
                    fi
                done
                ;;
            *)
                echo "[install] Please answer Y or N."
                ;;
        esac
    done
}

prompt_ssh_user_override() {
    # Configure default SSH admin username for node connections.
    local current_user reply new_user

    echo ""
    echo "[install] Configure default SSH admin username for node connections."

    current_user=$(json_get_flag "NODE_SSH_USER" "__MISSING__" "$SETTINGS_FILE" 2>/dev/null)
    if [ "$current_user" = "__MISSING__" ] || [ -z "$current_user" ]; then
        current_user=$(json_get_flag "SSH_USER" "admin" "$SETTINGS_FILE" 2>/dev/null)
    fi
    [ -n "$current_user" ] || current_user="admin"

    while :; do
        printf '[install] Use SSH username "%s"? [Y/n]: ' "$current_user"
        IFS= read -r reply || reply=""
        case "$reply" in
            ""|Y|y|YES|yes|Yes)
                echo "[install] Keeping SSH username \"$current_user\"."
                json_set_flag "NODE_SSH_USER" "$current_user" "$SETTINGS_FILE" >/dev/null 2>&1
                json_set_flag "SSH_USER" "$current_user" "$SETTINGS_FILE" >/dev/null 2>&1
                return 0
                ;;
            N|n|NO|no|No)
                while :; do
                    printf '[install] Enter SSH username (no spaces, no quotes): '
                    IFS= read -r new_user || new_user=""
                    case "$new_user" in
                        "")
                            echo "[install] Username cannot be empty."
                            continue
                            ;;
                        *["\ ]*)
                            echo "[install] Invalid username; avoid spaces and double quotes."
                            continue
                            ;;
                    esac

                    if json_set_flag "NODE_SSH_USER" "$new_user" "$SETTINGS_FILE" >/dev/null 2>&1; then
                        json_set_flag "SSH_USER" "$new_user" "$SETTINGS_FILE" >/dev/null 2>&1
                        echo "[install] SSH username updated to \"$new_user\" in settings.json."
                    else
                        echo "[install] Failed to update SSH username in settings.json."
                    fi
                    return 0
                done
                ;;
            *)
                echo "[install] Please answer Y or N."
                ;;
        esac
    done
}

_sync_ssh_flag() {
    local desired="$1"
    [ -n "$desired" ] || return 0

    if command -v json_set_flag >/dev/null 2>&1; then
        json_set_flag "SSH_KEYS_INSTALLED" "$desired" "$SETTINGS_FILE" >/dev/null 2>&1
    fi
    return 0
}

ssh_keys_effectively_installed() {
    local flag="0" have_keys="0" flag_present="0"

    if [ -n "${SSH_KEY:-}" ] && [ -f "$SSH_KEY" ] && \
       [ -n "${SSH_PUBKEY:-}" ] && [ -f "$SSH_PUBKEY" ]; then
        have_keys="1"
    fi

    if command -v json_get_flag >/dev/null 2>&1; then
        flag=$(json_get_flag "SSH_KEYS_INSTALLED" "0" "$SETTINGS_FILE" 2>/dev/null)
        if [ "$(json_get_flag "SSH_KEYS_INSTALLED" "__MISSING__" "$SETTINGS_FILE" 2>/dev/null)" != "__MISSING__" ]; then
            flag_present="1"
        fi
    elif [ -f "${SETTINGS_FILE:-}" ]; then
        if grep -q '"SSH_KEYS_INSTALLED"[[:space:]]*:[[:space:]]*"1"' "$SETTINGS_FILE" 2>/dev/null; then
            flag="1"
        fi
        if grep -q '"SSH_KEYS_INSTALLED"' "$SETTINGS_FILE" 2>/dev/null; then
            flag_present="1"
        fi
    fi

    if [ "$flag_present" = "0" ] && [ -n "${SETTINGS_FILE:-}" ] && command -v json_set_flag >/dev/null 2>&1; then
        _sync_ssh_flag "$flag"
        flag=$(json_get_flag "SSH_KEYS_INSTALLED" "0" "$SETTINGS_FILE" 2>/dev/null)
    fi

    if [ "$have_keys" = "1" ] && [ "$flag" != "1" ]; then
        _sync_ssh_flag "1"
        flag="1"
    elif [ "$have_keys" = "0" ] && [ "$flag" = "1" ]; then
        _sync_ssh_flag "0"
        flag="0"
    fi

    if [ "$have_keys" = "1" ] || [ "$flag" = "1" ]; then
        return 0
    fi

    return 1
}

# ========================================================================== #
# NODE & SSH STATE HELPERS — Detect existing node config and key installs    #
# ========================================================================== #
# (Embedded subset in this script to avoid external dependencies)

# has_configured_nodes — Report if any NODE1..NODE5 entries contain IPs
# Returns: 0 when at least one valid IPv4 is present, 1 otherwise
# Explanation: Allows installer to decide whether to call nodeenable later
has_configured_nodes() {
    [ -f "$SETTINGS_FILE" ] || return 1
    local nodes
    nodes=$(grep -o '"NODE[1-5]"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" 2>/dev/null | \
        sed -n 's/.*:[[:space:]]*"\([^"]*\)".*/\1/p' | \
        grep -v "none" | \
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    [ -n "$nodes" ]
}

# ========================================================================== #
# DOWNLOAD & BOOTSTRAP UTILITIES — Fetch repo and prepare fresh install      #
# ========================================================================== #

# download_mervlan — Retrieve tarball, extract, copy into $MERV_BASE
# Args: none (uses global paths/URLs)
# Returns: 0 on success, non-zero on download/extract failures
# Explanation: Handles BusyBox quirks (tar -z support), ensures permissions,
#   injects service-event hooks, and runs hardware probe on new installs
download_mervlan() {
  set -e
    echo "[download_mervlan] start"
    echo "[download_mervlan] GITHUB_URL=$GITHUB_URL"
    echo "[download_mervlan] MERV_BASE=$MERV_BASE"
    mkdir -p "$MERV_BASE"
    echo "[download_mervlan] ensured MERV_BASE exists"

  # Use provided TMP_DIR; otherwise create a private temp workspace
  local tmp created=0
    if [ -n "$TMP_DIR" ]; then
    tmp="$TMP_DIR"
    mkdir -p "$tmp"
  else
    tmp="$(mktemp -d)"; created=1
  fi
    echo "[download_mervlan] tmp workspace: $tmp (created=$created)"
    trap 'if [ "$created" -eq 1 ]; then echo "[download_mervlan] cleaning tmp: $tmp"; rm -rf "$tmp"; fi' EXIT

# ========================================================================== #
# SSH PORT CONFIGURATION — Optional override for node SSH connections       #
# ========================================================================== #
# Source: settings/lib_ssh.sh

  # Fetch archive to a file (curl only)
    echo "[download_mervlan] downloading archive -> $tmp/mervlan.tar.gz"
    /usr/sbin/curl -fsL --retry 3 "$GITHUB_URL" -o "$tmp/mervlan.tar.gz"
    if [ -s "$tmp/mervlan.tar.gz" ]; then
        echo "[download_mervlan] download ok, size=$(wc -c < "$tmp/mervlan.tar.gz" 2>/dev/null) bytes"
    else
        echo "[download_mervlan] ERROR: download failed or empty file" >&2
        return 1
    fi

  # Extract: prefer tar -xzf; fallback to gzip -dc | tar -x for BusyBox without -z
    if tar -tzf "$tmp/mervlan.tar.gz" >/dev/null 2>&1; then
        echo "[download_mervlan] extracting with tar -xzf"
        tar -xzf "$tmp/mervlan.tar.gz" -C "$tmp"
  else
        echo "[download_mervlan] extracting with gzip -dc | tar -x (fallback)"
        gzip -dc "$tmp/mervlan.tar.gz" | tar -x -C "$tmp"
  fi
    echo "[download_mervlan] extraction complete; top-level entries:"
    ls -1 "$tmp" 2>/dev/null | sed 's/^/[download_mervlan]   /'

    # Determine top-level extracted directory from archive listing, with fallbacks
    local topdir="" topname=""
    if tar -tzf "$tmp/mervlan.tar.gz" >/dev/null 2>&1; then
        topname="$(tar -tzf "$tmp/mervlan.tar.gz" 2>/dev/null | head -1 | cut -d/ -f1)"
        echo "[download_mervlan] tar lists topname: ${topname:-<none>}"
    else
        topname="$(gzip -dc "$tmp/mervlan.tar.gz" 2>/dev/null | tar -t 2>/dev/null | head -1 | cut -d/ -f1)"
        echo "[download_mervlan] gzip|tar lists topname: ${topname:-<none>}"
    fi
    if [ -n "$topname" ] && [ -d "$tmp/$topname" ]; then
        topdir="$tmp/$topname"
    else
        # Prefer directories matching mervlan-* if present
        for d in "$tmp"/mervlan-*; do
            [ -d "$d" ] && { topdir="$d"; break; }
        done
        # Else pick first directory that isn't a known temp subdir like 'logs'
        if [ -z "$topdir" ]; then
            for d in "$tmp"/*; do
                [ -d "$d" ] || continue
                [ "$(basename "$d")" = "logs" ] && continue
                topdir="$d"; break
            done
        fi
    fi
    echo "[download_mervlan] detected topdir (final): ${topdir:-<none>}"

  if [ -n "$topdir" ]; then
        echo "[download_mervlan] copying contents from $topdir -> $MERV_BASE"
        if ! cp -a "$topdir"/. "$MERV_BASE"/ 2>/dev/null; then
            echo "[download_mervlan] cp -a failed; using tar pipe fallback"
      ( cd "$topdir" && tar -cf - . ) | ( cd "$MERV_BASE" && tar -xpf - )
    fi
        echo "[download_mervlan] copy step complete"
  else
    echo "ERROR: Unexpected archive layout (no top directory)" >&2
    return 1
  fi

        # Permissions: BusyBox-safe (no find). 755 for all .sh except the two settings files -> 644
    # First set 644 for settings/log_settings.sh and settings/var_settings.sh if present
        echo "[download_mervlan] adjusting file permissions (.sh)"
    for depth in "" "*/" "*/*/"; do
        for f in $MERV_BASE/${depth}*.sh; do
            [ -f "$f" ] 2>/dev/null || continue
            base="$(basename "$f")"
            if [ "$base" = "log_settings.sh" ] || [ "$base" = "var_settings.sh" ]; then
                chmod 644 "$f" 2>/dev/null || :
            fi
        done
    done

    # Then apply 755 to all other .sh files
    for depth in "" "*/" "*/*/"; do
        for f in $MERV_BASE/${depth}*.sh; do
            [ -f "$f" ] 2>/dev/null || continue
            base="$(basename "$f")"
            if [ "$base" != "log_settings.sh" ] && [ "$base" != "var_settings.sh" ]; then
                chmod 755 "$f" 2>/dev/null || :
            fi
        done
    done
        echo "[download_mervlan] permission step complete"

    # Inject service-event on fresh download so a new install is functional
    if [ -x "$MERV_BASE/functions/mervlan_boot.sh" ]; then
        echo "[download_mervlan] invoking setupenable to inject service-event"
        if MERV_SKIP_NODE_SYNC=1 sh "$MERV_BASE/functions/mervlan_boot.sh" setupenable >/dev/null 2>&1; then
            echo "[download_mervlan] setupenable completed successfully"
        else
            echo "[download_mervlan] WARNING: setupenable failed" >&2
        fi
    else
        echo "[download_mervlan] WARNING: mervlan_boot.sh not executable or missing; skipping setupenable" >&2
    fi

        # Setup HW probe on fresh install
    if [ -x "$MERV_BASE/functions/hw_probe.sh" ]; then
        echo "[download_mervlan] invoking hw_probe to inject settings"
        if sh "$MERV_BASE/functions/hw_probe.sh"; then
            echo "[download_mervlan] hw_probe completed successfully"
        else
            echo "[download_mervlan] WARNING: hw_probe failed" >&2
        fi
    else
        echo "[download_mervlan] WARNING: hw_probe.sh not executable or missing; skipping setupenable" >&2
    fi

  trap - EXIT
    if [ "$created" -eq 1 ]; then
        echo "[download_mervlan] cleaning tmp (manual): $tmp"
        rm -rf "$tmp"
    fi
    echo "[download_mervlan] done"
}




# ========================================================================== #
# DIRECTORY & LOG SETUP — Ensure runtime paths exist with correct perms      #
# ========================================================================== #

# create_dirs — Prepare temp/log/public directories used by web UI & CLI
# Returns: 0 on success, 1 on failure (logs error message)
# Explanation: Creates shared folders for logs, results, and user-facing UI
create_dirs() {
    local d
    for d in \
        "$TMP_DIR" \
        "$TMP_DIR/logs" \
        "$TMP_DIR/locks" \
        "$TMP_DIR"/results \
        "$TMP_DIR"/results/vlan_changes \
        "$TMP_DIR"/results/client_collection \
        "$PUBLIC_DIR" \
        "$PUBLIC_DIR/settings" \
        "$PUBLIC_DIR/.ssh" \
        "$PUBLIC_DIR/tmp/results" \
        "$PUBLIC_DIR/tmp/logs"
    do
        mkdir -p "$d" 2>/dev/null || {
            printf 'ERROR: Failed to create directory: %s\n' "$d" >&2
            return 1
        }
    done
}

# create_dirs_first_install — Build addon skeleton under $MERV_BASE
# Returns: 0 on success, 1 on failure
# Explanation: Used for "full" mode to lay out initial folder hierarchy
create_dirs_first_install() {
    # Create base addon directories inside MERV_BASE on first install
    local base d
    base="${MERV_BASE:-/jffs/addons/mervlan}"
    for d in \
        "$base" \
        "$base/functions" \
        "$base/settings" \
        "$base/flags" \
        "$base/www" \
        "$base/.ssh"
    do
        mkdir -p "$d" 2>/dev/null || {
            printf 'ERROR: Failed to create directory: %s\n' "$d" >&2
            return 1
        }
    done
}

# create_link — Idempotent symlink helper for exposing logs/results via UI
# Args: target, dest; recreates existing symlink if present
create_link() {
    # create_link <target> <dest>
    local target="$1" dest="$2"
    
    if [ -L "$dest" ]; then
        rm -f "$dest"
    fi
    ln -sf "$target" "$dest" || {
        printf 'ERROR: Failed to create symlink %s -> %s\n' "$target" "$dest" >&2
        return 1
    }
}
# create_logs — Initialize log files with safe permissions
# Explanation: Truncates/creates CLI and VLAN manager logs and sets modes
create_logs() {
    : > "$TMP_DIR/logs/cli_output.log"    || { printf 'ERROR: Failed to init cli_output.log\n' >&2; return 1; }
    : > "$TMP_DIR/logs/vlan_manager.log"       || { printf 'ERROR: Failed to init vlan_manager.log\n' >&2; return 1; }

    chmod 755 "$TMP_DIR" "$TMP_DIR/logs"
    chmod 644 "$TMP_DIR/logs/cli_output.log" "$TMP_DIR/logs/vlan_manager.log"
}

# ========================================================================== #
# INSTALL ENTRYPOINT — Support "full" bootstrap mode with download step     #
# ========================================================================== #

# Handle "full" install mode: first-install dirs + fetch latest, then continue
# Full mode bootstraps directory skeleton and downloads the current package
MODE="${1:-}"
if [ "$MODE" = "full" ]; then
    logger -t "$ADDON" "Full install requested: creating base dirs and downloading package"
    create_dirs_first_install || { logger -t "$ADDON" "ERROR: create_dirs_first_install failed"; exit 1; }
    download_mervlan || { logger -t "$ADDON" "ERROR: download_mervlan failed"; exit 1; }
fi

# ========================================================================== #
# CORE INSTALL FLOW — Validate firmware support and mount addon web page     #
# ========================================================================== #

# 1. Does the firmware support addons?
nvram get rc_support | grep -q am_addons
if [ $? != 0 ]; then
    logger -t "$ADDON" "This firmware does not support addons!"
    exit 5
fi

# 2. Obtain the first available mount point into $am_webui_page
am_get_webui_page "$ADDON_DIR/$ADDON/mervlan.asp"

# Abort installation if router has no free user page slots available
if [ "$am_webui_page" = "none" ]; then
    logger -t "$ADDON" "Unable to install $ADDON (no free user page)"
    exit 5
fi
logger -t "$ADDON" "Mounting $ADDON as $am_webui_page"

# 3. Publish our page to /www/user/<slot>.asp
cp "$ADDON_DIR/$ADDON/mervlan.asp" "/www/user/$am_webui_page"

# ========================================================================== #
# FILE & ASSET PROVISIONING — Prepare runtime directories and static assets  #
# ========================================================================== #

# 3a. Create Project Dirs
# Ensure runtime temp/log directories exist before exposing UI assets
if create_dirs && create_logs; then
    logger -t "$ADDON" "Logs & folder structure complete!"
else
    logger -t "$ADDON" "ERROR: Failed to initialize directories or logs"
    exit 1
fi

prompt_ssh_user_override
prompt_ssh_port_override

# 3b. Copy Static assets to Public Dir
cp -p "$ADDON_DIR/$ADDON/www/index.html"            "$PUBLIC_DIR/index.html" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/vlan_index_style.css"  "$PUBLIC_DIR/vlan_index_style.css" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/vlan_form_style.css"   "$PUBLIC_DIR/vlan_form_style.css" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/help.html"             "$PUBLIC_DIR/help.html" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/view_logs.html"        "$PUBLIC_DIR/view_logs.html" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/settings/settings.json"    "$PUBLIC_DIR/settings/settings.json" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/settings/hw_settings.json" "$PUBLIC_DIR/settings/hw_settings.json" 2>/dev/null

# 3c. Publish SSH public key for UI if it already exists (rename to .json for compatibility)
if [ -f "$ADDON_DIR/$ADDON/.ssh/vlan_manager.pub" ]; then
    # Copy it to a .json filename so fetch('.ssh/vlan_manager.json') returns raw text
    cp -p "$ADDON_DIR/$ADDON/.ssh/vlan_manager.pub" "$PUBLIC_DIR/.ssh/vlan_manager.json" 2>/dev/null || {
        logger -t "$ADDON" "ERROR: Failed to publish SSH key to $PUBLIC_DIR/.ssh/vlan_manager.json"
    }
    chmod 644 "$PUBLIC_DIR/.ssh/vlan_manager.json" 2>/dev/null
    logger -t "$ADDON" "SSH public key published to web UI"
else
    logger -t "$ADDON" "SSH public key not present yet, skipping publish"
fi

# Create and log symlinks
create_link "$TMP_DIR/logs/cli_output.log"              "$PUBLIC_DIR/tmp/logs/cli_output.json"
create_link "$TMP_DIR/logs/vlan_manager.log"            "$PUBLIC_DIR/tmp/logs/vlan_manager.json"
create_link "$TMP_DIR/results/vlan_clients.json"        "$PUBLIC_DIR/tmp/results/vlan_clients.json"

logger -t "$ADDON" "Symlinks created successfully"
echo "$ADDON" "Symlinks created successfully"


# ========================================================================== #
# ASUSWRT UI INTEGRATION — Modify menu tree and persist addon metadata       #
# ========================================================================== #

# 4. Copy menuTree.js (if not already bind-mounted) so we can modify it
if [ ! -f /tmp/menuTree.js ]; then
    cp /www/require/modules/menuTree.js /tmp/
    mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js
fi

# 5. Insert our tab inside the LAN menu
# Clean any previous MerVLAN line so we're idempotent (leave other VLAN tabs intact)
sed -i '/tabName: "MerVLAN"/d' /tmp/menuTree.js

# Append our MerVLAN tab just before the LAN menu's __INHERIT__ sentinel
sed -i "/index: \"menu_LAN\"/,/{url: \"NULL\", tabName: \"__INHERIT__\"}/ {/{url: \"NULL\", tabName: \"__INHERIT__\"}/i \\
{url: \"$am_webui_page\", tabName: \"MerVLAN\"},
}" /tmp/menuTree.js

# 6. Remount after sed (bind+sed quirk)
umount /www/require/modules/menuTree.js
mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js

# 7. Record metadata (optional but good practice)
am_settings_set mervlan_page "$am_webui_page"
am_settings_set mervlan_state "enabled"
am_settings_set mervlan_version "v0.46"

logger -t "$ADDON" "Installed tab 'MerVLAN' under LAN -> $am_webui_page"
echo "$ADDON" "Installed tab 'MerVLAN' under LAN -> $am_webui_page"

# ========================================================================== #
# POST-INSTALL HOOKS — Ensure service scripts reachable and sync nodes       #
# ========================================================================== #

# Ensure boot/service-event hooks are present even on non-full installs
if [ -x "$MERV_BASE/functions/mervlan_boot.sh" ]; then
    if MERV_SKIP_NODE_SYNC=1 sh "$MERV_BASE/functions/mervlan_boot.sh" setupenable >/dev/null 2>&1; then
        logger -t "$ADDON" "addon setupenable completed (post-install)"
    else
        logger -t "$ADDON" "WARNING: setupenable failed during post-install"
    fi
else
    logger -t "$ADDON" "WARNING: mervlan_boot.sh not executable; skipping post-install setupenable"
fi

# If nodes are configured and SSH keys are ready, propagate nodeenable now
if has_configured_nodes && ssh_keys_effectively_installed; then
    if [ -x "$BOOT_SCRIPT" ]; then
        logger -t "$ADDON" "Propagating nodeenable to configured nodes"
        if sh "$BOOT_SCRIPT" nodeenable >/dev/null 2>&1; then
            logger -t "$ADDON" "nodeenable completed successfully"
        else
            logger -t "$ADDON" "WARNING: nodeenable encountered errors"
        fi
    else
        logger -t "$ADDON" "WARNING: mervlan_boot.sh not executable; skipping nodeenable"
    fi
else
    logger -t "$ADDON" "Nodeenable skipped (no nodes configured or SSH keys not installed)"
fi

exit 0