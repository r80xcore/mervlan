#!/bin/sh
# ---- merv: portable `command -v` replacement ----
if ! type merv_has >/dev/null 2>&1; then
  merv_has() { type "$1" >/dev/null 2>&1; }
  merv_cmd() {
    _merv_c="$1"
    case "$_merv_c" in
      */*) [ -x "$_merv_c" ] && { printf '%s\n' "$_merv_c"; return 0; } ;;
    esac
    _merv_oldIFS="$IFS"; IFS=:
    for _merv_d in $PATH; do
      [ -z "$_merv_d" ] && _merv_d="."
      [ -x "$_merv_d/$_merv_c" ] && { IFS="$_merv_oldIFS"; printf '%s\n' "$_merv_d/$_merv_c"; return 0; }
    done
    IFS="$_merv_oldIFS"
    return 1
  }
fi
# ---- end shim ----
#
# MerVLAN Full Cleanup
# Cleaner protocol: phase6-v1
#
# Standalone, local-only cleanup for MerVLAN installations. This script does
# not source any MerVLAN code and can thus be used to clean up broken or
# problematic installations caused by updates or other kind of scenarios.
# Run it locally on MAIN and separately on each node that must be cleaned.
#
# It removes MerVLAN files, durable state, locks, hooks, known CRU jobs, web
# publication, runtime ebtables chains, and known transient workspaces.
# Retained backup archives are optional. External administrator files such as
# /root/.ssh/authorized_keys are deliberately outside the ownership boundary.
#
# Reboot before reinstalling MerVLAN. Firmware-managed bridge/VLAN state is
# intentionally cleared by reboot rather than deleting unrelated live network
# configuration blindly.

PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH
umask 077

LOGTAG="MerVLAN-Cleanup"
BACKUP_ROOT="/jffs/addons/mervlan_backups"
CUSTOM_SETTINGS="/jffs/addons/custom_settings.txt"
SERVICES_START="/jffs/scripts/services-start"
SERVICE_EVENT="/jffs/scripts/service-event"
MENU_TREE_TMP="/tmp/menuTree.js"
MENU_TREE_TARGET="/www/require/modules/menuTree.js"

# Fixed MerVLAN-owned roots/files.
MERVLAN_OWNED_PATHS="
/jffs/addons/mervlan
/jffs/addons/mervlan_state
/jffs/addons/mervlan.asp
/jffs/addons/mervlan-test-run
/www/user/mervlan
/www/user/merlin_vlan_manager
/www/user/mervlan-test-run
/tmp/var/wwwext/mervlan
/tmp/var/wwwext/merlin_vlan_manager
/tmp/var/wwwext/mervlan-test-run
/tmp/mervlan_tmp
/tmp/mervlan_staging
/tmp/mervlan_recovery
/tmp/mervlan_tpls
/tmp/mervlan-installer-last.log
"

# Explicit transient patterns. Only these patterns are ever expanded.
MERVLAN_OWNED_GLOBS="
/jffs/addons/.mervlan-install-rollback.*
/jffs/addons/.mervlan-install-incomplete.*
/tmp/mervlan_autonodes.*
/tmp/mervlan_selected_nodes.*
/tmp/mervlan-uninstall-hooks.*
/tmp/menuTree.mervlan-test.*
/tmp/mervlan_repair.*
/tmp/mervlan_carrier_snap.*
/tmp/merv_tpl.*
"

# The persistent/volatile split is used by the shared-hook safety gate below.
# The combined lists above remain the authoritative residue-verification and
# allowlist inventory. Runtime web publication under /tmp may be removed even
# when persistent destruction must be held back.
MERVLAN_PERSISTENT_PATHS="
/jffs/addons/mervlan
/jffs/addons/mervlan_state
/jffs/addons/mervlan.asp
/jffs/addons/mervlan-test-run
/www/user/mervlan
/www/user/merlin_vlan_manager
/www/user/mervlan-test-run
"

MERVLAN_VOLATILE_PATHS="
/tmp/var/wwwext/mervlan
/tmp/var/wwwext/merlin_vlan_manager
/tmp/var/wwwext/mervlan-test-run
/tmp/mervlan_tmp
/tmp/mervlan_staging
/tmp/mervlan_recovery
/tmp/mervlan_tpls
/tmp/mervlan-installer-last.log
"

MERVLAN_PERSISTENT_GLOBS="
/jffs/addons/.mervlan-install-rollback.*
/jffs/addons/.mervlan-install-incomplete.*
"

MERVLAN_VOLATILE_GLOBS="
/tmp/mervlan_autonodes.*
/tmp/mervlan_selected_nodes.*
/tmp/mervlan-uninstall-hooks.*
/tmp/menuTree.mervlan-test.*
/tmp/mervlan_repair.*
/tmp/mervlan_carrier_snap.*
/tmp/merv_tpl.*
"

# Incomplete backup/recovery publications are safe to discard when the user
# keeps completed backups. These patterns intentionally do not match completed
# .tar.gz archives or completed metadata files.
MERVLAN_BACKUP_STALE_GLOBS="
/jffs/addons/mervlan_backups/.mervlan.recovery
/jffs/addons/mervlan_backups/.mervlan.recovery.tmp.*
/jffs/addons/mervlan_backups/.mervlan.old.*
/jffs/addons/mervlan_backups/.mervlan.new.*
/jffs/addons/mervlan_backups/.mervlan.backup.*.partial.*
/jffs/addons/mervlan_backups/mervlan.backup.*.tar.gz.meta.partial.*
/jffs/addons/mervlan_backups/.mervlan.manual.backup.*.partial.*
/jffs/addons/mervlan_backups/mervlan.manual.backup.*.tar.gz.meta.partial.*
/jffs/addons/mervlan_backups/.recovery_state.sh.partial.*
/jffs/addons/mervlan_backups/.update_state.sh.partial.*
/jffs/addons/mervlan_backups/.recover.sh.partial.*
"

MERVLAN_CRON_NAMES="
mervlan_health
MerVLANLiveTestGuard
"

MERVLAN_EBTABLES_CHAINS="
MERV_QT
MERV_MAC
MERV_DHCP_HOLD
"

FAILURES=0
WARNINGS=0
KEEP_BACKUPS=1
BACKUPS_DELETION_SKIPPED=0
HOOKS_CLEAN=1
RELOCATED_SELF=""
WORK_DIR=""
SHARED_TMP_FILES=""
DISCOVERED_WEB_PAGE=""
LEGACY_WEB_PAGE=""
EBTABLES_BIN=""
CRU_BIN=""

log() {
    printf '%s\n' "$*"
    if merv_has logger >/dev/null 2>&1; then
        logger -t "$LOGTAG" "$*" 2>/dev/null || :
    fi
}

warn() {
    WARNINGS=$((WARNINGS + 1))
    log "[cleanup] WARNING: $*"
}

fail() {
    FAILURES=$((FAILURES + 1))
    log "[cleanup] ERROR: $*"
}

path_exists() {
    [ -e "$1" ] || [ -L "$1" ]
}

owned_path_allowed() {
    case "$1" in
        /jffs/addons/mervlan|/jffs/addons/mervlan/*|\
        /jffs/addons/mervlan_state|/jffs/addons/mervlan_state/*|\
        /jffs/addons/mervlan.asp|\
        /jffs/addons/mervlan-test-run|/jffs/addons/mervlan-test-run/*|\
        /jffs/addons/.mervlan-install-rollback.*|\
        /jffs/addons/.mervlan-install-incomplete.*|\
        /jffs/addons/mervlan_backups|/jffs/addons/mervlan_backups/*|\
        /www/user/mervlan|/www/user/mervlan/*|\
        /www/user/merlin_vlan_manager|/www/user/merlin_vlan_manager/*|\
        /www/user/mervlan-test-run|/www/user/mervlan-test-run/*|\
        /tmp/var/wwwext/mervlan|/tmp/var/wwwext/mervlan/*|\
        /tmp/var/wwwext/merlin_vlan_manager|/tmp/var/wwwext/merlin_vlan_manager/*|\
        /tmp/var/wwwext/mervlan-test-run|/tmp/var/wwwext/mervlan-test-run/*|\
        /tmp/mervlan_tmp|/tmp/mervlan_tmp/*|\
        /tmp/mervlan_staging|/tmp/mervlan_staging/*|\
        /tmp/mervlan_recovery|/tmp/mervlan_recovery/*|\
        /tmp/mervlan_tpls|/tmp/mervlan_tpls/*|\
        /tmp/mervlan-installer-last.log|\
        /tmp/mervlan_autonodes.*|/tmp/mervlan_selected_nodes.*|\
        /tmp/mervlan-uninstall-hooks.*|/tmp/menuTree.mervlan-test.*|\
        /tmp/mervlan_repair.*|/tmp/mervlan_carrier_snap.*|\
        /tmp/merv_tpl.*)
            return 0 ;;
        *)  return 1 ;;
    esac
}

safe_rm_owned_path() {
    _srp_path="$1"
    [ -n "$_srp_path" ] || return 0
    owned_path_allowed "$_srp_path" || {
        fail "Refusing unrecognized cleanup path: $_srp_path"
        return 1
    }
    path_exists "$_srp_path" || return 0

    # /jffs/addons/mervlan.asp is a legacy nominal-file target, not an owned
    # directory root. Never let an unexpected directory (or another unusual
    # object) turn this exact path into a recursive deletion target.
    case "$_srp_path" in
        /jffs/addons/mervlan.asp)
            if [ -L "$_srp_path" ]; then
                if rm -f "$_srp_path" 2>/dev/null; then
                    log "[cleanup] Removed legacy MerVLAN web file link: $_srp_path"
                    return 0
                fi
                fail "Could not remove legacy MerVLAN web file link: $_srp_path"
                return 1
            fi
            if [ -f "$_srp_path" ]; then
                if rm -f "$_srp_path" 2>/dev/null; then
                    log "[cleanup] Removed legacy MerVLAN web file: $_srp_path"
                    return 0
                fi
                fail "Could not remove legacy MerVLAN web file: $_srp_path"
                return 1
            fi
            if [ -d "$_srp_path" ]; then
                fail "Refusing to recursively remove directory obstruction: $_srp_path"
            else
                fail "Refusing to remove non-file legacy target obstruction: $_srp_path"
            fi
            return 1
            ;;
    esac

    if rm -rf "$_srp_path" 2>/dev/null; then
        log "[cleanup] Removed: $_srp_path"
    else
        fail "Could not remove: $_srp_path"
        return 1
    fi
}

cleanup_work() {
    for _cwt_file in $SHARED_TMP_FILES; do
        case "$_cwt_file" in
            /jffs/scripts/.mervlan-cleanup.*|/jffs/addons/.mervlan-cleanup.*)
                rm -f "$_cwt_file" 2>/dev/null || :
                ;;
        esac
    done
    SHARED_TMP_FILES=""
    case "$RELOCATED_SELF" in
        /tmp/.mervlan-full-cleanup.*.sh)
            rm -f "$RELOCATED_SELF" 2>/dev/null || :
            ;;
    esac
    RELOCATED_SELF=""
    case "$WORK_DIR" in
        /tmp/.mervlan-full-cleanup.*)
            rm -rf "$WORK_DIR" 2>/dev/null || :
            ;;
    esac
    WORK_DIR=""
}

# Replace a validated shared file atomically. The temporary is created beside
# the destination so BusyBox mv can perform a same-filesystem rename. cp -p
# first copies the original mode/owner, then cat writes only the temporary; a
# failed write therefore cannot truncate the live shared file. Callers must
# validate the complete source before entering this helper.
atomic_replace_shared_file() {
    _ars_source="$1"
    _ars_dest="$2"
    [ -f "$_ars_source" ] || {
        fail "Atomic replacement source is not a regular file: $_ars_source"
        return 1
    }
    [ -f "$_ars_dest" ] || {
        fail "Atomic replacement destination is not a regular file: $_ars_dest"
        return 1
    }
    [ ! -L "$_ars_dest" ] || {
        fail "Refusing to atomically replace symlinked shared file: $_ars_dest"
        return 1
    }

    _ars_dir="$(dirname "$_ars_dest" 2>/dev/null)"
    _ars_base="$(basename "$_ars_dest" 2>/dev/null)"
    _ars_stamp="$(date +%s 2>/dev/null || printf '0')"
    case "$_ars_stamp" in ''|*[!0-9]*) _ars_stamp=0 ;; esac
    _ars_try=0
    while [ "$_ars_try" -le 9 ]; do
        _ars_tmp="$_ars_dir/.mervlan-cleanup.$_ars_base.$_ars_stamp.$$.$_ars_try"
        if [ ! -e "$_ars_tmp" ] && [ ! -L "$_ars_tmp" ]; then
            break
        fi
        _ars_try=$((_ars_try + 1))
    done
    if [ "$_ars_try" -gt 9 ]; then
        fail "Could not allocate an atomic replacement temporary for $_ars_dest"
        return 1
    fi
    SHARED_TMP_FILES="$SHARED_TMP_FILES $_ars_tmp"

    if ! cp -p "$_ars_dest" "$_ars_tmp" 2>/dev/null; then
        rm -f "$_ars_tmp" 2>/dev/null || :
        fail "Could not preserve mode/ownership for shared replacement: $_ars_dest"
        return 1
    fi
    if ! cat "$_ars_source" >"$_ars_tmp" 2>/dev/null; then
        rm -f "$_ars_tmp" 2>/dev/null || :
        fail "Could not write atomic shared replacement: $_ars_dest"
        return 1
    fi
    [ ! -L "$_ars_dest" ] || {
        rm -f "$_ars_tmp" 2>/dev/null || :
        fail "Shared file became a symlink before replacement: $_ars_dest"
        return 1
    }
    if ! mv -f "$_ars_tmp" "$_ars_dest" 2>/dev/null; then
        rm -f "$_ars_tmp" 2>/dev/null || :
        fail "Could not atomically replace shared file: $_ars_dest"
        return 1
    fi
    [ -f "$_ars_dest" ] || {
        fail "Shared file disappeared after atomic replacement: $_ars_dest"
        return 1
    }
    return 0
}

# Relocate before removing an addon tree that may contain the original script.
#
# A file-based invocation has a real cleanup script at $0, so it must be
# copied before its source tree is removed. A piped/stdin invocation commonly
# has the interpreter (for example /bin/sh) at $0; that is not the cleanup
# source and must never be copied to /tmp. The bounded header check below
# distinguishes the two cases. If $0 is an unreadable path inside the
# MerVLAN tree, fail closed because deleting that tree could truncate the
# script that is still being read.
cleanup_script_candidate() {
    _csc_candidate="$1"
    [ -n "$_csc_candidate" ] || return 1
    [ -f "$_csc_candidate" ] || return 1
    [ -r "$_csc_candidate" ] || return 1
    [ ! -L "$_csc_candidate" ] || return 1

    # Read only the first 40 lines. The shebang plus the stable MerVLAN
    # header identify this utility without trusting an arbitrary interpreter
    # or another shell script named by $0.
    sed -n '1,40p;41q' "$_csc_candidate" 2>/dev/null |
        grep -q '^#!/bin/sh' 2>/dev/null || return 1
    sed -n '1,40p;41q' "$_csc_candidate" 2>/dev/null |
        grep -q 'MerVLAN Full Cleanup' 2>/dev/null || return 1
    return 0
}
metadata_get() {
    _mg_key="$1"
    [ ! -L "$CUSTOM_SETTINGS" ] || return 0
    [ -f "$CUSTOM_SETTINGS" ] || return 0
    awk -v wanted="$_mg_key" '
        {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            if (line ~ ("^" wanted "([[:space:]]|=)")) {
                sub("^" wanted "[[:space:]]*=?[[:space:]]*", "", line)
                print line
                exit
            }
        }
    ' "$CUSTOM_SETTINGS" 2>/dev/null
}

metadata_remove_all() {
    if [ -L "$CUSTOM_SETTINGS" ]; then
        fail "Refusing to edit symlinked shared metadata file: $CUSTOM_SETTINGS"
        return 1
    fi
    [ -e "$CUSTOM_SETTINGS" ] || return 0
    [ -f "$CUSTOM_SETTINGS" ] || {
        fail "Refusing to edit non-regular shared metadata file: $CUSTOM_SETTINGS"
        return 1
    }
    _mra_tmp="$WORK_DIR/custom_settings.cleaned"
    if ! awk '
        function owned(k) {
            return (k ~ /^vlanmgr_/) ||
                   (k ~ /^mervlan_/) ||
                   (k ~ /^merlin_vlan_manager_/)
        }
        {
            line=$0
            key=line
            sub(/^[[:space:]]*/, "", key)
            sub(/[=[:space:]].*$/, "", key)
            if (!owned(key)) print line
        }
    ' "$CUSTOM_SETTINGS" >"$_mra_tmp" 2>/dev/null; then
        rm -f "$_mra_tmp" 2>/dev/null || :
        fail "Could not prepare MerVLAN metadata cleanup"
        return 1
    fi
    if ! atomic_replace_shared_file "$_mra_tmp" "$CUSTOM_SETTINGS"; then
        rm -f "$_mra_tmp" 2>/dev/null || :
        fail "Could not update $CUSTOM_SETTINGS"
        return 1
    fi
    rm -f "$_mra_tmp" 2>/dev/null || :
    if grep -Eq '^[[:space:]]*(vlanmgr_|mervlan_|merlin_vlan_manager_)' \
       "$CUSTOM_SETTINGS" 2>/dev/null; then
        fail "MerVLAN metadata remains in $CUSTOM_SETTINGS"
        return 1
    fi
    log "[cleanup] Removed MerVLAN addon metadata from custom_settings.txt"
}

# Remove complete marker blocks and only unambiguous legacy direct lines.
clean_shared_hook_file() {
    _csh_file="$1"
    if [ -L "$_csh_file" ]; then
        fail "Refusing to edit symlinked shared hook: $_csh_file"
        return 1
    fi
    [ -e "$_csh_file" ] || return 0
    [ -f "$_csh_file" ] || {
        fail "Refusing to edit non-regular shared hook: $_csh_file"
        return 1
    }
    _csh_base="$(basename "$_csh_file" 2>/dev/null)"
    _csh_tmp="$WORK_DIR/"$_csh_base.markers
    _csh_tmp2="$WORK_DIR/"$_csh_base.legacy
    if ! awk '
        BEGIN { skip=0; malformed=0 }
        /^### >>> MERVLAN START:/ { if (skip) malformed=1; skip=1; next }
        /^### <<< MERVLAN END:/ { if (!skip) malformed=1; skip=0; next }
        !skip { print }
        END { if (skip || malformed) exit 42 }
    ' "$_csh_file" >"$_csh_tmp" 2>/dev/null; then
        rm -f "$_csh_tmp" "$_csh_tmp2" 2>/dev/null || :
        fail "Malformed MerVLAN marker block in $_csh_file; shared file left untouched"
        return 1
    fi
    if ! awk '
        index($0, "/jffs/addons/mervlan") { next }
        index($0, "/www/user/mervlan") { next }
        index($0, "merlin_vlan_manager") { next }
        index($0, "mervlan_boot_wrap.sh") { next }
        { print }
    ' "$_csh_tmp" >"$_csh_tmp2" 2>/dev/null; then
        rm -f "$_csh_tmp" "$_csh_tmp2" 2>/dev/null || :
        fail "Could not prepare legacy MerVLAN hook cleanup for $_csh_file"
        return 1
    fi
    if ! /bin/sh -n "$_csh_tmp2" >/dev/null 2>&1; then
        rm -f "$_csh_tmp" "$_csh_tmp2" 2>/dev/null || :
        fail "Cleanup would leave invalid shell syntax in $_csh_file; shared file left untouched"
        return 1
    fi
    if ! atomic_replace_shared_file "$_csh_tmp2" "$_csh_file"; then
        rm -f "$_csh_tmp" "$_csh_tmp2" 2>/dev/null || :
        fail "Could not write cleaned hook: $_csh_file"
        return 1
    fi
    rm -f "$_csh_tmp" "$_csh_tmp2" 2>/dev/null || :
    if grep -q '^### >>> MERVLAN START:' "$_csh_file" 2>/dev/null ||
       grep -q '^### <<< MERVLAN END:' "$_csh_file" 2>/dev/null ||
       grep -q '/jffs/addons/mervlan' "$_csh_file" 2>/dev/null ||
       grep -q '/www/user/mervlan' "$_csh_file" 2>/dev/null ||
       grep -q 'merlin_vlan_manager' "$_csh_file" 2>/dev/null ||
       grep -q 'mervlan_boot_wrap.sh' "$_csh_file" 2>/dev/null; then
        fail "MerVLAN hook content remains in $_csh_file"
        return 1
    fi
    log "[cleanup] Removed MerVLAN hook content from $_csh_file"
}

menu_tree_target_is_mounted() {
    if [ -r /proc/mounts ] &&
       awk -v target="$MENU_TREE_TARGET" '$2 == target { found=1 }
           END { exit found ? 0 : 1 }' /proc/mounts 2>/dev/null; then
        return 0
    fi
    if merv_has mount >/dev/null 2>&1 &&
       mount 2>/dev/null |
       awk -v target="$MENU_TREE_TARGET" \
           '($2 == "on" && $3 == target) || $3 == target { found=1 }
            END { exit found ? 0 : 1 }'; then
        return 0
    fi
    return 1
}

cleanup_menu_tree() {
    if [ -L "$MENU_TREE_TARGET" ]; then
        warn "Menu tree target is a symlink; leaving it untouched: $MENU_TREE_TARGET"
        return 0
    fi
    [ -f "$MENU_TREE_TARGET" ] || return 0
    if [ -L "$MENU_TREE_TMP" ]; then
        warn "Runtime menu copy is a symlink; leaving menu publication untouched: $MENU_TREE_TMP"
        return 0
    fi
    if [ -e "$MENU_TREE_TMP" ] || [ -L "$MENU_TREE_TMP" ]; then
        if [ ! -f "$MENU_TREE_TMP" ] || [ ! -r "$MENU_TREE_TMP" ]; then
            warn "Runtime menu copy is not a usable regular file: $MENU_TREE_TMP"
            return 0
        fi
    else
        # In the normal Merlin bind-mount lifecycle the target already reads
        # from this file. Only make a copy when that runtime file is absent.
        if ! cp "$MENU_TREE_TARGET" "$MENU_TREE_TMP" 2>/dev/null; then
            warn "Could not create writable menuTree.js copy; reboot will clear the runtime menu"
            return 0
        fi
    fi
    if ! sed -i '/tabName: "MerVLAN"/d; /tabName: "MerVLAN Test"/d' \
        "$MENU_TREE_TMP" 2>/dev/null; then
        warn "Could not remove MerVLAN menu entries from $MENU_TREE_TMP"
        return 0
    fi

    # Do not overlay an unrelated, unmounted firmware file. The target is
    # rebound only when the normal runtime mount is actually present.
    if ! menu_tree_target_is_mounted; then
        warn "Menu tree target is not currently bind-mounted; reboot will clear the runtime menu"
        return 0
    fi
    umount "$MENU_TREE_TARGET" 2>/dev/null || :
    if ! mount -o bind "$MENU_TREE_TMP" "$MENU_TREE_TARGET" 2>/dev/null; then
        warn "Could not re-establish cleaned menuTree.js bind mount; reboot will clear the runtime menu"
        return 0
    fi
    if grep -q 'tabName: "MerVLAN"' "$MENU_TREE_TARGET" 2>/dev/null ||
       grep -q 'tabName: "MerVLAN Test"' "$MENU_TREE_TARGET" 2>/dev/null; then
        fail "MerVLAN menu entries remain in the active menu tree"
        return 1
    fi
    log "[cleanup] Removed MerVLAN runtime menu entries"
}

remove_web_pages() {
    _rwp_removed=0
    for _rwp_page in "$DISCOVERED_WEB_PAGE" "$LEGACY_WEB_PAGE"; do
        [ -n "$_rwp_page" ] || continue
        if printf '%s\n' "$_rwp_page" |
           grep -Eq '^user[0-9][0-9]*[.]asp$' 2>/dev/null; then
            _rwp_path="/www/user/$_rwp_page"
            if path_exists "$_rwp_path"; then
                if rm -f "$_rwp_path" 2>/dev/null; then
                    log "[cleanup] Removed MerVLAN web UI page: $_rwp_path"
                    _rwp_removed=1
                else
                    fail "Could not remove MerVLAN web UI page: $_rwp_path"
                fi
            fi
        else
            warn "Ignoring unsafe stored MerVLAN page name: $_rwp_page"
        fi
    done
    for _rwp_candidate in /www/user/user*.asp; do
        [ -f "$_rwp_candidate" ] || continue
        [ ! -L "$_rwp_candidate" ] || continue
        if grep -Eqi 'MerVLAN|merlin_vlan_manager|Merlin_VLAN_Manager|mervlan[.]asp|/jffs/addons/mervlan|/www/user/mervlan' \
           "$_rwp_candidate" 2>/dev/null; then
            if rm -f "$_rwp_candidate" 2>/dev/null; then
                log "[cleanup] Removed detected MerVLAN web UI page: $_rwp_candidate"
                _rwp_removed=1
            else
                fail "Could not remove detected MerVLAN web UI page: $_rwp_candidate"
            fi
        fi
    done
    [ "$_rwp_removed" -eq 1 ] ||
        log "[cleanup] No MerVLAN user*.asp page was present"
}

resolve_cru() {
    if merv_has cru; then
        CRU_BIN="$(merv_cmd cru)"
    elif [ -x /usr/sbin/cru ]; then
        CRU_BIN="/usr/sbin/cru"
    else
        CRU_BIN=""
    fi
}

cru_owned_job_names() {
    printf '%s\n' "$1" |
        awk '
            {
                line=$0
                hit=(line ~ /\/jffs\/addons\/mervlan([\/[:space:]]|$)/ ||
                     line ~ /\/www\/user\/mervlan([\/[:space:]]|$)/ ||
                     line ~ /\/tmp\/mervlan_tmp([\/[:space:]]|$)/)
                # Asuswrt-Merlin stores the CRU identifier in a trailing
                # #job_name# comment. The cron schedule is never an ID.
                if (hit && line ~ /#[A-Za-z0-9_.-]+#[[:space:]]*$/) {
                    count=split(line, parts, "#")
                    name=parts[count-1]
                    lower=tolower(name)
                    if (name ~ /^[A-Za-z0-9_.-]+$/ &&
                        (lower ~ /(^|_)mervlan([_.-]|$)/ ||
                         lower ~ /^merlin_vlan_manager([_.-]|$)/ ||
                         lower ~ /^vlanmgr_mervlan([_.-]|$)/ ||
                         lower == "mervlanlivetestguard")) print name
                }
            }
        '
}

cru_id_owned() {
    case "$1" in
        mervlan|mervlan_*|mervlan-*|mervlan.*|\
        MerVLAN|MerVLAN_*|MerVLAN-*|MerVLAN.*|\
        merlin_vlan_manager|merlin_vlan_manager_*|merlin_vlan_manager-*|merlin_vlan_manager.*|\
        vlanmgr_mervlan|vlanmgr_mervlan_*|vlanmgr_mervlan-*|vlanmgr_mervlan.*|\
        *_mervlan|*_mervlan_*|*_mervlan-*|*_mervlan.*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

remove_cru_jobs() {
    resolve_cru
    if [ -z "$CRU_BIN" ]; then
        warn "cru is unavailable; scheduled MerVLAN jobs could not be checked"
        return 0
    fi
    for _rcj_name in $MERVLAN_CRON_NAMES; do
        "$CRU_BIN" d "$_rcj_name" >/dev/null 2>&1 || :
    done
    _rcj_list="$("$CRU_BIN" l 2>/dev/null)"
    _rcj_list_rc=$?
    if [ "$_rcj_list_rc" -ne 0 ]; then
        fail "Could not list CRU jobs after known MerVLAN job removal"
        return 1
    fi
    _rcj_extra="$(cru_owned_job_names "$_rcj_list")"
    for _rcj_name in $_rcj_extra; do
        cru_id_owned "$_rcj_name" || continue
        "$CRU_BIN" d "$_rcj_name" >/dev/null 2>&1 || :
    done
    _rcj_list="$("$CRU_BIN" l 2>/dev/null)"
    _rcj_list_rc=$?
    if [ "$_rcj_list_rc" -ne 0 ]; then
        fail "Could not verify CRU jobs after MerVLAN cleanup"
        return 1
    fi
    if printf '%s\n' "$_rcj_list" |
       grep -Eqi 'mervlan_health|MerVLANLiveTestGuard|/jffs/addons/mervlan|/www/user/mervlan' \
       2>/dev/null; then
        fail "A MerVLAN-related CRU entry still appears to be present"
        return 1
    fi
    log "[cleanup] Removed known and discoverable MerVLAN CRU jobs"
}

process_matches_mervlan() {
    case "$1" in
        *"/jffs/addons/mervlan"*|\
        *"/www/user/mervlan"*|*"/www/user/merlin_vlan_manager"*|\
        *"/tmp/var/wwwext/mervlan"*|*"/tmp/var/wwwext/merlin_vlan_manager"*|\
        *"/tmp/mervlan_tmp"*|*"/tmp/mervlan_recovery"*|\
        *"/tmp/mervlan_repair."*|*"/tmp/mervlan_carrier_snap."*|\
        *"mervlan_health"*|*"MerVLANLiveTestGuard"*)
            return 0 ;;
        *)  return 1 ;;
    esac
}

find_mervlan_processes() {
    _fmp_result=""
    for _fmp_proc in /proc/[0-9]*; do
        [ -r "$_fmp_proc/cmdline" ] || continue
        _fmp_pid="$(basename "$_fmp_proc" 2>/dev/null)"
        [ "$_fmp_pid" != "$$" ] || continue
        [ "$_fmp_pid" != "$PPID" ] || continue
        _fmp_cmd="$(tr '\000' ' ' <"$_fmp_proc/cmdline" 2>/dev/null)"
        if process_matches_mervlan "$_fmp_cmd"; then
            _fmp_result="$_fmp_result $_fmp_pid"
        fi
    done
    printf '%s\n' "$_fmp_result" | sed 's/^ *//'
}

stop_mervlan_processes() {
    _smp_pids="$(find_mervlan_processes)"
    [ -n "$_smp_pids" ] || {
        log "[cleanup] No live MerVLAN processes detected"
        return 0
    }
    log "[cleanup] Stopping live MerVLAN processes"
    for _smp_pid in $_smp_pids; do kill "$_smp_pid" 2>/dev/null || :; done
    sleep 1
    for _smp_pid in $_smp_pids; do
        [ -d "/proc/$_smp_pid" ] && kill -9 "$_smp_pid" 2>/dev/null || :
    done
    _smp_left="$(find_mervlan_processes)"
    if [ -n "$_smp_left" ]; then
        fail "Could not stop all MerVLAN processes: $_smp_left"
        return 1
    fi
}

resolve_ebtables() {
    if merv_has ebtables; then
        EBTABLES_BIN="$(merv_cmd ebtables)"
    elif [ -x /usr/sbin/ebtables ]; then
        EBTABLES_BIN="/usr/sbin/ebtables"
    else
        EBTABLES_BIN=""
    fi
}

ebtables_chain_exists() {
    "$EBTABLES_BIN" -t filter -L "$1" >/dev/null 2>&1
}

ebtables_chain_names() {
    "$EBTABLES_BIN" -t filter -L 2>/dev/null |
        awk '/^Bridge chain: / { n=$3; sub(/,$/, "", n); if (n != "") print n }'
}

mervlan_discovered_ebtables_chain_name() {
    printf '%s\n' "$1" |
        grep -Eq '^(MERV_TRUNK_eth[0-9]+|_merv_test_[0-9]+)$' 2>/dev/null
}

teardown_ebtables_chain() {
    _tec_chain="$1"
    [ -n "$EBTABLES_BIN" ] || return 0
    case "$_tec_chain" in
        MERV_QT|MERV_MAC|MERV_DHCP_HOLD)
            ;;
        *)
            mervlan_discovered_ebtables_chain_name "$_tec_chain" || return 0
            ;;
    esac
    while "$EBTABLES_BIN" -t filter -D FORWARD -j "$_tec_chain" \
        >/dev/null 2>&1; do :; done
    while "$EBTABLES_BIN" -t filter -D INPUT -j "$_tec_chain" \
        >/dev/null 2>&1; do :; done
    case "$_tec_chain" in
        MERV_TRUNK_eth*)
            _tec_port="$(printf '%s\n' "$_tec_chain" | sed 's/^MERV_TRUNK_//')"
            while "$EBTABLES_BIN" -t filter -D FORWARD -p 802_1Q \
                -i "$_tec_port" -j "$_tec_chain" >/dev/null 2>&1; do :; done
            while "$EBTABLES_BIN" -t filter -D FORWARD -p 802_1Q \
                -o "$_tec_port" -j "$_tec_chain" >/dev/null 2>&1; do :; done
            ;;
    esac
    # A malformed/interrupted state can leave a parent reference after its
    # user chain disappeared. The reference cleanup above is still useful in
    # that case; there is simply no chain left to flush or delete.
    ebtables_chain_exists "$_tec_chain" || return 0
    "$EBTABLES_BIN" -t filter -F "$_tec_chain" >/dev/null 2>&1 || :
    "$EBTABLES_BIN" -t filter -X "$_tec_chain" >/dev/null 2>&1 || :
    if ebtables_chain_exists "$_tec_chain"; then
        fail "Could not fully remove ebtables chain $_tec_chain"
        return 1
    fi
    log "[cleanup] Removed ebtables chain: $_tec_chain"
}

teardown_ebtables() {
    resolve_ebtables
    if [ -z "$EBTABLES_BIN" ]; then
        warn "ebtables is unavailable; runtime chain cleanup could not be checked"
        return 0
    fi
    for _te_chain in $MERVLAN_EBTABLES_CHAINS; do
        teardown_ebtables_chain "$_te_chain" || :
    done
    _te_discovered="$(ebtables_chain_names)"
    for _te_chain in $_te_discovered; do
        mervlan_discovered_ebtables_chain_name "$_te_chain" ||
            continue
        teardown_ebtables_chain "$_te_chain" || :
    done
}

verify_ebtables() {
    [ -n "$EBTABLES_BIN" ] || return 0
    _ve_residue=0
    for _ve_chain in $MERVLAN_EBTABLES_CHAINS; do
        if ebtables_chain_exists "$_ve_chain"; then
            fail "MerVLAN ebtables residue remains: $_ve_chain"
            _ve_residue=1
        fi
    done
    _ve_discovered="$(ebtables_chain_names)"
    for _ve_chain in $_ve_discovered; do
        mervlan_discovered_ebtables_chain_name "$_ve_chain" ||
            continue
        fail "MerVLAN ebtables residue remains: $_ve_chain"
        _ve_residue=1
    done
    return "$_ve_residue"
}

sanitize_retained_backup_root() {
    [ "$KEEP_BACKUPS" = "1" ] || return 0
    path_exists "$BACKUP_ROOT" || return 0
    if [ -L "$BACKUP_ROOT" ] || [ ! -d "$BACKUP_ROOT" ]; then
        fail "Backup root is not a normal directory; refusing to follow it: $BACKUP_ROOT"
        return 1
    fi
    for _sbr_pattern in $MERVLAN_BACKUP_STALE_GLOBS
    do
        for _sbr_match in $_sbr_pattern; do
            [ "$_sbr_match" != "$_sbr_pattern" ] ||
                path_exists "$_sbr_match" || continue
            safe_rm_owned_path "$_sbr_match" || :
        done
    done
    log "[cleanup] Retained backup archives/data while removing stale recovery bookkeeping"
}

remove_path_list() {
    for _rpl_path in $1; do
        safe_rm_owned_path "$_rpl_path" || :
    done
}

remove_glob_list() {
    for _rgl_pattern in $1; do
        for _rgl_match in $_rgl_pattern; do
            [ "$_rgl_match" != "$_rgl_pattern" ] ||
                path_exists "$_rgl_match" || continue
            safe_rm_owned_path "$_rgl_match" || :
        done
    done
}

remove_volatile_owned_paths() {
    remove_path_list "$MERVLAN_VOLATILE_PATHS"
    remove_glob_list "$MERVLAN_VOLATILE_GLOBS"
}

remove_persistent_owned_paths() {
    remove_path_list "$MERVLAN_PERSISTENT_PATHS"
    remove_glob_list "$MERVLAN_PERSISTENT_GLOBS"
    if [ "$KEEP_BACKUPS" = "1" ]; then
        sanitize_retained_backup_root || :
        if path_exists "$BACKUP_ROOT"; then
            log "[cleanup] Preserved MerVLAN backups: $BACKUP_ROOT"
        else
            log "[cleanup] No retained MerVLAN backup directory was present"
        fi
    else
        safe_rm_owned_path "$BACKUP_ROOT" || :
    fi
}

remove_owned_paths() {
    remove_persistent_owned_paths
    remove_volatile_owned_paths
}

hook_has_residue() {
    [ -f "$1" ] || return 1
    grep -q '^### >>> MERVLAN START:' "$1" 2>/dev/null ||
    grep -q '^### <<< MERVLAN END:' "$1" 2>/dev/null ||
    grep -q '/jffs/addons/mervlan' "$1" 2>/dev/null ||
    grep -q '/www/user/mervlan' "$1" 2>/dev/null ||
    grep -q 'merlin_vlan_manager' "$1" 2>/dev/null ||
    grep -q 'mervlan_boot_wrap.sh' "$1" 2>/dev/null
}

verify_cru_jobs() {
    [ -n "$CRU_BIN" ] || return 0
    if ! _vcj_list="$("$CRU_BIN" l 2>/dev/null)"; then
        fail "Could not verify CRU jobs"
        return 1
    fi
    if printf '%s\n' "$_vcj_list" |
       grep -Eqi 'mervlan_health|MerVLANLiveTestGuard|/jffs/addons/mervlan|/www/user/mervlan' \
       2>/dev/null; then
        fail "MerVLAN CRU residue remains"
        return 1
    fi
}

verify_cleanup() {
    _vc_residue=0
    for _vc_path in $MERVLAN_OWNED_PATHS; do
        if path_exists "$_vc_path"; then
            fail "Cleanup residue remains: $_vc_path"
            _vc_residue=1
        fi
    done
    for _vc_pattern in $MERVLAN_OWNED_GLOBS; do
        for _vc_match in $_vc_pattern; do
            [ "$_vc_match" != "$_vc_pattern" ] ||
                path_exists "$_vc_match" || continue
            if path_exists "$_vc_match"; then
                fail "Cleanup residue remains: $_vc_match"
                _vc_residue=1
            fi
        done
    done
    if [ "$KEEP_BACKUPS" = "0" ] && path_exists "$BACKUP_ROOT"; then
        fail "Backup directory remains after deletion was requested: $BACKUP_ROOT"
        _vc_residue=1
    elif [ "$KEEP_BACKUPS" = "1" ] &&
         [ -d "$BACKUP_ROOT" ] && [ ! -L "$BACKUP_ROOT" ]; then
        for _vc_pattern in $MERVLAN_BACKUP_STALE_GLOBS
        do
            for _vc_match in $_vc_pattern; do
                [ "$_vc_match" != "$_vc_pattern" ] ||
                    path_exists "$_vc_match" || continue
                if path_exists "$_vc_match"; then
                    fail "Stale backup/recovery residue remains: $_vc_match"
                    _vc_residue=1
                fi
            done
        done
    fi
    for _vc_hook in "$SERVICES_START" "$SERVICE_EVENT"; do
        if hook_has_residue "$_vc_hook"; then
            fail "MerVLAN hook residue remains in $_vc_hook"
            _vc_residue=1
        fi
    done
    if [ -f "$CUSTOM_SETTINGS" ] &&
       grep -Eq '^[[:space:]]*(vlanmgr_|mervlan_|merlin_vlan_manager_)' \
       "$CUSTOM_SETTINGS" 2>/dev/null; then
        fail "MerVLAN metadata residue remains in $CUSTOM_SETTINGS"
        _vc_residue=1
    fi
    if [ -L "$CUSTOM_SETTINGS" ]; then
        fail "Shared metadata file is still a symlink: $CUSTOM_SETTINGS"
        _vc_residue=1
    fi
    verify_cru_jobs || _vc_residue=1
    verify_ebtables || _vc_residue=1
    _vc_pids="$(find_mervlan_processes)"
    if [ -n "$_vc_pids" ]; then
        fail "MerVLAN processes remain: $_vc_pids"
        _vc_residue=1
    fi
    if [ -f "$MENU_TREE_TARGET" ] &&
       { grep -q 'tabName: "MerVLAN"' "$MENU_TREE_TARGET" 2>/dev/null ||
         grep -q 'tabName: "MerVLAN Test"' "$MENU_TREE_TARGET" 2>/dev/null; }; then
        fail "MerVLAN menu entries remain in the active menu tree"
        _vc_residue=1
    fi
    return "$_vc_residue"
}

# Phase-6 cleaner protocol v1. Exit codes: 0 success, 2 pre-destruction
# refusal, 3 known terminal cleanup failure, 4 ambiguous (retain F).
# No installed libraries or environment variables confer cleanup authority.
FENCE=/tmp/.mervlan-full-uninstall.lock
MAINTENANCE=/tmp/mervlan_tmp/locks/mervlan_maintenance.lock
OWNER_PID= OWNER_START= OWNER_NONCE= RUN= CONTEXT= PRIVATE_DIR=
WORKER_PID= WORKER_START= SIGNALLED=0

cleanup_uint() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    case "$1" in *[1-9]*) return 0 ;; *) return 1 ;; esac
}
cleanup_token() {
    case "${1:-}" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
    [ "${#1}" -le 160 ]
}
cleanup_start() {
    cleanup_uint "$1" || return 1
    _cs_stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    case "$_cs_stat" in *') '*) _cs_tail=${_cs_stat##*) } ;; *) return 1 ;; esac
    _cs_start=$(printf '%s\n' "$_cs_tail" | awk '{print $20}')
    cleanup_uint "$_cs_start" || return 1
    printf '%s\n' "$_cs_start"
}
cleanup_mode() {
    [ ! -L "$1" ] || return 1
    LC_ALL=C ls -ldn "$1" 2>/dev/null | awk 'NR==1 {print $1}'
}
cleanup_chain() {
    _cc_path=$1
    while [ "$_cc_path" != / ]; do
        [ ! -L "$_cc_path" ] || return 1
        if ls -ld "$_cc_path" >/dev/null 2>&1; then
            [ -d "$_cc_path" ] && [ -r "$_cc_path" ] && [ -x "$_cc_path" ] || return 1
        else
            [ ! -e "$_cc_path" ] || return 1
        fi
        _cc_path=${_cc_path%/*}; [ -n "$_cc_path" ] || _cc_path=/
    done
}
# Strict owner-v2 DATA reader. Reject unknown/duplicate/missing keys and
# nonprintable bytes; preserve the canonical 512-byte and nonce bounds.
cleanup_owner_read() {
    [ ! -L "$1" ] && [ -f "$1" ] && [ -r "$1" ] || return 1
    _cor_size=$(wc -c < "$1") || return 1
    [ "$_cor_size" -gt 0 ] && [ "$_cor_size" -le 512 ] || return 1
    LC_ALL=C grep -q '[^ -~]' "$1" && return 1
    _cor_values=$(LC_ALL=C awk -F= '
      NF!=2 || seen[$1]++ {exit 1}
      $1=="pid" || $1=="proc_start_time" || $1=="created" || $1=="heartbeat" {
        if ($2 !~ /^[0-9]+$/ || $2 !~ /[1-9]/) exit 1; v[$1]=$2; count++; next
      }
      $1=="owner_nonce" {
        if ($2 !~ /^[A-Za-z0-9._:-]+$/ || length($2)>160) exit 1; v[$1]=$2; count++; next
      }
      {exit 1}
      END {if (NR!=5 || count!=5) exit 1;
        print v["pid"],v["proc_start_time"],v["owner_nonce"],v["created"],v["heartbeat"]}
    ' "$1") || return 1
    read -r RECORD_PID RECORD_START RECORD_NONCE RECORD_CREATED RECORD_HEARTBEAT <<EOF_OWNER
$_cor_values
EOF_OWNER
}
cleanup_classify() {
    cleanup_chain "${1%/*}" || { printf unknown; return; }
    if ! ls -ld "$1" >/dev/null 2>&1; then
        # Canonical owner absence requires an observable immediate parent.
        # Missing runtime/lock parents do not establish safe M absence.
        [ -d "${1%/*}" ] && [ -r "${1%/*}" ] && [ -x "${1%/*}" ] &&
        [ ! -L "$1" ] && [ ! -e "$1" ] && { printf absent; return; }
        printf unknown; return
    fi
    [ -d "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] && [ -x "$1" ] || { printf unknown; return; }
    cleanup_owner_read "$1/owner" || { printf unknown; return; }
    _cl_actual=$(cleanup_start "$RECORD_PID")
    if cleanup_uint "$_cl_actual"; then
        if [ "$_cl_actual" != "$RECORD_START" ]; then printf reused
        elif kill -0 "$RECORD_PID" 2>/dev/null; then printf live
        else printf unknown; fi
    elif [ -d /proc ] && [ -r /proc ] && [ -x /proc ] &&
         ! ls -ld "/proc/$RECORD_PID" >/dev/null 2>&1 && [ ! -e "/proc/$RECORD_PID" ]; then
        printf dead
    else printf unknown; fi
}
cleanup_fence_matches() {
    cleanup_chain "${FENCE%/*}" || return 1
    [ "$(cleanup_mode "$FENCE")" = drwx------ ] &&
    [ "$(cleanup_mode "$FENCE/owner")" = -rw------- ] || return 1
    cleanup_owner_read "$FENCE/owner" || return 1
    [ "$RECORD_PID" = "$OWNER_PID" ] && [ "$RECORD_START" = "$OWNER_START" ] &&
    [ "$RECORD_NONCE" = "$OWNER_NONCE" ] || return 1
    [ "$(cleanup_start "$OWNER_PID")" = "$OWNER_START" ] && kill -0 "$OWNER_PID" 2>/dev/null
}
cleanup_fence_claim() {
    [ "$(cleanup_classify "$FENCE")" = absent ] || return 1
    mkdir "$FENCE" 2>/dev/null || return 1
    OWNER_PID=$$
    OWNER_START=$(cleanup_start "$$") || return 1
    _cfc_now=$(date +%s) || return 1
    cleanup_uint "$_cfc_now" || return 1
    OWNER_NONCE="$_cfc_now.$$.$OWNER_START.$RUN"
    cleanup_token "$OWNER_NONCE" || return 1
    printf 'pid=%s\nproc_start_time=%s\nowner_nonce=%s\ncreated=%s\nheartbeat=%s\n' \
      "$OWNER_PID" "$OWNER_START" "$OWNER_NONCE" "$_cfc_now" "$_cfc_now" > "$FENCE/.owner.tmp" || return 1
    chmod 600 "$FENCE/.owner.tmp" && mv "$FENCE/.owner.tmp" "$FENCE/owner" || return 1
    cleanup_fence_matches
}
cleanup_fence_release() {
    [ "$OWNER_PID" = "$$" ] && cleanup_fence_matches || return 1
    [ "$(LC_ALL=C ls -A "$FENCE")" = owner ] || return 1
    cleanup_fence_matches || return 1
    rm -f "$FENCE/owner" && rmdir "$FENCE"
}
cleanup_private_valid() {
    case "$1" in /tmp/.mervlan-full-cleanup.*) ;; *) return 1 ;; esac
    case "${1#/tmp/.mervlan-full-cleanup.}" in ''|*[!A-Za-z0-9.-]*) return 1 ;; esac
    cleanup_chain "$1" || return 1
    [ "$(cleanup_mode "$1")" = drwx------ ] || return 1
    [ "$(ls -ldn "$1" | awk '{print $3}')" = "$(id -u)" ]
}
cleanup_prepare() {
    cleanup_script_candidate "$0" &&
        grep -q '^# Cleaner protocol: phase6-v1$' "$0" || return 1
    _cp_now=$(date +%s) || return 1
    cleanup_uint "$_cp_now" || return 1
    _cp_start=$(cleanup_start "$$") || return 1
    _cp_try=0
    while [ "$_cp_try" -lt 10 ]; do
        RUN="$_cp_now.$$.$_cp_start.$_cp_try"
        PRIVATE_DIR="/tmp/.mervlan-full-cleanup.$RUN"
        if mkdir "$PRIVATE_DIR" 2>/dev/null; then break; fi
        _cp_try=$((_cp_try + 1))
    done
    [ "$_cp_try" -lt 10 ] && cleanup_private_valid "$PRIVATE_DIR" || return 1
    cp "$0" "$PRIVATE_DIR/cleaner.sh" && chmod 700 "$PRIVATE_DIR/cleaner.sh" &&
    cleanup_script_candidate "$PRIVATE_DIR/cleaner.sh" &&
    grep -q '^# Cleaner protocol: phase6-v1$' "$PRIVATE_DIR/cleaner.sh" &&
    cmp "$0" "$PRIVATE_DIR/cleaner.sh" >/dev/null 2>&1 &&
    /bin/sh -n "$PRIVATE_DIR/cleaner.sh"
}
cleanup_context_write() {
    CONTEXT="$PRIVATE_DIR/context"
    printf 'fence=%s\npid=%s\nstart=%s\nnonce=%s\nrun=%s\nmode=standalone\nkeep=%s\nno_reboot=%s\n' \
      "$FENCE" "$OWNER_PID" "$OWNER_START" "$OWNER_NONCE" "$RUN" "$KEEP_BACKUPS" "$NO_REBOOT" > "$CONTEXT.tmp" &&
    chmod 600 "$CONTEXT.tmp" && mv "$CONTEXT.tmp" "$CONTEXT"
}
cleanup_context_read() {
    CONTEXT=$1
    _ccr_dir=${CONTEXT%/*}
    cleanup_private_valid "$_ccr_dir" || return 1
    [ "$CONTEXT" = "$_ccr_dir/context" ] &&
    [ "$(cleanup_mode "$CONTEXT")" = -rw------- ] && [ -r "$CONTEXT" ] || return 1
    [ "$(ls -ldn "$CONTEXT" | awk '{print $3}')" = "$(id -u)" ] || return 1
    # Never follow a pre-existing result temporary or reuse a terminal context.
    # Coordinated consumption is separately enforced by atomic claim mkdir.
    [ ! -e "$_ccr_dir/terminal" ] && [ ! -L "$_ccr_dir/terminal" ] &&
    [ ! -e "$_ccr_dir/terminal.tmp" ] && [ ! -L "$_ccr_dir/terminal.tmp" ] || return 1
    _ccr_size=$(wc -c < "$CONTEXT") || return 1
    [ "$_ccr_size" -gt 0 ] && [ "$_ccr_size" -le 1024 ] || return 1
    LC_ALL=C grep -q '[^ -~]' "$CONTEXT" && return 1
    _ccr_values=$(LC_ALL=C awk -F= '
      NF!=2 || seen[$1]++ {exit 1}
      $1=="fence" || $1=="pid" || $1=="start" || $1=="nonce" ||
      $1=="run" || $1=="mode" || $1=="keep" || $1=="no_reboot" {
        if ($2 == "" || $2 ~ /[[:space:]]/) exit 1; v[$1]=$2; count++; next}
      {exit 1}
      END {if(NR!=8 || count!=8) exit 1;
        print v["fence"],v["pid"],v["start"],v["nonce"],v["run"],v["mode"],v["keep"],v["no_reboot"]}
    ' "$CONTEXT") || return 1
    read -r _ccr_fence OWNER_PID OWNER_START OWNER_NONCE _ccr_run CONTEXT_MODE KEEP_BACKUPS NO_REBOOT <<EOF_CONTEXT
$_ccr_values
EOF_CONTEXT
    [ "$_ccr_fence" = "$FENCE" ] && [ "$_ccr_run" = "$2" ] || return 1
    cleanup_uint "$OWNER_PID" && cleanup_uint "$OWNER_START" &&
    cleanup_token "$OWNER_NONCE" && cleanup_token "$_ccr_run" || return 1
    [ "$_ccr_dir" = "/tmp/.mervlan-full-cleanup.$_ccr_run" ] || return 1
    case "$KEEP_BACKUPS:$NO_REBOOT:$CONTEXT_MODE" in
        0:0:standalone|0:1:standalone|1:0:standalone|1:1:standalone|0:1:coordinated|1:1:coordinated) ;;
        *) return 1 ;;
    esac
    RUN=$_ccr_run
    cleanup_fence_matches
}
cleanup_claim_record() {
    _ccp_start=$(cleanup_start "$$") || return 1
    printf 'protocol=phase6-v1\nrun=%s\npid=%s\nstart=%s\nowner_pid=%s\nowner_start=%s\nowner_nonce=%s\nkeep=%s\nno_reboot=%s\n' \
      "$RUN" "$$" "$_ccp_start" "$OWNER_PID" "$OWNER_START" "$OWNER_NONCE" "$KEEP_BACKUPS" "$NO_REBOOT"
}
cleanup_claim_matches() {
    cleanup_private_valid "${CONTEXT%/*}" || return 1
    _ccm_claim="${CONTEXT%/*}/claim"
    [ "$(cleanup_mode "$_ccm_claim")" = drwx------ ] &&
    [ "$(cleanup_mode "$_ccm_claim/consumer")" = -rw------- ] || return 1
    [ "$(ls -ldn "$_ccm_claim" | awk '{print $3}')" = "$(id -u)" ] &&
    [ "$(ls -ldn "$_ccm_claim/consumer" | awk '{print $3}')" = "$(id -u)" ] || return 1
    [ "$(LC_ALL=C ls -A "$_ccm_claim")" = consumer ] || return 1
    _ccm_size=$(wc -c < "$_ccm_claim/consumer") || return 1
    [ "$_ccm_size" -gt 0 ] && [ "$_ccm_size" -le 1024 ] || return 1
    _ccm_expected=$(cleanup_claim_record) || return 1
    # Fixed serialization is strict DATA: exact known keys, order, identity,
    # values and byte count. Extra/duplicate keys or trailing bytes fail.
    [ "$(cat "$_ccm_claim/consumer" 2>/dev/null)" = "$_ccm_expected" ] &&
    [ "$(wc -c < "$_ccm_claim/consumer")" = "$(printf '%s\n' "$_ccm_expected" | wc -c)" ]
}
cleanup_context_claim() {
    # Wrapper-owned lifecycle: UNCLAIMED -> CLAIMED -> CLAIMED + TERMINAL.
    # Any existing object blocks mkdir, even an incomplete/crashed claim.
    # Never reclaim/delete a claim; CLAIMED + NO TERMINAL stays ambiguous.
    [ "$CONTEXT_MODE" = coordinated ] && cleanup_private_valid "${CONTEXT%/*}" || return 1
    mkdir "${CONTEXT%/*}/claim" 2>/dev/null || return 1
    cleanup_claim_record > "${CONTEXT%/*}/claim/consumer.tmp" &&
    chmod 600 "${CONTEXT%/*}/claim/consumer.tmp" &&
    mv "${CONTEXT%/*}/claim/consumer.tmp" "${CONTEXT%/*}/claim/consumer" || return 1
    # Re-read context/F after consuming it; metadata binds the same policy
    # and owner to this PID/start, preserved by exec into the frozen worker.
    cleanup_context_read "$CONTEXT" "$RUN" && [ "$PPID" = "$OWNER_PID" ] && cleanup_claim_matches
}
cleanup_reboot_prompt() {
    log "[cleanup] IMPORTANT: Reboot this device before reinstalling MerVLAN."
    [ "$NO_REBOOT" = 0 ] || return 0
    printf 'Reboot this device now? [y/N]: '
    IFS= read -r _crp_answer || _crp_answer=
    case "$_crp_answer" in
        y|Y|yes|YES|Yes) sync; reboot ;;
        *) log "[cleanup] Reboot not requested." ;;
    esac
}
cleanup_supervisor_signal() {
    SIGNALLED=1
    if [ -n "$WORKER_START" ] &&
       [ "$(cleanup_start "$WORKER_PID")" = "$WORKER_START" ]; then
        kill -TERM "$WORKER_PID" 2>/dev/null || :
    fi
}
cleanup_supervise() {
    trap 'cleanup_supervisor_signal' HUP INT TERM
    # F first, then nonblocking M classification. Never acquire or recreate M.
    if ! cleanup_fence_claim; then
        log "[cleanup] Full fence exists or cannot be authenticated; refusing. Reboot resets a stale/ambiguous fence."
        rm -rf "$PRIVATE_DIR"
        exit 2
    fi
    case "$(cleanup_classify "$MAINTENANCE")" in
        absent|dead|reused) ;;
        *) log "[cleanup] MerVLAN maintenance is active or unverifiable; finish/stop it before cleanup."
           rm -rf "$PRIVATE_DIR"
           cleanup_fence_release || exit 4
           exit 2 ;;
    esac
    if [ "$SIGNALLED" = 1 ] || ! cleanup_context_write; then
        rm -rf "$PRIVATE_DIR"
        cleanup_fence_release || exit 4
        exit 2
    fi
    /bin/sh "$PRIVATE_DIR/cleaner.sh" --mervlan-cleanup-worker "$CONTEXT" "$RUN" &
    WORKER_PID=$!
    WORKER_START=$(cleanup_start "$WORKER_PID") || WORKER_START=
    [ "$SIGNALLED" = 0 ] || cleanup_supervisor_signal
    # Poll only this direct child. A signal never releases F on exit alone.
    _csp_ticks=0
    while kill -0 "$WORKER_PID" 2>/dev/null; do
        _csp_actual=$(cleanup_start "$WORKER_PID") || _csp_actual=
        if [ -n "$WORKER_START" ] && [ -n "$_csp_actual" ] &&
           [ "$_csp_actual" != "$WORKER_START" ]; then break; fi
        [ "$SIGNALLED" = 0 ] || _csp_ticks=$((_csp_ticks + 1))
        if [ "$_csp_ticks" -ge 10 ]; then
            log "[cleanup] Worker terminal state is ambiguous; Full fence retained. Reboot is the safe reset."
            exit 4
        fi
        sleep 1
    done
    wait "$WORKER_PID"; _csp_rc=$?
    trap '' HUP INT TERM
    # An atomic run-bound result is emitted only after synchronous cleanup
    # and private worker cleanup finish. Killed workers cannot publish it.
    if [ "$(cleanup_mode "$PRIVATE_DIR/terminal")" != -rw------- ] ||
       [ "$(cat "$PRIVATE_DIR/terminal" 2>/dev/null)" != "$RUN:$WORKER_PID:$_csp_rc" ]; then
        log "[cleanup] Missing terminal proof; Full fence retained. Reboot is the safe reset."
        exit 4
    fi
    rm -rf "$PRIVATE_DIR" || exit 4
    cleanup_fence_release || { log "[cleanup] Exact fence release refused; fence retained."; exit 4; }
    cleanup_reboot_prompt
    exit "$_csp_rc"
}

# Read-only historical parser seam remains harmless and needs no authority.
if [ "${1:-}" = --mervlan-cleanup-test-cru-parser ]; then
    cru_owned_job_names "$(cat)"
    exit $?
fi

case "${1:-}" in
    --mervlan-cleanup-supervisor)
        [ "$#" = 4 ] || exit 2
        PRIVATE_DIR=$2; RUN=$3; CONTEXT=$4
        cleanup_private_valid "$PRIVATE_DIR" && cleanup_token "$RUN" || exit 2
        [ "$0" = "$PRIVATE_DIR/cleaner.sh" ] &&
        [ "$PRIVATE_DIR" = "/tmp/.mervlan-full-cleanup.$RUN" ] &&
        [ "$(cleanup_mode "$PRIVATE_DIR/supervisor")" = -rw------- ] &&
        [ "$(cat "$PRIVATE_DIR/supervisor" 2>/dev/null)" = "$$:$(cleanup_start "$$"):$RUN" ] || exit 2
        # Preferences are strict data, not shell source.
        [ "$(cleanup_mode "$CONTEXT")" = -rw------- ] || exit 2
        _prefs=$(cat "$CONTEXT")
        case "$_prefs" in 0:0|0:1|1:0|1:1) ;; *) exit 2 ;; esac
        KEEP_BACKUPS=${_prefs%:*}; NO_REBOOT=${_prefs#*:}
        cleanup_supervise ;;
    --mervlan-cleanup-borrowed|--mervlan-cleanup-worker)
        [ "$#" -ge 3 ] || exit 2
        _entry=$1; _context=$2; _run=$3
        cleanup_context_read "$_context" "$_run" && [ "$PPID" = "$OWNER_PID" ] || exit 2
        if [ "$_entry" = --mervlan-cleanup-borrowed ]; then
            [ "$CONTEXT_MODE" = coordinated ] || exit 2
            shift 3
            # Future wrappers may pass the mapped public options. Context
            # policy remains authoritative; options cannot override it.
            _borrow_yes=0; _borrow_choice=
            for _borrow_arg in "$@"; do
                case "$_borrow_arg" in
                    --yes) _borrow_yes=1 ;;
                    --keep-backups)
                        [ "$_borrow_choice" != delete ] && [ "$KEEP_BACKUPS" = 1 ] || exit 2
                        _borrow_choice=keep ;;
                    --delete-backups)
                        [ "$_borrow_choice" != keep ] && [ "$KEEP_BACKUPS" = 0 ] || exit 2
                        _borrow_choice=delete ;;
                    --no-reboot) [ "$NO_REBOOT" = 1 ] || exit 2 ;;
                    *) exit 2 ;;
                esac
            done
            [ "$_borrow_choice:$_borrow_yes" != delete:0 ] || exit 2
            cleanup_context_claim || exit 2
            cleanup_prepare || exit 2
            exec /bin/sh "$PRIVATE_DIR/cleaner.sh" --mervlan-cleanup-worker "$_context" "$_run"
            exit 2
        fi
        [ "$#" = 3 ] || exit 2
        if [ "$CONTEXT_MODE" = coordinated ]; then
            cleanup_claim_matches || exit 2
        fi
        PRIVATE_DIR=${0%/*}
        cleanup_private_valid "$PRIVATE_DIR" && [ "$0" = "$PRIVATE_DIR/cleaner.sh" ] || exit 2
        WORK_DIR="$PRIVATE_DIR/work"
        mkdir "$WORK_DIR" || exit 2
        # Defer catchable termination until synchronous commands have returned.
        # No child is intentionally detached by the destructive engine.
        trap 'SIGNALLED=1' HUP INT TERM
        ;;
    *)
        YES=0; BACKUP_CHOICE=; NO_REBOOT=0
        for _arg in "$@"; do
            case "$_arg" in
                --yes) YES=1 ;;
                --no-reboot) NO_REBOOT=1 ;;
                --keep-backups) [ "$BACKUP_CHOICE" != delete ] || exit 2; BACKUP_CHOICE=keep ;;
                --delete-backups) [ "$BACKUP_CHOICE" != keep ] || exit 2; BACKUP_CHOICE=delete ;;
                *) printf '[cleanup] Unknown option: %s\n' "$_arg" >&2; exit 2 ;;
            esac
        done
        [ "$BACKUP_CHOICE:$YES" != delete:0 ] || { log "[cleanup] --delete-backups requires --yes"; exit 2; }
        log "MerVLAN FULL CLEANUP - LOCAL DEVICE ONLY. Configured nodes are NOT contacted."
        if [ "$YES" = 0 ]; then
            printf 'Continue with destructive MerVLAN cleanup on THIS device? [y/N]: '
            IFS= read -r _answer || _answer=
            case "$_answer" in y|Y|yes|YES|Yes) ;; *) log "[cleanup] Cleanup cancelled."; exit 0 ;; esac
        fi
        if [ -z "$BACKUP_CHOICE" ]; then
            printf 'Keep retained MerVLAN backups in %s? [Y/n]: ' "$BACKUP_ROOT"
            IFS= read -r _answer || _answer=
            case "$_answer" in n|N|no|NO|No) BACKUP_CHOICE=delete ;; *) BACKUP_CHOICE=keep ;; esac
        fi
        [ "$BACKUP_CHOICE" != delete ] || KEEP_BACKUPS=0
        cleanup_prepare || { log "[cleanup] Cannot freeze a validated file-based cleaner in private /tmp storage."; exit 2; }
        printf '%s:%s:%s\n' "$$" "$(cleanup_start "$$")" "$RUN" > "$PRIVATE_DIR/supervisor" || exit 2
        printf '%s:%s\n' "$KEEP_BACKUPS" "$NO_REBOOT" > "$PRIVATE_DIR/preferences" || exit 2
        exec /bin/sh "$PRIVATE_DIR/cleaner.sh" --mervlan-cleanup-supervisor "$PRIVATE_DIR" "$RUN" "$PRIVATE_DIR/preferences"
        exit 2 ;;
esac

DISCOVERED_WEB_PAGE="$(metadata_get mervlan_page)"
LEGACY_WEB_PAGE="$(metadata_get merlin_vlan_manager_page)"
log ""
log "[cleanup] Starting destructive local cleanup"

remove_cru_jobs || :
stop_mervlan_processes || :

# Persistent destruction is gated on both shared hooks. A missing hook is
# safe; an existing hook must be rewritten and revalidated successfully before
# any persistent MerVLAN tree, recovery artifact, web publication, or metadata
# is removed. This prevents a dangling boot/service reference to deleted code.
HOOKS_CLEAN=1
if ! clean_shared_hook_file "$SERVICE_EVENT"; then
    HOOKS_CLEAN=0
fi
if ! clean_shared_hook_file "$SERVICES_START"; then
    HOOKS_CLEAN=0
fi

teardown_ebtables
cleanup_menu_tree || :
if [ "$HOOKS_CLEAN" -eq 1 ]; then
    remove_web_pages || :
    metadata_remove_all || :
    remove_owned_paths
else
    fail "Persistent MerVLAN removal skipped because shared hook cleanup was not proven safe"
    remove_volatile_owned_paths
    if [ "$KEEP_BACKUPS" = "0" ]; then
        BACKUPS_DELETION_SKIPPED=1
        warn "Retained backup deletion was skipped because persistent cleanup is safety-gated"
    else
        warn "Persistent MerVLAN paths and retained backup sanitation were skipped because a shared hook is unsafe"
    fi
fi

log ""
log "[cleanup] Verifying cleanup"
verify_cleanup || :
log ""
log "======================================================================"
if [ "$FAILURES" -eq 0 ]; then
    log " MerVLAN persistent cleanup completed successfully."
else
    log " MerVLAN cleanup completed with $FAILURES error(s)."
    log " Review the messages above before reinstalling MerVLAN."
fi
[ "$WARNINGS" -gt 0 ] && log " Additional warnings: $WARNINGS"
if [ "$KEEP_BACKUPS" = "1" ] || [ "$BACKUPS_DELETION_SKIPPED" = "1" ]; then
    log " Backups preserved: $BACKUP_ROOT"
else
    log " Backups deleted."
fi
log "======================================================================"
log ""
log "A reboot is required before a clean MerVLAN reinstall and is strongly"
log "recommended to clear remaining firmware-managed VLAN/bridge/runtime state."
log ""

# Fix the result only after all synchronous mutation and scratch cleanup.
cleanup_work
_terminal_rc=0
[ "$FAILURES" -eq 0 ] && [ "$SIGNALLED" = 0 ] || _terminal_rc=3
if [ "$CONTEXT_MODE" = coordinated ]; then
    # This is the execution-local relocation, not the wrapper-owned context,
    # claim and result directory. Finish all rc-changing cleanup first.
    if ! rm -f "$PRIVATE_DIR/cleaner.sh" || ! rmdir "$PRIVATE_DIR"; then
        _terminal_rc=4
    fi
    # Catchable signals at the publication boundary cannot alter final rc.
    trap '' HUP INT TERM
fi
# Final rc is now fixed. Publication failure has no definitive terminal proof.
printf '%s:%s:%s\n' "$RUN" "$$" "$_terminal_rc" > "${CONTEXT%/*}/terminal.tmp" &&
    chmod 600 "${CONTEXT%/*}/terminal.tmp" &&
    mv "${CONTEXT%/*}/terminal.tmp" "${CONTEXT%/*}/terminal" || exit 4
exit "$_terminal_rc"
