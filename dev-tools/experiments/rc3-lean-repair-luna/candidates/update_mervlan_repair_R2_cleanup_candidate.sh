#!/bin/sh
# MerVLAN RC3 lean Repair -- ISOLATED QUALIFICATION ONLY, NOT FOR ROUTERS.
# A real installation must first prove all conflicting runtime writers obey
# the same exclusion gate. No such proof exists for the installed legacy code.
set -u
LC_ALL=C; export LC_ALL
: "${MERV_BASE:=/jffs/addons/mervlan}"
: "${MERV_REPAIR_TMP_ROOT:=/tmp}"
: "${MERV_REPAIR_PROC_ROOT:=/proc}"
: "${MERV_REPAIR_LOCK:=/tmp/mervlan_tmp/locks/mervlan_maintenance.lock}"
: "${MERV_REPAIR_LEGACY_LOCK_ROOT:=/tmp/mervlan_tmp/locks}"
: "${MERV_REPAIR_SNAPSHOT_BASE:=https://codeload.github.com/r80xcore/mervlan/tar.gz}"
: "${MERV_REPAIR_MEMINFO:=/proc/meminfo}"
: "${MERV_REPAIR_CURL:=curl}"
WORK= LOCKED=0 TX=0 COMMITTED=0 ROLLBACK_OK=0 PUBLISHED=0
RUN_START=$(date +%s 2>/dev/null || printf '0')
START_ID= REF= ROOT= COHORT= MANIFEST= STAGE= BACKUP= LEDGER= ARCHIVE=
status() {
  now=$(date +%s 2>/dev/null || printf '%s' "$RUN_START")
  printf '[mervlan-lean] %s elapsed=%ss %s\n' "$1" "$((now-RUN_START))" "${2:-}" >&2
}
stop() { status ERROR "$*"; exit 1; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
regular() { [ -f "$1" ] && [ ! -L "$1" ]; }
# No symlinked ancestor or malformed filesystem path is trusted.
safe_chain() {
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in *..*|*//*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
  rest=${1#/}; part=/
  while [ -n "$rest" ]; do
    case "$rest" in */*) component=${rest%%/*}; rest=${rest#*/} ;; *) component=$rest; rest= ;; esac
    [ -n "$component" ] || return 1
    part="$part$component"
    if exists "$part"; then
      [ ! -L "$part" ] && [ -d "$part" ] || return 1
    fi
    part="$part/"
  done
}
# Parents for the allowlisted cohort can be created, but never via symlinks.
ensure_dir() {
  safe_chain "$1" || return 1
  rest=${1#/}; part=/
  while [ -n "$rest" ]; do
    case "$rest" in */*) component=${rest%%/*}; rest=${rest#*/} ;; *) component=$rest; rest= ;; esac
    part="$part$component"
    if ! exists "$part"; then mkdir "$part" || return 1; fi
    [ -d "$part" ] && [ ! -L "$part" ] || return 1
    part="$part/"
  done
}
valid_rel() {
  case "$1" in ''|/*|*..*|*//*|*' '*|*'\t'*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
  case "$1" in .|./*|*/.|*/./*|*/..) return 1 ;; esac
}
valid_ref() {
  case "$1" in ''|/*|*/|*..*|*//*|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  case "$1" in [A-Za-z0-9]* ) : ;; *) return 1 ;; esac
  [ "${#1}" -le 96 ]
}
# The allowlist is compiled into the trusted standalone engine, not loaded
# from potentially broken installed files or an untrusted source manifest.
write_contract() {
  cat >"$WORK/expected.manifest" <<'CONTRACT'
format=2
cohort=control-plane
0644 changelog.txt
0644 mervlan.asp
0644 www/index.html
0755 functions/collect_clients.sh
0755 functions/collect_local_clients.sh
0755 functions/device_support_mapper.sh
0755 functions/dropbear_sshkey_gen.sh
0755 functions/execute_nodes.sh
0755 functions/heal_event.sh
0755 functions/hw_probe.sh
0755 functions/mac_client_meta.sh
0755 functions/mac_refresh.sh
0755 functions/mervlan_backup.sh
0755 functions/mervlan_boot.sh
0755 functions/mervlan_boot_wrap.sh
0755 functions/mervlan_manager.sh
0755 functions/mervlan_node_runner.sh
0755 functions/mervlan_recover.sh
0755 functions/mervlan_trunk.sh
0755 functions/mervlan_wan.sh
0755 functions/post_apply_worker.sh
0755 functions/save_settings.sh
0755 functions/settings_reconcile.sh
0755 functions/service-event-handler.sh
0755 functions/ssh_hostkey_probe.sh
0755 functions/ssh_trust_action.sh
0755 functions/sync_nodes.sh
0755 functions/update_mervlan.sh
0644 functions/update_mervlan_repair.manifest
0755 functions/update_mervlan_repair.sh
0755 install.sh
0644 settings/lib_action_ack.sh
0644 settings/lib_action_lock.sh
0644 settings/lib_action_progress.sh
0644 settings/lib_action_runtime.sh
0644 settings/lib_br0_guard.sh
0644 settings/lib_debug.sh
0644 settings/lib_identity.sh
0644 settings/lib_json.sh
0644 settings/lib_maintenance_recovery.sh
0644 settings/lib_backup_state.sh
0644 settings/lib_mervqt.sh
0644 settings/lib_node_jobs.sh
0644 settings/lib_node_reconcile.sh
0644 settings/lib_settings_reconcile.sh
0644 settings/lib_owner_lock.sh
0644 settings/lib_progress.sh
0644 settings/lib_radio.sh
0644 settings/lib_ssh.sh
0644 settings/lib_ssh_trust.sh
0644 settings/lib_ssid_filter.sh
0644 settings/lib_stp.sh
0644 settings/lib_update_state.sh
0644 settings/log_settings.sh
0644 settings/mac_shield_snapshot.sh
0644 settings/var_settings.sh
0644 templates/mervlan_templates.sh
0755 uninstall.sh
CONTRACT
  sed '1,2d' "$WORK/expected.manifest" >"$COHORT"
}
proc_start() (
  pid=$1; proc_root=${2:-/proc}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "$proc_root/$pid/stat" ] || return 1
  line=; IFS= read -r line <"$proc_root/$pid/stat" || [ -n "$line" ] || return 1
  case "$line" in *')'*) after=${line#*)} ;; *) return 1 ;; esac
  IFS=' 	
'
  set -- $after
  tick=${20:-}
  case "$tick" in ''|*[!0-9]*) return 1 ;; esac
  case "$tick" in *[1-9]*) : ;; *) return 1 ;; esac
  printf '%s\n' "$tick"
)
owner_ok() {
  [ "$LOCKED" -eq 1 ] && [ -d "$MERV_REPAIR_LOCK" ] &&
    [ ! -L "$MERV_REPAIR_LOCK" ] && regular "$MERV_REPAIR_LOCK/owner" || return 1
  expected=$(printf 'pid=%s\nproc_start_time=%s\nowner_nonce=%s\ncreated=%s\nheartbeat=%s\n' \
    "$$" "$START_ID" "lean.$$.$START_ID" "$START_TIME" "$START_TIME")
  actual=$(cat "$MERV_REPAIR_LOCK/owner") || return 1
  [ "$actual" = "$expected" ] && [ "$(proc_start $$ 2>/dev/null)" = "$START_ID" ]
}
acquire() {
  safe_chain "${MERV_REPAIR_LOCK%/*}" || return 1
  ensure_dir "${MERV_REPAIR_LOCK%/*}" || return 1
  # Refuse ALL existing owners, even apparently stale or malformed ones.
  # This avoids dangerous lock stealing and any stale-owner election framework.
  if exists "$MERV_REPAIR_LOCK"; then status REFUSED 'maintenance owner exists'; return 1; fi
  START_ID=$(proc_start $$) || return 1
  START_TIME=$(date +%s) || return 1
  mkdir "$MERV_REPAIR_LOCK" 2>/dev/null || return 1
  LOCKED=1
  (umask 077; printf 'pid=%s\nproc_start_time=%s\nowner_nonce=%s\ncreated=%s\nheartbeat=%s\n' \
    "$$" "$START_ID" "lean.$$.$START_ID" "$START_TIME" "$START_TIME" >"$MERV_REPAIR_LOCK/owner") || return 1
  owner_ok || return 1
  status ADMISSION 'exclusive maintenance owner acquired'
}
release() {
  [ "$LOCKED" -eq 1 ] || return 0
  owner_ok || return 1
  rm "$MERV_REPAIR_LOCK/owner" || return 1
  rmdir "$MERV_REPAIR_LOCK" || return 1
  LOCKED=0
}
# Historical writer inventory (identical recognized basenames to accepted R1).
mutator() {
  case "$1" in
    "$MERV_BASE"/install.sh|"$MERV_BASE"/uninstall.sh|\
    "$MERV_BASE"/functions/update_mervlan.sh|"$MERV_BASE"/functions/mervlan_manager.sh|\
    "$MERV_BASE"/functions/sync_nodes.sh|"$MERV_BASE"/functions/execute_nodes.sh|\
    "$MERV_BASE"/functions/service-event-handler.sh|"$MERV_BASE"/functions/mervlan_boot.sh|\
    "$MERV_BASE"/functions/mervlan_boot_wrap.sh|"$MERV_BASE"/functions/heal_event.sh|\
    "$MERV_BASE"/functions/save_settings.sh|"$MERV_BASE"/functions/hw_probe.sh|\
    "$MERV_BASE"/functions/dropbear_sshkey_gen.sh) return 0 ;; esac
  return 1
}
relative_candidate() {
  case "$1" in ''|/*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
  case "${1##*/}" in
    install.sh|uninstall.sh|update_mervlan.sh|mervlan_manager.sh|\
    sync_nodes.sh|execute_nodes.sh|service-event-handler.sh|\
    mervlan_boot.sh|mervlan_boot_wrap.sh|heal_event.sh|\
    save_settings.sh|hw_probe.sh|dropbear_sshkey_gen.sh) return 0 ;;
  esac
  return 1
}
# Strip harmless ./ components, including nested ones. Reject '..' and
# malformed candidates instead of assuming their resulting path is harmless.
normalize_relative() (
  rest=$1; output=
  case "$rest" in ''|/*|*..*|*//*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
  while [ -n "$rest" ]; do
    case "$rest" in */*) component=${rest%%/*}; rest=${rest#*/} ;;
      *) component=$rest; rest= ;; esac
    case "$component" in ''|.) : ;;
      *) if [ -n "$output" ]; then output="$output/$component";
         else output=$component; fi ;; esac
  done
  [ -n "$output" ] || return 1
  printf '%s\n' "$output"
)
scan_processes() {
  safe_chain "$MERV_REPAIR_PROC_ROOT" && [ -d "$MERV_REPAIR_PROC_ROOT" ] &&
    [ -r "$MERV_REPAIR_PROC_ROOT" ] && [ -x "$MERV_REPAIR_PROC_ROOT" ] || return 1
  for entry in "$MERV_REPAIR_PROC_ROOT"/[0-9]*; do
    exists "$entry" || continue
    [ -d "$entry" ] && [ ! -L "$entry" ] || return 1
    pid=${entry##*/}
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    case "$pid" in *[1-9]*) : ;; *) return 1 ;; esac
    regular "$entry/cmdline" && [ -r "$entry/cmdline" ] || return 1
    # Important: read each PID only when its turn arrives. Never pre-shortlist.
    argv=$(tr '\000' '\n' <"$entry/cmdline") || return 1
    [ -n "$argv" ] || continue
    matched=0
    # Exact absolute paths take priority; all other arguments are inspected
    # as relative candidates, including BARE filenames (the R1 regression).
    while IFS= read -r arg || [ -n "$arg" ]; do
      if mutator "$arg"; then matched=1; break; fi
    done <<ARGS
$argv
ARGS
    if [ "$matched" -eq 0 ]; then
      while IFS= read -r arg || [ -n "$arg" ]; do
        relative_candidate "$arg" || continue
        [ -L "$entry/cwd" ] || return 1
        cwd=$(readlink "$entry/cwd" 2>/dev/null) || return 1
        safe_chain "$cwd" && [ -d "$cwd" ] && [ ! -L "$cwd" ] || return 1
        normalized=$(normalize_relative "$arg") || return 1
        if mutator "${cwd%/}/$normalized"; then matched=1; break; fi
        # A known script basename under the addon with unexpected spelling
        # must not silently pass (even when its canonical target differs).
        case "$cwd" in "$MERV_BASE"|"$MERV_BASE"/*)
          status REFUSED 'ambiguous addon-relative writer candidate'; return 1 ;;
        esac
      done <<ARGS
$argv
ARGS
    fi
    if [ "$matched" -eq 1 ]; then
      # R1 checks the process generation and liveness for any candidate.
      # Our lean policy is stricter: unreadable/disappeared/reused identities
      # also BLOCK, rather than treating a stale observation as safe.
      start=$(proc_start "$pid" "$MERV_REPAIR_PROC_ROOT" 2>/dev/null) || {
        status REFUSED 'writer process identity unavailable'; return 1;
      }
      kill -0 "$pid" 2>/dev/null || {
        status REFUSED 'writer process liveness uncertain'; return 1;
      }
      [ "$(proc_start "$pid" "$MERV_REPAIR_PROC_ROOT" 2>/dev/null)" = "$start" ] || {
        status REFUSED 'writer process generation changed'; return 1;
      }
      status REFUSED "recognized writer pid=$pid"; return 1
    fi
  done
  safe_chain "$MERV_REPAIR_LEGACY_LOCK_ROOT" &&
    [ -d "$MERV_REPAIR_LEGACY_LOCK_ROOT" ] &&
    [ ! -L "$MERV_REPAIR_LEGACY_LOCK_ROOT" ] || return 1
  for lock in "$MERV_REPAIR_LEGACY_LOCK_ROOT"/*.lock; do
    exists "$lock" || continue
    [ "$lock" = "$MERV_REPAIR_LOCK" ] && continue
    status REFUSED 'legacy owner needs offline resolution'; return 1
  done
  return 0
}
# A proof of cooperating writer exclusion currently exists ONLY in the local
# fixture harness. It is impossible for this standalone tool to certify the
# installed service-event-handler/Heal without their own companion changes.
coordination_preflight() {
  case "$MERV_BASE" in /tmp/mervlan_lean_fixture.*/*) : ;; *) return 1 ;; esac
  [ "${MERV_REPAIR_TEST_ONLY:-0}" = 1 ] || return 1
  case "$MERV_REPAIR_LOCK" in /tmp/mervlan_lean_fixture.*/*) : ;; *) return 1 ;; esac
  [ "${MERV_REPAIR_PROC_ROOT}" != /proc ] || return 1
  [ "${MERV_REPAIR_MEMINFO}" != /proc/meminfo ] || return 1
  # The harness supplies a controlled runtime with no uncoordinated writers.
}
capacity_kib() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}
preflight() {
  available=$(awk '$1=="MemAvailable:" {print $2}' "$MERV_REPAIR_MEMINFO") || return 1
  case "$available" in ''|*[!0-9]*) return 1 ;; esac
  tmpfree=$(capacity_kib "$MERV_REPAIR_TMP_ROOT")
  flashfree=$(capacity_kib "$MERV_BASE")
  case "$tmpfree:$flashfree" in *[!0-9:]*|:*|*:) return 1 ;; esac
  status PREFLIGHT "MemAvailable=${available}KiB tmpFree=${tmpfree}KiB destFree=${flashfree}KiB"
  [ "$available" -ge 98304 ] && [ "$tmpfree" -ge 65536 ] && [ "$flashfree" -ge 8192 ]
}
# Refuse unresolved workspaces from BOTH this engine and the accepted R1.
# A known pre-transaction workspace is harmless but is never deleted here.
prior_workspaces_clear() {
  for prior_root in "$MERV_REPAIR_TMP_ROOT" "${MERV_REPAIR_BOOTSTRAP_DIR:-$MERV_REPAIR_TMP_ROOT}"; do
    safe_chain "$prior_root" && [ -d "$prior_root" ] && [ ! -L "$prior_root" ] || return 1
    for pattern in mervlan_lean mervlan_repair; do
      for prior in "$prior_root"/"$pattern".*; do
        exists "$prior" || continue
        [ -d "$prior" ] && [ ! -L "$prior" ] && regular "$prior/.owner" || return 1
        case "$pattern" in
          mervlan_lean) grep -Fqx 'lean-repair-v1' "$prior/.owner" || return 1 ;;
          mervlan_repair) grep -Fqx 'mervlan-repair-workspace-v2' "$prior/.owner" || return 1 ;;
        esac
        if exists "$prior/ledger"; then
          regular "$prior/ledger" || return 1
          [ ! -s "$prior/ledger" ] || return 1
        fi
      done
    done
  done
}
create_work() {
  safe_chain "$MERV_REPAIR_TMP_ROOT" && [ -d "$MERV_REPAIR_TMP_ROOT" ] || return 1
  prior_workspaces_clear || return 1
  i=0
  while [ "$i" -lt 8 ]; do
    WORK="$MERV_REPAIR_TMP_ROOT/mervlan_lean.$RUN_START.$$.$i"
    if (umask 077; mkdir "$WORK") 2>/dev/null; then break; fi
    i=$((i+1))
  done
  [ -d "$WORK" ] || return 1
  (umask 077; printf 'lean-repair-v1\n' >"$WORK/.owner") || return 1
  ARCHIVE="$WORK/snapshot.tar.gz"; STAGE="$WORK/stage"; BACKUP="$WORK/backup"
  LEDGER="$WORK/ledger"; MANIFEST="$WORK/expected.manifest"; COHORT="$WORK/cohort"
  mkdir "$STAGE" "$BACKUP" "$WORK/extract" "$WORK/protected" || return 1
  write_contract
}
fetch_archive() {
  status DOWNLOAD "HTTPS source=$REF; connect<=5s attempt<=18s total~38s"
  # No retry of the archive after validation: this is the one source snapshot.
  "$MERV_REPAIR_CURL" -fsSL --proto '=https' --proto-redir '=https' \
    --connect-timeout 5 --max-time 18 --retry 1 --retry-delay 1 \
    --retry-max-time 38 --max-filesize 8388608 \
    -o "$ARCHIVE.part" "$MERV_REPAIR_SNAPSHOT_BASE/$REF" || return 1
  regular "$ARCHIVE.part" && [ -s "$ARCHIVE.part" ] || return 1
  bytes=$(wc -c <"$ARCHIVE.part") || return 1
  [ "$bytes" -le 8388608 ] || return 1
  mv "$ARCHIVE.part" "$ARCHIVE" || return 1
  status DOWNLOAD "complete compressedBytes=$bytes"
}
validate_archive() {
  # Stream cap protects /tmp against a gzip bomb; tar still verifies CRC.
  expanded=$(gzip -dc "$ARCHIVE" 2>/dev/null | head -c 16777217 | wc -c) || return 1
  [ "$expanded" -le 16777216 ] || return 1
  tar -tzf "$ARCHIVE" >"$WORK/names" 2>/dev/null || return 1
  tar -tvzf "$ARCHIVE" >"$WORK/details" 2>/dev/null || return 1
  : >"$WORK/seen"; ROOT=; n=0
  while IFS= read -r member || [ -n "$member" ]; do
    case "$member" in */) member=${member%/} ;; esac
    valid_rel "$member" || return 1
    candidate=${member%%/*}
    case "$candidate" in mervlan-*) : ;; *) return 1 ;; esac
    [ -z "$ROOT" ] && ROOT=$candidate
    [ "$candidate" = "$ROOT" ] || return 1
    printf '%s\n' "$member" >>"$WORK/seen" || return 1
    n=$((n+1)); [ "$n" -le 4096 ] || return 1
  done <"$WORK/names"
  [ "$n" -ge 58 ] || return 1
  awk 'seen[$0]++ {exit 1}' "$WORK/seen" || return 1
  while IFS= read -r detail || [ -n "$detail" ]; do
    case "$detail" in -*|d*) : ;; *) return 1 ;; esac
    case "$detail" in *' -> '*|*' link to '*) return 1 ;; esac
  done <"$WORK/details"
  # Extract ONLY the embedded allowlist, never execute downloaded scripts.
  set --
  while IFS=' ' read -r mode relative; do
    case "$mode:$relative" in 0644:*|0755:*) : ;; *) return 1 ;; esac
    valid_rel "$relative" || return 1
    set -- "$@" "$ROOT/$relative"
  done <"$COHORT"
  tar -xzf "$ARCHIVE" -C "$WORK/extract" "$@" 2>/dev/null || return 1
  source_root="$WORK/extract/$ROOT"
  actual_manifest="$source_root/functions/update_mervlan_repair.manifest"
  regular "$actual_manifest" && cmp -s "$MANIFEST" "$actual_manifest" || return 1
  status ARCHIVE "validated members=$n uncompressedBytes=$expanded manifest=exact"
}
stage_files() {
  size=0; count=0
  while IFS=' ' read -r mode relative; do
    from="$source_root/$relative"; to="$STAGE/$relative"
    safe_chain "${from%/*}" && regular "$from" && [ -s "$from" ] || return 1
    ensure_dir "${to%/*}" || return 1
    cp "$from" "$to" && chmod "$mode" "$to" || return 1
    regular "$to" && cmp -s "$from" "$to" || return 1
    case "$relative" in *.sh) sh -n "$to" >/dev/null 2>&1 || return 1 ;; esac
    this=$(wc -c <"$to") || return 1
    size=$((size+this)); [ "$size" -le 8388608 ] || return 1
    count=$((count+1))
  done <"$COHORT"
  [ "$count" -eq 58 ] || return 1
  status STAGING "complete files=$count bytes=$size"
}
mode_ok() {
  listing=$(LC_ALL=C ls -ld "$2" 2>/dev/null) || return 1
  perms=${listing%% *}
  case "$1:$perms" in 0755:-rwxr-xr-x|0644:-rw-r--r--) return 0 ;; esac
  return 1
}
protected_files() {
  for rel in settings/settings.json .ssh/vlan_manager .ssh/vlan_manager.pub \
    tmp/mac_shield.db tmp/mac_shield_override.db tmp/client_name_override.db \
    flags/.install_ok www/settings/hardware_profiles.json; do
    src="$MERV_BASE/$rel"; saved="$WORK/protected/$rel"
    if exists "$src"; then
      regular "$src" || return 1
      ensure_dir "${saved%/*}" || return 1
      cp -p "$src" "$saved" || return 1
      printf 'present %s\n' "$rel" >>"$WORK/protected.index" || return 1
    else
      printf 'absent %s\n' "$rel" >>"$WORK/protected.index" || return 1
    fi
  done
}
protected_unchanged() {
  while IFS=' ' read -r state rel; do
    case "$state" in
      present) regular "$MERV_BASE/$rel" && cmp -s "$WORK/protected/$rel" "$MERV_BASE/$rel" || return 1 ;;
      absent) exists "$MERV_BASE/$rel" && return 1 ;;
      *) return 1 ;;
    esac
  done <"$WORK/protected.index"
  return 0
}
backup_files() {
  size=0
  while IFS=' ' read -r mode relative; do
    target="$MERV_BASE/$relative"; saved="$BACKUP/$relative"
    safe_chain "${target%/*}" || return 1
    if exists "$target"; then
      regular "$target" || return 1
      ensure_dir "${saved%/*}" || return 1
      cp -p "$target" "$saved" && cmp -s "$target" "$saved" || return 1
      this=$(wc -c <"$saved") || return 1
      size=$((size+this)); [ "$size" -le 8388608 ] || return 1
      printf 'old %s\n' "$relative" >>"$WORK/kinds" || return 1
    else
      printf 'new %s\n' "$relative" >>"$WORK/kinds" || return 1
    fi
  done <"$COHORT"
  status BACKUP "complete originalBytes=$size"
}
# The ledger is written before EACH rename. Pending means either unchanged
# original or the exact staged successor; anything else requires human review.
publication() {
  : >"$LEDGER" || return 1
  TX=1
  exec 3<"$WORK/kinds" || return 1
  while IFS=' ' read -r mode relative; do
    IFS=' ' read -r kind saved_relative <&3 || return 1
    [ "$relative" = "$saved_relative" ] || return 1
    target="$MERV_BASE/$relative"; staged="$STAGE/$relative"
    safe_chain "${target%/*}" && ensure_dir "${target%/*}" || return 1
    case "$kind" in old) regular "$target" && cmp -s "$BACKUP/$relative" "$target" || return 1 ;;
      new) exists "$target" && return 1 ;; *) return 1 ;; esac
    printf '%s %s\n' "$kind" "$relative" >>"$LEDGER" || return 1
    tmp="$target.lean.$$"
    exists "$tmp" && return 1
    cp "$staged" "$tmp" && chmod "$mode" "$tmp" || return 1
    regular "$tmp" && cmp -s "$staged" "$tmp" || return 1
    owner_ok || return 1
    if [ "${MERV_REPAIR_TEST_PAUSE_AT:-}" = "$((PUBLISHED+1))" ]; then sleep 3; fi
    owner_ok || return 1
    [ "${MERV_REPAIR_TEST_FAIL_AT:-}" != "$((PUBLISHED+1))" ] || return 1
    mv -f "$tmp" "$target" || return 1
    regular "$target" && cmp -s "$staged" "$target" || return 1
    PUBLISHED=$((PUBLISHED+1))
    if [ $((PUBLISHED%10)) -eq 0 ] || [ "$PUBLISHED" -eq 58 ]; then
      status PUBLISH "verified=$PUBLISHED/58"
    fi
  done <"$COHORT"
  exec 3<&-
}
rollback() {
  owner_ok || { status ROLLBACK 'ownership uncertain, evidence retained'; return 1; }
  status ROLLBACK 'starting'
  # Reverse order from a fixed, bounded, append-only ledger.
  sed '1!G;h;$!d' "$LEDGER" >"$WORK/reverse" || return 1
  failed=0
  while IFS=' ' read -r kind relative; do
    owner_ok || { status ROLLBACK 'owner changed during rollback'; return 1; }
    valid_rel "$relative" || { failed=1; continue; }
    target="$MERV_BASE/$relative"; staged="$STAGE/$relative"
    safe_chain "${target%/*}" || { failed=1; continue; }
    # A failed rename can leave a candidate beside the destination. Remove
    # only the exact bytes that this transaction staged, under our owner.
    pending_tmp="$target.lean.$$"
    if exists "$pending_tmp"; then
      if regular "$pending_tmp" && cmp -s "$pending_tmp" "$staged"; then
        rm "$pending_tmp" || failed=1
      else
        failed=1
      fi
    fi
    if regular "$target" && cmp -s "$staged" "$target"; then
      case "$kind" in
        old)
          saved="$BACKUP/$relative"; regular "$saved" || { failed=1; continue; }
          tmp="$target.undo.$$"; exists "$tmp" && { failed=1; continue; }
          cp -p "$saved" "$tmp" && mv -f "$tmp" "$target" && cmp -s "$saved" "$target" || failed=1 ;;
        new) rm "$target" && ! exists "$target" || failed=1 ;;
        *) failed=1 ;;
      esac
    else
      case "$kind" in
        old) regular "$target" && cmp -s "$BACKUP/$relative" "$target" || failed=1 ;;
        new) ! exists "$target" || failed=1 ;;
        *) failed=1 ;;
      esac
    fi
  done <"$WORK/reverse"
  [ "$failed" -eq 0 ] && owner_ok && protected_unchanged || return 1
  # Do not report rollback success just because a truncated ledger only
  # verified the subset that it happened to contain.
  exec 3<"$WORK/kinds" || return 1
  while IFS=' ' read -r mode relative; do
    IFS=' ' read -r kind saved_relative <&3 || return 1
    [ "$relative" = "$saved_relative" ] || return 1
    target="$MERV_BASE/$relative"
    case "$kind" in
      old) regular "$target" && regular "$BACKUP/$relative" &&
           cmp -s "$target" "$BACKUP/$relative" || return 1 ;;
      new) ! exists "$target" || return 1 ;;
      *) return 1 ;;
    esac
  done <"$COHORT"
  exec 3<&-
  owner_ok || return 1
  ROLLBACK_OK=1; TX=0
  status ROLLBACK 'verified complete'
}
cleanup() {
  rc=$?
  trap - 0 HUP INT TERM
  if [ "$COMMITTED" -ne 1 ] && [ "$TX" -eq 1 ]; then
    if owner_ok; then rollback || { status ROLLBACK 'INCOMPLETE'; rc=1; };
    else status ROLLBACK 'SKIPPED: no verified owner'; rc=1; fi
  fi
  if [ "$LOCKED" -eq 1 ]; then release || { status ERROR 'owner release failed'; rc=1; }; fi
  if [ "$COMMITTED" -eq 1 ] && [ "$rc" -eq 0 ]; then
    rm -rf "$WORK" || { rc=1; status EVIDENCE "cleanup incomplete=$WORK"; }
  elif [ "$TX" -eq 0 ] && [ "$ROLLBACK_OK" -eq 0 ] &&
       [ "$LOCKED" -eq 0 ] && [ -n "$WORK" ] &&
       [ ! -s "${LEDGER:-/dev/null}" ] &&
       regular "$WORK/.owner" &&
       [ "$(cat "$WORK/.owner" 2>/dev/null)" = lean-repair-v1 ]; then
    # No publication was attempted: this is our private scratch data, not
    # rollback evidence. Never remove a workspace with a transaction ledger.
    case "$WORK" in
      "$MERV_REPAIR_TMP_ROOT"/mervlan_lean.*)
        if rm -rf "$WORK"; then
          status CLEANUP 'unpublished private workspace removed'
        else
          rc=1; status EVIDENCE "cleanup incomplete=$WORK"
        fi
        ;;
      *) rc=1; status EVIDENCE "unsafe workspace path=$WORK" ;;
    esac
  elif [ -n "$WORK" ]; then
    status EVIDENCE "retained=$WORK"
  fi
  if [ "$rc" -eq 0 ]; then status SUCCESS "files=$PUBLISHED no Update/Apply invoked";
  else status FAILED "published=$PUBLISHED rollback_verified=$ROLLBACK_OK"; fi
  exit "$rc"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
main() {
  REF=${1:-main}
  valid_ref "$REF" || stop 'invalid source ref'
  status START "source=$REF date=$(date '+%Y-%m-%dT%H:%M:%S%z')"
  case "$MERV_REPAIR_SNAPSHOT_BASE" in
    https://codeload.github.com/r80xcore/mervlan/tar.gz) : ;;
    https://*) [ "${MERV_REPAIR_TEST_ONLY:-0}" = 1 ] || stop 'unapproved source host' ;;
    *) stop 'HTTPS required' ;;
  esac
  safe_chain "$MERV_BASE" && [ -d "$MERV_BASE" ] || stop 'unsafe destination'
  # This release gate is intentional and is NEVER satisfied on a router.
  coordination_preflight || stop 'installed writer-coordination not qualified; hardware publication disabled'
  status BOOTSTRAP 'standalone engine running; external HELP bootstrap is a separate unqualified transfer'
  preflight || stop 'insufficient RAM or storage'
  create_work || stop 'workspace unavailable or earlier transaction unresolved'
  fetch_archive || stop 'bounded snapshot download failed'
  validate_archive || stop 'snapshot/manifest validation failed'
  stage_files || stop 'stage validation failed'
  # Gate acquisition precedes all protected-state and destination observations.
  scan_processes || stop 'initial legacy mutator exclusion failed'
  acquire || stop 'maintenance admission refused'
  scan_processes || stop 'post-acquisition legacy mutator exclusion failed'
  protected_files && backup_files || stop 'backup/protected-state capture failed'
  preflight || stop 'resource preflight before publication failed'
  status QUIESCED 'fixture writers obey one maintenance gate'
  publication || stop 'publication failed'
  owner_ok && protected_unchanged || stop 'final owner/protected verification failed'
  while IFS=' ' read -r mode relative; do
    target="$MERV_BASE/$relative"; staged="$STAGE/$relative"
    regular "$target" && cmp -s "$target" "$staged" && mode_ok "$mode" "$target" || stop 'final cohort content/mode mismatch'
  done <"$COHORT"
  status VERIFY '58/58 content and protected state verified'
  COMMITTED=1; TX=0
  release || stop 'maintenance release failed'
}
main "$@"
