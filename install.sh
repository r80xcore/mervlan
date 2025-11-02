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

# Folder and file paths

GITHUB_URL="https://codeload.github.com/r80xcore/mervlan/tar.gz/refs/heads/main"
ADDON_DIR="/jffs/addons"
ADDON="mervlan"
MERV_BASE="$ADDON_DIR/$ADDON"
PUBLIC_DIR="/www/user/mervlan"
TMP_DIR="/tmp/mervlan_tmp"
TMP="${TMP_DIR:-$(mktemp -d)}"

# Helpers Begin ------------------------------------------------------

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
        if sh "$MERV_BASE/functions/mervlan_boot.sh" setupenable; then
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




# Create directory function
create_dirs() {
    local d
    for d in \
        "$TMP_DIR" \
        "$TMP_DIR/logs" \
        "$TMP_DIR"/results \
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

# --- Create Project Dirs & Logs ---
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

# Symlink function
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
# Create log function
create_logs() {
    : > "$TMP_DIR/logs/cli_output.log"    || { printf 'ERROR: Failed to init cli_output.log\n' >&2; return 1; }
    : > "$TMP_DIR/logs/vlan_manager.log"       || { printf 'ERROR: Failed to init vlan_manager.log\n' >&2; return 1; }

    chmod 755 "$TMP_DIR" "$TMP_DIR/logs"
    chmod 644 "$TMP_DIR/logs/cli_output.log" "$TMP_DIR/logs/vlan_manager.log"
}

# Helpers End --------------------------------------------------------

# Handle "full" install mode: first-install dirs + fetch latest, then continue
MODE="${1:-}"
if [ "$MODE" = "full" ]; then
    logger -t "$ADDON" "Full install requested: creating base dirs and downloading package"
    create_dirs_first_install || { logger -t "$ADDON" "ERROR: create_dirs_first_install failed"; exit 1; }
    download_mervlan || { logger -t "$ADDON" "ERROR: download_mervlan failed"; exit 1; }
fi

# 1. Does the firmware support addons?
nvram get rc_support | grep -q am_addons
if [ $? != 0 ]; then
    logger -t "$ADDON" "This firmware does not support addons!"
    exit 5
fi

# 2. Obtain the first available mount point into $am_webui_page
am_get_webui_page "$ADDON_DIR/$ADDON/mervlan.asp"

if [ "$am_webui_page" = "none" ]; then
    logger -t "$ADDON" "Unable to install $ADDON (no free user page)"
    exit 5
fi
logger -t "$ADDON" "Mounting $ADDON as $am_webui_page"

# 3. Publish our page to /www/user/<slot>.asp
cp "$ADDON_DIR/$ADDON/mervlan.asp" "/www/user/$am_webui_page"

# 3a. Create Project Dirs
if create_dirs && create_logs; then
    logger -t "$ADDON" "Logs & folder structure complete!"
else
    logger -t "$ADDON" "ERROR: Failed to initialize directories or logs"
    exit 1
fi

# 3b. Copy Static assets to Public Dir
cp -p "$ADDON_DIR/$ADDON/www/index.html"            "$PUBLIC_DIR/index.html" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/vlan_index_style.css"  "$PUBLIC_DIR/vlan_index_style.css" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/vlan_form_style.css"   "$PUBLIC_DIR/vlan_form_style.css" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/help.html"             "$PUBLIC_DIR/help.html" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/www/view_logs.html"        "$PUBLIC_DIR/view_logs.html" 2>/dev/null
cp -p "$ADDON_DIR/$ADDON/settings/settings.json"    "$PUBLIC_DIR/settings/settings.json" 2>/dev/null

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


# 4. Copy menuTree.js (if not already bind-mounted) so we can modify it
if [ ! -f /tmp/menuTree.js ]; then
    cp /www/require/modules/menuTree.js /tmp/
    mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js
fi

# 5. Insert our tab at the end of the Tools menu
# Clean any previous VLAN line so we're idempotent
sed -i '/tabName: "VLAN"/d' /tmp/menuTree.js

# Match "Tools_OtherSettings.asp" (same pattern as wiki), then append our tab
sed -i "/url: \"Tools_OtherSettings.asp\", tabName:/a {url: \"$am_webui_page\", tabName: \"VLAN\"}," /tmp/menuTree.js

# 6. Remount after sed (bind+sed quirk)
umount /www/require/modules/menuTree.js
mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js

# 7. Record metadata (optional but good practice)
am_settings_set mervlan_page "$am_webui_page"
am_settings_set mervlan_state "enabled"
am_settings_set mervlan_version "v0.45"

logger -t "$ADDON" "Installed tab 'VLAN' under Tools -> $am_webui_page"
echo "$ADDON" "Installed tab 'VLAN' under Tools -> $am_webui_page"
exit 0