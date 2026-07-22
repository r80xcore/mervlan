# ============================================================================ #
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
# ============================================================================ #
#               - File: log_settings.sh || version="0.46"                      #
# ============================================================================ #
# - Purpose:    Define logging settings and environment variables used         #
#               throughout the MerVLAN addon. Enables colored output,          #
#               per-channel log files, and syslog integration.                 #
# ============================================================================ #
[ -n "${LOG_SETTINGS_LOADED:-}" ] && return 0 2>/dev/null

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

# ===================================================== Central settings setup #
: "${LOGROOT:=/tmp/mervlan_tmp/logs}"   # default dir for logs
: "${LOG_TAG:=mervlan}"             # syslog tag
: "${LOG_SYSLOG:=1}"                # 1 = send marked logs to syslog
: "${COLOR:=auto}"                  # auto | always | never

# ========================================================== Log trim settings #
# Maximum lines to keep per log file (set to 0 to disable trimming)
: "${LOG_MAX_LINES:=2000}"
# Maximum bytes to keep per log file (set to 0 to disable byte trimming).
# Both limits apply; the newest complete lines within the tighter limit win.
: "${LOG_MAX_BYTES:=1048576}"
# Periodic maintenance interval.  The existing health cron calls the cheap due
# gate every tick, but trimming runs at most once per interval.
: "${LOG_MAINT_INTERVAL:=86400}"
: "${LOG_MAINT_LOCK_STALE:=300}"

# ======================================================= Log channel settings #
# Default command names
: "${LOG_CMD_LOG:=log}"
: "${LOG_CMD_INFO:=info}"
: "${LOG_CMD_WARN:=warn}"
: "${LOG_CMD_ERROR:=error}" # auto-sends ERROR messages to syslog if used 
#                             with channel "vlan" and LOG_SYSLOG=1
# ========================================================== Override settings #
LOG_chan_cli="$LOGROOT/cli_output.log"
LOG_chan_vlan="$LOGROOT/vlan_manager.log"
# ============================================== End of Central settings setup #


# =========================== internals (do not edit) ======================== #

# color policy: TTY-aware per-FD
_log_use_color() {
    fd="$1"
    case "$COLOR" in
        always) return 0 ;;
        never)  return 1 ;;
        *)      [ -t "$fd" ] || return 1 ;;
    esac
}

# printf with optional color; $1=color code (31/32/33...), $2=text, $3=fd
_log_cprintln() {
    code="$1"; text="$2"; fd="${3:-1}"
    if _log_use_color "$fd"; then
        printf '\033[%sm%s\033[0m\n' "$code" "$text" >&"$fd"
    else
        printf '%s\n' "$text" >&"$fd"
    fi
}

# resolve channel -> filepath (uses per-channel overrides if set)
# Fallback: $LOGROOT/<channel>.log
_log_path_for_channel() {
    ch="$1"
    # turn '-' and spaces into underscores for var lookup; keep original for filename
    vname=$(printf '%s' "$ch" | tr ' -' '__')
    eval "override=\${LOG_chan_${vname}:-}"
    if [ -n "$override" ]; then
        printf '%s' "$override"
    else
        printf '%s/%s.log' "$LOGROOT" "$ch"
    fi
}

# ensure directory for a file exists; best-effort; silent on failure
_log_ensure_dir() {
    f="$1"
    case "$f" in
        */*) d="${f%/*}" ;;
        *)   d="." ;;
    esac
    [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || :
}

# append one line to a channel (best-effort, silent)
_log_append_channel() {
    ch="$1"; line="$2"
    f=$(_log_path_for_channel "$ch")
    _log_ensure_dir "$f"
    { printf '%s\n' "$line" >>"$f"; } 2>/dev/null || :
}

# fan-out over comma-separated channels; default "vlan" if none
_log_for_each_channel() {
    list="$1"
    if [ -z "$list" ]; then
        set -- vlan
    else
        oldIFS=$IFS; IFS=,
        # shellcheck disable=SC2086
        set -- $list
        IFS=$oldIFS
    fi
    for ch in "$@"; do printf '%s\n' "$ch"; done
}

# ========================= Log trimming / rotation =========================== #
# Trims a single log file to LOG_MAX_LINES/LOG_MAX_BYTES (newest complete lines).
# Usage: _log_trim_file "/path/to/logfile"
_log_trim_file() {
    _ltf_file="$1"
    [ -z "$_ltf_file" ] && return 0
    [ -f "$_ltf_file" ] || return 0

    _ltf_lines="${LOG_MAX_LINES:-0}"
    _ltf_bytes="${LOG_MAX_BYTES:-0}"
    case "$_ltf_lines" in ''|*[!0-9]*) _ltf_lines=0 ;; esac
    case "$_ltf_bytes" in ''|*[!0-9]*) _ltf_bytes=0 ;; esac
    [ "$_ltf_lines" -gt 0 ] 2>/dev/null || [ "$_ltf_bytes" -gt 0 ] 2>/dev/null || return 0

    _ltf_count=$(wc -l < "$_ltf_file" 2>/dev/null | tr -d '[:space:]')
    _ltf_size=$(wc -c < "$_ltf_file" 2>/dev/null | tr -d '[:space:]')
    case "$_ltf_count" in ''|*[!0-9]*) _ltf_count=0 ;; esac
    case "$_ltf_size" in ''|*[!0-9]*) _ltf_size=0 ;; esac
    _ltf_over=0
    [ "$_ltf_lines" -gt 0 ] 2>/dev/null && [ "$_ltf_count" -gt "$_ltf_lines" ] 2>/dev/null && _ltf_over=1
    [ "$_ltf_bytes" -gt 0 ] 2>/dev/null && [ "$_ltf_size" -gt "$_ltf_bytes" ] 2>/dev/null && _ltf_over=1
    [ "$_ltf_over" = "1" ] || return 0

    _ltf_tmp="${_ltf_file}.trim.$$"
    _ltf_byte_tmp="${_ltf_file}.bytes.$$"
    rm -f "$_ltf_tmp" "$_ltf_byte_tmp" 2>/dev/null || :
    if [ "$_ltf_lines" -gt 0 ] 2>/dev/null; then
        tail -n "$_ltf_lines" "$_ltf_file" > "$_ltf_tmp" 2>/dev/null || { rm -f "$_ltf_tmp"; return 1; }
    else
        cp "$_ltf_file" "$_ltf_tmp" 2>/dev/null || return 1
    fi

    _ltf_trimmed_size=$(wc -c < "$_ltf_tmp" 2>/dev/null | tr -d '[:space:]')
    case "$_ltf_trimmed_size" in ''|*[!0-9]*) _ltf_trimmed_size=0 ;; esac
    if [ "$_ltf_bytes" -gt 0 ] 2>/dev/null && [ "$_ltf_trimmed_size" -gt "$_ltf_bytes" ] 2>/dev/null; then
        if ! tail -c "$_ltf_bytes" "$_ltf_tmp" > "$_ltf_byte_tmp" 2>/dev/null; then
            rm -f "$_ltf_tmp" "$_ltf_byte_tmp" 2>/dev/null || :
            return 1
        fi
        # The byte window normally begins in the middle of a line.  Discard
        # that fragment so the retained log always starts with a complete line.
        sed '1d' "$_ltf_byte_tmp" > "$_ltf_tmp" 2>/dev/null || {
            rm -f "$_ltf_tmp" "$_ltf_byte_tmp" 2>/dev/null || :
            return 1
        }
    fi
    rm -f "$_ltf_byte_tmp" 2>/dev/null || :
    if mv -f "$_ltf_tmp" "$_ltf_file" 2>/dev/null; then
        chmod 644 "$_ltf_file" 2>/dev/null || :
        return 0
    fi
    rm -f "$_ltf_tmp" 2>/dev/null || :
    return 1
}

# Internal best-effort maintenance lock.  It prevents cron, boot, and a manual
# maintenance action from replacing the same log concurrently.
_log_maintenance_lock_acquire() {
    _lmla_lock="$LOGROOT/.maintenance.lock"
    mkdir -p "$LOGROOT" 2>/dev/null || return 1
    if mkdir "$_lmla_lock" 2>/dev/null; then
        date +%s > "$_lmla_lock/created" 2>/dev/null || :
        return 0
    fi
    _lmla_now=$(date +%s 2>/dev/null || printf '0')
    _lmla_created=$(cat "$_lmla_lock/created" 2>/dev/null || printf '0')
    case "$_lmla_now" in ''|*[!0-9]*) _lmla_now=0 ;; esac
    case "$_lmla_created" in ''|*[!0-9]*) _lmla_created=0 ;; esac
    _lmla_age=$((_lmla_now - _lmla_created))
    [ "$_lmla_age" -ge "${LOG_MAINT_LOCK_STALE:-300}" ] 2>/dev/null || return 1
    rm -rf "$_lmla_lock" 2>/dev/null || return 1
    mkdir "$_lmla_lock" 2>/dev/null || return 1
    printf '%s\n' "$_lmla_now" > "$_lmla_lock/created" 2>/dev/null || :
    return 0
}

_log_maintenance_lock_release() {
    _lmlr_lock="$LOGROOT/.maintenance.lock"
    rm -f "$_lmlr_lock/created" 2>/dev/null || :
    rmdir "$_lmlr_lock" 2>/dev/null || :
}

# Trim every managed log file, including boot/custom channels, and record the
# successful maintenance time.  This function is intentionally silent.
log_maintain_all() {
    _log_maintenance_lock_acquire || return 0
    _lma_failed=0
    for _lma_file in "$LOGROOT"/*.log; do
        [ -f "$_lma_file" ] || continue
        _log_trim_file "$_lma_file" || _lma_failed=1
    done
    if [ "$_lma_failed" = "0" ]; then
        date +%s > "$LOGROOT/.last_maintenance" 2>/dev/null || :
    fi
    _log_maintenance_lock_release
    [ "$_lma_failed" = "0" ]
}

# Compatibility name retained for existing callers.
log_trim_all() {
    log_maintain_all
}

# Cheap once-per-interval gate suitable for a five-minute health cron.
log_maintenance_due() {
    _lmd_now=$(date +%s 2>/dev/null || printf '0')
    _lmd_last=$(cat "$LOGROOT/.last_maintenance" 2>/dev/null || printf '0')
    _lmd_interval="${LOG_MAINT_INTERVAL:-86400}"
    case "$_lmd_now" in ''|*[!0-9]*) return 0 ;; esac
    case "$_lmd_last" in ''|*[!0-9]*) _lmd_last=0 ;; esac
    case "$_lmd_interval" in ''|*[!0-9]*) _lmd_interval=86400 ;; esac
    _lmd_age=$((_lmd_now - _lmd_last))
    if [ "$_lmd_age" -lt 0 ] 2>/dev/null || [ "$_lmd_age" -ge "$_lmd_interval" ] 2>/dev/null; then
        log_maintain_all
    fi
}

# Truncate managed logs in place so public symlinks remain valid.  The caller
# writes the first post-clear audit entry after this returns.
log_clear_all() {
    _log_maintenance_lock_acquire || return 1
    _lca_failed=0
    for _lca_file in "$LOGROOT"/*.log; do
        [ -f "$_lca_file" ] || continue
        : > "$_lca_file" 2>/dev/null || _lca_failed=1
        chmod 644 "$_lca_file" 2>/dev/null || :
    done
    if [ "$_lca_failed" = "0" ]; then
        date +%s > "$LOGROOT/.last_maintenance" 2>/dev/null || :
    fi
    _log_maintenance_lock_release
    [ "$_lca_failed" = "0" ]
}

# --------------------------- public API impls --------------------------------

# Unmarked: file-only (good for watchdog). Usage:
#   log [-c ch1,ch2] "message"
log() {
    channels=""
    if [ "$1" = "-c" ] && [ -n "$2" ]; then channels="$2"; shift 2 || :; fi
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    line="$ts $*"
    for ch in $(_log_for_each_channel "$channels"); do
        _log_append_channel "$ch" "$line"
    done
    # no screen, no syslog
}

# Marked: screen + file (+ optional syslog). Usage:
#   info  [-c ch1,ch2] "message"
#   warn  [-c ch1,ch2] "message"
#   error [-c ch1,ch2] "message"
_info_warn_error() {
    level="$1"; shift || :
    channels=""
    if [ "$1" = "-c" ] && [ -n "$2" ]; then channels="$2"; shift 2 || :; fi
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    plain="[$level] $*"
    line="$ts $plain"

    # screen
    case "$level" in
        INFO)  fd=1; col=32 ;;  # green
        WARN)  fd=1; col=33 ;;  # yellow
        ERROR) fd=2; col=31 ;;  # red
        *)     fd=1; col=0  ;;
    esac
  # Only print to screen if the target fd is a TTY to avoid doubling when stdout/stderr is redirected
  if [ -t "$fd" ]; then
    if [ "$col" -eq 0 ]; then
      printf '%s\n' "$line" >&"$fd"
    else
      _log_cprintln "$col" "$line" "$fd"
    fi
  fi

    # file(s)
    for ch in $(_log_for_each_channel "$channels"); do
        _log_append_channel "$ch" "$line"
        # syslog (optional, per-channel with tag suffix)
        if [ "$LOG_SYSLOG" = 1 ] && [ "$level" = "ERROR" ] && [ "$ch" = "vlan" ] && merv_has logger; then
            case "$level" in
                ERROR) 
                    logger -t "${LOG_TAG}:${ch}" -p "user.err" -- "$*"
                    ;;
                # WARN and INFO cases removed - no syslog for them
            esac
        fi
    done
}

info()  { _info_warn_error INFO  "$@"; }
warn()  { _info_warn_error WARN  "$@"; }
error() { _info_warn_error ERROR "$@"; }

# --------------------------- command renaming --------------------------------
# Create wrappers if you want different names (set vars at top)
# e.g. LOG_CMD_INFO=note -> defines note(){ info "$@"; }
# (No-ops if names match defaults.)
_log_define_alias() {
    name="$1"; target="$2"
    [ "$name" = "$target" ] && return 0
    # shellcheck disable=SC3045
    eval "$name() { $target \"\$@\"; }"
}
_log_define_alias "$LOG_CMD_LOG"   log
_log_define_alias "$LOG_CMD_INFO"  info
_log_define_alias "$LOG_CMD_WARN"  warn
_log_define_alias "$LOG_CMD_ERROR" error

LOG_SETTINGS_LOADED=1
# ========================= end of log_settings ===============================
