#!/bin/sh
# Durable maintenance-recovery transaction metadata.
#
# This library stores only bounded, non-executable names for the exact
# backup-root activation trees that must survive a failed transaction.

[ -n "${LIB_MAINTENANCE_RECOVERY_LOADED:-}" ] && return 0 2>/dev/null

: "${MERV_MAINTENANCE_RECOVERY_ROOT:=/jffs/addons/mervlan_backups}"
: "${MERV_MAINTENANCE_RECOVERY_MARKER:=$MERV_MAINTENANCE_RECOVERY_ROOT/.mervlan.recovery}"

merv_maintenance_recovery_component_valid() {
  _mmr_component="$1"
  case "$_mmr_component" in
    .mervlan.old.*) _mmr_suffix=${_mmr_component#.mervlan.old.} ;;
    .mervlan.new.*) _mmr_suffix=${_mmr_component#.mervlan.new.} ;;
    *) return 1 ;;
  esac
  case "$_mmr_suffix" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

merv_maintenance_recovery_path_component() {
  _mmr_path="$1"
  case "$_mmr_path" in
    "$MERV_MAINTENANCE_RECOVERY_ROOT"/.mervlan.old.*|"$MERV_MAINTENANCE_RECOVERY_ROOT"/.mervlan.new.*)
      _mmr_component=${_mmr_path#"$MERV_MAINTENANCE_RECOVERY_ROOT"/}
      merv_maintenance_recovery_component_valid "$_mmr_component" || return 1
      printf '%s\n' "$_mmr_component"
      ;;
    *) return 1 ;;
  esac
}

merv_maintenance_recovery_write() {
  _mmr_kind="$1" _mmr_phase="$2" _mmr_old="$3" _mmr_stage="$4"
  case "$MERV_MAINTENANCE_RECOVERY_ROOT" in /|''|/tmp|/jffs|/jffs/addons) return 1 ;; esac
  case "$MERV_MAINTENANCE_RECOVERY_MARKER" in "$MERV_MAINTENANCE_RECOVERY_ROOT"/.mervlan.recovery) ;; *) return 1 ;; esac
  case "$_mmr_kind:$_mmr_phase" in
    restore:prepared|restore:displaced|recovery:prepared|recovery:displaced) ;;
    *) return 1 ;;
  esac
  _mmr_old=$(merv_maintenance_recovery_path_component "$_mmr_old") || return 1
  _mmr_stage=$(merv_maintenance_recovery_path_component "$_mmr_stage") || return 1
  case "$_mmr_old:$_mmr_stage" in .mervlan.old.*:.mervlan.new.*) ;; *) return 1 ;; esac
  mkdir -p "$MERV_MAINTENANCE_RECOVERY_ROOT" 2>/dev/null || return 1
  chmod 700 "$MERV_MAINTENANCE_RECOVERY_ROOT" 2>/dev/null || return 1
  : "${MERV_MAINTENANCE_RECOVERY_SEQ:=0}"
  MERV_MAINTENANCE_RECOVERY_SEQ=$((MERV_MAINTENANCE_RECOVERY_SEQ + 1))
  _mmr_tmp="$MERV_MAINTENANCE_RECOVERY_MARKER.tmp.$$.${MERV_MAINTENANCE_RECOVERY_SEQ}"
  ( umask 077
    {
      printf 'format=1\n'
      printf 'kind=%s\n' "$_mmr_kind"
      printf 'phase=%s\n' "$_mmr_phase"
      printf 'old=%s\n' "$_mmr_old"
      printf 'stage=%s\n' "$_mmr_stage"
    } > "$_mmr_tmp"
  ) 2>/dev/null || { rm -f "$_mmr_tmp" 2>/dev/null || :; return 1; }
  chmod 600 "$_mmr_tmp" 2>/dev/null || { rm -f "$_mmr_tmp" 2>/dev/null || :; return 1; }
  mv -f "$_mmr_tmp" "$MERV_MAINTENANCE_RECOVERY_MARKER" 2>/dev/null || {
    rm -f "$_mmr_tmp" 2>/dev/null || :
    return 1
  }
}

merv_maintenance_recovery_read() {
  MERV_MAINTENANCE_RECOVERY_STATUS=absent
  MERV_MAINTENANCE_RECOVERY_KIND=""
  MERV_MAINTENANCE_RECOVERY_PHASE=""
  MERV_MAINTENANCE_RECOVERY_OLD=""
  MERV_MAINTENANCE_RECOVERY_STAGE=""
  case "$MERV_MAINTENANCE_RECOVERY_MARKER" in "$MERV_MAINTENANCE_RECOVERY_ROOT"/.mervlan.recovery) ;; *) MERV_MAINTENANCE_RECOVERY_STATUS=malformed; return 2 ;; esac
  [ -e "$MERV_MAINTENANCE_RECOVERY_MARKER" ] || return 1
  [ -f "$MERV_MAINTENANCE_RECOVERY_MARKER" ] || { MERV_MAINTENANCE_RECOVERY_STATUS=malformed; return 2; }
  _mmr_seen=""
  _mmr_format="" _mmr_kind="" _mmr_phase="" _mmr_old="" _mmr_stage=""
  while IFS= read -r _mmr_line || [ -n "$_mmr_line" ]; do
    case "$_mmr_line" in
      format=*) _mmr_key=format; _mmr_value=${_mmr_line#format=} ;;
      kind=*) _mmr_key=kind; _mmr_value=${_mmr_line#kind=} ;;
      phase=*) _mmr_key=phase; _mmr_value=${_mmr_line#phase=} ;;
      old=*) _mmr_key=old; _mmr_value=${_mmr_line#old=} ;;
      stage=*) _mmr_key=stage; _mmr_value=${_mmr_line#stage=} ;;
      *) MERV_MAINTENANCE_RECOVERY_STATUS=malformed; return 2 ;;
    esac
    case " $_mmr_seen " in *" $_mmr_key "*) MERV_MAINTENANCE_RECOVERY_STATUS=malformed; return 2 ;; esac
    _mmr_seen="$_mmr_seen $_mmr_key"
    case "$_mmr_key" in
      format) _mmr_format=$_mmr_value ;;
      kind) _mmr_kind=$_mmr_value ;;
      phase) _mmr_phase=$_mmr_value ;;
      old) _mmr_old=$_mmr_value ;;
      stage) _mmr_stage=$_mmr_value ;;
    esac
  done < "$MERV_MAINTENANCE_RECOVERY_MARKER"
  [ "$_mmr_seen" = " format kind phase old stage" ] || { MERV_MAINTENANCE_RECOVERY_STATUS=malformed; return 2; }
  [ "$_mmr_format" = 1 ] || { MERV_MAINTENANCE_RECOVERY_STATUS=malformed; return 2; }
  case "$_mmr_kind:$_mmr_phase" in
    restore:prepared|restore:displaced|recovery:prepared|recovery:displaced) ;;
    *) MERV_MAINTENANCE_RECOVERY_STATUS=malformed; return 2 ;;
  esac
  merv_maintenance_recovery_component_valid "$_mmr_old" || { MERV_MAINTENANCE_RECOVERY_STATUS=malformed; return 2; }
  merv_maintenance_recovery_component_valid "$_mmr_stage" || { MERV_MAINTENANCE_RECOVERY_STATUS=malformed; return 2; }
  case "$_mmr_old:$_mmr_stage" in .mervlan.old.*:.mervlan.new.*) ;; *) MERV_MAINTENANCE_RECOVERY_STATUS=malformed; return 2 ;; esac
  MERV_MAINTENANCE_RECOVERY_STATUS=active
  MERV_MAINTENANCE_RECOVERY_KIND=$_mmr_kind
  MERV_MAINTENANCE_RECOVERY_PHASE=$_mmr_phase
  MERV_MAINTENANCE_RECOVERY_OLD="$MERV_MAINTENANCE_RECOVERY_ROOT/$_mmr_old"
  MERV_MAINTENANCE_RECOVERY_STAGE="$MERV_MAINTENANCE_RECOVERY_ROOT/$_mmr_stage"
  return 0
}

merv_maintenance_recovery_matches() {
  _mmr_kind="$1" _mmr_old="$2" _mmr_stage="$3"
  merv_maintenance_recovery_read || return 1
  [ "$MERV_MAINTENANCE_RECOVERY_KIND" = "$_mmr_kind" ] && \
    [ "$MERV_MAINTENANCE_RECOVERY_OLD" = "$_mmr_old" ] && \
    [ "$MERV_MAINTENANCE_RECOVERY_STAGE" = "$_mmr_stage" ]
}

merv_maintenance_recovery_clear() {
  [ -e "$MERV_MAINTENANCE_RECOVERY_MARKER" ] || return 0
  case "$MERV_MAINTENANCE_RECOVERY_MARKER" in "$MERV_MAINTENANCE_RECOVERY_ROOT"/.mervlan.recovery) ;; *) return 1 ;; esac
  rm -f "$MERV_MAINTENANCE_RECOVERY_MARKER" 2>/dev/null
}

merv_maintenance_recovery_drop_recorded_stages() {
  merv_maintenance_recovery_read || return 1
  for _mmr_path in "$MERV_MAINTENANCE_RECOVERY_STAGE" "$MERV_MAINTENANCE_RECOVERY_OLD"; do
    case "$_mmr_path" in
      "$MERV_MAINTENANCE_RECOVERY_ROOT"/.mervlan.new.*|"$MERV_MAINTENANCE_RECOVERY_ROOT"/.mervlan.old.*)
        [ ! -e "$_mmr_path" ] || rm -rf "$_mmr_path" 2>/dev/null || return 1
        ;;
      *) return 1 ;;
    esac
  done
  merv_maintenance_recovery_clear
}

LIB_MAINTENANCE_RECOVERY_LOADED=1
