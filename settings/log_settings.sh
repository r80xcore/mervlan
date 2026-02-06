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
#               - File: log_settings.sh || version="0.45"                      #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Define logging settings and environment variables used         #
#               throughout the MerVLAN addon. Enables colored output,          #
#               per-channel log files, and syslog integration.                 #
# ──────────────────────────────────────────────────────────────────────────── #
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
# Trims a single log file to LOG_MAX_LINES (keeps the newest lines).
# Usage: _log_trim_file "/path/to/logfile"
_log_trim_file() {
    _ltf_file="$1"
    [ -z "$_ltf_file" ] && return 0
    [ -f "$_ltf_file" ] || return 0
    [ "${LOG_MAX_LINES:-0}" -gt 0 ] 2>/dev/null || return 0

    _ltf_count=$(wc -l < "$_ltf_file" 2>/dev/null) || return 0
    _ltf_count=${_ltf_count##* }  # strip leading spaces from wc output
    [ "$_ltf_count" -le "$LOG_MAX_LINES" ] && return 0

    # Keep last LOG_MAX_LINES lines
    tail -n "$LOG_MAX_LINES" "$_ltf_file" > "$_ltf_file.tmp" 2>/dev/null && \
        mv "$_ltf_file.tmp" "$_ltf_file" 2>/dev/null || \
        rm -f "$_ltf_file.tmp" 2>/dev/null
}

# Trim all known log channels. Call on boot or periodically.
# Usage: log_trim_all
log_trim_all() {
    for _lta_ch in cli vlan; do
        _lta_f=$(_log_path_for_channel "$_lta_ch")
        _log_trim_file "$_lta_f"
    done
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