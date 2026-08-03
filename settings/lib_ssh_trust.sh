#!/bin/sh
# MerVLAN main-router-owned SSH host-key trust contract.
#
# The browser may request a challenge or submit an accept/reject decision, but
# it never supplies the key, fingerprint, endpoint, or node identity that is
# persisted here.  Probe data is produced by a backend capability adapter and
# is re-probed immediately before enrollment.  Unknown capability, malformed
# state, stale challenges, endpoint changes, and key changes all fail closed.

[ -n "${LIB_SSH_TRUST_LOADED:-}" ] && return 0 2>/dev/null
LIB_SSH_TRUST_LOADED=1

: "${MERV_STATE_ROOT:=/jffs/addons/mervlan_state}"
: "${MERV_SSH_TRUST_ROOT:=$MERV_STATE_ROOT/ssh_trust}"
: "${MERV_SSH_TRUST_FILE:=$MERV_SSH_TRUST_ROOT/known_hosts.v1}"
: "${MERV_SSH_TRUST_PENDING_ROOT:=$MERV_SSH_TRUST_ROOT/pending}"
: "${MERV_SSH_TRUST_REQUESTS_ROOT:=$MERV_SSH_TRUST_ROOT/requests}"
: "${MERV_SSH_TRUST_STAGING_ROOT:=$MERV_SSH_TRUST_ROOT/staging}"
: "${MERV_SSH_TRUST_QUARANTINE_ROOT:=$MERV_SSH_TRUST_ROOT/quarantine}"
: "${MERV_SSH_TRUST_LOCK_PATH:=$MERV_SSH_TRUST_ROOT/state.lock}"
: "${MERV_SSH_TRUST_TTL_SEC:=31536000}"
: "${MERV_SSH_TRUST_PENDING_TTL_SEC:=300}"
: "${MERV_SSH_TRUST_RETENTION_SEC:=86400}"
: "${MERV_SSH_TRUST_MAX_PENDING:=64}"
: "${MERV_SSH_TRUST_MAX_STAGING:=64}"
: "${MERV_SSH_TRUST_MAX_QUARANTINE:=64}"
: "${MERV_SSH_TRUST_MAX_RECORDS:=64}"
: "${MERV_SSH_HOSTKEY_PROBE_CMD:=$MERV_BASE/functions/ssh_hostkey_probe.sh}"
: "${MERV_SSH_CAPABILITY_PROVEN:=1}"
: "${MERV_SSH_TRUST_TEST_MODE:=0}"

if ! type merv_has >/dev/null 2>&1; then
  merv_has() { type "$1" >/dev/null 2>&1; }
fi

merv_ssh_trust_root_valid() {
  _mst_root="${MERV_SSH_TRUST_ROOT:-}"
  [ -n "$_mst_root" ] || return 1
  case "$_mst_root" in *..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
  if [ "${MERV_SSH_TRUST_TEST_MODE:-0}" = "1" ]; then
    case "$_mst_root" in /tmp/mervlan_tmp/selftest.*|/tmp/mervlan_tmp/selftest.*/*) return 0 ;; esac
    return 1
  fi
  case "$_mst_root" in
    /jffs/addons/mervlan_state/ssh_trust|/jffs/addons/mervlan_state/ssh_trust/*) return 0 ;;
    "$MERV_STATE_ROOT/ssh_trust"|"$MERV_STATE_ROOT/ssh_trust"/*) return 0 ;;
    *) return 1 ;;
  esac
}

merv_ssh_trust_path_valid() {
  _mst_path="$1"
  merv_ssh_trust_root_valid || return 1
  case "$_mst_path" in
    "$MERV_SSH_TRUST_ROOT"|"$MERV_SSH_TRUST_ROOT"/*) ;;
    *) return 1 ;;
  esac
  case "$_mst_path" in *..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
}

merv_ssh_trust_now() {
  date +%s 2>/dev/null || printf '0\n'
}

merv_ssh_trust_uint() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
}

# Full trust-database validation derives every pinned host fingerprint. That is
# deliberately strict, but repeating the same cryptographic work before every
# bounded SSH call made a healthy node sync spend most of its time in local
# validation. Cache only a SHA-256 change stamp for an unchanged database.
# A current stamped record is still shape-checked, bound to its endpoint and
# expiry-checked immediately before use; any file change, enroll, or revoke
# discards both caches before a connection can proceed.
merv_ssh_trust_file_digest() {
  _mstfd_file="${1:-$MERV_SSH_TRUST_FILE}"
  merv_ssh_trust_path_valid "$_mstfd_file" || return 1
  [ -f "$_mstfd_file" ] || return 1
  merv_has openssl || return 1
  _mstfd_line=$(openssl dgst -sha256 "$_mstfd_file" 2>/dev/null) || return 1
  _mstfd_digest=${_mstfd_line##* }
  printf '%s\n' "$_mstfd_digest" | grep -Eq '^[0-9A-Fa-f]{64}$' || return 1
  printf 'sha256:%s\n' "$_mstfd_digest"
}

# A synchronization worker can spawn a short-lived child for each independent
# SSH command.  Carry the one already-validated pinned record to those children
# only while the exact trust-file digest still matches.  This is a performance
# cache, not a trust decision: a cache hit still validates the record shape,
# endpoint identity, expiry, and a fresh digest immediately before use.
merv_ssh_trust_find_cache_clear() {
  unset MERV_SSH_TRUST_FIND_CACHE_NODE MERV_SSH_TRUST_FIND_CACHE_DIGEST
  unset MERV_SSH_TRUST_FIND_CACHE_SLOT MERV_SSH_TRUST_FIND_CACHE_MAC
  unset MERV_SSH_TRUST_FIND_CACHE_HOST MERV_SSH_TRUST_FIND_CACHE_PORT
  unset MERV_SSH_TRUST_FIND_CACHE_ALGORITHM MERV_SSH_TRUST_FIND_CACHE_PUBLIC_KEY
  unset MERV_SSH_TRUST_FIND_CACHE_FINGERPRINT MERV_SSH_TRUST_FIND_CACHE_CREATED
  unset MERV_SSH_TRUST_FIND_CACHE_UPDATED
}

merv_ssh_trust_find_cache_store() {
  _mstfcs_node="$1" _mstfcs_digest="$2"
  case "$_mstfcs_digest" in sha256:[0-9A-Fa-f][0-9A-Fa-f]*) ;; *) return 1 ;; esac
  [ "$SSH_TRUST_NODE" = "$_mstfcs_node" ] || return 1
  MERV_SSH_TRUST_FIND_CACHE_NODE="$SSH_TRUST_NODE"
  MERV_SSH_TRUST_FIND_CACHE_DIGEST="$_mstfcs_digest"
  MERV_SSH_TRUST_FIND_CACHE_SLOT="$SSH_TRUST_SLOT"
  MERV_SSH_TRUST_FIND_CACHE_MAC="$SSH_TRUST_MAC"
  MERV_SSH_TRUST_FIND_CACHE_HOST="$SSH_TRUST_HOST"
  MERV_SSH_TRUST_FIND_CACHE_PORT="$SSH_TRUST_PORT"
  MERV_SSH_TRUST_FIND_CACHE_ALGORITHM="$SSH_TRUST_ALGORITHM"
  MERV_SSH_TRUST_FIND_CACHE_PUBLIC_KEY="$SSH_TRUST_PUBLIC_KEY"
  MERV_SSH_TRUST_FIND_CACHE_FINGERPRINT="$SSH_TRUST_FINGERPRINT"
  MERV_SSH_TRUST_FIND_CACHE_CREATED="$SSH_TRUST_CREATED"
  MERV_SSH_TRUST_FIND_CACHE_UPDATED="$SSH_TRUST_UPDATED"
  export MERV_SSH_TRUST_FIND_CACHE_NODE MERV_SSH_TRUST_FIND_CACHE_DIGEST
  export MERV_SSH_TRUST_FIND_CACHE_SLOT MERV_SSH_TRUST_FIND_CACHE_MAC
  export MERV_SSH_TRUST_FIND_CACHE_HOST MERV_SSH_TRUST_FIND_CACHE_PORT
  export MERV_SSH_TRUST_FIND_CACHE_ALGORITHM MERV_SSH_TRUST_FIND_CACHE_PUBLIC_KEY
  export MERV_SSH_TRUST_FIND_CACHE_FINGERPRINT MERV_SSH_TRUST_FIND_CACHE_CREATED
  export MERV_SSH_TRUST_FIND_CACHE_UPDATED
}

merv_ssh_trust_find_cache_restore() {
  _mstfcr_node="$1" _mstfcr_digest="$2"
  [ "${MERV_SSH_TRUST_FIND_CACHE_NODE:-}" = "$_mstfcr_node" ] || return 1
  [ "${MERV_SSH_TRUST_FIND_CACHE_DIGEST:-}" = "$_mstfcr_digest" ] || return 1
  merv_ssh_trust_uint "${MERV_SSH_TRUST_FIND_CACHE_SLOT:-}" && [ "${MERV_SSH_TRUST_FIND_CACHE_SLOT:-}" -ge 1 ] || { merv_ssh_trust_find_cache_clear; return 1; }
  _mstfcr_mac=$(merv_ssh_trust_mac_or_none "${MERV_SSH_TRUST_FIND_CACHE_MAC:-}") || { merv_ssh_trust_find_cache_clear; return 1; }
  [ "$_mstfcr_mac" = "${MERV_SSH_TRUST_FIND_CACHE_MAC:-}" ] || { merv_ssh_trust_find_cache_clear; return 1; }
  _mstfcr_host=$(merv_ssh_trust_normalize_host "${MERV_SSH_TRUST_FIND_CACHE_HOST:-}") || { merv_ssh_trust_find_cache_clear; return 1; }
  [ "$_mstfcr_host" = "${MERV_SSH_TRUST_FIND_CACHE_HOST:-}" ] || { merv_ssh_trust_find_cache_clear; return 1; }
  _mstfcr_port=$(merv_ssh_trust_normalize_port "${MERV_SSH_TRUST_FIND_CACHE_PORT:-}") || { merv_ssh_trust_find_cache_clear; return 1; }
  [ "$_mstfcr_port" = "${MERV_SSH_TRUST_FIND_CACHE_PORT:-}" ] || { merv_ssh_trust_find_cache_clear; return 1; }
  merv_ssh_trust_algorithm_valid "${MERV_SSH_TRUST_FIND_CACHE_ALGORITHM:-}" &&
    merv_ssh_trust_key_valid "${MERV_SSH_TRUST_FIND_CACHE_PUBLIC_KEY:-}" &&
    merv_ssh_trust_fingerprint_valid "${MERV_SSH_TRUST_FIND_CACHE_FINGERPRINT:-}" || { merv_ssh_trust_find_cache_clear; return 1; }
  merv_ssh_trust_uint "${MERV_SSH_TRUST_FIND_CACHE_CREATED:-}" &&
    merv_ssh_trust_uint "${MERV_SSH_TRUST_FIND_CACHE_UPDATED:-}" &&
    [ "$(( MERV_SSH_TRUST_FIND_CACHE_UPDATED - MERV_SSH_TRUST_FIND_CACHE_CREATED ))" -ge 0 ] 2>/dev/null || { merv_ssh_trust_find_cache_clear; return 1; }
  _mstfcr_expected=$(merv_ssh_trust_node_id "$MERV_SSH_TRUST_FIND_CACHE_SLOT" "$MERV_SSH_TRUST_FIND_CACHE_MAC" "$MERV_SSH_TRUST_FIND_CACHE_HOST" "$MERV_SSH_TRUST_FIND_CACHE_PORT") || { merv_ssh_trust_find_cache_clear; return 1; }
  [ "$_mstfcr_expected" = "$_mstfcr_node" ] || { merv_ssh_trust_find_cache_clear; return 1; }
  _mstfcr_now=$(merv_ssh_trust_now)
  merv_ssh_trust_uint "$_mstfcr_now" || { merv_ssh_trust_find_cache_clear; return 1; }
  if [ "$MERV_SSH_TRUST_TTL_SEC" -ge 1 ] 2>/dev/null &&
     [ "$(( _mstfcr_now - MERV_SSH_TRUST_FIND_CACHE_UPDATED ))" -gt "$MERV_SSH_TRUST_TTL_SEC" ] 2>/dev/null; then
    SSH_TRUST_EXPIRED=1
    MERV_SSH_TRUST_LAST_REASON=trust-expired
    return 3
  fi
  _mstfcr_current=$(merv_ssh_trust_file_digest "$MERV_SSH_TRUST_FILE" 2>/dev/null || printf '')
  [ "$_mstfcr_current" = "$_mstfcr_digest" ] || { merv_ssh_trust_find_cache_clear; return 1; }
  SSH_TRUST_NODE="$MERV_SSH_TRUST_FIND_CACHE_NODE"
  SSH_TRUST_SLOT="$MERV_SSH_TRUST_FIND_CACHE_SLOT"
  SSH_TRUST_MAC="$MERV_SSH_TRUST_FIND_CACHE_MAC"
  SSH_TRUST_HOST="$MERV_SSH_TRUST_FIND_CACHE_HOST"
  SSH_TRUST_PORT="$MERV_SSH_TRUST_FIND_CACHE_PORT"
  SSH_TRUST_ALGORITHM="$MERV_SSH_TRUST_FIND_CACHE_ALGORITHM"
  SSH_TRUST_PUBLIC_KEY="$MERV_SSH_TRUST_FIND_CACHE_PUBLIC_KEY"
  SSH_TRUST_FINGERPRINT="$MERV_SSH_TRUST_FIND_CACHE_FINGERPRINT"
  SSH_TRUST_CREATED="$MERV_SSH_TRUST_FIND_CACHE_CREATED"
  SSH_TRUST_UPDATED="$MERV_SSH_TRUST_FIND_CACHE_UPDATED"
  SSH_TRUST_EXPIRED=0
  return 0
}

merv_ssh_trust_escape() {
  _mse_value="$1"
  # Newlines disappear in command substitution.  Reject all control bytes
  # before the byte-wise canonical percent encoding instead.
  printf '%s' "$_mse_value" | LC_ALL=C grep -q '[[:cntrl:]]' 2>/dev/null && return 1
  # The router image may not include BusyBox od.  All persisted production
  # fields have already been restricted to this ASCII contract, so preserve
  # them directly when the byte-wise encoder is unavailable.  Arbitrary test
  # values still fail closed instead of being written without canonical escape.
  if ! merv_has od; then
    case "$_mse_value" in *[!A-Za-z0-9._:@/+,=-]*) return 1 ;; esac
    printf '%s\n' "$_mse_value"
    return 0
  fi
  _mse_out=""
  for _mse_hex in $(printf '%s' "$_mse_value" | od -An -v -t x1 2>/dev/null); do
    case "$_mse_hex" in
      30|31|32|33|34|35|36|37|38|39|41|42|43|44|45|46|47|48|49|4a|4b|4c|4d|4e|4f|50|51|52|53|54|55|56|57|58|59|5a|61|62|63|64|65|66|67|68|69|6a|6b|6c|6d|6e|6f|70|71|72|73|74|75|76|77|78|79|7a|2d|2e|5f|7e)
        _mse_char=$(printf '%b' "\\$(printf '%03o' "$((0x$_mse_hex))")") || return 1
        _mse_out="$_mse_out$_mse_char"
        ;;
      *) _mse_out="$_mse_out%$(printf '%s' "$_mse_hex" | tr 'a-f' 'A-F')" ;;
    esac
  done
  printf '%s\n' "$_mse_out"
}

merv_ssh_trust_unescape() {
  _msu_value="$1"; _msu_out=""
  while [ -n "$_msu_value" ]; do
    case "$_msu_value" in
      %??*)
        _msu_pair=${_msu_value#%}; _msu_pair=${_msu_pair%${_msu_pair#??}}
        case "$_msu_pair" in *[!0123456789abcdefABCDEF]*) return 1 ;; esac
        _msu_oct=$(printf '%03o' "$((0x$_msu_pair))") || return 1
        _msu_out="$_msu_out$(printf '%b' "\\$_msu_oct")"
        _msu_value=${_msu_value#???}
        ;;
      %*) return 1 ;;
      *) _msu_char=${_msu_value%${_msu_value#?}}; _msu_out="$_msu_out$_msu_char"; _msu_value=${_msu_value#?} ;;
    esac
  done
  printf '%s' "$_msu_out" | LC_ALL=C grep -q '[[:cntrl:]]' 2>/dev/null && return 1
  printf '%s\n' "$_msu_out"
}

merv_ssh_trust_cleanup_files() {
  _mstcf_rc=0
  for _mstcf_file in "$@"; do
    [ -n "$_mstcf_file" ] || continue
    [ -e "$_mstcf_file" ] || continue
    rm -f "$_mstcf_file" 2>/dev/null || {
      printf '%s\n' "[ERROR] SSH trust cleanup failed: $_mstcf_file" >&2
      _mstcf_rc=1
    }
  done
  return "$_mstcf_rc"
}

merv_ssh_trust_cleanup_dir() {
  _mstcd_dir="$1"
  _mstcd_rc=0
  [ -d "$_mstcd_dir" ] || return 0
  merv_ssh_trust_cleanup_files "$_mstcd_dir"/* || _mstcd_rc=1
  rmdir "$_mstcd_dir" 2>/dev/null || _mstcd_rc=1
  return "$_mstcd_rc"
}

merv_ssh_trust_normalize_mac() {
  _msn_mac=$(printf '%s' "$1" | tr 'a-f' 'A-F')
  case "$_msn_mac" in
    [0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]) printf '%s\n' "$_msn_mac" ;;
    *) return 1 ;;
  esac
}

merv_ssh_trust_mac_or_none() {
  case "${1:-}" in
    ''|none) printf 'none\n' ;;
    *) merv_ssh_trust_normalize_mac "$1" ;;
  esac
}

merv_ssh_trust_normalize_host() {
  _msh_host="$1"
  case "$_msh_host" in ''|*[!A-Za-z0-9.:-]*) return 1 ;; esac
  case "$_msh_host" in
    *:*)
      # The utility must both validate and emit the target's canonical
      # spelling. Merely lower-casing an alias is not RFC-5952 canonicalization.
      merv_has ip || return 1
      _msh_lower=$(printf '%s' "$_msh_host" | tr 'A-F' 'a-f')
      _msh_route=$(ip -6 route get "$_msh_lower" 2>/dev/null) || return 1
      _msh_canon=${_msh_route%% *}
      [ -n "$_msh_canon" ] && [ "$_msh_canon" = "$_msh_lower" ] || return 1
      printf '%s\n' "$_msh_canon"
      ;;
    *)
      # An all-numeric dotted value is the only IPv4 candidate. Everything
      # else follows the DNS grammar, including names with four labels.
      case "$_msh_host" in
        *[!0-9.]* )
          _msh_host=$(printf '%s' "$_msh_host" | tr 'A-Z' 'a-z' | sed 's/\.$//')
          case "$_msh_host" in ''|.*|*.) return 1 ;; esac
          printf '%s\n' "$_msh_host" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$' || return 1
          printf '%s\n' "$_msh_host"
          ;;
        *)
          printf '%s\n' "$_msh_host" | awk -F. 'NF==4 {ok=1; for(i=1;i<=4;i++){if($i==""||$i !~ /^[0-9]+$/||$i+0>255||($i!="0"&&$i ~ /^0/))ok=0} if(ok)print; exit !ok}' || return 1
          ;;
      esac
      ;;
  esac
}

merv_ssh_trust_normalize_port() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  _mstp_port=$(printf '%s' "$1" | sed 's/^0*//')
  [ -n "$_mstp_port" ] || _mstp_port=0
  [ "$_mstp_port" -ge 1 ] 2>/dev/null && [ "$_mstp_port" -le 65535 ] 2>/dev/null || return 1
  printf '%s\n' "$_mstp_port"
}

merv_ssh_trust_algorithm_valid() {
  case "${1:-}" in ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) return 0 ;; *) return 1 ;; esac
}

merv_ssh_trust_key_valid() {
  case "${1:-}" in ''|*[!A-Za-z0-9+/=]*) return 1 ;; esac
  printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9+/]+={0,2}$' || return 1
  [ $(( ${#1} % 4 )) -eq 0 ] 2>/dev/null || return 1
  return 0
}

merv_ssh_trust_fingerprint_valid() {
  printf '%s\n' "${1:-}" | grep -Eq '^SHA256:[A-Za-z0-9+/]{43}$'
}

merv_ssh_trust_node_id() {
  _msnid_slot="$1"; _msnid_mac="${2:-}"; _msnid_host="${3:-}"; _msnid_port="${4:-}"
  case "$_msnid_slot" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_msnid_slot" -ge 1 ] 2>/dev/null || return 1
  _msnid_mac=$(merv_ssh_trust_mac_or_none "$_msnid_mac") || return 1
  if [ "$_msnid_mac" != none ]; then
    printf 'NODE%s@%s\n' "$_msnid_slot" "$_msnid_mac"
    return 0
  fi
  _msnid_host=$(merv_ssh_trust_normalize_host "$_msnid_host") || return 1
  _msnid_port=$(merv_ssh_trust_normalize_port "$_msnid_port") || return 1
  printf 'NODE%s@%s:%s\n' "$_msnid_slot" "$_msnid_host" "$_msnid_port"
}

merv_ssh_trust_init() {
  merv_ssh_trust_root_valid || return 2
  merv_ssh_trust_path_valid "$MERV_SSH_TRUST_FILE" || return 2
  merv_ssh_trust_path_valid "$MERV_SSH_TRUST_PENDING_ROOT" || return 2
  merv_ssh_trust_path_valid "$MERV_SSH_TRUST_REQUESTS_ROOT" || return 2
  merv_ssh_trust_path_valid "$MERV_SSH_TRUST_STAGING_ROOT" || return 2
  merv_ssh_trust_path_valid "$MERV_SSH_TRUST_QUARANTINE_ROOT" || return 2
  mkdir -p "$MERV_SSH_TRUST_ROOT" "$MERV_SSH_TRUST_PENDING_ROOT" "$MERV_SSH_TRUST_REQUESTS_ROOT" "$MERV_SSH_TRUST_STAGING_ROOT" "$MERV_SSH_TRUST_QUARANTINE_ROOT" 2>/dev/null || return 1
  chmod 700 "$MERV_SSH_TRUST_ROOT" "$MERV_SSH_TRUST_PENDING_ROOT" "$MERV_SSH_TRUST_REQUESTS_ROOT" "$MERV_SSH_TRUST_STAGING_ROOT" "$MERV_SSH_TRUST_QUARANTINE_ROOT" 2>/dev/null || return 1
  if [ ! -e "$MERV_SSH_TRUST_FILE" ]; then
    _mst_tmp="$MERV_SSH_TRUST_FILE.tmp.$$"
    ( umask 077; printf 'MERV_SSH_TRUST_V1\nversion\tnode_id\tslot\tmac\thost\tport\talgorithm\tpublic_key_b64\tfingerprint_sha256\tcreated_epoch\tupdated_epoch\n' > "$_mst_tmp" ) 2>/dev/null || { rm -f "$_mst_tmp" 2>/dev/null; return 1; }
    chmod 600 "$_mst_tmp" 2>/dev/null || { rm -f "$_mst_tmp" 2>/dev/null; return 1; }
    mv -f "$_mst_tmp" "$MERV_SSH_TRUST_FILE" 2>/dev/null || { rm -f "$_mst_tmp" 2>/dev/null; return 1; }
  fi
  merv_ssh_trust_validate_db
}

merv_ssh_trust_validate_db() {
  MERV_SSH_TRUST_VALIDATION_DIGEST=""
  merv_ssh_trust_path_valid "$MERV_SSH_TRUST_FILE" || return 2
  [ -f "$MERV_SSH_TRUST_FILE" ] || return 2
  _mst_validation_digest=$(merv_ssh_trust_file_digest "$MERV_SSH_TRUST_FILE" 2>/dev/null || printf '')
  if [ -n "${MERV_SSH_TRUST_FIND_CACHE_DIGEST:-}" ] &&
     [ "$MERV_SSH_TRUST_FIND_CACHE_DIGEST" != "$_mst_validation_digest" ]; then
    merv_ssh_trust_find_cache_clear
  fi
  if [ -n "$_mst_validation_digest" ] &&
     [ "${MERV_SSH_TRUST_VALIDATED_FILE:-}" = "$MERV_SSH_TRUST_FILE" ] &&
     [ "${MERV_SSH_TRUST_VALIDATED_DIGEST:-}" = "$_mst_validation_digest" ]; then
    MERV_SSH_TRUST_VALIDATION_DIGEST="$_mst_validation_digest"
    return 0
  fi
  unset MERV_SSH_TRUST_VALIDATED_FILE MERV_SSH_TRUST_VALIDATED_DIGEST
  _mst_header=$(sed -n '1p' "$MERV_SSH_TRUST_FILE" 2>/dev/null); [ "$_mst_header" = 'MERV_SSH_TRUST_V1' ] || return 2
  _mst_schema=$(sed -n '2p' "$MERV_SSH_TRUST_FILE" 2>/dev/null)
  _mst_schema_expected=$(printf 'version\tnode_id\tslot\tmac\thost\tport\talgorithm\tpublic_key_b64\tfingerprint_sha256\tcreated_epoch\tupdated_epoch')
  [ "$_mst_schema" = "$_mst_schema_expected" ] || return 2
  _mst_count=0; _mst_header_lines=0; _mst_nodes=' '; _mst_endpoints=' '; _mst_prev_node=""
  _mst_tab=$(printf '\t')
  while IFS= read -r _mst_line || [ -n "$_mst_line" ]; do
    if [ "$_mst_header_lines" -lt 2 ]; then
      _mst_header_lines=$((_mst_header_lines + 1)); continue
    fi
    [ -n "$_mst_line" ] || return 2
    OLDIFS=$IFS; IFS="$_mst_tab"; set -- $_mst_line; IFS=$OLDIFS
    [ "$#" -eq 11 ] || return 2
    _mst_version=$(merv_ssh_trust_unescape "$1") || return 2
    [ "$(merv_ssh_trust_escape "$_mst_version")" = "$1" ] || return 2
    _mst_node=$(merv_ssh_trust_unescape "$2") || return 2
    [ "$(merv_ssh_trust_escape "$_mst_node")" = "$2" ] || return 2
    _mst_slot=$(merv_ssh_trust_unescape "$3") || return 2
    [ "$(merv_ssh_trust_escape "$_mst_slot")" = "$3" ] || return 2
    _mst_mac=$(merv_ssh_trust_unescape "$4") || return 2
    [ "$(merv_ssh_trust_escape "$_mst_mac")" = "$4" ] || return 2
    _mst_host=$(merv_ssh_trust_unescape "$5") || return 2
    [ "$(merv_ssh_trust_escape "$_mst_host")" = "$5" ] || return 2
    _mst_port=$(merv_ssh_trust_unescape "$6") || return 2
    [ "$(merv_ssh_trust_escape "$_mst_port")" = "$6" ] || return 2
    _mst_alg=$(merv_ssh_trust_unescape "$7") || return 2
    [ "$(merv_ssh_trust_escape "$_mst_alg")" = "$7" ] || return 2
    _mst_key=$(merv_ssh_trust_unescape "$8") || return 2
    [ "$(merv_ssh_trust_escape "$_mst_key")" = "$8" ] || return 2
    _mst_fp=$(merv_ssh_trust_unescape "$9") || return 2
    [ "$(merv_ssh_trust_escape "$_mst_fp")" = "$9" ] || return 2
    _mst_created=$(merv_ssh_trust_unescape "${10}") || return 2
    [ "$(merv_ssh_trust_escape "$_mst_created")" = "${10}" ] || return 2
    _mst_updated=$(merv_ssh_trust_unescape "${11}") || return 2
    [ "$(merv_ssh_trust_escape "$_mst_updated")" = "${11}" ] || return 2
    [ "$_mst_version" = 1 ] || return 2
    _mst_mac_raw="$_mst_mac"; _mst_mac=$(merv_ssh_trust_mac_or_none "$_mst_mac_raw") || return 2
    [ "$_mst_mac" = "$_mst_mac_raw" ] || return 2
    _mst_host_raw="$_mst_host"; _mst_host=$(merv_ssh_trust_normalize_host "$_mst_host_raw") || return 2
    [ "$_mst_host" = "$_mst_host_raw" ] || return 2
    _mst_port_raw="$_mst_port"; _mst_port=$(merv_ssh_trust_normalize_port "$_mst_port_raw") || return 2
    [ "$_mst_port" = "$_mst_port_raw" ] || return 2
    merv_ssh_trust_algorithm_valid "$_mst_alg" || return 2
    merv_ssh_trust_key_valid "$_mst_key" || return 2
    merv_ssh_trust_fingerprint_valid "$_mst_fp" || return 2
    _mst_derived=$(merv_ssh_trust_derive_fingerprint "$_mst_alg" "$_mst_key" 2>/dev/null) || return 2
    [ "$_mst_fp" = "$_mst_derived" ] || return 2
    merv_ssh_trust_uint "$_mst_slot" && [ "$_mst_slot" -ge 1 ] || return 2
    merv_ssh_trust_uint "$_mst_created" && merv_ssh_trust_uint "$_mst_updated" || return 2
    [ "$(( _mst_updated - _mst_created ))" -ge 0 ] 2>/dev/null || return 2
    _mst_now=$(merv_ssh_trust_now); merv_ssh_trust_uint "$_mst_now" || return 2
    [ "$_mst_created" -le "$_mst_now" ] 2>/dev/null && [ "$_mst_updated" -le "$_mst_now" ] 2>/dev/null || return 2
    _mst_expected_node=$(merv_ssh_trust_node_id "$_mst_slot" "$_mst_mac" "$_mst_host" "$_mst_port") || return 2
    [ "$_mst_node" = "$_mst_expected_node" ] || return 2
    if [ -n "${_mst_prev_node:-}" ]; then
      awk -v p="$_mst_prev_node" -v n="$_mst_node" 'BEGIN { exit !(p < n) }' || return 2
    fi
    _mst_prev_node="$_mst_node"
    case "$_mst_nodes" in *" $_mst_node "*) return 2 ;; esac
    case "$_mst_endpoints" in *" $_mst_host:$_mst_port "*) return 2 ;; esac
    _mst_nodes="$_mst_nodes$_mst_node "; _mst_endpoints="$_mst_endpoints$_mst_host:$_mst_port "; _mst_count=$((_mst_count + 1))
    [ "$_mst_count" -le "$MERV_SSH_TRUST_MAX_RECORDS" ] 2>/dev/null || return 2
  done < "$MERV_SSH_TRUST_FILE"
  [ "$_mst_header_lines" -eq 2 ] || return 2
  if [ -n "$_mst_validation_digest" ]; then
    _mst_validation_digest_after=$(merv_ssh_trust_file_digest "$MERV_SSH_TRUST_FILE" 2>/dev/null || printf '')
    [ "$_mst_validation_digest_after" = "$_mst_validation_digest" ] || return 2
    MERV_SSH_TRUST_VALIDATED_FILE="$MERV_SSH_TRUST_FILE"
    MERV_SSH_TRUST_VALIDATED_DIGEST="$_mst_validation_digest"
    MERV_SSH_TRUST_VALIDATION_DIGEST="$_mst_validation_digest"
    export MERV_SSH_TRUST_VALIDATED_FILE MERV_SSH_TRUST_VALIDATED_DIGEST
  fi
  return 0
}

merv_ssh_trust_find() {
  _mstf_node="$1"; _mstf_found=1
  SSH_TRUST_NODE=""; SSH_TRUST_SLOT=""; SSH_TRUST_MAC=""; SSH_TRUST_HOST=""; SSH_TRUST_PORT=""; SSH_TRUST_ALGORITHM=""; SSH_TRUST_PUBLIC_KEY=""; SSH_TRUST_FINGERPRINT=""; SSH_TRUST_CREATED=""; SSH_TRUST_UPDATED=""; SSH_TRUST_EXPIRED=0
  merv_ssh_trust_validate_db || return 2
  _mstf_validation_digest="${MERV_SSH_TRUST_VALIDATION_DIGEST:-}"
  if [ -n "$_mstf_validation_digest" ]; then
    merv_ssh_trust_find_cache_restore "$_mstf_node" "$_mstf_validation_digest"
    _mstf_cache_rc=$?
    [ "$_mstf_cache_rc" -eq 0 ] && return 0
    [ "$_mstf_cache_rc" -eq 3 ] && return 3
  fi
  _mst_tab=$(printf '\t')
  while IFS= read -r _mst_line || [ -n "$_mst_line" ]; do
    case "$_mst_line" in MERV_SSH_TRUST_V1|version*) continue ;; esac
    OLDIFS=$IFS; IFS="$_mst_tab"; set -- $_mst_line; IFS=$OLDIFS
    [ "$#" -eq 11 ] || return 2
    _mst_node_raw=$(merv_ssh_trust_unescape "$2") || return 2
    [ "$_mst_node_raw" = "$_mstf_node" ] || continue
    SSH_TRUST_NODE=$(merv_ssh_trust_unescape "$2") || return 2
    SSH_TRUST_SLOT=$(merv_ssh_trust_unescape "$3") || return 2
    SSH_TRUST_MAC=$(merv_ssh_trust_unescape "$4") || return 2
    SSH_TRUST_HOST=$(merv_ssh_trust_unescape "$5") || return 2
    SSH_TRUST_PORT=$(merv_ssh_trust_unescape "$6") || return 2
    SSH_TRUST_ALGORITHM=$(merv_ssh_trust_unescape "$7") || return 2
    SSH_TRUST_PUBLIC_KEY=$(merv_ssh_trust_unescape "$8") || return 2
    SSH_TRUST_FINGERPRINT=$(merv_ssh_trust_unescape "$9") || return 2
    SSH_TRUST_CREATED=$(merv_ssh_trust_unescape "${10}") || return 2
    SSH_TRUST_UPDATED=$(merv_ssh_trust_unescape "${11}") || return 2
    SSH_TRUST_EXPIRED=0
    _mstf_now=$(merv_ssh_trust_now)
    if merv_ssh_trust_uint "$_mstf_now" && merv_ssh_trust_uint "$SSH_TRUST_UPDATED" &&
       [ "$MERV_SSH_TRUST_TTL_SEC" -ge 1 ] 2>/dev/null &&
       [ "$(( _mstf_now - SSH_TRUST_UPDATED ))" -gt "$MERV_SSH_TRUST_TTL_SEC" ] 2>/dev/null; then
      SSH_TRUST_EXPIRED=1
      MERV_SSH_TRUST_LAST_REASON=trust-expired
      _mstf_found=3
      return 3
    fi
    if [ -n "$_mstf_validation_digest" ]; then
      _mstf_digest_after=$(merv_ssh_trust_file_digest "$MERV_SSH_TRUST_FILE" 2>/dev/null || printf '')
      [ "$_mstf_digest_after" = "$_mstf_validation_digest" ] || {
        MERV_SSH_TRUST_LAST_REASON=trust-record-changed
        return 2
      }
      merv_ssh_trust_find_cache_store "$_mstf_node" "$_mstf_validation_digest" || return 2
    fi
    _mstf_found=0; return 0
  done < "$MERV_SSH_TRUST_FILE"
  return "$_mstf_found"
}

_merv_ssh_trust_cleanup_fp_files() {
  _mstcf_rc=0
  for _mstcf_file in "$@"; do
    [ -n "$_mstcf_file" ] || continue
    [ -e "$_mstcf_file" ] || continue
    rm -f "$_mstcf_file" 2>/dev/null || _mstcf_rc=1
  done
  return "$_mstcf_rc"
}

_merv_ssh_trust_fp_abort() {
  _mstfa_rc=0
  _merv_ssh_trust_cleanup_fp_files "$@" >/dev/null 2>&1 || _mstfa_rc=1
  [ "$_mstfa_rc" -eq 0 ] || printf '%s\n' "[ERROR] SSH trust fingerprint staging cleanup failed; evidence retained" >&2
  return 1
}

merv_ssh_trust_derive_fingerprint() {
  _mstfp_alg="$1"; _mstfp_key="$2"
  merv_ssh_trust_algorithm_valid "$_mstfp_alg" && merv_ssh_trust_key_valid "$_mstfp_key" || return 1
  merv_ssh_trust_root_valid || return 1
  merv_ssh_trust_path_valid "$MERV_SSH_TRUST_STAGING_ROOT" || return 1
  [ -d "$MERV_SSH_TRUST_STAGING_ROOT" ] || return 1
  # ASUSWRT builds may omit the BusyBox base64 applet.  OpenSSL is already
  # part of the router image and provides the same strict RFC 4648 conversion
  # without introducing a new binary or weakening the key validation.
  _mstfp_has_base64=0; merv_has base64 && _mstfp_has_base64=1
  _mstfp_has_openssl=0; merv_has openssl && _mstfp_has_openssl=1
  [ "$_mstfp_has_base64" -eq 1 ] || [ "$_mstfp_has_openssl" -eq 1 ] || return 1
  _mstfp_file="$MERV_SSH_TRUST_STAGING_ROOT/fingerprint.$$"
  if [ "$_mstfp_has_base64" -eq 1 ]; then
    printf '%s' "$_mstfp_key" | base64 -d > "$_mstfp_file" 2>/dev/null || {
      printf '%s' "$_mstfp_key" | base64 -D > "$_mstfp_file" 2>/dev/null || {
        _merv_ssh_trust_fp_abort "$_mstfp_file"
        return 1
      }
    }
  else
    # OpenSSL's -A prevents line wrapping and -d reads the canonical public
    # key payload without invoking a shell pipeline that can hide failures.
    printf '%s' "$_mstfp_key" | openssl base64 -d -A > "$_mstfp_file" 2>/dev/null || {
      _merv_ssh_trust_fp_abort "$_mstfp_file"
      return 1
    }
  fi
  [ -s "$_mstfp_file" ] || {
    _merv_ssh_trust_fp_abort "$_mstfp_file"
    return 1
  }
  if [ "$_mstfp_has_base64" -eq 1 ]; then
    _mstfp_canon=$(base64 "$_mstfp_file" 2>/dev/null | tr -d '\r\n')
  else
    _mstfp_canon=$(openssl base64 -A -in "$_mstfp_file" 2>/dev/null | tr -d '\r\n')
  fi
  [ "$?" -eq 0 ] || {
    _merv_ssh_trust_fp_abort "$_mstfp_file"
    return 1
  }
  [ "$_mstfp_canon" = "$_mstfp_key" ] || {
    _merv_ssh_trust_fp_abort "$_mstfp_file"
    return 1
  }
  _mstfp_digest="$MERV_SSH_TRUST_STAGING_ROOT/digest.$$"
  if merv_has openssl; then
    openssl dgst -sha256 -binary "$_mstfp_file" > "$_mstfp_digest" 2>/dev/null || {
      _merv_ssh_trust_fp_abort "$_mstfp_file" "$_mstfp_digest"
      return 1
    }
  elif merv_has sha256sum; then
    _mstfp_hex=$(sha256sum "$_mstfp_file" 2>/dev/null | awk '{print $1}')
    [ "${#_mstfp_hex}" -eq 64 ] || {
      _merv_ssh_trust_fp_abort "$_mstfp_file" "$_mstfp_digest"
      return 1
    }
    : > "$_mstfp_digest" || {
      _merv_ssh_trust_fp_abort "$_mstfp_file" "$_mstfp_digest"
      return 1
    }
    while [ -n "$_mstfp_hex" ]; do
      _mstfp_pair=${_mstfp_hex%${_mstfp_hex#??}}; _mstfp_hex=${_mstfp_hex#??}
      printf '%b' "\\$(printf '%03o' "$((0x$_mstfp_pair))")" >> "$_mstfp_digest" || {
        _merv_ssh_trust_fp_abort "$_mstfp_file" "$_mstfp_digest"
        return 1
      }
    done
  else
    _merv_ssh_trust_cleanup_fp_files "$_mstfp_file" "$_mstfp_digest" >/dev/null 2>&1 || printf '%s\n' "[ERROR] SSH trust fingerprint staging cleanup failed; evidence retained" >&2
    return 1
  fi
  if [ "$_mstfp_has_base64" -eq 1 ]; then
    _mstfp_b64=$(base64 "$_mstfp_digest" 2>/dev/null | tr -d '\r\n=')
  else
    _mstfp_b64=$(openssl base64 -A -in "$_mstfp_digest" 2>/dev/null | tr -d '\r\n=')
  fi
  [ "$?" -eq 0 ] || {
    _merv_ssh_trust_cleanup_fp_files "$_mstfp_file" "$_mstfp_digest" >/dev/null 2>&1 || printf '%s\n' "[ERROR] SSH trust fingerprint staging cleanup failed; evidence retained" >&2
    return 1
  }
  _merv_ssh_trust_cleanup_fp_files "$_mstfp_file" "$_mstfp_digest" >/dev/null 2>&1 || return 1
  [ -n "$_mstfp_b64" ] || return 1
  printf 'SHA256:%s\n' "$_mstfp_b64"
}

merv_ssh_trust_wire_fingerprint() {
  _mstfp_alg="$1"; _mstfp_key="$2"
  merv_ssh_trust_algorithm_valid "$_mstfp_alg" && merv_ssh_trust_key_valid "$_mstfp_key" || return 1
  if [ -n "${MERV_SSH_TEST_FINGERPRINT:-}" ]; then
    merv_ssh_trust_fingerprint_valid "$MERV_SSH_TEST_FINGERPRINT" || return 1
    printf '%s\n' "$MERV_SSH_TEST_FINGERPRINT"; return 0
  fi
  merv_ssh_trust_init >/dev/null 2>&1 || return 1
  merv_ssh_trust_derive_fingerprint "$_mstfp_alg" "$_mstfp_key"
}

merv_ssh_trust_atomic_db() {
  _mstad_stage="$1"
  merv_ssh_trust_path_valid "$_mstad_stage" || return 2
  merv_ssh_trust_validate_file "$_mstad_stage" || return 2
  chmod 600 "$_mstad_stage" 2>/dev/null || return 1
  mv -f "$_mstad_stage" "$MERV_SSH_TRUST_FILE" 2>/dev/null || return 1
  unset MERV_SSH_TRUST_VALIDATED_FILE MERV_SSH_TRUST_VALIDATED_DIGEST
  MERV_SSH_TRUST_VALIDATION_DIGEST=""
  merv_ssh_trust_find_cache_clear
}

merv_ssh_trust_validate_file() {
  _mstvf_file="$1"
  merv_ssh_trust_path_valid "$_mstvf_file" || return 2
  _mstvf_saved="$MERV_SSH_TRUST_FILE"
  MERV_SSH_TRUST_FILE="$_mstvf_file"
  merv_ssh_trust_validate_db; _mstvf_rc=$?
  MERV_SSH_TRUST_FILE="$_mstvf_saved"
  return "$_mstvf_rc"
}

merv_ssh_trust_stage_record() {
  _mstr_slot="$1"; _mstr_mac=$(merv_ssh_trust_mac_or_none "$2") || return 2
  _mstr_host=$(merv_ssh_trust_normalize_host "$3") || return 2
  _mstr_port=$(merv_ssh_trust_normalize_port "$4") || return 2
  _mstr_alg="$5"; _mstr_key="$6"; _mstr_fp="$7"
  merv_ssh_trust_algorithm_valid "$_mstr_alg" && merv_ssh_trust_key_valid "$_mstr_key" && merv_ssh_trust_fingerprint_valid "$_mstr_fp" || return 2
  merv_ssh_trust_init >/dev/null 2>&1 || return 1
  _mstr_derived=$(merv_ssh_trust_derive_fingerprint "$_mstr_alg" "$_mstr_key" 2>/dev/null) || return 2
  [ "$_mstr_fp" = "$_mstr_derived" ] || return 2
  merv_ssh_trust_validate_db || return 2
  _mstr_node=$(merv_ssh_trust_node_id "$_mstr_slot" "$_mstr_mac" "$_mstr_host" "$_mstr_port") || return 2
  _mstr_now=$(merv_ssh_trust_now); merv_ssh_trust_uint "$_mstr_now" || return 1
  _mstr_created="$_mstr_now"; _mstr_old=""
  if merv_ssh_trust_find "$_mstr_node"; then
    _mstr_created="$SSH_TRUST_CREATED"
  else
    _mstr_find_rc=$?
    [ "$_mstr_find_rc" -eq 1 ] || [ "$_mstr_find_rc" -eq 3 ] || return 2
    [ "$_mstr_find_rc" -eq 3 ] && [ -n "$SSH_TRUST_CREATED" ] && _mstr_created="$SSH_TRUST_CREATED"
  fi
  _mstr_stage="$MERV_SSH_TRUST_STAGING_ROOT/.known_hosts.$$"
  _mstr_body="$MERV_SSH_TRUST_STAGING_ROOT/.known_hosts.body.$$"
  _mstr_sorted="$MERV_SSH_TRUST_STAGING_ROOT/.known_hosts.sorted.$$"
  _mstr_tab=$(printf '\t')
  _mstr_e1=$(merv_ssh_trust_escape 1) || return 2
  _mstr_e2=$(merv_ssh_trust_escape "$_mstr_node") || return 2
  _mstr_e3=$(merv_ssh_trust_escape "$_mstr_slot") || return 2
  _mstr_e4=$(merv_ssh_trust_escape "$_mstr_mac") || return 2
  _mstr_e5=$(merv_ssh_trust_escape "$_mstr_host") || return 2
  _mstr_e6=$(merv_ssh_trust_escape "$_mstr_port") || return 2
  _mstr_e7=$(merv_ssh_trust_escape "$_mstr_alg") || return 2
  _mstr_e8=$(merv_ssh_trust_escape "$_mstr_key") || return 2
  _mstr_e9=$(merv_ssh_trust_escape "$_mstr_fp") || return 2
  _mstr_e10=$(merv_ssh_trust_escape "$_mstr_created") || return 2
  _mstr_e11=$(merv_ssh_trust_escape "$_mstr_now") || return 2
  {
    while IFS= read -r _mstr_line || [ -n "$_mstr_line" ]; do
      case "$_mstr_line" in MERV_SSH_TRUST_V1|version*) continue ;; esac
      OLDIFS=$IFS; IFS="$_mstr_tab"; set -- $_mstr_line; IFS=$OLDIFS
      [ "$#" -eq 11 ] || return 2
      _mstr_existing=$(merv_ssh_trust_unescape "$2") || exit 2
      [ "$_mstr_existing" = "$_mstr_node" ] && continue
      printf '%s\n' "$_mstr_line"
    done < "$MERV_SSH_TRUST_FILE"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_mstr_e1" "$_mstr_e2" "$_mstr_e3" "$_mstr_e4" "$_mstr_e5" "$_mstr_e6" "$_mstr_e7" "$_mstr_e8" "$_mstr_e9" "$_mstr_e10" "$_mstr_e11"
  } > "$_mstr_body" 2>/dev/null || { merv_ssh_trust_cleanup_files "$_mstr_body"; return 1; }
  LC_ALL=C sort -t "$_mstr_tab" -k2,2 "$_mstr_body" > "$_mstr_sorted" 2>/dev/null || { merv_ssh_trust_cleanup_files "$_mstr_body" "$_mstr_sorted"; return 1; }
  {
    printf 'MERV_SSH_TRUST_V1\nversion\tnode_id\tslot\tmac\thost\tport\talgorithm\tpublic_key_b64\tfingerprint_sha256\tcreated_epoch\tupdated_epoch\n'
    cat "$_mstr_sorted"
  } > "$_mstr_stage" 2>/dev/null || { merv_ssh_trust_cleanup_files "$_mstr_body" "$_mstr_sorted" "$_mstr_stage"; return 1; }
  merv_ssh_trust_cleanup_files "$_mstr_body" "$_mstr_sorted" || { merv_ssh_trust_cleanup_files "$_mstr_stage"; return 1; }
  chmod 600 "$_mstr_stage" 2>/dev/null || { merv_ssh_trust_cleanup_files "$_mstr_stage"; return 1; }
  merv_ssh_trust_validate_file "$_mstr_stage" || { rm -f "$_mstr_stage"; return 2; }
  MERV_SSH_TRUST_STAGED_FILE="$_mstr_stage"
  printf '%s\n' "$_mstr_stage"
}

merv_ssh_trust_publish_stage() {
  _mstps_stage="$1"; merv_ssh_trust_path_valid "$_mstps_stage" || return 2
  merv_ssh_trust_validate_file "$_mstps_stage" || return 2
  chmod 600 "$_mstps_stage" 2>/dev/null || return 1
  mv -f "$_mstps_stage" "$MERV_SSH_TRUST_FILE" 2>/dev/null || return 1
  unset MERV_SSH_TRUST_VALIDATED_FILE MERV_SSH_TRUST_VALIDATED_DIGEST
  MERV_SSH_TRUST_VALIDATION_DIGEST=""
  merv_ssh_trust_find_cache_clear
  merv_ssh_trust_validate_db
}

# Stage removal of one exact trusted node identity.  The caller owns the
# trust-state lock and must publish the returned stage with
# merv_ssh_trust_publish_stage().  The browser may request only the canonical
# node_id returned by the status action; no endpoint or key material is
# accepted here.
merv_ssh_trust_stage_remove_node() {
  _mstrn_node="$1"
  printf '%s\n' "$_mstrn_node" | grep -Eq '^NODE[1-9][0-9]*@[A-Za-z0-9.:-]+$' || return 2
  case "$_mstrn_node" in *[!A-Za-z0-9@.:-]*) return 2 ;; esac
  [ "${#_mstrn_node}" -le 320 ] || return 2
  merv_ssh_trust_init >/dev/null 2>&1 || return 1
  merv_ssh_trust_validate_db || return 2
  _mstrn_body="$MERV_SSH_TRUST_STAGING_ROOT/.known_hosts.revoke.body.$$"
  _mstrn_sorted="$MERV_SSH_TRUST_STAGING_ROOT/.known_hosts.revoke.sorted.$$"
  _mstrn_stage="$MERV_SSH_TRUST_STAGING_ROOT/.known_hosts.revoke.$$"
  _mstrn_tab=$(printf '\t')
  _mstrn_found=0
  _mstrn_rc=0
  : > "$_mstrn_body" 2>/dev/null || return 1
  while IFS= read -r _mstrn_line || [ -n "$_mstrn_line" ]; do
    case "$_mstrn_line" in MERV_SSH_TRUST_V1|version*) continue ;; esac
    OLDIFS=$IFS; IFS="$_mstrn_tab"; set -- $_mstrn_line; IFS=$OLDIFS
    if [ "$#" -ne 11 ]; then _mstrn_rc=2; break; fi
    _mstrn_existing=$(merv_ssh_trust_unescape "$2") || { _mstrn_rc=2; break; }
    if [ "$_mstrn_existing" = "$_mstrn_node" ]; then
      _mstrn_found=1
    else
      printf '%s\n' "$_mstrn_line" >> "$_mstrn_body" 2>/dev/null || { _mstrn_rc=1; break; }
    fi
  done < "$MERV_SSH_TRUST_FILE"
  if [ "$_mstrn_rc" -ne 0 ] || [ "$_mstrn_found" -ne 1 ]; then
    merv_ssh_trust_cleanup_files "$_mstrn_body" "$_mstrn_sorted" "$_mstrn_stage" >/dev/null 2>&1
    [ "$_mstrn_rc" -ne 0 ] && return "$_mstrn_rc"
    return 3
  fi
  LC_ALL=C sort -t "$_mstrn_tab" -k2,2 "$_mstrn_body" > "$_mstrn_sorted" 2>/dev/null || {
    merv_ssh_trust_cleanup_files "$_mstrn_body" "$_mstrn_sorted" "$_mstrn_stage" >/dev/null 2>&1
    return 1
  }
  {
    printf 'MERV_SSH_TRUST_V1\nversion\tnode_id\tslot\tmac\thost\tport\talgorithm\tpublic_key_b64\tfingerprint_sha256\tcreated_epoch\tupdated_epoch\n'
    cat "$_mstrn_sorted"
  } > "$_mstrn_stage" 2>/dev/null || {
    merv_ssh_trust_cleanup_files "$_mstrn_body" "$_mstrn_sorted" "$_mstrn_stage" >/dev/null 2>&1
    return 1
  }
  merv_ssh_trust_cleanup_files "$_mstrn_body" "$_mstrn_sorted" >/dev/null 2>&1 || {
    merv_ssh_trust_cleanup_files "$_mstrn_stage" >/dev/null 2>&1
    return 1
  }
  chmod 600 "$_mstrn_stage" 2>/dev/null || {
    merv_ssh_trust_cleanup_files "$_mstrn_stage" >/dev/null 2>&1
    return 1
  }
  merv_ssh_trust_validate_file "$_mstrn_stage" || {
    merv_ssh_trust_cleanup_files "$_mstrn_stage" >/dev/null 2>&1
    return 2
  }
  MERV_SSH_TRUST_STAGED_FILE="$_mstrn_stage"
  MERV_SSH_TRUST_REMOVED_NODE="$_mstrn_node"
  printf '%s\n' "$_mstrn_stage"
}

merv_ssh_hostkey_probe() {
  _mshkp_slot="$1"; _mshkp_host=$(merv_ssh_trust_normalize_host "$2") || { MERV_SSH_TRUST_LAST_REASON=invalid-endpoint; return 3; }
  _mshkp_port=$(merv_ssh_trust_normalize_port "$3") || { MERV_SSH_TRUST_LAST_REASON=invalid-port; return 3; }
  _mshkp_mac=$(merv_ssh_trust_mac_or_none "$4") || { MERV_SSH_TRUST_LAST_REASON=invalid-mac; return 3; }
  _mshkp_node=$(merv_ssh_trust_node_id "$_mshkp_slot" "$_mshkp_mac" "$_mshkp_host" "$_mshkp_port") || return 3
  MERV_SSH_TRUST_LAST_REASON=""; MERV_SSH_TRUST_LAST_STATUS=""
  if [ -n "${MERV_SSH_TEST_PROBE_FILE:-}" ] && [ -f "$MERV_SSH_TEST_PROBE_FILE" ]; then
    _mshkp_line=$(awk -F '\t' -v n="$_mshkp_node" '$1==n {print; exit}' "$MERV_SSH_TEST_PROBE_FILE" 2>/dev/null)
    [ -n "$_mshkp_line" ] || { MERV_SSH_TRUST_LAST_REASON=probe-no-record; return 7; }
    _mshkp_tab=$(printf '\t'); OLDIFS=$IFS; IFS="$_mshkp_tab"; set -- $_mshkp_line; IFS=$OLDIFS
    [ "$#" -ge 3 ] || return 7
    _mshkp_alg="$2"; _mshkp_key="$3"; _mshkp_fp="${4:-}"
  elif [ "${MERV_SSH_CAPABILITY_PROVEN:-0}" = "1" ] && [ -n "${MERV_SSH_HOSTKEY_PROBE_CMD:-}" ]; then
    case "$MERV_SSH_HOSTKEY_PROBE_CMD" in *[!A-Za-z0-9_./-]*) MERV_SSH_TRUST_LAST_REASON=capability-unknown; return 7 ;; esac
    if [ -f "$MERV_SSH_HOSTKEY_PROBE_CMD" ]; then
      _mshkp_probe=$(sh "$MERV_SSH_HOSTKEY_PROBE_CMD" "$_mshkp_node" "$_mshkp_host" "$_mshkp_port" 2>/dev/null)
    else
      _mshkp_probe=$($MERV_SSH_HOSTKEY_PROBE_CMD "$_mshkp_node" "$_mshkp_host" "$_mshkp_port" 2>/dev/null)
    fi
    _mshkp_probe_rc=$?
    if [ "$_mshkp_probe_rc" -ne 0 ]; then
      case "$_mshkp_probe_rc" in
        10) MERV_SSH_TRUST_LAST_REASON=unreachable; MERV_SSH_TRUST_LAST_STATUS=unreachable; return 10 ;;
        11) MERV_SSH_TRUST_LAST_REASON=refused; MERV_SSH_TRUST_LAST_STATUS=unreachable; return 11 ;;
        *) MERV_SSH_TRUST_LAST_REASON=probe-failed; MERV_SSH_TRUST_LAST_STATUS=probe-failed; return 7 ;;
      esac
    fi
    _mshkp_tab=$(printf '\t'); OLDIFS=$IFS; IFS="$_mshkp_tab"; set -- $_mshkp_probe; IFS=$OLDIFS
    [ "$#" -ge 2 ] || { MERV_SSH_TRUST_LAST_REASON=probe-malformed; return 7; }
    _mshkp_alg="$1"; _mshkp_key="$2"; _mshkp_fp="${3:-}"
  else
    MERV_SSH_TRUST_LAST_REASON=capability-unknown
    return 7
  fi
  merv_ssh_trust_algorithm_valid "$_mshkp_alg" && merv_ssh_trust_key_valid "$_mshkp_key" || { MERV_SSH_TRUST_LAST_REASON=probe-malformed; return 7; }
  _mshkp_derived=$(merv_ssh_trust_derive_fingerprint "$_mshkp_alg" "$_mshkp_key" 2>/dev/null) || { MERV_SSH_TRUST_LAST_REASON=fingerprint-unavailable; return 7; }
  [ -n "$_mshkp_fp" ] || _mshkp_fp="$_mshkp_derived"
  merv_ssh_trust_fingerprint_valid "$_mshkp_fp" && [ "$_mshkp_fp" = "$_mshkp_derived" ] || { MERV_SSH_TRUST_LAST_REASON=probe-malformed; return 7; }
  SSH_PROBE_NODE="$_mshkp_node"; SSH_PROBE_SLOT="$_mshkp_slot"; SSH_PROBE_MAC="$_mshkp_mac"; SSH_PROBE_HOST="$_mshkp_host"; SSH_PROBE_PORT="$_mshkp_port"; SSH_PROBE_ALGORITHM="$_mshkp_alg"; SSH_PROBE_PUBLIC_KEY="$_mshkp_key"; SSH_PROBE_FINGERPRINT="$_mshkp_fp"
  merv_ssh_trust_find "$_mshkp_node"
  _mshkp_find_rc=$?
  if [ "$_mshkp_find_rc" -eq 0 ]; then
    if [ "$SSH_TRUST_HOST" = "$_mshkp_host" ] && [ "$SSH_TRUST_PORT" = "$_mshkp_port" ] && [ "$SSH_TRUST_FINGERPRINT" = "$_mshkp_fp" ] && [ "$SSH_TRUST_PUBLIC_KEY" = "$_mshkp_key" ]; then
      MERV_SSH_TRUST_LAST_STATUS=verified; return 0
    fi
    MERV_SSH_TRUST_LAST_REASON=key-or-endpoint-changed; MERV_SSH_TRUST_LAST_STATUS=changed; return 8
  fi
  [ "$_mshkp_find_rc" -eq 1 ] || {
    [ "$_mshkp_find_rc" -eq 3 ] && MERV_SSH_TRUST_LAST_STATUS=expired
    return 2
  }
  MERV_SSH_TRUST_LAST_REASON=ssh-trust-required
  MERV_SSH_TRUST_LAST_STATUS=untrusted
  return 6
}

merv_ssh_status() {
  _msshstat_slot="$1"; _msshstat_mac="$2"; _msshstat_host="${3:-}"; _msshstat_port="${4:-}"
  _msshstat_node=$(merv_ssh_trust_node_id "$_msshstat_slot" "$_msshstat_mac" "$_msshstat_host" "$_msshstat_port") || return 3
  merv_ssh_trust_find "$_msshstat_node"; _msshstat_rc=$?
  if [ "$_msshstat_rc" -eq 0 ]; then
    printf 'status=verified\nnode_id=%s\nhost=%s\nport=%s\nfingerprint=%s\n' "$SSH_TRUST_NODE" "$SSH_TRUST_HOST" "$SSH_TRUST_PORT" "$SSH_TRUST_FINGERPRINT"
    return 0
  fi
  [ "$_msshstat_rc" -eq 1 ] || {
    [ "$_msshstat_rc" -eq 3 ] && printf 'status=expired\nnode_id=%s\n' "$_msshstat_node"
    return 2
  }
  printf 'status=untrusted\nnode_id=%s\n' "$_msshstat_node"; return 6
}

merv_ssh_require_verified_node() {
  _msrv_slot="$1"; _msrv_host=$(merv_ssh_trust_normalize_host "$2") || { MERV_SSH_TRUST_LAST_REASON=invalid-endpoint; return 3; }
  _msrv_port=$(merv_ssh_trust_normalize_port "$3") || return 3
  _msrv_mac=$(merv_ssh_trust_mac_or_none "$4") || return 3
  _msrv_node=$(merv_ssh_trust_node_id "$_msrv_slot" "$_msrv_mac" "$_msrv_host" "$_msrv_port") || return 3
  merv_ssh_trust_find "$_msrv_node"; _msrv_find_rc=$?
  if [ "$_msrv_find_rc" -ne 0 ]; then
    [ "$_msrv_find_rc" -eq 1 ] && MERV_SSH_TRUST_LAST_REASON=ssh-trust-required && return 6
    [ "$_msrv_find_rc" -eq 3 ] && MERV_SSH_TRUST_LAST_REASON=trust-expired && return 9
    MERV_SSH_TRUST_LAST_REASON=trust-record-invalid
    return 2
  fi
  [ "$SSH_TRUST_HOST" = "$_msrv_host" ] && [ "$SSH_TRUST_PORT" = "$_msrv_port" ] || { MERV_SSH_TRUST_LAST_REASON=endpoint-changed; return 8; }
  [ "${MERV_SSH_CAPABILITY_PROVEN:-0}" = "1" ] || [ "${MERV_SSH_TEST_MODE:-0}" = "1" ] || { MERV_SSH_TRUST_LAST_REASON=capability-unknown; return 7; }
  return 0
}

merv_ssh_preflight_node_set() {
  _msp_file="$1"; [ -f "$_msp_file" ] || return 2
  _msp_nodes=' '; _msp_eps=' '; _msp_lines=''
  while IFS=' ' read -r _msp_slot _msp_host _msp_mac _msp_extra || [ -n "$_msp_slot" ]; do
    [ -z "$_msp_extra" ] || return 2
    case "$_msp_slot" in ''|*[!0-9]*) return 2 ;; esac
    if [ -z "$_msp_mac" ] && type json_get_flag >/dev/null 2>&1; then
      _msp_mac=$(json_get_flag "AUTO_NODE${_msp_slot}_MAC" "" "${SETTINGS_FILE:-}" 2>/dev/null)
    fi
    _msp_mac=$(merv_ssh_trust_mac_or_none "$_msp_mac") || return 2
    _msp_host=$(merv_ssh_trust_normalize_host "$_msp_host") || return 2
    _msp_port=$(merv_ssh_trust_normalize_port "${MERV_NODE_SSH_PORT:-22}") || return 2
    _msp_node=$(merv_ssh_trust_node_id "$_msp_slot" "$_msp_mac" "$_msp_host" "$_msp_port") || return 2
    case "$_msp_nodes" in *" $_msp_node "*) return 2 ;; esac
    case "$_msp_eps" in *" $_msp_host:$_msp_port "*) return 2 ;; esac
    _msp_nodes="$_msp_nodes$_msp_node "; _msp_eps="$_msp_eps$_msp_host:$_msp_port "; _msp_lines="$_msp_lines$_msp_slot $_msp_host $_msp_mac\n"
  done < "$_msp_file"
  [ -n "$_msp_lines" ] || return 0
  # Keep the probe loop in this shell.  A pipeline would run it in a
  # subshell on BusyBox ash, which loses MERV_SSH_TRUST_LAST_REASON and
  # MERV_SSH_TRUST_LAST_STATUS at the exact point callers need to publish a
  # useful trust/capability result.  It also made Sync report the misleading
  # literal reason "unknown" and caused its fallback acknowledgement to lose
  # the node context needed by the browser prompt.
  while IFS=' ' read -r _msp_slot _msp_host _msp_mac _msp_extra || [ -n "$_msp_slot" ]; do
    [ -n "$_msp_slot" ] || continue
    [ -z "$_msp_extra" ] || return 2
    merv_ssh_hostkey_probe "$_msp_slot" "$_msp_host" "${MERV_NODE_SSH_PORT:-22}" "$_msp_mac"
    _msp_probe_rc=$?
    if [ "$_msp_probe_rc" -ne 0 ]; then
      case "$_msp_probe_rc:${MERV_SSH_TRUST_LAST_REASON:-}" in
        10:*|11:*|*:unreachable|*:timeout|*:refused|*:no-route)
          MERV_SSH_LAST_REASON="${MERV_SSH_TRUST_LAST_REASON:-unreachable}"
          MERV_SSH_LAST_DETAIL="NODE${_msp_slot:-?} host-key probe could not reach the node"
          return 4
          ;;
      esac
      MERV_SSH_LAST_REASON="${MERV_SSH_TRUST_LAST_REASON:-probe-failed}"
      MERV_SSH_LAST_DETAIL="NODE${_msp_slot:-?} host-key preflight failed"
      return "$_msp_probe_rc"
    fi
    [ "$MERV_SSH_TRUST_LAST_STATUS" = verified ] || {
      [ -n "${MERV_SSH_TRUST_LAST_REASON:-}" ] || MERV_SSH_TRUST_LAST_REASON=ssh-trust-required
      case "${MERV_SSH_TRUST_LAST_REASON:-}" in
        unreachable|timeout|refused|no-route)
          MERV_SSH_LAST_REASON="$MERV_SSH_TRUST_LAST_REASON"
          MERV_SSH_LAST_DETAIL="NODE${_msp_slot:-?} host-key probe could not reach the node"
          return 4
          ;;
      esac
      MERV_SSH_LAST_REASON="$MERV_SSH_TRUST_LAST_REASON"
      MERV_SSH_LAST_DETAIL="NODE${_msp_slot:-?} host-key trust precondition failed"
      return 6
    }
  done < "$_msp_file"
}

# Convert the canonical settings node list (<slot> <host>) into the complete
# preflight contract (<slot> <host> <MAC>) and probe every node before a caller
# performs any local or remote mutation.  The helper is deliberately fail
# closed: a missing MAC, malformed line, duplicate endpoint, unknown SSH
# capability, or any unverified host key rejects the complete set.
merv_ssh_preflight_node_lines() {
  _mspnl_lines="${1:-}"; _mspnl_settings="${2:-${SETTINGS_FILE:-}}"
  [ -n "$_mspnl_settings" ] && [ -f "$_mspnl_settings" ] || return 2
  type json_get_flag >/dev/null 2>&1 || return 2
  merv_ssh_trust_init >/dev/null 2>&1 || return 2
  _mspnl_tmp="$MERV_SSH_TRUST_STAGING_ROOT/.preflight.$$.$(merv_ssh_trust_now)"
  merv_ssh_trust_path_valid "$_mspnl_tmp" || return 2
  ( umask 077; : > "$_mspnl_tmp" ) 2>/dev/null || return 1
  while IFS=' ' read -r _mspnl_slot _mspnl_host _mspnl_extra || [ -n "$_mspnl_slot" ]; do
    [ -n "$_mspnl_slot" ] || continue
    [ -z "$_mspnl_extra" ] || { merv_ssh_trust_cleanup_files "$_mspnl_tmp"; return 2; }
    case "$_mspnl_slot" in ''|*[!0-9]*) merv_ssh_trust_cleanup_files "$_mspnl_tmp"; return 2 ;; esac
    _mspnl_mac=$(json_get_flag "AUTO_NODE${_mspnl_slot}_MAC" "" "$_mspnl_settings" 2>/dev/null)
    _mspnl_mac=$(merv_ssh_trust_mac_or_none "$_mspnl_mac") || { merv_ssh_trust_cleanup_files "$_mspnl_tmp"; return 2; }
    _mspnl_host=$(merv_ssh_trust_normalize_host "$_mspnl_host") || { merv_ssh_trust_cleanup_files "$_mspnl_tmp"; return 2; }
    printf '%s %s %s\n' "$_mspnl_slot" "$_mspnl_host" "$_mspnl_mac" >> "$_mspnl_tmp" 2>/dev/null || { merv_ssh_trust_cleanup_files "$_mspnl_tmp"; return 1; }
  done <<EOF
$_mspnl_lines
EOF
  if type get_node_ssh_port >/dev/null 2>&1; then
    MERV_NODE_SSH_PORT=$(get_node_ssh_port 2>/dev/null) || MERV_NODE_SSH_PORT="${MERV_NODE_SSH_PORT:-22}"
  fi
  MERV_NODE_SSH_PORT=$(merv_ssh_trust_normalize_port "${MERV_NODE_SSH_PORT:-22}") || {
    merv_ssh_trust_cleanup_files "$_mspnl_tmp"
    return 2
  }
  merv_ssh_preflight_node_set "$_mspnl_tmp"; _mspnl_rc=$?
  merv_ssh_trust_cleanup_files "$_mspnl_tmp" || _mspnl_rc=1
  return "$_mspnl_rc"
}

merv_ssh_preflight_settings_file() {
  _mspfs_file="$1"
  [ -f "$_mspfs_file" ] || return 2
  type merv_node_list >/dev/null 2>&1 || return 2
  # var_settings.sh intentionally declares SETTINGS_FILE read-only.  Pass the
  # staged settings file directly to the canonical list reader instead of
  # temporarily rebinding the runtime path (which BusyBox ash rejects).
  _mspfs_nodes=$(merv_node_list "$_mspfs_file" 2>/dev/null); _mspfs_list_rc=$?
  [ "$_mspfs_list_rc" -eq 0 ] || return 2
  merv_ssh_preflight_node_lines "$_mspfs_nodes" "$_mspfs_file"
}

merv_ssh_preflight_configured_nodes() {
  merv_ssh_preflight_settings_file "${1:-${SETTINGS_FILE:-}}"
}

merv_ssh_trust_issue_challenge() {
  _mstic_slot="$1"; _mstic_host="$2"; _mstic_port="$3"; _mstic_mac="$4"
  merv_ssh_trust_init >/dev/null 2>&1 || return 1
  _mstic_now=$(merv_ssh_trust_now); _mstic_count=0
  for _mstic_existing in "$MERV_SSH_TRUST_PENDING_ROOT"/c.*; do
    [ -d "$_mstic_existing" ] || continue
    _mstic_state=$(cat "$_mstic_existing/state" 2>/dev/null)
    _mstic_created=$(cat "$_mstic_existing/created_epoch" 2>/dev/null)
    if [ "$_mstic_state" = pending ] && merv_ssh_trust_uint "$_mstic_created" &&
       [ "$(( _mstic_now - _mstic_created ))" -le "$MERV_SSH_TRUST_PENDING_TTL_SEC" ] 2>/dev/null; then
      _mstic_count=$((_mstic_count + 1))
    fi
  done
  [ "$_mstic_count" -lt "$MERV_SSH_TRUST_MAX_PENDING" ] 2>/dev/null || return 12
  if merv_ssh_hostkey_probe "$_mstic_slot" "$_mstic_host" "$_mstic_port" "$_mstic_mac"; then
    return 2
  else
    _mstic_probe_rc=$?
  fi
  [ "$_mstic_probe_rc" -eq 6 ] || [ "$_mstic_probe_rc" -eq 8 ] || return "$_mstic_probe_rc"
  [ -n "${SSH_PROBE_NODE:-}" ] || return 7
  : "${MERV_SSH_TRUST_CHALLENGE_SEQ:=0}"
  case "$MERV_SSH_TRUST_CHALLENGE_SEQ" in ''|*[!0-9]*) MERV_SSH_TRUST_CHALLENGE_SEQ=0 ;; esac
  _mstic_seq=$((MERV_SSH_TRUST_CHALLENGE_SEQ + 1)); MERV_SSH_TRUST_CHALLENGE_SEQ="$_mstic_seq"
  _mstic_id="c.$_mstic_now.$$.$_mstic_seq"; case "$_mstic_id" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  _mstic_dir="$MERV_SSH_TRUST_PENDING_ROOT/$_mstic_id"
  _mstic_tmp="$MERV_SSH_TRUST_PENDING_ROOT/.$_mstic_id.tmp.$$"
  mkdir "$_mstic_tmp" 2>/dev/null || return 1
  _mstic_old_fingerprint="${SSH_TRUST_FINGERPRINT:-}"
  ( umask 077
    printf '%s\n' "$SSH_PROBE_NODE" > "$_mstic_tmp/node_id"
    printf '%s\n' "$SSH_PROBE_SLOT" > "$_mstic_tmp/slot"
    printf '%s\n' "$SSH_PROBE_MAC" > "$_mstic_tmp/mac"
    printf '%s\n' "$SSH_PROBE_HOST" > "$_mstic_tmp/host"
    printf '%s\n' "$SSH_PROBE_PORT" > "$_mstic_tmp/port"
    printf '%s\n' "$SSH_PROBE_ALGORITHM" > "$_mstic_tmp/algorithm"
    printf '%s\n' "$SSH_PROBE_PUBLIC_KEY" > "$_mstic_tmp/public_key_b64"
    printf '%s\n' "$SSH_PROBE_FINGERPRINT" > "$_mstic_tmp/fingerprint_sha256"
    printf '%s\n' "$_mstic_old_fingerprint" > "$_mstic_tmp/old_fingerprint_sha256"
    printf '%s\n' "$_mstic_probe_rc" > "$_mstic_tmp/probe_status"
    printf '%s\n' "$_mstic_now" > "$_mstic_tmp/created_epoch"
    printf '%s\n' pending > "$_mstic_tmp/state"
  ) 2>/dev/null || {
    merv_ssh_trust_cleanup_dir "$_mstic_tmp"
    return 1
  }
  chmod 600 "$_mstic_tmp"/* 2>/dev/null || {
    merv_ssh_trust_cleanup_dir "$_mstic_tmp"
    return 1
  }
  mv -f "$_mstic_tmp" "$_mstic_dir" 2>/dev/null || {
    merv_ssh_trust_cleanup_dir "$_mstic_tmp"
    return 1
  }
  MERV_SSH_TRUST_CHALLENGE_ID="$_mstic_id"; MERV_SSH_TRUST_CHALLENGE_FINGERPRINT="$SSH_PROBE_FINGERPRINT"; MERV_SSH_TRUST_CHALLENGE_NODE="$SSH_PROBE_NODE"
  printf '%s\n' "$_mstic_id"
}

merv_ssh_trust_validate_challenge() {
  _mstvc_dir="$1"
  [ -d "$_mstvc_dir" ] || return 1
  _mstvc_state=$(cat "$_mstvc_dir/state" 2>/dev/null)
  [ "$_mstvc_state" = pending ] || return 1
  _mstvc_slot=$(cat "$_mstvc_dir/slot" 2>/dev/null)
  _mstvc_mac=$(cat "$_mstvc_dir/mac" 2>/dev/null)
  _mstvc_host=$(cat "$_mstvc_dir/host" 2>/dev/null)
  _mstvc_port=$(cat "$_mstvc_dir/port" 2>/dev/null)
  _mstvc_alg=$(cat "$_mstvc_dir/algorithm" 2>/dev/null)
  _mstvc_key=$(cat "$_mstvc_dir/public_key_b64" 2>/dev/null)
  _mstvc_fp=$(cat "$_mstvc_dir/fingerprint_sha256" 2>/dev/null)
  _mstvc_status=$(cat "$_mstvc_dir/probe_status" 2>/dev/null)
  _mstvc_created=$(cat "$_mstvc_dir/created_epoch" 2>/dev/null)
  case "$_mstvc_status" in 6|8) ;; *) return 1 ;; esac
  merv_ssh_trust_uint "$_mstvc_slot" && [ "$_mstvc_slot" -ge 1 ] || return 1
  _mstvc_mac_norm=$(merv_ssh_trust_mac_or_none "$_mstvc_mac") || return 1
  [ "$_mstvc_mac_norm" = "$_mstvc_mac" ] || return 1
  _mstvc_host_norm=$(merv_ssh_trust_normalize_host "$_mstvc_host") || return 1
  [ "$_mstvc_host_norm" = "$_mstvc_host" ] || return 1
  _mstvc_port_norm=$(merv_ssh_trust_normalize_port "$_mstvc_port") || return 1
  [ "$_mstvc_port_norm" = "$_mstvc_port" ] || return 1
  merv_ssh_trust_algorithm_valid "$_mstvc_alg" && merv_ssh_trust_key_valid "$_mstvc_key" && merv_ssh_trust_fingerprint_valid "$_mstvc_fp" || return 1
  _mstvc_derived=$(merv_ssh_trust_derive_fingerprint "$_mstvc_alg" "$_mstvc_key" 2>/dev/null) || return 1
  [ "$_mstvc_derived" = "$_mstvc_fp" ] || return 1
  _mstvc_node=$(merv_ssh_trust_node_id "$_mstvc_slot" "$_mstvc_mac" "$_mstvc_host" "$_mstvc_port") || return 1
  [ "$(cat "$_mstvc_dir/node_id" 2>/dev/null)" = "$_mstvc_node" ] || return 1
  merv_ssh_trust_uint "$_mstvc_created" || return 1
  _mstvc_now=$(merv_ssh_trust_now); merv_ssh_trust_uint "$_mstvc_now" || return 1
  [ "$_mstvc_created" -le "$_mstvc_now" ] 2>/dev/null || return 1
  return 0
}

merv_ssh_trust_quarantine_move() {
  _mstqm_src="$1"; _mstqm_dest="$2"
  merv_ssh_trust_path_valid "$_mstqm_src" || return 1
  merv_ssh_trust_path_valid "$_mstqm_dest" || return 1
  _mstqm_count=0
  for _mstqm_existing in "$MERV_SSH_TRUST_QUARANTINE_ROOT"/*; do
    [ -e "$_mstqm_existing" ] || continue
    _mstqm_count=$((_mstqm_count + 1))
  done
  [ "$_mstqm_count" -lt "$MERV_SSH_TRUST_MAX_QUARANTINE" ] 2>/dev/null || return 1
  mv "$_mstqm_src" "$_mstqm_dest" 2>/dev/null || return 1
  return 0
}

merv_ssh_trust_enroll_challenge() {
  _mste_id="$1"; _mste_decision="$2"
  case "$_mste_id" in c.[0-9]*.[0-9]*.*) ;; *) return 2 ;; esac
  case "$_mste_decision" in accept|reject) ;; *) return 2 ;; esac
  _mste_dir="$MERV_SSH_TRUST_PENDING_ROOT/$_mste_id"; [ -d "$_mste_dir" ] || return 2
  [ "$(cat "$_mste_dir/state" 2>/dev/null)" = pending ] || return 9
  _mste_created=$(cat "$_mste_dir/created_epoch" 2>/dev/null); _mste_now=$(merv_ssh_trust_now)
  merv_ssh_trust_uint "$_mste_created" && merv_ssh_trust_uint "$_mste_now" || return 2
  [ "$(( _mste_now - _mste_created ))" -le "$MERV_SSH_TRUST_PENDING_TTL_SEC" ] 2>/dev/null || { printf 'expired\n'; return 9; }
  if [ "$_mste_decision" = reject ]; then printf 'rejected\n' > "$_mste_dir/state" 2>/dev/null || return 1; return 10; fi
  _mste_slot=$(cat "$_mste_dir/slot"); _mste_mac=$(cat "$_mste_dir/mac"); _mste_host=$(cat "$_mste_dir/host"); _mste_port=$(cat "$_mste_dir/port"); _mste_alg=$(cat "$_mste_dir/algorithm"); _mste_key=$(cat "$_mste_dir/public_key_b64"); _mste_oldfp=$(cat "$_mste_dir/fingerprint_sha256")
  merv_ssh_hostkey_probe "$_mste_slot" "$_mste_host" "$_mste_port" "$_mste_mac" || return 7
  [ "$SSH_PROBE_FINGERPRINT" = "$_mste_oldfp" ] && [ "$SSH_PROBE_PUBLIC_KEY" = "$_mste_key" ] || return 8
  _mste_stage=$(merv_ssh_trust_stage_record "$_mste_slot" "$_mste_mac" "$_mste_host" "$_mste_port" "$_mste_alg" "$_mste_key" "$_mste_oldfp") || return $?
  merv_ssh_trust_publish_stage "$_mste_stage" || return 1
  printf 'verified\n' > "$_mste_dir/state" 2>/dev/null || return 1
  printf 'verified\n'
}

# Final bounded reaper used by the main-router trust worker.  It only walks
# immediate children of the exact trust roots, never follows user-supplied
# paths, and moves malformed/terminal entries into the bounded quarantine
# namespace instead of recursively deleting unknown content.
merv_ssh_trust_prune_pending() {
  merv_ssh_trust_root_valid || return 2
  merv_ssh_trust_init >/dev/null 2>&1 || return 1
  _mstpr_now=$(merv_ssh_trust_now); _mstpr_seq=0; _mstpr_pending=0
  for _mstpr_dir in "$MERV_SSH_TRUST_PENDING_ROOT"/c.*; do
    [ -d "$_mstpr_dir" ] || continue
    _mstpr_id=${_mstpr_dir##*/}; case "$_mstpr_id" in c.*) ;; *) continue ;; esac
    _mstpr_state=$(cat "$_mstpr_dir/state" 2>/dev/null)
    _mstpr_created=$(cat "$_mstpr_dir/created_epoch" 2>/dev/null)
    if ! merv_ssh_trust_uint "$_mstpr_created" || [ -z "$_mstpr_state" ]; then
      _mstpr_seq=$((_mstpr_seq + 1)); merv_ssh_trust_quarantine_move "$_mstpr_dir" "$MERV_SSH_TRUST_QUARANTINE_ROOT/${_mstpr_id}.invalid.$_mstpr_seq" || return 1
      continue
    fi
    case "$_mstpr_state" in pending|expired|canceled|rejected|failed|verified) ;; *)
      _mstpr_seq=$((_mstpr_seq + 1)); merv_ssh_trust_quarantine_move "$_mstpr_dir" "$MERV_SSH_TRUST_QUARANTINE_ROOT/${_mstpr_id}.invalid.$_mstpr_seq" || return 1
      continue
      ;;
    esac
    if [ "$_mstpr_state" = pending ] && ! merv_ssh_trust_validate_challenge "$_mstpr_dir"; then
      _mstpr_seq=$((_mstpr_seq + 1)); merv_ssh_trust_quarantine_move "$_mstpr_dir" "$MERV_SSH_TRUST_QUARANTINE_ROOT/${_mstpr_id}.invalid.$_mstpr_seq" || return 1
      continue
    fi
    if [ "$_mstpr_state" = pending ]; then
      _mstpr_age=$(( _mstpr_now - _mstpr_created ))
      if [ "$_mstpr_age" -gt "$MERV_SSH_TRUST_PENDING_TTL_SEC" ] 2>/dev/null; then
        printf 'expired\n' > "$_mstpr_dir/state" 2>/dev/null || return 1
        printf 'none\n' > "$_mstpr_dir/request_id" 2>/dev/null || return 1
      fi
    fi
    _mstpr_age=$(( _mstpr_now - _mstpr_created ))
    case "$(cat "$_mstpr_dir/state" 2>/dev/null)" in
      expired|canceled|rejected|failed|verified)
        if [ "$_mstpr_age" -gt "$MERV_SSH_TRUST_RETENTION_SEC" ] 2>/dev/null; then
          _mstpr_seq=$((_mstpr_seq + 1)); merv_ssh_trust_quarantine_move "$_mstpr_dir" "$MERV_SSH_TRUST_QUARANTINE_ROOT/${_mstpr_id}.terminal.$_mstpr_seq" || return 1
        fi
        ;;
    esac
  done
  for _mstpr_dir in "$MERV_SSH_TRUST_REQUESTS_ROOT"/p.*; do
    [ -d "$_mstpr_dir" ] || continue
    _mstpr_id=${_mstpr_dir##*/}; case "$_mstpr_id" in p.*) ;; *) continue ;; esac
    _mstpr_state=$(cat "$_mstpr_dir/state" 2>/dev/null)
    _mstpr_created=$(cat "$_mstpr_dir/created_epoch" 2>/dev/null)
    if ! merv_ssh_trust_uint "$_mstpr_created" || [ -z "$_mstpr_state" ]; then
      _mstpr_seq=$((_mstpr_seq + 1)); merv_ssh_trust_quarantine_move "$_mstpr_dir" "$MERV_SSH_TRUST_QUARANTINE_ROOT/${_mstpr_id}.invalid.$_mstpr_seq" || return 1
      continue
    fi
    case "$_mstpr_state" in pending|enrolling|committed|running|expired|canceled|failed|completed|consumed) ;; *)
      _mstpr_seq=$((_mstpr_seq + 1)); merv_ssh_trust_quarantine_move "$_mstpr_dir" "$MERV_SSH_TRUST_QUARANTINE_ROOT/${_mstpr_id}.invalid.$_mstpr_seq" || return 1
      continue
      ;;
    esac
    if [ "$_mstpr_state" = pending ] || [ "$_mstpr_state" = enrolling ] || [ "$_mstpr_state" = running ]; then
      _mstpr_age=$(( _mstpr_now - _mstpr_created ))
      if [ "$_mstpr_age" -gt "$MERV_SSH_TRUST_PENDING_TTL_SEC" ] 2>/dev/null; then
        printf 'expired\n' > "$_mstpr_dir/state" 2>/dev/null || return 1
        printf 'none\n' > "$_mstpr_dir/resume_id" 2>/dev/null || return 1
      fi
    fi
    case "$(cat "$_mstpr_dir/state" 2>/dev/null)" in pending|enrolling|committed|running) _mstpr_pending=$((_mstpr_pending + 1)) ;; esac
    _mstpr_age=$(( _mstpr_now - _mstpr_created ))
    case "$(cat "$_mstpr_dir/state" 2>/dev/null)" in expired|canceled|failed|completed|consumed)
      if [ "$_mstpr_age" -gt "$MERV_SSH_TRUST_RETENTION_SEC" ] 2>/dev/null; then
        _mstpr_seq=$((_mstpr_seq + 1)); merv_ssh_trust_quarantine_move "$_mstpr_dir" "$MERV_SSH_TRUST_QUARANTINE_ROOT/${_mstpr_id}.terminal.$_mstpr_seq" || return 1
      fi
      ;;
    esac
  done
  [ "$_mstpr_pending" -le "$MERV_SSH_TRUST_MAX_PENDING" ] 2>/dev/null || return 1
  _mstpr_stage_count=0
  for _mstpr_file in "$MERV_SSH_TRUST_STAGING_ROOT"/.*; do
    [ -f "$_mstpr_file" ] || continue
    case "$_mstpr_file" in *.known_hosts.*|*.candidate.*|*.accepted.*|*.probe-*|*.enroll-*|*/fingerprint.*|*/digest.*) ;;
      *) continue ;;
    esac
    _mstpr_stage_count=$((_mstpr_stage_count + 1))
    if [ "$_mstpr_stage_count" -gt "$MERV_SSH_TRUST_MAX_STAGING" ] 2>/dev/null; then
      _mstpr_seq=$((_mstpr_seq + 1)); merv_ssh_trust_quarantine_move "$_mstpr_file" "$MERV_SSH_TRUST_QUARANTINE_ROOT/${_mstpr_file##*/}.$$.staging" || return 1
    fi
  done
  return 0
}
