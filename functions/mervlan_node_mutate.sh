#!/bin/sh
# NODE-local guarded mutation dispatcher for Sync Nodes and Execute Nodes.
# Remote callers may select only the fixed operations below.  They cannot
# supply shell code, lock paths, process roots, or a test context.

MNM_REQUEST_BASE=${MERV_BASE:-/jffs/addons/mervlan}
MNM_SCRIPT_PATH=$0
MNM_SELFTEST=0
MNM_BOOTSTRAP_ROOT=
MNM_LIBRARY_ROOT=
MNM_BOOTSTRAP_RUN=
MNM_BOOTSTRAP_NODE=
MNM_BOOTSTRAP_FILES='settings/lib_selftest_context.sh settings/lib_identity.sh settings/lib_owner_lock.sh settings/lib_action_lock.sh settings/lib_update_state.sh settings/lib_full_fence.sh settings/lib_continuation.sh settings/lib_mutation_admission.sh functions/mervlan_node_mutate.sh'

mnm_early_private_mode() {
  _mnm_mode=$(LC_ALL=C ls -ldn "$1" 2>/dev/null | awk 'NR == 1 { print $1 }') || return 1
  case "$_mnm_mode:$2" in drwx------:700|-rw-------:600) return 0 ;; *) return 1 ;; esac
}

mnm_early_path_safe() {
  _mnm_path=${1:-}
  case "$_mnm_path" in /tmp/.mervlan-node-admission.*|/tmp/mervlan_tmp/selftest.*/*|/tmp/mervlan-*/*|/tmp/mervlan_*/*) ;; *) return 1 ;; esac
  case "$_mnm_path" in *..*|*//*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
  _mnm_walk=/
  _mnm_rest=${_mnm_path#/}
  while [ -n "$_mnm_rest" ]; do
    case "$_mnm_rest" in */*) _mnm_part=${_mnm_rest%%/*}; _mnm_rest=${_mnm_rest#*/} ;; *) _mnm_part=$_mnm_rest; _mnm_rest= ;; esac
    case "$_mnm_part" in ''|.|..) return 1 ;; esac
    _mnm_walk=${_mnm_walk%/}/$_mnm_part
    [ ! -L "$_mnm_walk" ] || return 1
    if [ -e "$_mnm_walk" ] && [ ! -d "$_mnm_walk" ] && [ "$_mnm_walk" != "$_mnm_path" ]; then return 1; fi
  done
  return 0
}

mnm_early_digest() {
  # This entry authenticates its support cohort before any library load.
  _mnm_digest=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
  [ "${#_mnm_digest}" = 64 ] || _mnm_digest=$(openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}')
  [ "${#_mnm_digest}" = 64 ] || return 1
  case "$_mnm_digest" in *[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$_mnm_digest"
}

mnm_early_verify_bootstrap() {
  _mnm_root=${1:-}
  _mnm_manifest=${2:-}
  _mnm_parent=${_mnm_root%/cohort}
  [ "$_mnm_parent/cohort" = "$_mnm_root" ] || return 1
  case "$_mnm_root" in
    /tmp/.mervlan-node-admission.*/*)
      _mnm_tail=${_mnm_parent#/tmp/.mervlan-node-admission.}
      _mnm_node=${_mnm_tail##*.}
      _mnm_run=${_mnm_tail%.*}
      case "$_mnm_run" in [0-9]*-[0-9]*) ;; *) return 1 ;; esac
      case "${_mnm_run%-*}:${_mnm_run#*-}" in *[!0-9:]*|:*|*::*) return 1 ;; esac
      case "$_mnm_node" in 1|2|3|4|5|6|7|8|9|10) ;; *) return 1 ;; esac
      [ "$_mnm_parent" = "/tmp/.mervlan-node-admission.$_mnm_run.$_mnm_node" ] || return 1
      [ -d /tmp ] && [ ! -L /tmp ] || return 1
      ;;
    *)
      type merv_selftest_context_path_allowed >/dev/null 2>&1 &&
        merv_selftest_context_path_allowed "$_mnm_root" || return 1
      _mnm_run=selftest
      _mnm_node=0
      ;;
  esac
  mnm_early_path_safe "$_mnm_root" || return 1
  [ -d "$_mnm_parent" ] && [ ! -L "$_mnm_parent" ] || return 1
  [ -d "$_mnm_root" ] && [ ! -L "$_mnm_root" ] || return 1
  [ -d "$_mnm_root/settings" ] && [ ! -L "$_mnm_root/settings" ] || return 1
  [ -d "$_mnm_root/functions" ] && [ ! -L "$_mnm_root/functions" ] || return 1
  [ -f "$_mnm_parent/.owner" ] && [ ! -L "$_mnm_parent/.owner" ] || return 1
  mnm_early_private_mode "$_mnm_parent" 700 &&
    mnm_early_private_mode "$_mnm_root" 700 &&
    mnm_early_private_mode "$_mnm_root/settings" 700 &&
    mnm_early_private_mode "$_mnm_root/functions" 700 &&
    mnm_early_private_mode "$_mnm_parent/.owner" 600 || return 1
  _mnm_owner_lines=$(wc -l < "$_mnm_parent/.owner" 2>/dev/null | tr -d '[:space:]') || return 1
  [ "$_mnm_owner_lines" = 3 ] || return 1
  _mnm_owner_format=$(sed -n '1p' "$_mnm_parent/.owner" 2>/dev/null)
  _mnm_owner_run=$(sed -n '2s/^run=//p' "$_mnm_parent/.owner" 2>/dev/null)
  _mnm_owner_node=$(sed -n '3s/^node=//p' "$_mnm_parent/.owner" 2>/dev/null)
  [ "$_mnm_owner_format" = format=mervlan-node-admission-v1 ] || return 1
  if [ "$_mnm_run" = selftest ]; then
    _mnm_run=$_mnm_owner_run
    _mnm_node=$_mnm_owner_node
    case "$_mnm_run" in [0-9]*-[0-9]*) ;; *) return 1 ;; esac
    case "${_mnm_run%-*}:${_mnm_run#*-}" in *[!0-9:]*|:*|*::*) return 1 ;; esac
    case "$_mnm_node" in 1|2|3|4|5|6|7|8|9|10) ;; *) return 1 ;; esac
  fi
  [ "$_mnm_owner_run" = "$_mnm_run" ] && [ "$_mnm_owner_node" = "$_mnm_node" ] || return 1
  MNM_BOOTSTRAP_RUN=$_mnm_run
  MNM_BOOTSTRAP_NODE=$_mnm_node
  _mnm_seen=' '
  _mnm_count=0
  while IFS='|' read -r _mnm_rel _mnm_expected _mnm_extra || [ -n "$_mnm_rel$_mnm_expected$_mnm_extra" ]; do
    [ -z "$_mnm_extra" ] || return 1
    case "$_mnm_rel" in settings/*|functions/*) ;; *) return 1 ;; esac
    case "$_mnm_expected" in *[!0-9a-f]*|'') return 1 ;; esac
    [ "${#_mnm_expected}" -eq 64 ] || return 1
    case " $MNM_BOOTSTRAP_FILES " in *" $_mnm_rel "*) ;; *) return 1 ;; esac
    case "$_mnm_seen" in *" $_mnm_rel "*) return 1 ;; esac
    _mnm_file="$_mnm_root/$_mnm_rel"
    [ -f "$_mnm_file" ] && [ ! -L "$_mnm_file" ] || return 1
    mnm_early_private_mode "$_mnm_file" 600 || return 1
    _mnm_actual=$(mnm_early_digest "$_mnm_file") || return 1
    [ "$_mnm_actual" = "$_mnm_expected" ] || return 1
    /bin/sh -n "$_mnm_file" >/dev/null 2>&1 || return 1
    _mnm_seen="$_mnm_seen$_mnm_rel "
    _mnm_count=$((_mnm_count + 1))
  done <<EOF
$_mnm_manifest
EOF
  [ "$_mnm_count" -eq 9 ] || return 1
  for _mnm_rel in $MNM_BOOTSTRAP_FILES; do
    case "$_mnm_seen" in *" $_mnm_rel "*) ;; *) return 1 ;; esac
  done
  for _mnm_file in "$_mnm_parent"/.[!.]* "$_mnm_parent"/..?* "$_mnm_parent"/*; do
    [ -e "$_mnm_file" ] || [ -L "$_mnm_file" ] || continue
    case "${_mnm_file##*/}" in .owner|cohort) ;; *) return 1 ;; esac
  done
  for _mnm_file in "$_mnm_root"/.[!.]* "$_mnm_root"/..?* "$_mnm_root"/*; do
    [ -e "$_mnm_file" ] || [ -L "$_mnm_file" ] || continue
    case "${_mnm_file##*/}" in settings|functions) ;; *) return 1 ;; esac
  done
  for _mnm_file in "$_mnm_root/settings"/.[!.]* "$_mnm_root/settings"/..?* "$_mnm_root/settings"/*; do
    [ -e "$_mnm_file" ] || [ -L "$_mnm_file" ] || continue
    case "${_mnm_file##*/}" in lib_selftest_context.sh|lib_identity.sh|lib_owner_lock.sh|lib_action_lock.sh|lib_update_state.sh|lib_full_fence.sh|lib_continuation.sh|lib_mutation_admission.sh) ;; *) return 1 ;; esac
  done
  for _mnm_file in "$_mnm_root/functions"/.[!.]* "$_mnm_root/functions"/..?* "$_mnm_root/functions"/*; do
    [ -e "$_mnm_file" ] || [ -L "$_mnm_file" ] || continue
    [ "${_mnm_file##*/}" = mervlan_node_mutate.sh ] || return 1
  done
  return 0
}

# A remote invocation has a fixed $0 supplied by lib_ssh and always uses the
# installed NODE control plane.  Never accept a MAIN-supplied self-test context
# over SSH.  Direct local tests may use the repository's authenticated seam.
case "$0" in
  mervlan_node_mutate_remote) unset MERVLAN_SELFTEST_CONTEXT ;;
esac
if [ -n "${MERVLAN_SELFTEST_CONTEXT:-}" ]; then
  _mnm_test_lib=/jffs/addons/mervlan/settings/lib_selftest_context.sh
  if [ ! -r "$_mnm_test_lib" ]; then
    case "$MNM_SCRIPT_PATH" in
      */*) _mnm_script_dir=${MNM_SCRIPT_PATH%/*}; _mnm_test_lib="$_mnm_script_dir/../settings/lib_selftest_context.sh" ;;
      *) _mnm_test_lib= ;;
    esac
  fi
  if [ -r "$_mnm_test_lib" ]; then
    . "$_mnm_test_lib" 2>/dev/null || :
    if type merv_selftest_context_valid >/dev/null 2>&1 &&
       merv_selftest_context_valid; then
      MNM_SELFTEST=1
    fi
  fi
fi

if [ "$MNM_SELFTEST" = 1 ]; then
  MNM_TEST_ROOT=$MERV_SELFTEST_CONTEXT_ROOT
  MERV_BASE=$MNM_TEST_ROOT/nodefs/mervlan
  MERV_ACTION_LOCK_PATH=$MNM_TEST_ROOT/locks/mervlan_action.lock
  MERV_ACTION_LOCK_PROC_ROOT=/proc
  MERV_OWNER_LOCK_PROC_ROOT=/proc
  MERVLAN_MAINTENANCE_LOCK_OVERRIDE=$MNM_TEST_ROOT/locks/mervlan_maintenance.lock
  MERV_FULL_FENCE_PATH=$MNM_TEST_ROOT/full.lock
  MERV_CONTINUATION_ROOT=$MNM_TEST_ROOT/continuations
  MNM_ACTIVE=$MERV_BASE
  MNM_BACKUPS=$MNM_TEST_ROOT/nodefs/mervlan_backups
  MNM_RUNTIME=$MNM_TEST_ROOT/nodefs/runtime
else
  MERV_BASE=/jffs/addons/mervlan
  MERV_STATE_ROOT=/jffs/addons/mervlan_state
  MERV_UPDATE_JOURNAL=$MERV_STATE_ROOT/update.journal
  MERV_UPDATE_QUIESCE_FILE=$MERV_STATE_ROOT/update.quiesce
  PATH=/sbin:/bin:/usr/sbin:/usr/bin
  export PATH
  unset MERVLAN_SELFTEST_CONTEXT TEST_RUN MERV_DISABLE_LOCKS
  unset MERV_ACTION_LOCK_PATH MERV_ACTION_LOCK_PROC_ROOT MERV_OWNER_LOCK_PROC_ROOT
  unset MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC MERV_OWNER_LOCK_FAULT
  unset MERVLAN_MAINTENANCE_LOCK_OVERRIDE MERV_UPDATE_MAINTENANCE_LOCK
  unset MERVLAN_RECOVERY_LOCK_OVERRIDE MERV_REPAIR_MAINTENANCE_LOCK
  unset MERV_FULL_FENCE_PATH MERV_CONTINUATION_ROOT MERV_CONTINUATION_PATH
  unset MERV_CONTINUATION_FAULT MERV_MUTATION_ADMISSION_FAULT
  unset MERV_CONTINUATION_TOKEN MERV_MAINTENANCE_SYNC MERV_MAINTENANCE_DELEGATED
  unset MERV_MAINTENANCE_DELEGATION_KIND MERV_INSTALL_DELEGATION MERV_UNINSTALL_DELEGATION
  unset MERV_BACKUP_DELEGATION MERV_RECOVERY_DELEGATION MERV_UPDATE_RECOVERY_DELEGATION
  unset MERV_UPDATE_RECOVERY MERV_UPDATE_RECOVERY_RUN_ID MERV_UPDATE_RECOVERY_PARENT_PID
  unset MERV_UPDATE_RECOVERY_PARENT_START MERV_UPDATE_RECOVERY_M_PATH MERV_UPDATE_RECOVERY_M_PID
  unset MERV_UPDATE_RECOVERY_M_START MERV_UPDATE_RECOVERY_M_NONCE
  unset MERV_MAINTENANCE_OWNER_PID MERV_MAINTENANCE_OWNER_START MERV_MAINTENANCE_OWNER_NONCE
  unset MERV_ACTION_LOCK_PARENT_HELD MERV_ACTION_LOCK_PARENT_PID
  unset MERV_ACTION_LOCK_PARENT_START MERV_ACTION_LOCK_PARENT_NONCE
  MNM_ACTIVE=/jffs/addons/mervlan
  MNM_BACKUPS=/jffs/addons/mervlan_backups
  MNM_RUNTIME=/tmp/mervlan_tmp
  MERV_ACTION_LOCK_PATH=/tmp/mervlan_tmp/locks/mervlan_action.lock
  MERV_ACTION_LOCK_PROC_ROOT=/proc
  MERV_OWNER_LOCK_PROC_ROOT=/proc
  MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC=10
  MERV_NODE_CONTEXT=1
fi
MERV_BASE=$MERV_BASE
export MERV_BASE

# Sync may provide a code-only admission cohort from its verified, private
# per-run NODE workspace.  The cohort is never an active addon/state root.
if [ "$MNM_SELFTEST" = 1 ] && [ -n "${MERV_NODE_MUTATE_LIB_ROOT:-}" ]; then
  MNM_BOOTSTRAP_ROOT=$MERV_NODE_MUTATE_LIB_ROOT
  MNM_BOOTSTRAP_MANIFEST=${MERV_NODE_MUTATE_LIB_MANIFEST:-}
  mnm_early_verify_bootstrap "$MNM_BOOTSTRAP_ROOT" "$MNM_BOOTSTRAP_MANIFEST" || exit 70
  MNM_LIBRARY_ROOT=$MNM_BOOTSTRAP_ROOT
elif [ "$MNM_SELFTEST" = 0 ] && [ "$MNM_SCRIPT_PATH" = mervlan_node_mutate_remote ] &&
     [ -n "${MERV_NODE_MUTATE_LIB_ROOT:-}" ]; then
  MNM_BOOTSTRAP_ROOT=$MERV_NODE_MUTATE_LIB_ROOT
  MNM_BOOTSTRAP_MANIFEST=${MERV_NODE_MUTATE_LIB_MANIFEST:-}
  mnm_early_verify_bootstrap "$MNM_BOOTSTRAP_ROOT" "$MNM_BOOTSTRAP_MANIFEST" || exit 70
  MNM_LIBRARY_ROOT=$MNM_BOOTSTRAP_ROOT
else
  unset MERV_NODE_MUTATE_LIB_ROOT MERV_NODE_MUTATE_LIB_MANIFEST
  MNM_LIBRARY_ROOT=$MERV_BASE
fi

unset LIB_SELFTEST_CONTEXT_LOADED LIB_IDENTITY_LOADED LIB_OWNER_LOCK_LOADED LIB_ACTION_LOCK_LOADED
unset LIB_UPDATE_STATE_LOADED LIB_FULL_FENCE_LOADED LIB_CONTINUATION_LOADED
unset LIB_MUTATION_ADMISSION_LOADED
. "$MNM_LIBRARY_ROOT/settings/lib_selftest_context.sh" 2>/dev/null || {
  [ "$MNM_SELFTEST" = 0 ] && . /jffs/addons/mervlan/settings/lib_selftest_context.sh 2>/dev/null || :
}
. "$MNM_LIBRARY_ROOT/settings/lib_identity.sh" 2>/dev/null || exit 70
. "$MNM_LIBRARY_ROOT/settings/lib_owner_lock.sh" 2>/dev/null || exit 70
. "$MNM_LIBRARY_ROOT/settings/lib_action_lock.sh" 2>/dev/null || exit 70
# update_state may opportunistically source lib_full_fence from MERV_BASE.
# Load the frozen fence first so an older active NODE copy cannot replace the
# verified bootstrap generation during a first-upgrade Sync.
. "$MNM_LIBRARY_ROOT/settings/lib_full_fence.sh" 2>/dev/null || exit 70
. "$MNM_LIBRARY_ROOT/settings/lib_update_state.sh" 2>/dev/null || exit 70
. "$MNM_LIBRARY_ROOT/settings/lib_continuation.sh" 2>/dev/null || exit 70
. "$MNM_LIBRARY_ROOT/settings/lib_mutation_admission.sh" 2>/dev/null || exit 70

MNM_ACTION=/tmp/mervlan_tmp/locks/mervlan_action.lock
MNM_LOCK_OWNED=0
MNM_LOCK_NONCE=
MNM_LOCK_START=
MNM_TEMP=
MNM_OUTPUT=
MNM_OP=${1:-}
shift 2>/dev/null || :

if [ "$MNM_SELFTEST" = 1 ]; then
  MNM_ACTION=$MERV_ACTION_LOCK_PATH
fi

mnm_valid_node() {
  case "${1:-}" in 1|2|3|4|5|6|7|8|9|10) return 0 ;; *) return 1 ;; esac
}

mnm_valid_run() {
  case "${1:-}" in [0-9]*-[0-9]*) ;; *) return 1 ;; esac
  case "${1%-*}:${1#*-}" in *[!0-9:]*|:*|*::*) return 1 ;; esac
  return 0
}

mnm_bootstrap_args_match() {
  [ -n "$MNM_BOOTSTRAP_ROOT" ] &&
    [ "${1:-}" = "$MNM_BOOTSTRAP_RUN" ] &&
    [ "${2:-}" = "$MNM_BOOTSTRAP_NODE" ]
}

mnm_valid_relpath() {
  case "${1:-}" in
    ''|/*|*..*|*[!A-Za-z0-9_./-]*) return 1 ;;
    */|*//*) return 1 ;;
  esac
  return 0
}

mnm_path_chain_no_symlink() {
  _mnm_p=${1:-}
  case "$_mnm_p" in /*) ;; *) return 1 ;; esac
  case "$_mnm_p" in *..*|*//*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
  _mnm_walk=/
  _mnm_rest=${_mnm_p#/}
  while [ -n "$_mnm_rest" ]; do
    case "$_mnm_rest" in
      */*) _mnm_part=${_mnm_rest%%/*}; _mnm_rest=${_mnm_rest#*/} ;;
      *) _mnm_part=$_mnm_rest; _mnm_rest= ;;
    esac
    case "$_mnm_part" in ''|.|..) return 1 ;; esac
    _mnm_walk=${_mnm_walk%/}/$_mnm_part
    [ ! -L "$_mnm_walk" ] || return 1
    if [ -e "$_mnm_walk" ] && [ ! -d "$_mnm_walk" ]; then return 1; fi
  done
  return 0
}

mnm_stage_paths() {
  mnm_valid_run "${1:-}" && mnm_valid_node "${2:-}" || return 1
  MNM_RUN=$1
  MNM_NODE=$2
  MNM_STAGE=$MNM_BACKUPS/.mervlan.new.$MNM_RUN.$MNM_NODE
  MNM_OLD=$MNM_BACKUPS/.mervlan.old.$MNM_RUN.$MNM_NODE
  case "$MNM_STAGE:$MNM_OLD" in
    "$MNM_BACKUPS"/.mervlan.new.*:"$MNM_BACKUPS"/.mervlan.old.*) ;;
    *) return 1 ;;
  esac
  return 0
}

mnm_cleanup() {
  _mnm_rc=$?
  trap - 0
  trap '' HUP INT TERM
  if [ -n "$MNM_TEMP" ]; then rm -f "$MNM_TEMP" 2>/dev/null || :; fi
  if [ -n "$MNM_OUTPUT" ]; then rm -f "$MNM_OUTPUT" 2>/dev/null || :; fi
  if [ "$MNM_LOCK_OWNED" = 1 ]; then
    merv_action_lock_leave "$MNM_ACTION" "$MNM_LOCK_NONCE" "$MNM_LOCK_START" self || _mnm_rc=74
    MNM_LOCK_OWNED=0
  fi
  exit "$_mnm_rc"
}

mnm_admit() {
  unset MERV_ACTION_LOCK_PARENT_HELD MERV_ACTION_LOCK_PARENT_PID
  unset MERV_ACTION_LOCK_PARENT_START MERV_ACTION_LOCK_PARENT_NONCE
  merv_action_lock_enter "$MNM_ACTION" self || {
    printf 'NODE_MUTATION_OWNER_BLOCKED|%s\n' "${MERV_ACTION_LOCK_LAST_FAILURE:-unknown}" >&2
    return 1
  }
  [ "${MERV_ACTION_LOCK_MODE:-none}" = self ] || return 1
  MNM_LOCK_OWNED=1
  MNM_LOCK_NONCE=$MERV_ACTION_LOCK_NONCE
  MNM_LOCK_START=$MERV_ACTION_LOCK_START
  trap 'mnm_cleanup' 0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  merv_mutation_admit_action "$MNM_ACTION" || return 1
  # Activation invokes the node-local boot script synchronously.  Pass that
  # child the authenticated owner identity so it reuses this complete action
  # lifetime instead of attempting a competing, non-reentrant action lock.
  merv_action_lock_export_child_context || return 1
  return 0
}

mnm_runtime_prepare() {
  mnm_path_chain_no_symlink "$MNM_RUNTIME" || return 1
  mkdir -p "$MNM_RUNTIME/tmp" "$MNM_RUNTIME/logs" "$MNM_RUNTIME/locks" \
    "$MNM_RUNTIME/results/vlan_changes" "$MNM_RUNTIME/client_collection" || return 1
  chmod 700 "$MNM_RUNTIME" "$MNM_RUNTIME/locks" 2>/dev/null || return 1
}

mnm_prepare_stage() {
  mnm_stage_paths "$1" "$2" || return 64
  _mnm_jffs=$(nvram get jffs2_on 2>/dev/null)
  _mnm_scripts=$(nvram get jffs2_scripts 2>/dev/null)
  if [ "$_mnm_jffs" != 1 ] || [ "$_mnm_scripts" != 1 ]; then
    printf 'SYNC_STAGE_JFFS_NOT_READY|%s|%s\n' "$_mnm_jffs" "$_mnm_scripts"
    return 0
  fi
  mnm_path_chain_no_symlink "$MNM_BACKUPS" || return 1
  mkdir -p "$MNM_BACKUPS" || return 1
  [ ! -L "$MNM_STAGE" ] && [ ! -L "$MNM_OLD" ] || return 1
  if [ -e "$MNM_STAGE" ]; then [ -d "$MNM_STAGE" ] || return 1; rm -rf "$MNM_STAGE" || return 1; fi
  if [ -e "$MNM_OLD" ]; then [ -d "$MNM_OLD" ] || return 1; rm -rf "$MNM_OLD" || return 1; fi
  mkdir -p "$MNM_STAGE/settings" "$MNM_STAGE/functions" "$MNM_STAGE/templates" || return 1
  mkdir -p "$MNM_STAGE/dev-tools/tests/router" "$MNM_STAGE/dev-tools/safety" || return 1
  mnm_runtime_prepare || return 1
  printf 'SYNC_STAGE_READY\n'
}

mnm_jffs_reboot() {
  nvram set jffs2_on=1 || return 1
  nvram set jffs2_scripts=1 || return 1
  nvram commit || return 1
  sleep 2
  reboot
}

mnm_put_stage_settings() {
  mnm_stage_paths "$1" "$2" || return 64
  _mnm_file=$MNM_STAGE/settings/settings.json
  [ -d "$MNM_STAGE/settings" ] && [ ! -L "$MNM_STAGE/settings" ] || return 1
  _mnm_tmp=$_mnm_file.node-mutate.$$.tmp
  [ ! -e "$_mnm_tmp" ] && [ ! -L "$_mnm_tmp" ] || return 1
  MNM_TEMP=$_mnm_tmp
  umask 077
  cat > "$_mnm_tmp" || return 1
  [ -s "$_mnm_tmp" ] || return 1
  chmod 600 "$_mnm_tmp" || return 1
  mv -f "$_mnm_tmp" "$_mnm_file" || return 1
  MNM_TEMP=
  printf 'NODE_SETTINGS_STAGED\n'
}

mnm_make_stage_dir() {
  mnm_stage_paths "$1" "$2" || return 64
  _mnm_rel=$3
  mnm_valid_relpath "$_mnm_rel" || return 64
  [ -d "$MNM_STAGE" ] && [ ! -L "$MNM_STAGE" ] || return 1
  _mnm_dir=$MNM_STAGE/$_mnm_rel
  mnm_path_chain_no_symlink "$_mnm_dir" || return 1
  mkdir -p "$_mnm_dir"
}

mnm_put_stage_file() {
  mnm_stage_paths "$1" "$2" || return 64
  _mnm_rel=$3
  mnm_valid_relpath "$_mnm_rel" || return 64
  [ -d "$MNM_STAGE" ] && [ ! -L "$MNM_STAGE" ] || return 1
  _mnm_parent=${_mnm_rel%/*}
  [ "$_mnm_parent" != "$_mnm_rel" ] || _mnm_parent=.
  [ -d "$MNM_STAGE/$_mnm_parent" ] && [ ! -L "$MNM_STAGE/$_mnm_parent" ] || return 1
  _mnm_file=$MNM_STAGE/$_mnm_rel
  [ ! -L "$_mnm_file" ] || return 1
  _mnm_tmp=$_mnm_file.node-mutate.$$.tmp
  [ ! -e "$_mnm_tmp" ] && [ ! -L "$_mnm_tmp" ] || return 1
  MNM_TEMP=$_mnm_tmp
  umask 077
  cat > "$_mnm_tmp" || return 1
  [ -s "$_mnm_tmp" ] || return 1
  mv -f "$_mnm_tmp" "$_mnm_file" || return 1
  MNM_TEMP=
}

mnm_chmod_stage_file() {
  mnm_stage_paths "$1" "$2" || return 64
  _mnm_mode=$3
  _mnm_rel=$4
  case "$_mnm_mode" in 644|755) ;; *) return 64 ;; esac
  mnm_valid_relpath "$_mnm_rel" || return 64
  [ -f "$MNM_STAGE/$_mnm_rel" ] && [ ! -L "$MNM_STAGE/$_mnm_rel" ] || return 1
  chmod "$_mnm_mode" "$MNM_STAGE/$_mnm_rel"
}

mnm_extract_stage() {
  mnm_stage_paths "$1" "$2" || return 64
  shift 2
  [ "$#" -gt 0 ] || return 64
  _mnm_expected=' '
  _mnm_seen=' '
  for _mnm_rel do
    mnm_valid_relpath "$_mnm_rel" || return 64
    case "$_mnm_expected" in *" $_mnm_rel "*) return 64 ;; esac
    _mnm_expected="$_mnm_expected$_mnm_rel "
  done
  _mnm_work=$MNM_RUNTIME/node_mutate
  mnm_path_chain_no_symlink "$_mnm_work" || return 1
  mkdir -p "$_mnm_work" || return 1
  chmod 700 "$_mnm_work" || return 1
  MNM_TEMP=$_mnm_work/archive.$$.${MNM_LOCK_NONCE}.tar
  [ ! -e "$MNM_TEMP" ] && [ ! -L "$MNM_TEMP" ] || return 1
  cat > "$MNM_TEMP" || return 1
  [ -s "$MNM_TEMP" ] || return 1
  _mnm_list=$_mnm_work/list.$$.${MNM_LOCK_NONCE}
  [ ! -e "$_mnm_list" ] && [ ! -L "$_mnm_list" ] || return 1
  tar -tf "$MNM_TEMP" > "$_mnm_list" 2>/dev/null || { rm -f "$_mnm_list"; return 1; }
  _mnm_count=0
  while IFS= read -r _mnm_entry || [ -n "$_mnm_entry" ]; do
    mnm_valid_relpath "$_mnm_entry" || { rm -f "$_mnm_list"; return 1; }
    case "$_mnm_expected" in *" $_mnm_entry "*) ;; *) rm -f "$_mnm_list"; return 1 ;; esac
    case "$_mnm_seen" in *" $_mnm_entry "*) rm -f "$_mnm_list"; return 1 ;; esac
    _mnm_seen="${_mnm_seen:- }$_mnm_entry "
    _mnm_count=$((_mnm_count + 1))
  done < "$_mnm_list"
  rm -f "$_mnm_list" || return 1
  [ "$_mnm_count" -eq "$#" ] || return 1
  [ -d "$MNM_STAGE" ] && [ ! -L "$MNM_STAGE" ] || return 1
  ( cd "$MNM_STAGE" && tar -xf "$MNM_TEMP" ) || return 1
  rm -f "$MNM_TEMP" || return 1
  MNM_TEMP=
  printf 'SYNC_ARCHIVE_STAGED|%s\n' "$_mnm_count"
}

mnm_finalize_stage() {
  mnm_stage_paths "$1" "$2" || return 64
  shift 2
  [ -f "$MNM_STAGE/settings/settings.json" ] && [ ! -L "$MNM_STAGE/settings/settings.json" ] || return 1
  [ -f "$MNM_STAGE/settings/lib_json.sh" ] && [ ! -L "$MNM_STAGE/settings/lib_json.sh" ] || return 1
  for _mnm_mode_path do
    case "$_mnm_mode_path" in
      755:*) _mnm_mode=755; _mnm_rel=${_mnm_mode_path#755:} ;;
      644:*) _mnm_mode=644; _mnm_rel=${_mnm_mode_path#644:} ;;
      *) return 64 ;;
    esac
    mnm_valid_relpath "$_mnm_rel" || return 64
    [ -f "$MNM_STAGE/$_mnm_rel" ] || return 1
    chmod "$_mnm_mode" "$MNM_STAGE/$_mnm_rel" || return 1
  done
  unset LIB_JSON_LOADED
  . "$MNM_STAGE/settings/lib_json.sh" 2>/dev/null || return 1
  json_set_flag IS_NODE 1 "$MNM_STAGE/settings/settings.json" || return 1
  json_set_flag NODE_ID "$MNM_NODE" "$MNM_STAGE/settings/settings.json" || return 1
  _mnm_is_node=$(json_get_flag IS_NODE 0 "$MNM_STAGE/settings/settings.json" 2>/dev/null)
  _mnm_node_id=$(json_get_flag NODE_ID none "$MNM_STAGE/settings/settings.json" 2>/dev/null)
  [ "$_mnm_is_node" = 1 ] && [ "$_mnm_node_id" = "$MNM_NODE" ] || return 1
  printf '1\n%s\n' "$MNM_NODE"
}

mnm_sync_boot_reconcile() {
  _mnm_active=$1
  SYNC_NODE_BOOT_DETAIL=
  SYNC_NODE_BOOT_REPORT=
  _mnm_services=${SCRIPTS_DIR:-/jffs/scripts}/services-start
  _mnm_event=${SCRIPTS_DIR:-/jffs/scripts}/service-event
  _mnm_settings=$_mnm_active/settings/settings.json
  _mnm_boot=$_mnm_active/functions/mervlan_boot.sh
  _mnm_json=$_mnm_active/settings/lib_json.sh
  _mnm_integrity=$_mnm_active/settings/lib_boot_integrity.sh
  [ -f "$_mnm_settings" ] && [ -f "$_mnm_json" ] && [ -f "$_mnm_integrity" ] || { SYNC_NODE_BOOT_DETAIL=settings-cohort-missing; return 1; }
  unset LIB_JSON_LOADED LIB_BOOT_INTEGRITY_LOADED
  . "$_mnm_json" 2>/dev/null || { SYNC_NODE_BOOT_DETAIL=settings-helper-load-failed; return 1; }
  . "$_mnm_integrity" 2>/dev/null || { SYNC_NODE_BOOT_DETAIL=boot-integrity-helper-load-failed; return 1; }
  _mnm_desired=$(merv_boot_read_preference "$_mnm_settings" 2>/dev/null)
  [ "$?" -eq 0 ] || { SYNC_NODE_BOOT_DETAIL=invalid-boot-enabled; return 1; }
  case "$_mnm_desired" in 1) _mnm_action=enable ;; 0) _mnm_action=disable ;; *) SYNC_NODE_BOOT_DETAIL=invalid-boot-enabled; return 1 ;; esac
  MERV_NODE_CONTEXT=1 sh "$_mnm_boot" "$_mnm_action" >/dev/null 2>&1 || { SYNC_NODE_BOOT_DETAIL="boot-${_mnm_action}-failed"; return 1; }
  merv_boot_verify_local "$_mnm_desired" node "$_mnm_services" "$_mnm_event" "$_mnm_settings" "${CRU_BIN:-}" "$_mnm_active" || {
    SYNC_NODE_BOOT_DETAIL="node-local-integrity-${MERV_BOOT_VERIFY_REASON:-unknown}"; return 1;
  }
  _mnm_report=$(MERV_NODE_CONTEXT=1 sh "$_mnm_boot" report 2>/dev/null | tail -1)
  SYNC_NODE_BOOT_REPORT=$_mnm_report
  case " $_mnm_report " in *" addon=node-on "*|*" addon=node-on"*) : ;; *) SYNC_NODE_BOOT_DETAIL=node-baseline-not-active; return 1 ;; esac
  case " $_mnm_report " in *" event=active "*|*" event=active"*) : ;; *) SYNC_NODE_BOOT_DETAIL=node-service-event-not-active; return 1 ;; esac
  if [ "$_mnm_desired" = 1 ]; then
    case " $_mnm_report " in *" boot=1 "*|*" boot=1"*) : ;; *) SYNC_NODE_BOOT_DETAIL=node-boot-state-mismatch; return 1 ;; esac
    case " $_mnm_report " in *" cron=present "*|*" cron=present"*) : ;; *) SYNC_NODE_BOOT_DETAIL=node-cron-missing; return 1 ;; esac
    case " $_mnm_report " in *" manager_hook=present "*) : ;; *) SYNC_NODE_BOOT_DETAIL=node-manager-hook-not-present; return 1 ;; esac
  else
    case " $_mnm_report " in *" boot=0 "*|*" boot=0"*) : ;; *) SYNC_NODE_BOOT_DETAIL=node-boot-state-mismatch; return 1 ;; esac
    case " $_mnm_report " in *" cron=absent "*|*" cron=absent"*) : ;; *) SYNC_NODE_BOOT_DETAIL=node-cron-present; return 1 ;; esac
    case " $_mnm_report " in *" manager_hook=absent "*) : ;; *) SYNC_NODE_BOOT_DETAIL=node-manager-hook-not-absent; return 1 ;; esac
  fi
  return 0
}

mnm_activate_full() {
  mnm_stage_paths "$1" "$2" || return 64
  _mnm_active=$MNM_ACTIVE
  [ -f "$MNM_STAGE/settings/settings.json" ] || return 21
  [ -x "$MNM_STAGE/functions/mervlan_boot.sh" ] || return 22
  [ ! -L "$MNM_ACTIVE" ] && [ ! -L "$MNM_STAGE" ] && [ ! -L "$MNM_OLD" ] || return 1
  if [ -e "$MNM_OLD" ]; then [ -d "$MNM_OLD" ] || return 1; rm -rf "$MNM_OLD" || return 23; fi
  _mnm_had_old=0
  if [ -d "$MNM_ACTIVE" ]; then mv "$MNM_ACTIVE" "$MNM_OLD" || return 24; _mnm_had_old=1; fi
  if [ "$_mnm_had_old" = 1 ] && [ -d "$MNM_OLD/tmp" ]; then
    mkdir -p "$MNM_STAGE/tmp" || return 23
    for _mnm_db in "$MNM_OLD"/tmp/*.db; do
      [ -f "$_mnm_db" ] || continue
      cp -p "$_mnm_db" "$MNM_STAGE/tmp/" || return 23
    done
  fi
  if ! mv "$MNM_STAGE" "$MNM_ACTIVE"; then
    if [ "$_mnm_had_old" = 1 ]; then mv "$MNM_OLD" "$MNM_ACTIVE" 2>/dev/null || return 27; fi
    return 25
  fi
  _mnm_nodeenable_rc=0
  if cd "$MNM_ACTIVE/functions"; then
    MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh nodeenable --local >/dev/null 2>&1 || _mnm_nodeenable_rc=$?
  else
    _mnm_nodeenable_rc=24
  fi
  _mnm_boot_rc=1
  _mnm_boot_detail=
  _mnm_report=
  if [ "$_mnm_nodeenable_rc" -eq 0 ]; then
    mnm_sync_boot_reconcile "$MNM_ACTIVE"
    _mnm_boot_rc=$?
    _mnm_boot_detail=${SYNC_NODE_BOOT_DETAIL:-}
    _mnm_report=${SYNC_NODE_BOOT_REPORT:-}
  fi
  if [ "$_mnm_nodeenable_rc" -eq 0 ] && [ "$_mnm_boot_rc" -eq 0 ]; then
    if [ "$_mnm_had_old" = 1 ]; then rm -rf "$MNM_OLD" || { echo STAGED_NODE_CLEANUP_FAILED; return 28; }; fi
    printf 'NODE_REPORT=%s\n' "$_mnm_report"
    echo STAGED_NODE_OK
    _mnm_probe_rc=1
    if cd "$MNM_ACTIVE/functions"; then MERV_NODE_CONTEXT=1 sh ./hw_probe.sh >/dev/null 2>&1; _mnm_probe_rc=$?; fi
    if [ "$_mnm_probe_rc" -eq 0 ] && . "$MNM_ACTIVE/settings/lib_json.sh" 2>/dev/null; then
      printf 'PRODUCTID=%s\n' "$(json_get_section_value Hardware PRODUCTID "$MNM_ACTIVE/settings/settings.json" 2>/dev/null)"
      printf 'MAX_ETH_PORTS=%s\n' "$(json_get_section_value Hardware MAX_ETH_PORTS "$MNM_ACTIVE/settings/settings.json" 2>/dev/null)"
      printf 'LAN_PORT_LABEL_OVERRIDES=%s\n' "$(json_get_section_value Hardware LAN_PORT_LABEL_OVERRIDES "$MNM_ACTIVE/settings/settings.json" 2>/dev/null)"
    else
      echo HWPROBE_FAILED
    fi
    return 0
  fi
  _mnm_msg=$(printf '%s\n' "${_mnm_boot_detail:-nodeenable-failed}" | tail -n 1 | tr -cd 'A-Za-z0-9_.,:=-' | cut -c 1-120)
  printf 'STAGED_NODE_FAIL nodeenable_rc=%s boot_rc=%s report=%s detail=%s\n' "$_mnm_nodeenable_rc" "$_mnm_boot_rc" "$_mnm_report" "$_mnm_msg"
  rm -rf "$MNM_STAGE" 2>/dev/null || return 26
  mv "$MNM_ACTIVE" "$MNM_STAGE" 2>/dev/null || return 26
  if [ "$_mnm_had_old" = 1 ]; then
    mv "$MNM_OLD" "$MNM_ACTIVE" 2>/dev/null || return 27
    cd "$MNM_ACTIVE/functions" 2>/dev/null || { echo STAGED_NODE_ROLLBACK_FAIL stage=nodeenable; return 28; }
    MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh nodeenable --local >/dev/null 2>&1 || { echo STAGED_NODE_ROLLBACK_FAIL stage=nodeenable; return 28; }
    mnm_sync_boot_reconcile "$MNM_ACTIVE" || {
      _mnm_rb_detail=$(printf '%s\n' "${SYNC_NODE_BOOT_DETAIL:-boot-reconcile-failed}" | tr -cd 'A-Za-z0-9_.,:=-' | cut -c 1-120)
      printf 'STAGED_NODE_ROLLBACK_FAIL stage=boot-reconcile detail=%s\n' "$_mnm_rb_detail"
      return 28
    }
    rm -rf "$MNM_STAGE" || return 29
    printf 'STAGED_NODE_ROLLBACK_OK\n'
    return 0
  fi
  mv "$MNM_STAGE" "$MNM_ACTIVE" 2>/dev/null || return 26
  printf 'STAGED_NODE_ROLLBACK_OK\n'
  return 0
}

mnm_activate_settings() {
  mnm_stage_paths "$1" "$2" || return 64
  _mnm_target=$MNM_ACTIVE/settings/settings.json
  _mnm_pub_dir=/www/user/mervlan/settings
  _mnm_pub_target=$_mnm_pub_dir/settings.json
  _mnm_staged=$MNM_STAGE/settings/settings.json
  _mnm_tmp=$_mnm_target.sync.$MNM_NODE.$$.tmp
  [ -f "$_mnm_staged" ] && [ ! -L "$_mnm_staged" ] || return 21
  mnm_path_chain_no_symlink "$MNM_ACTIVE/settings" || return 1
  mkdir -p "$MNM_ACTIVE/settings" || return 23
  [ ! -e "$_mnm_tmp" ] && [ ! -L "$_mnm_tmp" ] || return 1
  cp "$_mnm_staged" "$_mnm_tmp" || return 25
  chmod 600 "$_mnm_tmp" 2>/dev/null || :
  [ -s "$_mnm_tmp" ] || { rm -f "$_mnm_tmp"; return 26; }
  cmp -s "$_mnm_staged" "$_mnm_tmp" || { rm -f "$_mnm_tmp"; return 27; }
  mv "$_mnm_tmp" "$_mnm_target" || { rm -f "$_mnm_tmp"; return 28; }
  cmp -s "$_mnm_staged" "$_mnm_target" || return 29
  if [ -d "$_mnm_pub_dir" ]; then
    cp "$_mnm_target" "$_mnm_pub_target" 2>/dev/null || :
    chmod 644 "$_mnm_pub_target" 2>/dev/null || :
  fi
  rm -rf "$MNM_STAGE" 2>/dev/null || :
  echo STAGED_SETTINGS_OK
}

mnm_execute_ensure_settings() {
  mnm_valid_node "$1" || return 64
  mnm_path_chain_no_symlink "$MNM_ACTIVE/settings" || return 1
  mkdir -p "$MNM_ACTIVE/settings"
}

mnm_execute_put_settings() {
  mnm_valid_node "$1" || return 64
  _mnm_file=$MNM_ACTIVE/settings/settings.json
  mnm_path_chain_no_symlink "$MNM_ACTIVE/settings" || return 1
  mkdir -p "$MNM_ACTIVE/settings" || return 1
  _mnm_tmp=$_mnm_file.node-mutate.$$.tmp
  [ ! -e "$_mnm_tmp" ] && [ ! -L "$_mnm_tmp" ] || return 1
  MNM_TEMP=$_mnm_tmp
  umask 077
  cat > "$_mnm_tmp" || return 1
  [ -s "$_mnm_tmp" ] || return 1
  chmod 600 "$_mnm_tmp" || return 1
  mv -f "$_mnm_tmp" "$_mnm_file" || return 1
  MNM_TEMP=
  printf 'NODE_SETTINGS_INSTALLED\n'
}

mnm_execute_node_flags() {
  mnm_valid_node "$1" || return 64
  _mnm_file=$MNM_ACTIVE/settings/settings.json
  [ -f "$_mnm_file" ] && [ ! -L "$_mnm_file" ] || return 1
  [ -f "$MNM_ACTIVE/settings/lib_json.sh" ] && [ ! -L "$MNM_ACTIVE/settings/lib_json.sh" ] || return 1
  unset LIB_JSON_LOADED
  . "$MNM_ACTIVE/settings/lib_json.sh" 2>/dev/null || return 1
  _mnm_current_node=$(json_get_flag IS_NODE '' "$_mnm_file" 2>/dev/null)
  _mnm_current_id=$(json_get_flag NODE_ID '' "$_mnm_file" 2>/dev/null)
  [ "$_mnm_current_node" = 1 ] || json_set_flag IS_NODE 1 "$_mnm_file" || return 1
  [ "$_mnm_current_id" = "$1" ] || json_set_flag NODE_ID "$1" "$_mnm_file" || return 1
  printf '%s\n%s\n' "$(json_get_flag IS_NODE 0 "$_mnm_file")" "$(json_get_flag NODE_ID none "$_mnm_file")"
}

mnm_hardware_probe() {
  _mnm_func_dir=$MNM_ACTIVE/functions
  [ -x "$_mnm_func_dir/hw_probe.sh" ] || return 1
  ( cd "$_mnm_func_dir" && MERV_NODE_CONTEXT=1 sh ./hw_probe.sh ) || return 1
  . "$MNM_ACTIVE/settings/lib_json.sh" 2>/dev/null || return 1
  printf 'PRODUCTID=%s\n' "$(json_get_section_value Hardware PRODUCTID "$MNM_ACTIVE/settings/settings.json" 2>/dev/null)"
  printf 'MAX_ETH_PORTS=%s\n' "$(json_get_section_value Hardware MAX_ETH_PORTS "$MNM_ACTIVE/settings/settings.json" 2>/dev/null)"
  printf 'LAN_PORT_LABEL_OVERRIDES=%s\n' "$(json_get_section_value Hardware LAN_PORT_LABEL_OVERRIDES "$MNM_ACTIVE/settings/settings.json" 2>/dev/null)"
}

mnm_test_pause_write() {
  [ "$MNM_SELFTEST" = 1 ] || return 64
  _mnm_target=${1:-}
  _mnm_ready=${2:-}
  _mnm_release=${3:-}
  merv_selftest_context_path_allowed "$_mnm_target" &&
    merv_selftest_context_path_allowed "$_mnm_ready" &&
    merv_selftest_context_path_allowed "$_mnm_release" || return 64
  : > "$_mnm_target" || return 1
  : > "$_mnm_ready" || return 1
  while [ ! -e "$_mnm_release" ]; do sleep 1; done
  printf 'NODE_MUTATION_TEST_DONE\n' >> "$_mnm_target"
}

mnm_bootstrap_cleanup() {
  [ -n "$MNM_BOOTSTRAP_ROOT" ] || return 1
  _mnm_parent=${MNM_BOOTSTRAP_ROOT%/cohort}
  for _mnm_rel in $MNM_BOOTSTRAP_FILES; do
    rm -f "$MNM_BOOTSTRAP_ROOT/$_mnm_rel" || return 1
  done
  rmdir "$MNM_BOOTSTRAP_ROOT/settings" "$MNM_BOOTSTRAP_ROOT/functions" \
    "$MNM_BOOTSTRAP_ROOT" || return 1
  rm -f "$_mnm_parent/.owner" || return 1
  rmdir "$_mnm_parent" || return 1
  return 0
}

# Validate the selected operation before acquiring ownership.  The operation
# and all positional values are revalidated in the handler as well.
case "$MNM_OP" in
  verify-bootstrap-cohort|cleanup-bootstrap-cohort|jffs-enable-reboot|prepare-stage|make-stage-dir|put-stage-file|put-stage-settings|extract-stage|finalize-stage|chmod-stage-file|cleanup-stage|activate-settings|activate-full|execute-ensure-settings|execute-put-settings|execute-node-flags|hardware-probe)
    ;;
  test-pause-write)
    [ "$MNM_SELFTEST" = 1 ] || exit 64
    ;;
  *) printf 'NODE_MUTATION_INVALID_OPERATION\n' >&2; exit 64 ;;
esac

_mnm_shape_ok=1
case "$MNM_OP" in
  verify-bootstrap-cohort|cleanup-bootstrap-cohort) [ "$#" -eq 2 ] && mnm_bootstrap_args_match "$1" "$2" || _mnm_shape_ok=0 ;;
  jffs-enable-reboot|hardware-probe) [ "$#" -eq 0 ] || _mnm_shape_ok=0 ;;
  prepare-stage|put-stage-settings|cleanup-stage|activate-settings|activate-full)
    [ "$#" -eq 2 ] && mnm_valid_run "$1" && mnm_valid_node "$2" || _mnm_shape_ok=0
    ;;
  extract-stage) [ "$#" -ge 3 ] && mnm_valid_run "$1" && mnm_valid_node "$2" || _mnm_shape_ok=0 ;;
  finalize-stage) [ "$#" -ge 2 ] && mnm_valid_run "$1" && mnm_valid_node "$2" || _mnm_shape_ok=0 ;;
  make-stage-dir|put-stage-file)
    [ "$#" -eq 3 ] && mnm_valid_run "$1" && mnm_valid_node "$2" || _mnm_shape_ok=0
    ;;
  chmod-stage-file)
    [ "$#" -eq 4 ] && mnm_valid_run "$1" && mnm_valid_node "$2" || _mnm_shape_ok=0
    ;;
  execute-ensure-settings|execute-put-settings|execute-node-flags) [ "$#" -eq 1 ] && mnm_valid_node "$1" || _mnm_shape_ok=0 ;;
  test-pause-write)
    [ "$MNM_SELFTEST" = 1 ] && [ "$#" -eq 3 ] || _mnm_shape_ok=0
    ;;
esac
[ "$_mnm_shape_ok" = 1 ] || { printf 'NODE_MUTATION_INVALID_ARGUMENTS\n'; exit 0; }

if [ -n "$MNM_BOOTSTRAP_ROOT" ]; then
  case "$MNM_OP" in
    verify-bootstrap-cohort)
      mnm_bootstrap_args_match "$1" "$2" || { printf 'NODE_MUTATION_INVALID_ARGUMENTS\n'; exit 0; }
      printf 'NODE_MUTATION_OK|verify-bootstrap-cohort\n'
      exit 0
      ;;
    cleanup-bootstrap-cohort)
      mnm_bootstrap_args_match "$1" "$2" && mnm_bootstrap_cleanup || {
        printf 'NODE_MUTATION_FAILED|cleanup-bootstrap-cohort|70\n'
        exit 0
      }
      printf 'NODE_MUTATION_OK|cleanup-bootstrap-cohort\n'
      exit 0
      ;;
    prepare-stage|put-stage-settings|cleanup-stage|activate-settings|activate-full|extract-stage|finalize-stage|make-stage-dir|put-stage-file|chmod-stage-file)
      mnm_bootstrap_args_match "$1" "$2" || { printf 'NODE_MUTATION_INVALID_ARGUMENTS\n'; exit 0; }
      ;;
    execute-ensure-settings|execute-put-settings|execute-node-flags|hardware-probe|test-pause-write)
      printf 'NODE_MUTATION_INVALID_OPERATION\n' >&2
      exit 64
      ;;
  esac
fi

if ! mnm_admit; then
  _mnm_reason=${MERV_MUTATION_ADMISSION_REASON:-${MERV_ACTION_LOCK_LAST_FAILURE:-owner-unverifiable}}
  case "$_mnm_reason" in *[!A-Za-z0-9._-]*) _mnm_reason=owner-unverifiable ;; esac
  if [ "$MNM_LOCK_OWNED" = 1 ]; then
    merv_action_lock_leave "$MNM_ACTION" "$MNM_LOCK_NONCE" "$MNM_LOCK_START" self || {
      printf 'NODE_MUTATION_RELEASE_FAILED|%s\n' "$MNM_OP"
      exit 0
    }
    MNM_LOCK_OWNED=0
  fi
  printf 'NODE_MUTATION_BLOCKED|%s\n' "$_mnm_reason"
  exit 0
fi

_mnm_output_root=$MNM_RUNTIME/node_mutate
mnm_path_chain_no_symlink "$_mnm_output_root" || { printf 'NODE_MUTATION_FAILED|%s|70\n' "$MNM_OP"; exit 0; }
mkdir -p "$_mnm_output_root" || { printf 'NODE_MUTATION_FAILED|%s|70\n' "$MNM_OP"; exit 0; }
chmod 700 "$_mnm_output_root" 2>/dev/null || { printf 'NODE_MUTATION_FAILED|%s|70\n' "$MNM_OP"; exit 0; }
MNM_OUTPUT=$_mnm_output_root/output.$$.${MNM_LOCK_NONCE}
[ ! -e "$MNM_OUTPUT" ] && [ ! -L "$MNM_OUTPUT" ] || { printf 'NODE_MUTATION_FAILED|%s|70\n' "$MNM_OP"; exit 0; }
( umask 077; : > "$MNM_OUTPUT" ) || { printf 'NODE_MUTATION_FAILED|%s|70\n' "$MNM_OP"; exit 0; }

case "$MNM_OP" in
  jffs-enable-reboot) mnm_jffs_reboot > "$MNM_OUTPUT" 2>&1; _mnm_rc=$? ;;
  prepare-stage) mnm_prepare_stage "$1" "$2" > "$MNM_OUTPUT" 2>&1; _mnm_rc=$? ;;
  put-stage-settings) mnm_put_stage_settings "$1" "$2" > "$MNM_OUTPUT" 2>&1; _mnm_rc=$? ;;
  make-stage-dir) mnm_make_stage_dir "$@" > "$MNM_OUTPUT" 2>&1; _mnm_rc=$? ;;
  put-stage-file) mnm_put_stage_file "$@" > "$MNM_OUTPUT" 2>&1; _mnm_rc=$? ;;
  chmod-stage-file) mnm_chmod_stage_file "$@" > "$MNM_OUTPUT" 2>&1; _mnm_rc=$? ;;
  extract-stage) mnm_extract_stage "$@" > "$MNM_OUTPUT" 2>&1; _mnm_rc=$? ;;
  finalize-stage) mnm_finalize_stage "$@" > "$MNM_OUTPUT" 2>&1; _mnm_rc=$? ;;
  cleanup-stage)
    mnm_stage_paths "$1" "$2" || exit 64
    if [ -L "$MNM_STAGE" ]; then _mnm_rc=1
    elif [ -e "$MNM_STAGE" ]; then [ -d "$MNM_STAGE" ] && rm -rf "$MNM_STAGE"; _mnm_rc=$?
    else _mnm_rc=0; fi
    ;;
  activate-settings) mnm_activate_settings "$1" "$2" > "$MNM_OUTPUT" 2>&1; _mnm_rc=$? ;;
  activate-full) mnm_activate_full "$1" "$2" > "$MNM_OUTPUT" 2>&1; _mnm_rc=$? ;;
  execute-ensure-settings) mnm_execute_ensure_settings "$1" > "$MNM_OUTPUT" 2>&1; _mnm_rc=$? ;;
  execute-put-settings) mnm_execute_put_settings "$1" > "$MNM_OUTPUT" 2>&1; _mnm_rc=$? ;;
  execute-node-flags) mnm_execute_node_flags "$1" > "$MNM_OUTPUT" 2>&1; _mnm_rc=$? ;;
  hardware-probe) mnm_hardware_probe > "$MNM_OUTPUT" 2>&1; _mnm_rc=$? ;;
  test-pause-write) mnm_test_pause_write "$@" > "$MNM_OUTPUT" 2>&1; _mnm_rc=$? ;;
esac

cat "$MNM_OUTPUT" 2>/dev/null || :
rm -f "$MNM_OUTPUT" 2>/dev/null || :
MNM_OUTPUT=
merv_action_lock_leave "$MNM_ACTION" "$MNM_LOCK_NONCE" "$MNM_LOCK_START" self || {
  printf 'NODE_MUTATION_RELEASE_FAILED|%s\n' "$MNM_OP"
  exit 0
}
MNM_LOCK_OWNED=0
if [ "$_mnm_rc" -eq 0 ]; then
  printf 'NODE_MUTATION_OK|%s\n' "$MNM_OP"
else
  printf 'NODE_MUTATION_FAILED|%s|%s\n' "$MNM_OP" "$_mnm_rc"
fi
exit 0
