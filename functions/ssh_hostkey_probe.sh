#!/bin/sh
# Bounded, non-mutating Dropbear first-contact probe.
#
# This is the only production path allowed to use one -y.  It runs in a fresh
# private HOME, requests -N (no remote command), waits only for Dropbear to
# publish the host key, then terminates the client before authentication can
# start a remote action.  The displayed fingerprint and the exact captured
# known-host key must match before the canonical tuple is returned.

: "${MERV_BASE:=/jffs/addons/mervlan}"
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh" || exit 2
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh" || exit 2
[ -n "${LIB_IDENTITY_LOADED:-}" ] || . "$MERV_BASE/settings/lib_identity.sh" || exit 2
[ -n "${LIB_SSH_TRUST_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh_trust.sh" || exit 2

_shkp_node="${1:-}"
_shkp_host=$(merv_ssh_trust_normalize_host "${2:-}") || exit 2
_shkp_port=$(merv_ssh_trust_normalize_port "${3:-}") || exit 2
printf '%s\n' "$_shkp_node" | grep -Eq '^NODE[1-9][0-9]*@[A-Za-z0-9.:-]+$' || exit 2
# The node ID may be MAC-based or endpoint-based.  The parent worker already
# derived and validated it; this adapter only preserves that identity and never
# substitutes a browser- or probe-supplied node key.

_shkp_user=$(json_get_flag NODE_SSH_USER "__MISSING__" "$SETTINGS_FILE" 2>/dev/null)
[ "$_shkp_user" = "__MISSING__" ] || [ -n "$_shkp_user" ] || _shkp_user=""
[ -n "$_shkp_user" ] || _shkp_user=$(json_get_flag SSH_USER admin "$SETTINGS_FILE" 2>/dev/null)
[ -n "$_shkp_user" ] || _shkp_user=admin
case "$_shkp_user" in *[!A-Za-z0-9._-]*) exit 2 ;; esac
[ -f "${SSH_KEY:-}" ] || exit 3

_shkp_client="${MERV_SSH_CLIENT:-dbclient}"
case "$_shkp_client" in *[!A-Za-z0-9_./-]*) exit 2 ;; esac
if merv_has merv_cmd; then
  _shkp_client_path=$(merv_cmd "$_shkp_client" 2>/dev/null) || exit 3
else
  _shkp_client_path="$_shkp_client"
  [ -x "$_shkp_client_path" ] || exit 3
fi

_shkp_root="${TMPDIR:-/tmp/mervlan_tmp}/ssh_hostkey_probe.$$"
case "$_shkp_root" in /tmp/mervlan_tmp/ssh_hostkey_probe.[0-9]*) ;; *) exit 2 ;; esac
mkdir -p "$_shkp_root/.ssh" 2>/dev/null || exit 4
chmod 700 "$_shkp_root" "$_shkp_root/.ssh" 2>/dev/null || exit 4
_shkp_pid=""
_shkp_start=""
_shkp_identity_failure=0
_shkp_cleanup() {
  if [ -n "${_shkp_pid:-}" ] && [ -n "${_shkp_start:-}" ] &&
     merv_identity_matches "$_shkp_pid" "$_shkp_start" 2>/dev/null; then
    kill "$_shkp_pid" 2>/dev/null || :
    sleep 1
    merv_identity_matches "$_shkp_pid" "$_shkp_start" 2>/dev/null &&
      kill -9 "$_shkp_pid" 2>/dev/null || :
  elif [ -n "${_shkp_pid:-}" ] && kill -0 "$_shkp_pid" 2>/dev/null; then
    # A live child whose start identity no longer matches might be a reused
    # PID.  Never signal or wait on it: preserve the workspace for recovery
    # instead of turning this bounded probe into an unbounded wait.
    _shkp_identity_failure=1
  fi
  [ "${_shkp_identity_failure:-0}" -eq 0 ] && [ -n "${_shkp_pid:-}" ] &&
    wait "$_shkp_pid" 2>/dev/null || :
  if [ "${_shkp_identity_failure:-0}" -eq 1 ]; then
    # The child could not be authenticated by PID/start identity. Preserve
    # its exact probe workspace and an explicit recovery marker instead of
    # silently removing state while an unknown child may still be running.
    printf '%s\n' "child-identity-unverifiable" > "$_shkp_root/recovery.pending" 2>/dev/null || :
    printf '%s\n' "[ERROR] SSH host-key probe retained recovery workspace $_shkp_root" >&2
  else
    rm -f "$_shkp_root/.ssh/known_hosts" "$_shkp_root/client.stdout" "$_shkp_root/client.stderr" 2>/dev/null || :
    rmdir "$_shkp_root/.ssh" "$_shkp_root" 2>/dev/null || :
  fi
}
_shkp_signal_handling=0
_shkp_handle_signal() {
  _shkp_signal_status="$1"
  [ "${_shkp_signal_handling:-0}" -eq 0 ] || exit "$_shkp_signal_status"
  _shkp_signal_handling=1
  trap - INT TERM
  printf '%s\n' "[WARN] SSH host-key probe interrupted (rc=$_shkp_signal_status)" >&2
  exit "$_shkp_signal_status"
}
trap '_shkp_cleanup' EXIT
trap '_shkp_handle_signal 130' INT
trap '_shkp_handle_signal 143' TERM

_shkp_home="$_shkp_root"
export HOME="$_shkp_home"
"$_shkp_client_path" -y -N -p "$_shkp_port" -i "$SSH_KEY" \
  "$_shkp_user@$_shkp_host" >"$_shkp_root/client.stdout" 2>"$_shkp_root/client.stderr" &
_shkp_pid=$!
_shkp_start=$(merv_identity_proc_start "$_shkp_pid" 2>/dev/null || printf '')
case "$_shkp_start" in
  ''|*[!0-9]*)
    _shkp_start=""
    _shkp_identity_failure=1
    printf '%s\n' "[ERROR] SSH host-key probe could not verify child process identity" >&2
    exit 4
    ;;
esac
_shkp_wait="${MERV_SSH_CONNECT_TIMEOUT:-10}"
case "$_shkp_wait" in ''|*[!0-9]*) _shkp_wait=10 ;; esac
[ "$_shkp_wait" -ge 1 ] 2>/dev/null || _shkp_wait=10
_shkp_tick=0
while [ "$_shkp_tick" -lt "$_shkp_wait" ]; do
  [ -s "$_shkp_root/.ssh/known_hosts" ] && break
  merv_identity_matches "$_shkp_pid" "$_shkp_start" 2>/dev/null || break
  sleep 1
  _shkp_tick=$((_shkp_tick + 1))
done
if [ ! -s "$_shkp_root/.ssh/known_hosts" ]; then
  if grep -qi "Connection refused" "$_shkp_root/client.stderr" 2>/dev/null; then
    exit 11
  fi
  # ASUS Dropbear commonly reports an unreachable route as "Connect failed"
  # instead of the OpenSSH-style timeout text.  No known_hosts record exists
  # at this point, so this is a pre-session transport failure, not a
  # host-key/identity result.  Callers may therefore try their already-pinned
  # recovery endpoint; any key observed by the probe remains terminal below.
  if grep -qi "No route to host\|Network is unreachable\|timed out\|Connection timed out\|Connect failed\|Connection closed\|Connection reset\|Connection aborted" "$_shkp_root/client.stderr" 2>/dev/null; then
    exit 10
  fi
  exit 5
fi

_shkp_host_token="$_shkp_host"
[ "$_shkp_port" = 22 ] || _shkp_host_token="[$_shkp_host]:$_shkp_port"
_shkp_count=$(awk -v h="$_shkp_host_token" '$1==h {n++} END {print n+0}' "$_shkp_root/.ssh/known_hosts" 2>/dev/null)
[ "$_shkp_count" = 1 ] || exit 5
_shkp_record=$(awk -v h="$_shkp_host_token" '$1==h {print $2 "\t" $3; exit}' "$_shkp_root/.ssh/known_hosts" 2>/dev/null) || exit 5
_shkp_algorithm=$(printf '%s\n' "$_shkp_record" | awk -F '\t' '{print $1}')
_shkp_key=$(printf '%s\n' "$_shkp_record" | awk -F '\t' '{print $2}')
merv_ssh_trust_algorithm_valid "$_shkp_algorithm" || exit 5
merv_ssh_trust_key_valid "$_shkp_key" || exit 5
_shkp_display=$(awk '{for (i=1; i<=NF; i++) if (substr($i,1,7)=="SHA256:") {print $i; exit}}' "$_shkp_root/client.stderr" 2>/dev/null)
case "$_shkp_display" in *')') _shkp_display="${_shkp_display%)}" ;; esac
merv_ssh_trust_fingerprint_valid "$_shkp_display" || exit 5
_shkp_derived=$(merv_ssh_trust_derive_fingerprint "$_shkp_algorithm" "$_shkp_key" 2>/dev/null) || exit 5
[ "$_shkp_display" = "$_shkp_derived" ] || exit 5

printf '%s\t%s\t%s\n' "$_shkp_algorithm" "$_shkp_key" "$_shkp_display"
exit 0
