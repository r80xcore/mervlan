#!/bin/sh
# Standalone emergency repair.  Intentionally source-free: this script must
# still work when MerVLAN's updater, locks, and libraries are damaged.
set -u

: "${MERV_BASE:=/jffs/addons/mervlan}"
: "${MERV_REPAIR_RAW_BASE:=https://raw.githubusercontent.com/r80xcore/mervlan}"
: "${MERV_REPAIR_TMP_ROOT:=/tmp}"
: "${MERV_REPAIR_CONNECT_TIMEOUT:=15}"
: "${MERV_REPAIR_MAX_TIME:=120}"

RUN_DIR=""
STAGE_DIR=""
BACKUP_DIR=""
PATHS_FILE=""
PUBLISHED_FILE=""
CURL_BIN="${MERV_REPAIR_CURL:-}"
REF=""
PROGRESS_TOKEN="${MERV_PROGRESS_TOKEN:-}"
PROGRESS_ACTION=""
PROGRESS_STARTED=""

log() { printf '%s\n' "[mervlan-repair] $*" >&2; }

cleanup() {
    case "${RUN_DIR:-}" in
        /tmp/mervlan_repair.*) rm -rf "$RUN_DIR" 2>/dev/null || : ;;
    esac
}
trap cleanup EXIT HUP INT TERM

token_valid() {
    case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    [ "${#1}" -le 96 ]
}

json_escape() { printf '%s' "${1:-}" | tr -d '\000-\010\013\014\016-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Best effort only.  The protocol deliberately matches lib_progress.sh but no
# MerVLAN helper is sourced.  The production path is fixed by contract.
progress() {
    _state="$1" _phase="$2" _percent="$3" _message="$4"
    token_valid "$PROGRESS_TOKEN" || return 0
    _root=/tmp/mervlan_tmp/progress
    mkdir -p "$_root" 2>/dev/null || return 0
    _path="$_root/$PROGRESS_TOKEN.json" _tmp="$_root/$PROGRESS_TOKEN.json.tmp.$$"
    _now=$(date +%s 2>/dev/null || printf 0); case "$_now" in *[!0-9]*|'') _now=0;; esac
    [ -n "$PROGRESS_STARTED" ] || PROGRESS_STARTED="$_now"
    _err=null; [ "$_state" = failed ] && _err="\"$(json_escape "$_message")\""
    {
        printf '{"format_version":2,"token":"%s","action":"%s","label":"Emergency MerVLAN Repair"' "$(json_escape "$PROGRESS_TOKEN")" "$(json_escape "$PROGRESS_ACTION")"
        printf ',"state":"%s","mode":"phase","phase":"%s","current":0,"total":0,"percent":%s' "$_state" "$(json_escape "$_phase")" "$_percent"
        printf ',"message":"%s","error":%s,"started_at":%s,"owner_pid":%s,"owner_start":0,"owner_nonce":"repair","terminal_state":"%s","updated_at":%s}\n' "$(json_escape "$_message")" "$_err" "$PROGRESS_STARTED" "$$" "$_state" "$_now"
    } >"$_tmp" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null || :; return 0; }
    chmod 644 "$_tmp" 2>/dev/null || :
    mv -f "$_tmp" "$_path" 2>/dev/null || rm -f "$_tmp" 2>/dev/null || :
}

valid_ref() {
    REF="${1:-main}"
    case "$REF" in main|dev) return 0;; esac
    case "$REF" in ''|/*|*/|*..*|*//*|*.lock|*[!A-Za-z0-9._/-]*) return 1;; esac
    case "$REF" in [A-Za-z0-9]* ) ;; *) return 1;; esac
    case "$REF" in *[A-Za-z0-9]) return 0;; *) return 1;; esac
}

find_curl() {
    if [ -z "$CURL_BIN" ]; then CURL_BIN=$(command -v curl 2>/dev/null || printf ''); fi
    [ -x "$CURL_BIN" ] || { [ -x /usr/sbin/curl ] && CURL_BIN=/usr/sbin/curl; }
    [ -n "$CURL_BIN" ] && [ -x "$CURL_BIN" ]
}

fetch() {
    _url="$1" _dest="$2" _part="${2}.part"
    rm -f "$_part" 2>/dev/null || return 1
    "$CURL_BIN" -f -sS -L --retry 3 --retry-delay 1 --connect-timeout "$MERV_REPAIR_CONNECT_TIMEOUT" --max-time "$MERV_REPAIR_MAX_TIME" -o "$_part" "$_url" || { rm -f "$_part" 2>/dev/null || :; return 1; }
    [ -s "$_part" ] || { rm -f "$_part" 2>/dev/null || :; return 1; }
    mv -f "$_part" "$_dest" 2>/dev/null || { rm -f "$_part" 2>/dev/null || :; return 1; }
}

path_allowed() {
    case "$1" in
        install.sh|uninstall.sh|changelog.txt|mervlan.asp|LICENSE|README.md|functions/*|settings/*|templates/*|www/*|docs/*) return 0;;
        *) return 1;;
    esac
}
path_protected() {
    case "$1" in
        settings/settings.json|.ssh|.ssh/*|tmp|tmp/*|flags|flags/*|www/.ssh|www/.ssh/*|www/tmp|www/tmp/*|www/settings/hardware_profiles.json) return 0;;
        *) return 1;;
    esac
}

parse_manifest() {
    _manifest="$1" _seen=0
    : >"$PATHS_FILE" || return 1
    while IFS= read -r _line || [ -n "$_line" ]; do
        [ -n "$_line" ] || continue
        case "$_line" in \#*) continue;; esac
        if [ "$_seen" -eq 0 ]; then [ "$_line" = 'format=1' ] || return 1; _seen=1; continue; fi
        _mode=${_line%% *}; _path=${_line#* }
        [ "$_mode" != "$_line" ] && [ -n "$_path" ] || return 1
        case "$_path" in *' '*|*'	'*|/*|*/|*//*|*..*|*'\\'*) return 1;; esac
        case "$_mode" in 0644|0755) ;; *) return 1;; esac
        path_allowed "$_path" && ! path_protected "$_path" || return 1
        grep -Fqx "$_path" "$PATHS_FILE" 2>/dev/null && return 1
        printf '%s %s\n' "$_mode" "$_path" >>"$PATHS_FILE" || return 1
    done <"$_manifest"
    [ "$_seen" -eq 1 ] && [ -s "$PATHS_FILE" ] || return 1
    for _required in install.sh uninstall.sh functions/update_mervlan.sh functions/mervlan_boot.sh functions/update_mervlan_repair.sh functions/update_mervlan_repair.manifest; do
        grep -Fq " $_required" "$PATHS_FILE" || return 1
    done
}

validate_stage() {
    while IFS=' ' read -r _mode _path; do
        _file="$STAGE_DIR/$_path"
        [ -f "$_file" ] && [ -s "$_file" ] || return 1
        _actual=$(ls -l "$_file" 2>/dev/null | awk '{print $1}')
        case "$_mode:$_actual" in 0755:-rwxr-xr-x|0644:-rw-r--r--) ;; *) return 1;; esac
        case "$_path" in *.sh) sh -n "$_file" >/dev/null 2>&1 || return 1;; esac
    done <"$PATHS_FILE"
}

rollback() {
    _failed=0
    _reverse="$RUN_DIR/published.reverse"
    sed '1!G;h;$!d' "$PUBLISHED_FILE" >"$_reverse" 2>/dev/null || return 1
    while IFS=' ' read -r _kind _path; do
        _dest="$MERV_BASE/$_path" _tmp="${_dest}.repair.$$"
        rm -f "$_tmp" 2>/dev/null || :
        if [ "$_kind" = old ]; then
            cp -p "$BACKUP_DIR/$_path" "$_tmp" 2>/dev/null && mv -f "$_tmp" "$_dest" 2>/dev/null || _failed=1
        else
            rm -f "$_dest" 2>/dev/null || _failed=1
        fi
    done <"$_reverse"
    while IFS=' ' read -r _mode _path; do rm -f "$MERV_BASE/${_path}.repair.$$" 2>/dev/null || :; done <"$PATHS_FILE"
    return "$_failed"
}

publish() {
    : >"$PUBLISHED_FILE" || return 1
    while IFS=' ' read -r _mode _path; do
        _source="$STAGE_DIR/$_path" _dest="$MERV_BASE/$_path" _dir=${_dest%/*} _tmp="${_dest}.repair.$$"
        mkdir -p "$_dir" 2>/dev/null || { log "Could not create destination directory for $_path"; rollback; return 1; }
        _kind=new
        if [ -e "$_dest" ] || [ -L "$_dest" ]; then
            _kind=old
            case "$_path" in */*) _backup_parent="$BACKUP_DIR/${_path%/*}";; *) _backup_parent="$BACKUP_DIR";; esac
            mkdir -p "$_backup_parent" 2>/dev/null || { rollback; return 1; }
            cp -p "$_dest" "$BACKUP_DIR/$_path" 2>/dev/null || { log "Could not back up $_path"; rollback; return 1; }
        fi
        rm -f "$_tmp" 2>/dev/null || { rollback; return 1; }
        cp -p "$_source" "$_tmp" 2>/dev/null && chmod "$_mode" "$_tmp" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null || :; rollback; return 1; }
        [ "${MERV_REPAIR_TEST_FAIL_PATH:-}" != "$_path" ] || { rm -f "$_tmp" 2>/dev/null || :; log "Forced publish failure: $_path"; rollback; return 1; }
        mv -f "$_tmp" "$_dest" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null || :; rollback; return 1; }
        printf '%s %s\n' "$_kind" "$_path" >>"$PUBLISHED_FILE" || { rollback; return 1; }
    done <"$PATHS_FILE"
}

main() {
    valid_ref "${1:-main}" || { log 'Invalid branch; use main, dev, or a safe custom branch name.'; return 2; }
    case "$MERV_BASE" in ''|/|/tmp|/jffs|/jffs/addons|*..*|*//*) log 'Unsafe MERV_BASE refused.'; return 2;; esac
    [ -d "$MERV_BASE" ] || { log 'MERV_BASE does not exist.'; return 2; }
    find_curl || { log 'curl is unavailable.'; return 2; }
    RUN_DIR="${MERV_REPAIR_TMP_ROOT%/}/mervlan_repair.$$"; STAGE_DIR="$RUN_DIR/stage"; BACKUP_DIR="$RUN_DIR/backup"; PATHS_FILE="$RUN_DIR/paths"; PUBLISHED_FILE="$RUN_DIR/published"
    case "$RUN_DIR" in /tmp/mervlan_repair.*) ;; *) log 'Repair workspace must be below /tmp.'; return 2;; esac
    mkdir -p "$STAGE_DIR" "$BACKUP_DIR" || { log 'Cannot create repair workspace.'; return 1; }
    PROGRESS_ACTION=repairmain_vlanmgr; [ "$REF" = dev ] && PROGRESS_ACTION=repairdev_vlanmgr
    progress starting prepare 1 'Preparing emergency repair'
    _manifest="$RUN_DIR/manifest"
    progress running manifest 10 'Downloading repair manifest'
    fetch "$MERV_REPAIR_RAW_BASE/$REF/functions/update_mervlan_repair.manifest" "$_manifest" || { progress failed failed 0 'Repair manifest download failed'; log 'Manifest download failed; no files changed.'; return 1; }
    parse_manifest "$_manifest" || { progress failed failed 0 'Repair manifest failed strict validation'; log 'Manifest validation failed; no files changed.'; return 1; }
    _n=0; while IFS=' ' read -r _mode _path; do
        _n=$((_n + 1)); _dest="$STAGE_DIR/$_path"; mkdir -p "${_dest%/*}" || { log "Cannot stage $_path"; return 1; }
        progress running download $((20 + (_n * 45 / 100))) "Downloading $_path"
        fetch "$MERV_REPAIR_RAW_BASE/$REF/$_path" "$_dest" || { progress failed failed 0 "Download failed for $_path"; log "Download failed; no files changed."; return 1; }
        chmod "$_mode" "$_dest" || { progress failed failed 0 "Cannot set mode for $_path"; return 1; }
    done <"$PATHS_FILE"
    progress running validate 75 'Validating all staged repair components'
    validate_stage || { progress failed failed 0 'Staged validation failed; no files changed'; log 'Staged validation failed; no files changed.'; return 1; }
    progress running publish 88 'Publishing validated repair components'
    publish || { progress failed failed 0 'Publication failed; rollback attempted'; log 'Publication failed; rollback attempted.'; return 1; }
    progress complete complete 100 'Emergency repair completed'
    log "MerVLAN update components repaired successfully from branch: $REF"
    log 'No update was started.'
}

main "$@"
