#!/bin/sh
# MerVLAN process identity and owner metadata primitives.
#
# This file is deliberately dependency-light so it can be used by the service
# event handler, progress publisher, action markers, and lock users without
# pulling in the full VLAN manager.  A PID is never considered ownership by
# itself: the /proc start time and an acquisition nonce are part of the
# identity contract.

[ -n "${LIB_IDENTITY_LOADED:-}" ] && return 0 2>/dev/null
LIB_IDENTITY_LOADED=1
MERV_IDENTITY_NONCE_SEQ="${MERV_IDENTITY_NONCE_SEQ:-0}"

merv_identity_proc_start() {
  _mi_pid="${1:-$$}"
  _mi_root="${2:-/proc}"
  case "$_mi_pid" in ''|*[!0-9]*) return 1 ;; esac
  _mi_line=$(cat "$_mi_root/$_mi_pid/stat" 2>/dev/null) || return 1
  case "$_mi_line" in *") "*) _mi_tail=${_mi_line##*) } ;; *) return 1 ;; esac
  _mi_start=$(printf '%s\n' "$_mi_tail" | awk '{print $20}')
  case "$_mi_start" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$_mi_start"
}

merv_identity_matches() {
  _mi_pid="$1"
  _mi_expected="$2"
  case "$_mi_pid:$_mi_expected" in *[!0-9:]*|:*|*::*) return 1 ;; esac
  _mi_actual=$(merv_identity_proc_start "$_mi_pid" "${3:-/proc}") || return 1
  [ "$_mi_actual" = "$_mi_expected" ] || return 1
  [ "${3:-/proc}" != "/proc" ] || kill -0 "$_mi_pid" 2>/dev/null
}

merv_identity_nonce() {
  case "$MERV_IDENTITY_NONCE_SEQ" in ''|*[!0-9]*) MERV_IDENTITY_NONCE_SEQ=0 ;; esac
  MERV_IDENTITY_NONCE_SEQ=$((MERV_IDENTITY_NONCE_SEQ + 1))
  _mi_now=$(date +%s 2>/dev/null || printf '0')
  _mi_start=$(merv_identity_proc_start "$$" 2>/dev/null || printf '0')
  printf '%s.%s.%s.%s\n' "$_mi_now" "$$" "$_mi_start" "$MERV_IDENTITY_NONCE_SEQ"
}

merv_identity_uint() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
}

merv_identity_nonce_valid() {
  case "${1:-}" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  [ "${#1}" -le 160 ]
}

merv_identity_atomic_field() {
  _mi_dir="$1"
  _mi_name="$2"
  _mi_value="$3"
  case "$_mi_name" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  # Command substitution strips a trailing newline, so detect control bytes
  # through the byte-oriented grep contract instead of embedding them in a
  # shell pattern.  Lock/identity metadata must remain one physical line.
  printf '%s' "$_mi_value" | LC_ALL=C grep -q '[[:cntrl:]]' 2>/dev/null && return 1
  _mi_tmp="$_mi_dir/.${_mi_name}.tmp.$$"
  printf '%s\n' "$_mi_value" > "$_mi_tmp" 2>/dev/null || { rm -f "$_mi_tmp" 2>/dev/null; return 1; }
  chmod 600 "$_mi_tmp" 2>/dev/null || { rm -f "$_mi_tmp" 2>/dev/null; return 1; }
  mv -f "$_mi_tmp" "$_mi_dir/$_mi_name" 2>/dev/null || { rm -f "$_mi_tmp" 2>/dev/null; return 1; }
}

merv_identity_current_start() {
  merv_identity_proc_start "$$" "${1:-/proc}"
}
