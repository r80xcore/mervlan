#!/bin/sh
# ============================================================================ #
# MerVLAN bounded node-reconciliation marker helpers                         #
# ============================================================================ #
# This stores only a small, non-secret retry marker. It is not a backup and
# never copies an installation tree or user data to the router.

[ -n "${LIB_NODE_RECONCILE_LOADED:-}" ] && return 0 2>/dev/null

: "${MERV_STATE_ROOT:=/jffs/addons/mervlan_state}"
: "${MERV_NODE_RECONCILE_FILE:=$MERV_STATE_ROOT/node_reconcile.pending}"

merv_node_reconcile_path_valid() {
  case "${1:-}" in
    "$MERV_STATE_ROOT"/*) return 0 ;;
    *) return 1 ;;
  esac
}

merv_node_reconcile_value() {
  _mnrv_value="${1:-}"
  case "$_mnrv_value" in
    *[!A-Za-z0-9._:/-]*) return 1 ;;
  esac
  printf '%s' "$_mnrv_value"
}

merv_node_reconcile_write() {
  _mnrw_action=$(merv_node_reconcile_value "${1:-}") || return 1
  _mnrw_reason=$(merv_node_reconcile_value "${2:-unknown}") || return 1
  _mnrw_detail=$(merv_node_reconcile_value "${3:-none}") || return 1
  _mnrw_attempt=$(merv_node_reconcile_value "${4:-0}") || return 1
  _mnrw_next=$(merv_node_reconcile_value "${5:-0}") || return 1
  _mnrw_digest=$(merv_node_reconcile_value "${6:-unknown}") || return 1
  case "$_mnrw_action" in
    enable|disable|setupenable|setupdisable|nodeenable|nodedisable) ;;
    *) return 1;
  esac
  merv_node_reconcile_path_valid "$MERV_NODE_RECONCILE_FILE" || return 1
  mkdir -p "$MERV_STATE_ROOT" 2>/dev/null || return 1
  chmod 700 "$MERV_STATE_ROOT" 2>/dev/null || return 1
  : "${MERV_NODE_RECONCILE_SEQ:=0}"
  MERV_NODE_RECONCILE_SEQ=$((MERV_NODE_RECONCILE_SEQ + 1))
  _mnrw_tmp="$MERV_NODE_RECONCILE_FILE.tmp.$$.$MERV_NODE_RECONCILE_SEQ"
  ( umask 077
    {
      printf 'format=1\n'
      printf 'action=%s\n' "$_mnrw_action"
      printf 'reason=%s\n' "$_mnrw_reason"
      printf 'detail=%s\n' "$_mnrw_detail"
      printf 'attempt=%s\n' "$_mnrw_attempt"
      printf 'next_epoch=%s\n' "$_mnrw_next"
      printf 'node_digest=%s\n' "$_mnrw_digest"
      printf 'updated_epoch=%s\n' "$(date +%s 2>/dev/null || printf '0')"
    } > "$_mnrw_tmp"
  ) 2>/dev/null || { rm -f "$_mnrw_tmp" 2>/dev/null || :; return 1; }
  chmod 600 "$_mnrw_tmp" 2>/dev/null || { rm -f "$_mnrw_tmp" 2>/dev/null || :; return 1; }
  mv -f "$_mnrw_tmp" "$MERV_NODE_RECONCILE_FILE" 2>/dev/null || {
    rm -f "$_mnrw_tmp" 2>/dev/null || :
    return 1
  }
}

merv_node_reconcile_get() {
  _mnrg_key="$1"
  _mnrg_default="${2:-}"
  case "$_mnrg_key" in
    action|reason|detail|attempt|next_epoch|node_digest|updated_epoch) ;;
    *) printf '%s' "$_mnrg_default"; return 1;
  esac
  [ -f "$MERV_NODE_RECONCILE_FILE" ] || { printf '%s' "$_mnrg_default"; return 1; }
  _mnrg_value=$(sed -n "s/^${_mnrg_key}=//p" "$MERV_NODE_RECONCILE_FILE" 2>/dev/null | tail -n 1)
  [ -n "$_mnrg_value" ] || _mnrg_value="$_mnrg_default"
  printf '%s' "$_mnrg_value"
}

merv_node_reconcile_active() {
  [ -f "$MERV_NODE_RECONCILE_FILE" ] || return 1
  [ "$(sed -n 's/^format=//p' "$MERV_NODE_RECONCILE_FILE" 2>/dev/null | head -n 1)" = "1" ] || return 1
  case "$(merv_node_reconcile_get action '')" in
    enable|disable|setupenable|setupdisable|nodeenable|nodedisable) return 0 ;;
    *) return 1 ;;
  esac
}

merv_node_reconcile_clear() {
  [ -e "$MERV_NODE_RECONCILE_FILE" ] || return 0
  merv_node_reconcile_path_valid "$MERV_NODE_RECONCILE_FILE" || return 1
  rm -f "$MERV_NODE_RECONCILE_FILE" 2>/dev/null
}

LIB_NODE_RECONCILE_LOADED=1
