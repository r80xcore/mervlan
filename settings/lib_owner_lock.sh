#!/bin/sh
# MerVLAN canonical v2 owner-record primitives.
#
# This library owns the generic single-owner lifecycle as well as the strict
# record contract.  Subsystems retain their own policy; in particular, a
# generic owner is never reclaimed merely because its heartbeat is old.

if [ -n "${LIB_OWNER_LOCK_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
LIB_OWNER_LOCK_LOADED=1

: "${MERV_BASE:=/jffs/addons/mervlan}"
[ -n "${LIB_IDENTITY_LOADED:-}" ] ||
  [ ! -r "$MERV_BASE/settings/lib_identity.sh" ] ||
  . "$MERV_BASE/settings/lib_identity.sh"

# Existing identity nonces use the accepted [A-Za-z0-9._:-] grammar and are
# bounded at 160 characters.  Keep that compatibility bound while allowing
# ample room for the five complete fields and their delimiters.
MERV_OWNER_V2_MAX_NONCE=160
MERV_OWNER_V2_MAX_RECORD=512
MERV_OWNER_V2_TMP_SEQ="${MERV_OWNER_V2_TMP_SEQ:-0}"

merv_owner_v2_positive_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$1" in
    *[1-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

merv_owner_v2_nonce_valid() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._:-]*) return 1 ;;
  esac
  [ "${#1}" -le "$MERV_OWNER_V2_MAX_NONCE" ]
}

# Resolve either a lock directory or an owner file.  Public callers normally
# pass the lock directory; accepting the file keeps parser tests and recovery
# diagnostics convenient without changing the persisted format.
merv_owner_v2_owner_file() {
  [ -n "${1:-}" ] || return 1
  [ -f "$1" ] && { printf '%s\n' "$1"; return 0; }
  [ -f "$1/owner" ] || return 1
  printf '%s\n' "$1/owner"
}

# merv_owner_v2_read <lock-dir|owner-file>
#
# Parse exactly five canonical key/value lines.  Parsed values are exported in
# MERV_OWNER_V2_* variables only after the complete record validates.  The
# file is treated as untrusted text and is never sourced or evaluated.
merv_owner_v2_read() {
  MERV_OWNER_V2_PID=''; MERV_OWNER_V2_PROC_START_TIME=''
  MERV_OWNER_V2_NONCE=''; MERV_OWNER_V2_CREATED=''; MERV_OWNER_V2_HEARTBEAT=''
  _mor_file=$(merv_owner_v2_owner_file "${1:-}") || return 1
  _mor_size=$(wc -c < "$_mor_file" 2>/dev/null | awk '{print $1}') || return 1
  case "$_mor_size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_mor_size" -gt 0 ] 2>/dev/null || return 1
  [ "$_mor_size" -le "$MERV_OWNER_V2_MAX_RECORD" ] 2>/dev/null || return 1
  # Every accepted byte is printable ASCII; newlines are consumed only as
  # record delimiters by the line reader below.  This rejects tabs, CR/NUL,
  # high-bit bytes, and other control data before any field is interpreted.
  LC_ALL=C grep -q '[^ -~]' "$_mor_file" 2>/dev/null && return 1

  _mor_pid=''; _mor_start=''; _mor_nonce=''; _mor_created=''; _mor_heartbeat=''
  _mor_seen_pid=0; _mor_seen_start=0; _mor_seen_nonce=0
  _mor_seen_created=0; _mor_seen_heartbeat=0; _mor_lines=0
  _mor_line=''
  while IFS= read -r _mor_line || [ -n "$_mor_line" ]; do
    _mor_lines=$((_mor_lines + 1))
    case "$_mor_line" in
      pid=*)
        [ "$_mor_seen_pid" -eq 0 ] || return 1
        _mor_seen_pid=1; _mor_pid=${_mor_line#pid=}
        merv_owner_v2_positive_uint "$_mor_pid" || return 1
        ;;
      proc_start_time=*)
        [ "$_mor_seen_start" -eq 0 ] || return 1
        _mor_seen_start=1; _mor_start=${_mor_line#proc_start_time=}
        merv_owner_v2_positive_uint "$_mor_start" || return 1
        ;;
      owner_nonce=*)
        [ "$_mor_seen_nonce" -eq 0 ] || return 1
        _mor_seen_nonce=1; _mor_nonce=${_mor_line#owner_nonce=}
        merv_owner_v2_nonce_valid "$_mor_nonce" || return 1
        ;;
      created=*)
        [ "$_mor_seen_created" -eq 0 ] || return 1
        _mor_seen_created=1; _mor_created=${_mor_line#created=}
        merv_owner_v2_positive_uint "$_mor_created" || return 1
        ;;
      heartbeat=*)
        [ "$_mor_seen_heartbeat" -eq 0 ] || return 1
        _mor_seen_heartbeat=1; _mor_heartbeat=${_mor_line#heartbeat=}
        merv_owner_v2_positive_uint "$_mor_heartbeat" || return 1
        ;;
      *)
        # Reject unknown keys, blank lines, whitespace, control bytes, and
        # shell syntax by construction of the five exact field patterns.
        return 1
        ;;
    esac
  done < "$_mor_file" || return 1

  [ "$_mor_lines" -eq 5 ] || return 1
  [ "$_mor_seen_pid" -eq 1 ] && [ "$_mor_seen_start" -eq 1 ] &&
    [ "$_mor_seen_nonce" -eq 1 ] && [ "$_mor_seen_created" -eq 1 ] &&
    [ "$_mor_seen_heartbeat" -eq 1 ] || return 1

  MERV_OWNER_V2_PID="$_mor_pid"
  MERV_OWNER_V2_PROC_START_TIME="$_mor_start"
  MERV_OWNER_V2_NONCE="$_mor_nonce"
  MERV_OWNER_V2_CREATED="$_mor_created"
  MERV_OWNER_V2_HEARTBEAT="$_mor_heartbeat"
  return 0
}

# merv_owner_v2_write_atomic <lock-dir> <pid> <proc-start> <nonce> <created> <heartbeat>
#
# The temporary file is created beside the authoritative owner and receives
# mode 0600 before same-directory mv makes it visible.  Validation occurs
# before publication and the exact temporary path is removed on every failure.
merv_owner_v2_write_atomic() {
  _mow_dir="${1:-}"; _mow_pid="${2:-}"; _mow_start="${3:-}"
  _mow_nonce="${4:-}"; _mow_created="${5:-}"; _mow_heartbeat="${6:-}"
  [ -d "$_mow_dir" ] || return 1
  merv_owner_v2_positive_uint "$_mow_pid" || return 1
  merv_owner_v2_positive_uint "$_mow_start" || return 1
  merv_owner_v2_nonce_valid "$_mow_nonce" || return 1
  merv_owner_v2_positive_uint "$_mow_created" || return 1
  merv_owner_v2_positive_uint "$_mow_heartbeat" || return 1

  case "$MERV_OWNER_V2_TMP_SEQ" in ''|*[!0-9]*) MERV_OWNER_V2_TMP_SEQ=0 ;; esac
  MERV_OWNER_V2_TMP_SEQ=$((MERV_OWNER_V2_TMP_SEQ + 1))
  _mow_now=$(date +%s 2>/dev/null || printf '0')
  case "$_mow_now" in ''|*[!0-9]*) _mow_now=0 ;; esac
  _mow_tmp="$_mow_dir/.owner.tmp.$$.$MERV_OWNER_V2_TMP_SEQ.$_mow_now.$_mow_nonce"
  while [ -e "$_mow_tmp" ]; do
    MERV_OWNER_V2_TMP_SEQ=$((MERV_OWNER_V2_TMP_SEQ + 1))
    _mow_tmp="$_mow_dir/.owner.tmp.$$.$MERV_OWNER_V2_TMP_SEQ.$_mow_now.$_mow_nonce"
  done

  merv_owner_lock_fault owner-temp-write && return 1
  ( umask 077
    printf 'pid=%s\nproc_start_time=%s\nowner_nonce=%s\ncreated=%s\nheartbeat=%s\n' \
      "$_mow_pid" "$_mow_start" "$_mow_nonce" "$_mow_created" "$_mow_heartbeat" > "$_mow_tmp"
  ) 2>/dev/null || { rm -f "$_mow_tmp" 2>/dev/null; return 1; }
  merv_owner_lock_fault owner-permissions && {
    rm -f "$_mow_tmp" 2>/dev/null
    return 1
  }
  chmod 600 "$_mow_tmp" 2>/dev/null || {
    rm -f "$_mow_tmp" 2>/dev/null
    return 1
  }
  merv_owner_v2_read "$_mow_tmp" 2>/dev/null || {
    rm -f "$_mow_tmp" 2>/dev/null
    return 1
  }
  merv_owner_lock_fault owner-rename && {
    rm -f "$_mow_tmp" 2>/dev/null
    return 1
  }
  mv -f "$_mow_tmp" "$_mow_dir/owner" 2>/dev/null || {
    rm -f "$_mow_tmp" 2>/dev/null
    return 1
  }
  return 0
}

# merv_owner_v2_matches <lock-dir|owner-file> <pid> <proc-start> <nonce> [proc-root]
# Exact record matching is followed by a live PID/start check.  The optional
# proc-root is used by isolated self-tests; normal callers use /proc.
merv_owner_v2_matches() {
  _mom_file="${1:-}"; _mom_pid="${2:-}"; _mom_start="${3:-}"
  _mom_nonce="${4:-}"; _mom_proc="${5:-/proc}"
  merv_owner_v2_positive_uint "$_mom_pid" || return 1
  merv_owner_v2_positive_uint "$_mom_start" || return 1
  merv_owner_v2_nonce_valid "$_mom_nonce" || return 1
  merv_owner_v2_read "$_mom_file" || return 1
  [ "$MERV_OWNER_V2_PID" = "$_mom_pid" ] &&
    [ "$MERV_OWNER_V2_PROC_START_TIME" = "$_mom_start" ] &&
    [ "$MERV_OWNER_V2_NONCE" = "$_mom_nonce" ] || return 1
  type merv_identity_matches >/dev/null 2>&1 || return 1
  merv_identity_matches "$_mom_pid" "$_mom_start" "$_mom_proc"
}

# Generic lifecycle ---------------------------------------------------------
#
# The owner file above is the only authoritative ownership commitment.
# Sidecars are retained temporarily for compatibility with already-synced
# readers, but are never parsed to decide liveness or reclaimability.
: "${MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC:=10}"
MERV_OWNER_LOCK_TMP_SEQ="${MERV_OWNER_LOCK_TMP_SEQ:-0}"

merv_owner_lock_fault() {
  _molf_stage="${1:-}"
  [ -n "$_molf_stage" ] || return 1
  case ",${MERV_OWNER_LOCK_FAULT:-}," in *",$_molf_stage,"*) return 0 ;; esac
  return 1
}

merv_owner_lock_now() {
  _moln_now=$(date +%s 2>/dev/null || printf '')
  merv_owner_v2_positive_uint "$_moln_now" || return 1
  printf '%s\n' "$_moln_now"
}

merv_owner_lock_tmp_next() {
  case "$MERV_OWNER_LOCK_TMP_SEQ" in ''|*[!0-9]*) MERV_OWNER_LOCK_TMP_SEQ=0 ;; esac
  MERV_OWNER_LOCK_TMP_SEQ=$((MERV_OWNER_LOCK_TMP_SEQ + 1))
  _moltn_now=$(merv_owner_lock_now) || return 1
  MERV_OWNER_LOCK_TMP_SUFFIX="$MERV_OWNER_LOCK_TMP_SEQ.$_moltn_now"
  return 0
}

# merv_owner_lock_compat_write <lock-dir> <field> <value>
#
# Compatibility sidecars are individually published with a same-directory
# rename.  They are deliberately written before the authoritative owner so a
# failed compatibility publication can still be cleaned as an uncommitted
# claim.  The deterministic fault points only make acquisition fail closed.
merv_owner_lock_compat_write() {
  _molcw_lock="${1:-}"; _molcw_field="${2:-}"; _molcw_value="${3:-}"
  [ -d "$_molcw_lock" ] || return 1
  case "$_molcw_field" in
    pid|proc_start_time|owner_nonce|created|heartbeat) ;;
    *) return 1 ;;
  esac
  merv_owner_lock_fault compat-write && return 1
  merv_owner_lock_tmp_next || return 1
  _molcw_tmp="$_molcw_lock/.${_molcw_field}.tmp.$$.$MERV_OWNER_LOCK_TMP_SUFFIX"
  ( umask 077
    printf '%s\n' "$_molcw_value" > "$_molcw_tmp"
  ) 2>/dev/null || { rm -f "$_molcw_tmp" 2>/dev/null; return 1; }
  chmod 600 "$_molcw_tmp" 2>/dev/null || { rm -f "$_molcw_tmp" 2>/dev/null; return 1; }
  merv_owner_lock_fault compat-rename && {
    rm -f "$_molcw_tmp" 2>/dev/null
    return 1
  }
  mv -f "$_molcw_tmp" "$_molcw_lock/$_molcw_field" 2>/dev/null || {
    rm -f "$_molcw_tmp" 2>/dev/null
    return 1
  }
  return 0
}

merv_owner_lock_compat_publish() {
  _molcp_lock="${1:-}"; _molcp_pid="${2:-}"; _molcp_start="${3:-}"
  _molcp_nonce="${4:-}"; _molcp_created="${5:-}"; _molcp_heartbeat="${6:-}"
  merv_owner_lock_compat_write "$_molcp_lock" pid "$_molcp_pid" || return 1
  merv_owner_lock_compat_write "$_molcp_lock" proc_start_time "$_molcp_start" || return 1
  merv_owner_lock_compat_write "$_molcp_lock" owner_nonce "$_molcp_nonce" || return 1
  merv_owner_lock_compat_write "$_molcp_lock" created "$_molcp_created" || return 1
  merv_owner_lock_compat_write "$_molcp_lock" heartbeat "$_molcp_heartbeat"
}

# Return success only when the lock path is authoritatively absent.  `-e` is
# deliberately not used here because it follows symlinks and would turn a
# dangling symlink into an absent path.
merv_owner_lock_absent_authoritative() {
  _molaa_lock="${1:-}"
  [ -n "$_molaa_lock" ] || return 1
  ls -ld "$_molaa_lock" >/dev/null 2>&1 && return 1
  _molaa_parent=${_molaa_lock%/*}
  [ -d "$_molaa_parent" ] && [ -r "$_molaa_parent" ] && [ -x "$_molaa_parent" ]
}

# Read and validate a directory mtime without following a symlink. Keeping the
# timestamp boundary in one helper also gives deterministic tests a narrow seam
# without replacing the owner-state classifier itself.
merv_owner_lock_timestamp() {
  _molt_path="${1:-}"
  [ -d "$_molt_path" ] || return 1
  [ ! -L "$_molt_path" ] || return 1
  _molt_epoch=$(date -r "$_molt_path" +%s 2>/dev/null || printf '')
  merv_owner_v2_positive_uint "$_molt_epoch" || return 1
  printf '%s\n' "$_molt_epoch"
}

merv_owner_lock_quarantine_restore() {
  _molqr_src="${1:-}"; _molqr_lock="${2:-}"
  [ -e "$_molqr_src" ] || [ -L "$_molqr_src" ] || return 1
  # Never overwrite a replacement that appeared while the old claim was in
  # quarantine.  In that case the old object remains retained for inspection.
  if ls -ld "$_molqr_lock" >/dev/null 2>&1 || [ -L "$_molqr_lock" ]; then
    return 1
  fi
  mv "$_molqr_src" "$_molqr_lock" 2>/dev/null
}

# Move only the exact lock directory into a sibling quarantine name.  A move is
# preferred to deletion so a failed acquisition remains inspectable.  The
# source is snapshotted immediately before the rename and the moved object is
# verified afterwards; a replacement is restored when possible and otherwise
# retained beside the new owner.
merv_owner_lock_quarantine() {
  _molq_lock="${1:-}"; _molq_reason="${2:-quarantine}"
  _molq_expected_pid="${3:-}"; _molq_expected_start="${4:-}"
  _molq_expected_nonce="${5:-}"; _molq_expected_created="${6:-}"
  _molq_expected_heartbeat="${7:-}"
  _molq_expected_contract=0
  if [ -n "$_molq_expected_pid" ] && [ -n "$_molq_expected_start" ] &&
     [ -n "$_molq_expected_nonce" ] && [ -n "$_molq_expected_created" ] &&
     [ -n "$_molq_expected_heartbeat" ]; then
    _molq_expected_contract=1
  fi
  # Re-inspect the exact path without following it immediately before the
  # rename.  A stale classification is only a hint: a release or a new owner
  # may have changed the path since the caller observed it.
  ls -ld "$_molq_lock" >/dev/null 2>&1 || return 2
  [ ! -L "$_molq_lock" ] || return 1
  [ -d "$_molq_lock" ] || return 1
  if [ -e "$_molq_lock/owner" ] || [ -L "$_molq_lock/owner" ]; then
    [ ! -L "$_molq_lock/owner" ] || return 1
  fi
  _molq_expected_owner=0
  if [ -e "$_molq_lock/owner" ]; then
    merv_owner_v2_read "$_molq_lock" 2>/dev/null || return 1
    _molq_expected_owner=1
    if [ "$_molq_expected_contract" -eq 1 ]; then
      [ "$MERV_OWNER_V2_PID" = "$_molq_expected_pid" ] || return 1
      [ "$MERV_OWNER_V2_PROC_START_TIME" = "$_molq_expected_start" ] || return 1
      [ "$MERV_OWNER_V2_NONCE" = "$_molq_expected_nonce" ] || return 1
      [ "$MERV_OWNER_V2_CREATED" = "$_molq_expected_created" ] || return 1
      [ "$MERV_OWNER_V2_HEARTBEAT" = "$_molq_expected_heartbeat" ] || return 1
    else
      _molq_expected_pid="$MERV_OWNER_V2_PID"
      _molq_expected_start="$MERV_OWNER_V2_PROC_START_TIME"
      _molq_expected_nonce="$MERV_OWNER_V2_NONCE"
      _molq_expected_created="$MERV_OWNER_V2_CREATED"
      _molq_expected_heartbeat="$MERV_OWNER_V2_HEARTBEAT"
    fi
  fi
  if [ "$_molq_expected_owner" -eq 1 ]; then
    _molq_state=$(merv_owner_lock_state "$_molq_lock" "${MERV_OWNER_LOCK_PROC_ROOT:-/proc}" 2>/dev/null || printf unknown)
    case "$_molq_reason:$_molq_state" in
      dead:dead|dead:reused|reused:dead|reused:reused) ;;
      *) return 1 ;;
    esac
  fi
  _molq_parent=${_molq_lock%/*}; _molq_base=${_molq_lock##*/}
  [ -n "$_molq_parent" ] && [ -n "$_molq_base" ] || return 1
  merv_owner_lock_tmp_next || return 1
  _molq_try=0
  while [ "$_molq_try" -lt 8 ]; do
    _molq_dest="$_molq_parent/.${_molq_base}.${_molq_reason}.$$.${MERV_OWNER_LOCK_TMP_SUFFIX}.${_molq_try}"
    # Test-only deterministic race gate. Production has no hook unless both a
    # named fault and an explicitly defined function are present.
    if merv_owner_lock_fault quarantine-window &&
       type merv_owner_lock_quarantine_hook >/dev/null 2>&1; then
      merv_owner_lock_quarantine_hook "$_molq_lock" "$_molq_dest" || return 1
    fi
    if mv "$_molq_lock" "$_molq_dest" 2>/dev/null; then
      _molq_valid=1
      [ ! -L "$_molq_dest" ] || _molq_valid=0
      [ -d "$_molq_dest" ] || _molq_valid=0
      if [ "$_molq_valid" -eq 1 ] && [ "$_molq_expected_owner" -eq 1 ]; then
        [ ! -L "$_molq_dest/owner" ] || _molq_valid=0
        if [ "$_molq_valid" -eq 1 ] && merv_owner_v2_read "$_molq_dest" 2>/dev/null; then
          [ "$MERV_OWNER_V2_PID" = "$_molq_expected_pid" ] || _molq_valid=0
          [ "$MERV_OWNER_V2_PROC_START_TIME" = "$_molq_expected_start" ] || _molq_valid=0
          [ "$MERV_OWNER_V2_NONCE" = "$_molq_expected_nonce" ] || _molq_valid=0
          [ "$MERV_OWNER_V2_CREATED" = "$_molq_expected_created" ] || _molq_valid=0
          [ "$MERV_OWNER_V2_HEARTBEAT" = "$_molq_expected_heartbeat" ] || _molq_valid=0
        else
          _molq_valid=0
        fi
        if [ "$_molq_valid" -eq 1 ]; then
          _molq_state=$(merv_owner_lock_state "$_molq_dest" "${MERV_OWNER_LOCK_PROC_ROOT:-/proc}" 2>/dev/null || printf unknown)
          case "$_molq_state" in
            dead|reused) ;;
            *) _molq_valid=0 ;;
          esac
        fi
      elif [ "$_molq_valid" -eq 1 ] && [ -e "$_molq_dest/owner" -o -L "$_molq_dest/owner" ]; then
        _molq_valid=0
      fi
      [ "$_molq_valid" -eq 1 ] && return 0
      # A changed object was moved. Restore it only into a still-absent path;
      # never overwrite a successor owner. Failure leaves both objects for
      # fail-closed reconciliation.
      merv_owner_lock_quarantine_restore "$_molq_dest" "$_molq_lock" || :
      return 1
    fi
    if merv_owner_lock_absent_authoritative "$_molq_lock"; then
      # The contender released between observation and rename.  The caller may
      # retry, but only after this non-following absence reinspection succeeds.
      return 2
    fi
    # A replacement or obstruction now owns the path. Do not retry a blind mv.
    [ ! -L "$_molq_lock" ] && [ -d "$_molq_lock" ] || return 1
    if [ "$_molq_expected_owner" -eq 1 ]; then
      [ ! -L "$_molq_lock/owner" ] || return 1
      merv_owner_v2_read "$_molq_lock" 2>/dev/null || return 1
      [ "$MERV_OWNER_V2_PID" = "$_molq_expected_pid" ] || return 1
      [ "$MERV_OWNER_V2_PROC_START_TIME" = "$_molq_expected_start" ] || return 1
      [ "$MERV_OWNER_V2_NONCE" = "$_molq_expected_nonce" ] || return 1
      [ "$MERV_OWNER_V2_CREATED" = "$_molq_expected_created" ] || return 1
      [ "$MERV_OWNER_V2_HEARTBEAT" = "$_molq_expected_heartbeat" ] || return 1
    elif [ -e "$_molq_lock/owner" ] || [ -L "$_molq_lock/owner" ]; then
      return 1
    fi
    _molq_try=$((_molq_try + 1))
  done
  return 1
}

# Remove the exact, still-uncommitted claim made by this acquisition.  If a
# directory obstruction prevents rmdir, quarantine that exact claim instead;
# no broad temporary-file glob is used.
merv_owner_lock_cleanup_claim() {
  _molcc_lock="${1:-}"
  [ -d "$_molcc_lock" ] || return 0
  rm -f "$_molcc_lock/owner" "$_molcc_lock/pid" \
    "$_molcc_lock/proc_start_time" "$_molcc_lock/owner_nonce" \
    "$_molcc_lock/created" "$_molcc_lock/heartbeat" 2>/dev/null || return 1
  if ! merv_owner_lock_fault cleanup-rmdir && rmdir "$_molcc_lock" 2>/dev/null; then
    return 0
  fi
  merv_owner_lock_quarantine "$_molcc_lock" acquire-failed
}

# merv_owner_lock_state_emit <state>
# Keep the last direct state observation available to callers that must retain
# its identity snapshot without using command substitution (which runs the
# observer in a subshell and loses parsed fields).
merv_owner_lock_state_emit() {
  MERV_OWNER_LOCK_STATE="$1"
  printf '%s' "$1"
}

# merv_owner_lock_state <lock-dir> [proc-root]
#
# Prints one of: absent, live, dead, reused, incomplete-grace,
# incomplete-expired, incomplete-unknown, malformed, or unknown.  The caller
# may use the distinctions for diagnostics, but generic acquisition reclaims
# only complete owners proven dead or PID-reused.  A non-directory object at
# the lock path is never equivalent to absence.
merv_owner_lock_state() {
  _mols_lock="${1:-}"; _mols_proc="${2:-${MERV_OWNER_LOCK_PROC_ROOT:-/proc}}"
  MERV_OWNER_LOCK_STATE=unknown
  [ -n "$_mols_lock" ] || { merv_owner_lock_state_emit unknown; return 1; }
  # Probe the lock path itself without following it. Owner-lock state must
  # distinguish true absence from fail-closed obstructions such as regular
  # files and dangling symlinks; `ls -ld` preserves that distinction.
  if ! ls -ld "$_mols_lock" >/dev/null 2>&1; then
    _mols_parent=${_mols_lock%/*}
    if [ -d "$_mols_parent" ] && [ -r "$_mols_parent" ] && [ -x "$_mols_parent" ]; then
      merv_owner_lock_state_emit absent
    else
      merv_owner_lock_state_emit unknown
    fi
    return 0
  fi
  if [ -L "$_mols_lock" ] || [ ! -d "$_mols_lock" ]; then
    # The initial ls succeeded, but the object changed during observation. A
    # second non-following probe distinguishes a real release from a file or
    # symlink replacement; only the former is equivalent to absence.
    if merv_owner_lock_absent_authoritative "$_mols_lock"; then
      merv_owner_lock_state_emit absent
    else
      merv_owner_lock_state_emit unknown
    fi
    return 0
  fi
  if [ -e "$_mols_lock/owner" ] || [ -L "$_mols_lock/owner" ]; then
    [ ! -L "$_mols_lock/owner" ] || { merv_owner_lock_state_emit unknown; return 0; }
    [ -r "$_mols_lock/owner" ] || { merv_owner_lock_state_emit unknown; return 0; }
    merv_owner_v2_read "$_mols_lock" 2>/dev/null || { merv_owner_lock_state_emit malformed; return 0; }
    type merv_identity_proc_start >/dev/null 2>&1 || { merv_owner_lock_state_emit unknown; return 0; }
    [ -d "$_mols_proc" ] && [ -r "$_mols_proc" ] || { merv_owner_lock_state_emit unknown; return 0; }
    _mols_actual=$(merv_identity_proc_start "$MERV_OWNER_V2_PID" "$_mols_proc" 2>/dev/null)
    if merv_owner_v2_positive_uint "$_mols_actual"; then
      if [ "$_mols_actual" != "$MERV_OWNER_V2_PROC_START_TIME" ]; then
        merv_owner_lock_state_emit reused
      elif [ "$_mols_proc" != /proc ]; then
        merv_owner_lock_state_emit live
      elif kill -0 "$MERV_OWNER_V2_PID" 2>/dev/null; then
        merv_owner_lock_state_emit live
      else
        # A readable stat with an unprobeable process could be a permissions
        # boundary or an exit race; neither proves a reclaimable dead owner.
        merv_owner_lock_state_emit unknown
      fi
      return 0
    fi
    if [ -e "$_mols_proc/$MERV_OWNER_V2_PID/stat" ]; then
      merv_owner_lock_state_emit unknown
    else
      merv_owner_lock_state_emit dead
    fi
    return 0
  fi
  _mols_now=$(merv_owner_lock_now 2>/dev/null) || { merv_owner_lock_state_emit incomplete-unknown; return 0; }
  _mols_mtime=$(merv_owner_lock_timestamp "$_mols_lock" 2>/dev/null) || {
    if merv_owner_lock_absent_authoritative "$_mols_lock"; then
      merv_owner_lock_state_emit absent
    else
      merv_owner_lock_state_emit incomplete-unknown
    fi
    return 0
  }
  case "${MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC:-}" in ''|*[!0-9]*) merv_owner_lock_state_emit incomplete-unknown; return 0 ;; esac
  [ "$_mols_now" -ge "$_mols_mtime" ] 2>/dev/null || { merv_owner_lock_state_emit incomplete-unknown; return 0; }
  _mols_age=$((_mols_now - _mols_mtime))
  if [ "$_mols_age" -le "$MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC" ]; then
    merv_owner_lock_state_emit incomplete-grace
  else
    merv_owner_lock_state_emit incomplete-expired
  fi
}

# merv_owner_lock_acquire <lock-dir> [legacy-stale-sec] [max-retries] [label]
#
# The second parameter is retained for caller compatibility only.  Complete
# owners are assessed by process identity, never age.  max-retries bounds waits
# for a live owner or a verified in-progress publication.
merv_owner_lock_acquire() {
  _mola_lock="${1:-}"; _mola_unused_stale="${2:-}"; _mola_max="${3:-30}"
  _mola_label="${4:-${1##*/}}"; _mola_attempt=0
  _mola_proc="${MERV_OWNER_LOCK_PROC_ROOT:-/proc}"
  MERV_LOCK_NONCE=''; MERV_LOCK_START=''
  [ -n "$_mola_lock" ] || return 1
  case "$_mola_max" in ''|*[!0-9]*) _mola_max=30 ;; esac
  _mola_parent=${_mola_lock%/*}
  [ -n "$_mola_parent" ] && [ "$_mola_parent" != "$_mola_lock" ] || return 1
  merv_owner_lock_fault identity && return 1
  _mola_start=$(merv_identity_current_start "$_mola_proc" 2>/dev/null) || return 1
  merv_owner_v2_positive_uint "$_mola_start" || return 1
  merv_identity_nonce_next || return 1
  _mola_nonce="$MERV_IDENTITY_NONCE"
  merv_owner_v2_nonce_valid "$_mola_nonce" || return 1
  mkdir -p "$_mola_parent" 2>/dev/null || return 1
  while ! mkdir "$_mola_lock" 2>/dev/null; do
    # Keep the parsed owner identity in this shell. Command substitution would
    # hide it and allow quarantine to snapshot a replacement owner instead of
    # the contender that was classified dead/reused.
    merv_owner_lock_state "$_mola_lock" >/dev/null 2>&1
    _mola_state="$MERV_OWNER_LOCK_STATE"
    case "$_mola_state" in
      dead|reused)
        merv_owner_lock_quarantine "$_mola_lock" "$_mola_state" \
          "$MERV_OWNER_V2_PID" "$MERV_OWNER_V2_PROC_START_TIME" \
          "$MERV_OWNER_V2_NONCE" "$MERV_OWNER_V2_CREATED" \
          "$MERV_OWNER_V2_HEARTBEAT"
        _mola_reclaim_rc=$?
        case "$_mola_reclaim_rc" in
          0) ;;
          2) continue ;;
          *) return 1 ;;
        esac
        ;;
      absent)
        # A concurrent release won the race; retry only after an authoritative
        # non-following absence reinspection of the exact path.
        merv_owner_lock_absent_authoritative "$_mola_lock" || return 1
        continue
        ;;
      live|incomplete-grace)
        [ "$_mola_attempt" -lt "$_mola_max" ] || return 1
        sleep 2
        _mola_attempt=$((_mola_attempt + 1))
        ;;
      incomplete-expired|incomplete-unknown|malformed|unknown|*)
        return 1
        ;;
    esac
  done
  _mola_now=$(merv_owner_lock_now) || { merv_owner_lock_cleanup_claim "$_mola_lock"; return 1; }
  merv_owner_lock_compat_publish "$_mola_lock" "$$" "$_mola_start" "$_mola_nonce" \
    "$_mola_now" "$_mola_now" || { merv_owner_lock_cleanup_claim "$_mola_lock"; return 1; }
  merv_owner_v2_write_atomic "$_mola_lock" "$$" "$_mola_start" "$_mola_nonce" \
    "$_mola_now" "$_mola_now" || { merv_owner_lock_cleanup_claim "$_mola_lock"; return 1; }
  MERV_LOCK_NONCE="$_mola_nonce"
  MERV_LOCK_START="$_mola_start"
  return 0
}

# merv_owner_lock_owner_matches <lock-dir> <nonce> [proc-root]
merv_owner_lock_owner_matches() {
  _molom_lock="${1:-}"; _molom_nonce="${2:-}"
  _molom_proc="${3:-${MERV_OWNER_LOCK_PROC_ROOT:-/proc}}"
  _molom_start=$(merv_identity_current_start "$_molom_proc" 2>/dev/null) || return 1
  merv_owner_v2_matches "$_molom_lock" "$$" "$_molom_start" "$_molom_nonce" "$_molom_proc"
}

# merv_owner_lock_release <lock-dir> [nonce]
#
# An owner is removed only after its PID, start time, and nonce all match the
# current process.  If the directory cannot be removed, restore the complete
# authoritative owner atomically and leave a recoverable, failing lock behind.
merv_owner_lock_release() {
  _molr_lock="${1:-}"; _molr_nonce="${2:-${MERV_LOCK_NONCE:-}}"
  [ -n "$_molr_lock" ] || return 0
  [ -d "$_molr_lock" ] || return 0
  merv_owner_lock_owner_matches "$_molr_lock" "$_molr_nonce" || return 1
  _molr_parent=${_molr_lock%/*}; _molr_base=${_molr_lock##*/}
  merv_owner_lock_tmp_next || return 1
  _molr_restore="$_molr_parent/.${_molr_base}.owner.restore.$$.$MERV_OWNER_LOCK_TMP_SUFFIX"
  cp -p "$_molr_lock/owner" "$_molr_restore" 2>/dev/null || return 1
  merv_owner_v2_read "$_molr_restore" 2>/dev/null || { rm -f "$_molr_restore" 2>/dev/null; return 1; }
  rm -f "$_molr_lock/owner" "$_molr_lock/pid" \
    "$_molr_lock/proc_start_time" "$_molr_lock/owner_nonce" \
    "$_molr_lock/created" "$_molr_lock/heartbeat" 2>/dev/null || {
    mv -f "$_molr_restore" "$_molr_lock/owner" 2>/dev/null || :
    return 1
  }
  if merv_owner_lock_fault release-rmdir || ! rmdir "$_molr_lock" 2>/dev/null; then
    mv -f "$_molr_restore" "$_molr_lock/owner" 2>/dev/null || return 1
    return 1
  fi
  rm -f "$_molr_restore" 2>/dev/null || :
  MERV_LOCK_NONCE=''; MERV_LOCK_START=''
  return 0
}
