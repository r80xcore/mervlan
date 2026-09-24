#!/bin/sh
# MerVLAN backup-only durable state payload.
#
# This library deliberately keeps the payload inside a private archive staging
# tree.  The reserved directory must never be present in the active addon
# tree.  SSH trust validation is delegated to lib_ssh_trust.sh; this file only
# supplies the bounded staging/context around that canonical parser.

[ -n "${LIB_BACKUP_STATE_LOADED:-}" ] && return 0 2>/dev/null
LIB_BACKUP_STATE_LOADED=1

: "${MERV_BACKUP_STATE_DIR_NAME:=.backup_state}"
: "${MERV_BACKUP_STATE_FORMAT_FILE_NAME:=format}"
: "${MERV_BACKUP_STATE_TRUST_DIR_NAME:=ssh_trust}"
: "${MERV_BACKUP_STATE_TRUST_FILE_NAME:=known_hosts.v1}"

merv_backup_state_path_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

merv_backup_state_tree_dir() {
  printf '%s/%s\n' "$1" "$MERV_BACKUP_STATE_DIR_NAME"
}

merv_backup_state_trust_file() {
  printf '%s/%s/%s/%s\n' "$1" "$MERV_BACKUP_STATE_DIR_NAME" \
    "$MERV_BACKUP_STATE_TRUST_DIR_NAME" "$MERV_BACKUP_STATE_TRUST_FILE_NAME"
}

# The canonical trust parser intentionally accepts only its configured trust
# root.  Validate a private snapshot by copying it into a private, temporary
# trust root that satisfies the same path contract.  No canonical trust path
# is changed by this helper.
merv_backup_state_context_begin() {
  _mbs_context_workspace="$1"
  _mbs_context_source="$2"
  [ -n "$_mbs_context_workspace" ] && [ -n "$_mbs_context_source" ] || return 1
  [ ! -L "$_mbs_context_workspace" ] && [ -d "$_mbs_context_workspace" ] || return 1
  [ ! -L "$_mbs_context_source" ] && [ -f "$_mbs_context_source" ] || return 1

  _mbs_context_state_root="$_mbs_context_workspace/trust-context"
  _mbs_context_trust_root="$_mbs_context_state_root/ssh_trust"
  case "$_mbs_context_state_root" in
    /*) : ;;
    *) return 1 ;;
  esac
  case "$_mbs_context_state_root" in
    *..*|*[!A-Za-z0-9_./-]*) return 1 ;;
  esac
  [ ! -e "$_mbs_context_state_root" ] && [ ! -L "$_mbs_context_state_root" ] || return 1
  mkdir -p "$_mbs_context_trust_root/pending" \
    "$_mbs_context_trust_root/requests" \
    "$_mbs_context_trust_root/staging" \
    "$_mbs_context_trust_root/quarantine" 2>/dev/null || return 1
  chmod 700 "$_mbs_context_state_root" "$_mbs_context_trust_root" \
    "$_mbs_context_trust_root/pending" "$_mbs_context_trust_root/requests" \
    "$_mbs_context_trust_root/staging" "$_mbs_context_trust_root/quarantine" 2>/dev/null || {
    rm -rf "$_mbs_context_state_root" 2>/dev/null || :
    return 1
  }
  cp -p "$_mbs_context_source" "$_mbs_context_trust_root/known_hosts.v1" 2>/dev/null || {
    rm -rf "$_mbs_context_state_root" 2>/dev/null || :
    return 1
  }
  chmod 600 "$_mbs_context_trust_root/known_hosts.v1" 2>/dev/null || {
    rm -rf "$_mbs_context_state_root" 2>/dev/null || :
    return 1
  }

  _mbs_saved_state_root=${MERV_STATE_ROOT:-}
  _mbs_saved_trust_root=${MERV_SSH_TRUST_ROOT:-}
  _mbs_saved_trust_file=${MERV_SSH_TRUST_FILE:-}
  _mbs_saved_pending_root=${MERV_SSH_TRUST_PENDING_ROOT:-}
  _mbs_saved_requests_root=${MERV_SSH_TRUST_REQUESTS_ROOT:-}
  _mbs_saved_staging_root=${MERV_SSH_TRUST_STAGING_ROOT:-}
  _mbs_saved_quarantine_root=${MERV_SSH_TRUST_QUARANTINE_ROOT:-}
  _mbs_saved_lock_path=${MERV_SSH_TRUST_LOCK_PATH:-}
  MERV_STATE_ROOT="$_mbs_context_state_root"
  MERV_SSH_TRUST_ROOT="$_mbs_context_trust_root"
  MERV_SSH_TRUST_FILE="$_mbs_context_trust_root/known_hosts.v1"
  MERV_SSH_TRUST_PENDING_ROOT="$_mbs_context_trust_root/pending"
  MERV_SSH_TRUST_REQUESTS_ROOT="$_mbs_context_trust_root/requests"
  MERV_SSH_TRUST_STAGING_ROOT="$_mbs_context_trust_root/staging"
  MERV_SSH_TRUST_QUARANTINE_ROOT="$_mbs_context_trust_root/quarantine"
  MERV_SSH_TRUST_LOCK_PATH="$_mbs_context_trust_root/state.lock"
  return 0
}

merv_backup_state_context_end() {
  _mbs_context_rc="$1"
  MERV_STATE_ROOT="$_mbs_saved_state_root"
  MERV_SSH_TRUST_ROOT="$_mbs_saved_trust_root"
  MERV_SSH_TRUST_FILE="$_mbs_saved_trust_file"
  MERV_SSH_TRUST_PENDING_ROOT="$_mbs_saved_pending_root"
  MERV_SSH_TRUST_REQUESTS_ROOT="$_mbs_saved_requests_root"
  MERV_SSH_TRUST_STAGING_ROOT="$_mbs_saved_staging_root"
  MERV_SSH_TRUST_QUARANTINE_ROOT="$_mbs_saved_quarantine_root"
  MERV_SSH_TRUST_LOCK_PATH="$_mbs_saved_lock_path"
  type merv_ssh_trust_find_cache_clear >/dev/null 2>&1 && merv_ssh_trust_find_cache_clear
  unset MERV_SSH_TRUST_VALIDATED_FILE MERV_SSH_TRUST_VALIDATED_DIGEST MERV_SSH_TRUST_VALIDATION_DIGEST
  if ! rm -rf "$_mbs_context_state_root" 2>/dev/null; then
    return 1
  fi
  return "$_mbs_context_rc"
}

merv_backup_state_validate_trust_file() {
  _mbs_trust_file="$1"
  _mbs_trust_workspace="$2"
  [ ! -L "$_mbs_trust_file" ] && [ -f "$_mbs_trust_file" ] || return 1
  type merv_ssh_trust_validate_file >/dev/null 2>&1 || return 1
  merv_backup_state_context_begin "$_mbs_trust_workspace" "$_mbs_trust_file" || return 1
  merv_ssh_trust_validate_file "$MERV_SSH_TRUST_FILE"
  _mbs_trust_rc=$?
  merv_backup_state_context_end "$_mbs_trust_rc"
  _mbs_context_rc=$?
  [ "$_mbs_context_rc" -eq 0 ] || return 1
  return "$_mbs_trust_rc"
}

# Run the canonical node preflight against a private trust snapshot.  The
# live canonical trust database is restored before returning and is never
# replaced by this operation.
merv_backup_state_preflight_with_trust() {
  _mbs_preflight_settings="$1"
  _mbs_preflight_trust="$2"
  _mbs_preflight_workspace="$3"
  [ -f "$_mbs_preflight_settings" ] || return 1
  [ ! -L "$_mbs_preflight_trust" ] && [ -f "$_mbs_preflight_trust" ] || return 1
  type merv_ssh_preflight_settings_file >/dev/null 2>&1 || return 1
  merv_backup_state_context_begin "$_mbs_preflight_workspace" "$_mbs_preflight_trust" || return 1
  merv_ssh_preflight_settings_file "$_mbs_preflight_settings"
  _mbs_preflight_rc=$?
  merv_backup_state_context_end "$_mbs_preflight_rc"
  _mbs_context_rc=$?
  [ "$_mbs_context_rc" -eq 0 ] || return 1
  return "$_mbs_preflight_rc"
}

merv_backup_state_configured_nodes() {
  _mbs_nodes_settings="$1"
  [ -f "$_mbs_nodes_settings" ] || return 1
  type merv_node_list >/dev/null 2>&1 || return 1
  merv_node_list "$_mbs_nodes_settings"
}

# Validate and publish the reserved payload into an already-private tree.  A
# configured node set without a usable trust database fails closed.  A
# no-node installation may carry an explicit trust=absent marker.
merv_backup_state_inject_tree() {
  _mbs_inject_tree="$1"
  _mbs_inject_settings="$2"
  _mbs_inject_trust="${3:-}"
  _mbs_inject_workspace="$4"
  [ ! -L "$_mbs_inject_tree" ] && [ -d "$_mbs_inject_tree" ] || return 1
  [ -f "$_mbs_inject_settings" ] || return 1
  merv_backup_state_path_present "$_mbs_inject_tree/$MERV_BACKUP_STATE_DIR_NAME" && return 1
  [ -n "$_mbs_inject_workspace" ] || return 1

  _mbs_inject_nodes=$(merv_backup_state_configured_nodes "$_mbs_inject_settings" 2>/dev/null) || return 1
  _mbs_inject_trust_present=0
  if [ -n "$_mbs_inject_trust" ]; then
    [ ! -L "$_mbs_inject_trust" ] || return 1
    if [ -f "$_mbs_inject_trust" ]; then
      merv_backup_state_validate_trust_file "$_mbs_inject_trust" "$_mbs_inject_workspace" || return 1
      _mbs_inject_trust_present=1
    elif merv_backup_state_path_present "$_mbs_inject_trust"; then
      return 1
    fi
  fi
  [ -n "$_mbs_inject_nodes" ] && [ "$_mbs_inject_trust_present" -eq 0 ] && return 1

  _mbs_inject_state="$_mbs_inject_tree/$MERV_BACKUP_STATE_DIR_NAME"
  _mbs_inject_trust_dir="$_mbs_inject_state/$MERV_BACKUP_STATE_TRUST_DIR_NAME"
  mkdir -p "$_mbs_inject_state" 2>/dev/null || return 1
  chmod 700 "$_mbs_inject_state" 2>/dev/null || return 1
  ( umask 077
    printf 'format=1\ntrust=%s\n' "$( [ "$_mbs_inject_trust_present" -eq 1 ] && printf present || printf absent )" \
      > "$_mbs_inject_state/$MERV_BACKUP_STATE_FORMAT_FILE_NAME"
  ) 2>/dev/null || return 1
  chmod 600 "$_mbs_inject_state/$MERV_BACKUP_STATE_FORMAT_FILE_NAME" 2>/dev/null || return 1
  if [ "$_mbs_inject_trust_present" -eq 1 ]; then
    mkdir "$_mbs_inject_trust_dir" 2>/dev/null || return 1
    chmod 700 "$_mbs_inject_trust_dir" 2>/dev/null || return 1
    cp -p "$_mbs_inject_trust" "$_mbs_inject_trust_dir/$MERV_BACKUP_STATE_TRUST_FILE_NAME" 2>/dev/null || return 1
    chmod 600 "$_mbs_inject_trust_dir/$MERV_BACKUP_STATE_TRUST_FILE_NAME" 2>/dev/null || return 1
  fi
  return 0
}

merv_backup_state_prepare_tree() {
  _mbs_prepare_source="$1"
  _mbs_prepare_stage="$2"
  _mbs_prepare_settings="$3"
  _mbs_prepare_trust="${4:-}"
  _mbs_prepare_workspace="$5"
  [ ! -L "$_mbs_prepare_source" ] && [ -d "$_mbs_prepare_source" ] || return 1
  merv_backup_state_path_present "$_mbs_prepare_source/$MERV_BACKUP_STATE_DIR_NAME" && return 1
  [ ! -e "$_mbs_prepare_stage" ] && [ ! -L "$_mbs_prepare_stage" ] || return 1
  cp -pR "$_mbs_prepare_source" "$_mbs_prepare_stage" 2>/dev/null || return 1
  if ! merv_backup_state_inject_tree "$_mbs_prepare_stage" \
      "$_mbs_prepare_stage/${_mbs_prepare_settings#$_mbs_prepare_source/}" \
      "$_mbs_prepare_trust" "$_mbs_prepare_workspace"; then
    rm -rf "$_mbs_prepare_stage" 2>/dev/null || :
    return 1
  fi
  return 0
}

# Validate the optional payload in an extracted archive tree.  Legacy archives
# intentionally remain valid.  The caller owns removal of the reserved tree
# after this function returns; this function never changes the active tree.
merv_backup_state_validate_tree() {
  _mbs_validate_tree="$1"
  _mbs_validate_settings="$2"
  _mbs_validate_workspace="$3"
  MERV_BACKUP_STATE_FORMAT=legacy
  MERV_BACKUP_STATE_TRUST_PRESENT=0
  MERV_BACKUP_STATE_TRUST_FILE=""
  MERV_BACKUP_STATE_LAST_ERROR=""
  _mbs_validate_state="$_mbs_validate_tree/$MERV_BACKUP_STATE_DIR_NAME"
  if ! merv_backup_state_path_present "$_mbs_validate_state"; then
    return 0
  fi
  [ ! -L "$_mbs_validate_state" ] && [ -d "$_mbs_validate_state" ] || {
    MERV_BACKUP_STATE_LAST_ERROR=malformed-payload
    return 1
  }
  _mbs_validate_format="$_mbs_validate_state/$MERV_BACKUP_STATE_FORMAT_FILE_NAME"
  _mbs_validate_trust_dir="$_mbs_validate_state/$MERV_BACKUP_STATE_TRUST_DIR_NAME"
  [ ! -L "$_mbs_validate_format" ] && [ -f "$_mbs_validate_format" ] || {
    MERV_BACKUP_STATE_LAST_ERROR=malformed-payload
    return 1
  }
  [ "$(sed -n '1p' "$_mbs_validate_format" 2>/dev/null)" = 'format=1' ] || {
    MERV_BACKUP_STATE_LAST_ERROR=unsupported-payload
    return 1
  }
  _mbs_validate_trust=$(sed -n 's/^trust=//p' "$_mbs_validate_format" 2>/dev/null)
  [ -n "$_mbs_validate_trust" ] && [ -z "$(sed -n '3p' "$_mbs_validate_format" 2>/dev/null)" ] || {
    MERV_BACKUP_STATE_LAST_ERROR=malformed-payload
    return 1
  }
  for _mbs_validate_entry in "$_mbs_validate_state"/* "$_mbs_validate_state"/.[!.]* "$_mbs_validate_state"/..?*; do
    merv_backup_state_path_present "$_mbs_validate_entry" || continue
    case "$_mbs_validate_entry" in
      "$_mbs_validate_format"|"$_mbs_validate_trust_dir") ;;
      *) MERV_BACKUP_STATE_LAST_ERROR=unexpected-payload-entry; return 1 ;;
    esac
  done
  case "$_mbs_validate_trust" in
    present)
      [ ! -L "$_mbs_validate_trust_dir" ] && [ -d "$_mbs_validate_trust_dir" ] || {
        MERV_BACKUP_STATE_LAST_ERROR=missing-trust-payload
        return 1
      }
      _mbs_validate_file="$_mbs_validate_trust_dir/$MERV_BACKUP_STATE_TRUST_FILE_NAME"
      [ ! -L "$_mbs_validate_file" ] && [ -f "$_mbs_validate_file" ] || {
        MERV_BACKUP_STATE_LAST_ERROR=missing-trust-payload
        return 1
      }
      for _mbs_validate_entry in "$_mbs_validate_trust_dir"/* "$_mbs_validate_trust_dir"/.[!.]* "$_mbs_validate_trust_dir"/..?*; do
        merv_backup_state_path_present "$_mbs_validate_entry" || continue
        [ "$_mbs_validate_entry" = "$_mbs_validate_file" ] || {
          MERV_BACKUP_STATE_LAST_ERROR=unexpected-trust-entry
          return 1
        }
      done
      merv_backup_state_validate_trust_file "$_mbs_validate_file" "$_mbs_validate_workspace" || {
        MERV_BACKUP_STATE_LAST_ERROR=invalid-trust-payload
        return 1
      }
      MERV_BACKUP_STATE_TRUST_PRESENT=1
      MERV_BACKUP_STATE_TRUST_FILE="$_mbs_validate_file"
      ;;
    absent)
      merv_backup_state_path_present "$_mbs_validate_trust_dir" && {
        MERV_BACKUP_STATE_LAST_ERROR=unexpected-trust-entry
        return 1
      }
      ;;
    *)
      MERV_BACKUP_STATE_LAST_ERROR=invalid-trust-state
      return 1
      ;;
  esac
  _mbs_validate_nodes=$(merv_backup_state_configured_nodes "$_mbs_validate_settings" 2>/dev/null) || return 1
  if [ -n "$_mbs_validate_nodes" ] && [ "$MERV_BACKUP_STATE_TRUST_PRESENT" -ne 1 ]; then
    MERV_BACKUP_STATE_LAST_ERROR=nodes-without-trust
    return 1
  fi
  MERV_BACKUP_STATE_FORMAT=modern
  return 0
}
