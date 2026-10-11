#!/bin/sh
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
# Read-only validation of the three MerVLAN startup hooks and configured boot
# preference. This library never sources hook content or changes external state.

if [ -n "${LIB_BOOT_INTEGRITY_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
LIB_BOOT_INTEGRITY_LOADED=1

: "${MERV_BASE:=/jffs/addons/mervlan}"
: "${MERV_BOOT_SCRIPTS_ROOT:=/jffs/scripts}"

# Validate an absolute data path without following symlink components. Missing
# components are permitted for a hook that has not been installed yet.
merv_boot_path_check() {
  MERV_BOOT_PATH_STATUS=invalid
  _mbpc_path="${1:-}"
  case "$_mbpc_path" in
    ''|*..*|*//*|*[!A-Za-z0-9_./-]*) return 1 ;;
    /*) ;;
    *) return 1 ;;
  esac
  _mbpc_rest=${_mbpc_path#/}
  _mbpc_current=/
  while [ -n "$_mbpc_rest" ]; do
    case "$_mbpc_rest" in
      */*) _mbpc_component=${_mbpc_rest%%/*}; _mbpc_rest=${_mbpc_rest#*/} ;;
      *) _mbpc_component=$_mbpc_rest; _mbpc_rest='' ;;
    esac
    case "$_mbpc_component" in ''|.|..) return 1 ;; esac
    _mbpc_current="${_mbpc_current%/}/$_mbpc_component"
    if [ -L "$_mbpc_current" ]; then return 1; fi
    if [ -e "$_mbpc_current" ] || [ -d "$_mbpc_current" ]; then
      [ -d "$_mbpc_current" ] || [ "$_mbpc_current" = "$_mbpc_path" ] || return 1
    else
      _mbpc_parent=${_mbpc_current%/*}
      [ -n "$_mbpc_parent" ] || _mbpc_parent=/
      [ -d "$_mbpc_parent" ] && [ -r "$_mbpc_parent" ] && [ -x "$_mbpc_parent" ] || {
        MERV_BOOT_PATH_STATUS=unknown
        return 1
      }
      MERV_BOOT_PATH_STATUS=missing
      return 0
    fi
  done
  MERV_BOOT_PATH_STATUS=present
  return 0
}

merv_boot_read_preference() {
  MERV_BOOT_PREFERENCE_REASON=''
  _mbrp_file="${1:-}"
  merv_boot_path_check "$_mbrp_file" || { MERV_BOOT_PREFERENCE_REASON=unsafe_settings_path; return 1; }
  [ ! -L "$_mbrp_file" ] && [ -f "$_mbrp_file" ] && [ -r "$_mbrp_file" ] || {
    MERV_BOOT_PREFERENCE_REASON=settings_unavailable
    return 1
  }
  type json_validate_file >/dev/null 2>&1 || {
    MERV_BOOT_PREFERENCE_REASON=json_validator_unavailable
    return 1
  }
  json_validate_file "$_mbrp_file" >/dev/null 2>&1 || {
    MERV_BOOT_PREFERENCE_REASON=settings_malformed
    return 1
  }
  _mbrp_counts=$(LC_ALL=C awk '
    {
      line=$0
      while (match(line, /"General"[[:space:]]*:/)) { general++; line=substr(line, RSTART+RLENGTH) }
      line=$0
      while (match(line, /"BOOT_ENABLED"[[:space:]]*:/)) { boot++; line=substr(line, RSTART+RLENGTH) }
    }
    END { printf "%d|%d\n", general+0, boot+0 }
  ' "$_mbrp_file" 2>/dev/null)
  _mbrp_rc=$?
  [ "$_mbrp_rc" -eq 0 ] || { MERV_BOOT_PREFERENCE_REASON=settings_inspection_failed; return 1; }
  _mbrp_general=${_mbrp_counts%%|*}
  _mbrp_boot=${_mbrp_counts#*|}
  [ "$_mbrp_general" = 1 ] && [ "$_mbrp_boot" = 1 ] || {
    MERV_BOOT_PREFERENCE_REASON=settings_missing_or_duplicate
    return 1
  }
  if type json_get_section_value_strict >/dev/null 2>&1; then
    _mbrp_value=$(json_get_section_value_strict General BOOT_ENABLED "$_mbrp_file" 2>/dev/null)
    _mbrp_rc=$?
  elif type json_get_section_value >/dev/null 2>&1; then
    _mbrp_value=$(json_get_section_value General BOOT_ENABLED "$_mbrp_file" 2>/dev/null)
    _mbrp_rc=$?
  else
    _mbrp_value=''
    _mbrp_rc=1
  fi
  [ "${_mbrp_rc:-1}" -eq 0 ] || { MERV_BOOT_PREFERENCE_REASON=settings_value_unreadable; return 1; }
  case "$_mbrp_value" in
    0|1) MERV_BOOT_PREFERENCE="$_mbrp_value"; printf '%s\n' "$_mbrp_value"; return 0 ;;
    *) MERV_BOOT_PREFERENCE_REASON=settings_value_unsupported; return 1 ;;
  esac
}

# Read General.IS_NODE when it exists; honor the established .is_node sentinel
# for legacy trees. A malformed or contradictory explicit value is unknown.
merv_boot_read_role() {
  MERV_BOOT_ROLE_REASON=''
  _mbrr_file="${1:-}"
  _mbrr_base="${2:-$MERV_BASE}"
  merv_boot_path_check "$_mbrr_file" || { MERV_BOOT_ROLE_REASON=unsafe_settings_path; return 1; }
  merv_boot_path_check "$_mbrr_base" || { MERV_BOOT_ROLE_REASON=unsafe_base_path; return 1; }
  [ ! -L "$_mbrr_file" ] && [ -f "$_mbrr_file" ] && [ -r "$_mbrr_file" ] || {
    MERV_BOOT_ROLE_REASON=settings_unavailable
    return 1
  }
  type json_validate_file >/dev/null 2>&1 && json_validate_file "$_mbrr_file" >/dev/null 2>&1 || {
    MERV_BOOT_ROLE_REASON=settings_malformed
    return 1
  }
  _mbrr_count=$(LC_ALL=C awk '
    { line=$0; while (match(line, /"IS_NODE"[[:space:]]*:/)) { count++; line=substr(line, RSTART+RLENGTH) } }
    END { print count+0 }
  ' "$_mbrr_file" 2>/dev/null)
  _mbrr_rc=$?
  [ "$_mbrr_rc" -eq 0 ] || { MERV_BOOT_ROLE_REASON=settings_inspection_failed; return 1; }
  case "$_mbrr_count" in
    0) _mbrr_value='' ;;
    1)
      if type json_get_section_value_strict >/dev/null 2>&1; then
        _mbrr_value=$(json_get_section_value_strict General IS_NODE "$_mbrr_file" 2>/dev/null) || _mbrr_value=''
      else
        _mbrr_value=''
      fi
      [ -n "$_mbrr_value" ] || {
        MERV_BOOT_ROLE_REASON=settings_role_unreadable
        return 1
      }
      case "$_mbrr_value" in 0|1) ;; *) MERV_BOOT_ROLE_REASON=settings_role_unsupported; return 1 ;; esac
      ;;
    *) MERV_BOOT_ROLE_REASON=settings_role_duplicate; return 1 ;;
  esac
  if [ -L "$_mbrr_base/.is_node" ]; then
    MERV_BOOT_ROLE_REASON=role_sentinel_symlink
    return 1
  fi
  if [ "$_mbrr_count" = 1 ]; then
    if [ "$_mbrr_value" = 1 ]; then
      MERV_BOOT_ROLE=node
    elif [ -e "$_mbrr_base/.is_node" ]; then
      MERV_BOOT_ROLE_REASON=role_preference_contradictory
      return 1
    else
      MERV_BOOT_ROLE=main
    fi
  elif [ -f "$_mbrr_base/.is_node" ]; then
    MERV_BOOT_ROLE=node
  else
    MERV_BOOT_ROLE=main
  fi
  printf '%s\n' "$MERV_BOOT_ROLE"
}

# Scan data between known MerVLAN markers. Current services-start,
# services-start-addon, and service-event template IDs support v1/v2. The
# The v0.53.15 manager payload is recognized only in its exact historical
# form, even though that release used the current services-start v1/v2 IDs.
# It is reported invalid with reason legacy_replaceable so the lifecycle
# writer can safely replace/remove the exact block; ordinary verification
# never counts it as a healthy effective manager hook.
merv_boot_hook_state() {
  MERV_BOOT_HOOK_REASON=''
  MERV_BOOT_HOOK_START_LINE=''
  MERV_BOOT_HOOK_END_LINE=''
  _mbhs_path="${1:-}"
  _mbhs_name="${2:-}"
  _mbhs_base="${3:-$MERV_BASE}"
  case "$_mbhs_name" in
    services-start|services-start-addon) _mbhs_expected_dest=services-start ;;
    service-event) _mbhs_expected_dest=service-event ;;
    *) MERV_BOOT_HOOK_REASON=unsupported_template; MERV_BOOT_HOOK_STATE=invalid; printf 'invalid\n'; return 0 ;;
  esac
  [ "${_mbhs_path##*/}" = "$_mbhs_expected_dest" ] || {
    MERV_BOOT_HOOK_REASON=wrong_destination_path
    MERV_BOOT_HOOK_STATE=invalid
    printf 'invalid\n'
    return 0
  }
  merv_boot_path_check "$_mbhs_path" || {
    if [ "${MERV_BOOT_PATH_STATUS:-}" = unknown ]; then
      MERV_BOOT_HOOK_REASON=hook_uninspectable
      MERV_BOOT_HOOK_STATE=unknown
      printf 'unknown\n'
    else
      MERV_BOOT_HOOK_REASON=unsafe_hook_path
      MERV_BOOT_HOOK_STATE=invalid
      printf 'invalid\n'
    fi
    return 0
  }
  if [ "${MERV_BOOT_PATH_STATUS:-}" = missing ]; then
    MERV_BOOT_HOOK_REASON=hook_file_missing
    MERV_BOOT_HOOK_STATE=absent
    printf 'absent\n'
    return 0
  fi
  if [ -L "$_mbhs_path" ]; then
    MERV_BOOT_HOOK_REASON=hook_symlink
    MERV_BOOT_HOOK_STATE=invalid
    printf 'invalid\n'
    return 0
  fi
  if ! ls -ld "$_mbhs_path" >/dev/null 2>&1; then
    _mbhs_parent=${_mbhs_path%/*}
    if [ -d "$_mbhs_parent" ] && [ -r "$_mbhs_parent" ] && [ -x "$_mbhs_parent" ]; then
      MERV_BOOT_HOOK_REASON=hook_file_missing
      MERV_BOOT_HOOK_STATE=absent
      printf 'absent\n'
    else
      MERV_BOOT_HOOK_REASON=hook_uninspectable
      MERV_BOOT_HOOK_STATE=unknown
      printf 'unknown\n'
    fi
    return 0
  fi
  [ -f "$_mbhs_path" ] || {
    MERV_BOOT_HOOK_REASON=hook_not_regular
    MERV_BOOT_HOOK_STATE=invalid
    printf 'invalid\n'
    return 0
  }
  [ -r "$_mbhs_path" ] || {
    MERV_BOOT_HOOK_REASON=hook_unreadable
    MERV_BOOT_HOOK_STATE=unknown
    printf 'unknown\n'
    return 0
  }
  _mbhs_shell="${MERV_BOOT_SH_BIN:-/bin/sh}"
  [ -x "$_mbhs_shell" ] || {
    MERV_BOOT_HOOK_REASON=hook_syntax_checker_unavailable
    MERV_BOOT_HOOK_STATE=unknown
    printf 'unknown\n'
    return 0
  }
  "$_mbhs_shell" -n "$_mbhs_path" >/dev/null 2>&1 || {
    MERV_BOOT_HOOK_REASON=hook_script_syntax_invalid
    MERV_BOOT_HOOK_STATE=invalid
    printf 'invalid\n'
    return 0
  }

  [ -n "$_mbhs_base" ] || {
    MERV_BOOT_HOOK_REASON=base_unknown
    MERV_BOOT_HOOK_STATE=unknown
    printf 'unknown\n'
    return 0
  }
  _mbhs_base=${_mbhs_base%/}
  _mbhs_scan=$(LC_ALL=C awk -v filedest="${_mbhs_path##*/}" -v request="$_mbhs_name" -v expected_base="$_mbhs_base" '
    function fail(why) { if (problem == "") problem=why }
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function template_kind(dest, tpl) {
      if (dest == "services-start") {
        if (tpl == "services-start.v1.tpl" || tpl == "services-start.v2.tpl") return "manager"
        if (tpl == "services-start-addon.v1.tpl" || tpl == "services-start-addon.v2.tpl") return "addon"
      }
      if (dest == "service-event") {
        if (tpl == "service-event.v1.tpl" || tpl == "service-event.v2.tpl") return "event"
      }
      return ""
    }
    function validate_payload(kind, tpl, body,   n, a, i, line, count, p, wrap, manager, cron, install, event) {
      n=split(body, a, "\n")
      count=0
      for (i=1; i<=n; i++) {
        line=a[i]
        sub(/\r$/, "", line)
        line=trim(line)
        if (line == "" || line ~ /^#/) continue
        p[++count]=line
      }
      wrap=expected_base "/functions/mervlan_boot_wrap.sh"
      install=expected_base "/install.sh"
      event=expected_base "/functions/service-event-handler.sh \"$@\""
      if (kind == "manager") {
        if (count == 5 &&
            p[1] == "if " wrap " shield </dev/null >/dev/null 2>&1; then" &&
            p[2] == wrap " manager </dev/null >/dev/null 2>&1 &" &&
            p[3] == "fi" && p[4] == "sleep 10" &&
            p[5] == wrap " cron </dev/null >/dev/null 2>&1 &") return 1
        # The v0.53.15 release used these same v1/v2 IDs with an unguarded
        # shield call and two delays. Keep that exact shipped payload only as
        # a rollback-replaceable manager, never as current healthy state.
        if (count == 5 &&
            p[1] == wrap " shield </dev/null >/dev/null 2>&1" &&
            p[2] == "sleep 10" &&
            p[3] == wrap " manager </dev/null >/dev/null 2>&1 &" &&
            p[4] == "sleep 10" &&
            p[5] == wrap " cron </dev/null >/dev/null 2>&1 &") return 2
        return 0
      }
      if (kind == "addon") {
        if (count == 1 && p[1] == wrap " install </dev/null >/dev/null 2>&1 &") return 1
        # v0.53.15 had a five-second install delay before the same wrapper.
        if (count == 2 && p[1] == "sleep 5" &&
            p[2] == wrap " install </dev/null >/dev/null 2>&1 &") return 1
        return 0
      }
      if (kind == "event") return count == 1 && p[1] == event
      return 0
    }
    function parse_marker(line,   f, n, t, h, kind, tpl, ver, md5, tail) {
      n=split(line, f, " ")
      if (n != 7 || f[1] != "###" || f[3] != "MERVLAN" || f[5] !~ /^[A-Za-z0-9_-]+$/ || f[6] !~ /^\[tpl=[A-Za-z0-9_-]+[.]v[12][.]tpl$/ || f[7] !~ /^md5=[0-9A-Fa-f]+\]$/) { fail("marker_format"); return 0 }
      if ((f[2] == ">>>" && f[4] != "START:") || (f[2] == "<<<" && f[4] != "END:") || (f[2] != ">>>" && f[2] != "<<<")) { fail("marker_tag_invalid"); return 0 }
      if (length(f[7]) != 37) { fail("marker_md5_invalid"); return 0 }
      md5=substr(f[7], 5, 32)
      tpl=substr(f[6], 6)
      kind=template_kind(f[5], tpl)
      if (kind == "") { fail("marker_template_unknown"); return 0 }
      if (f[5] != filedest) { fail("marker_destination_mismatch"); return 0 }
      marker_dest=f[5]; marker_tpl=tpl; marker_md5=md5; marker_kind=kind
      return 1
    }
    BEGIN { opened=0; requested_count=0; requested_legacy=0; any=0; target_start=0; target_end=0; manager_count=0; addon_count=0; event_count=0; problem="" }
    {
      line=$0
      sub(/\r$/, "", line)
      marker_line=line
      sub(/^[[:space:]]*/, "", marker_line)
      marker_indented=(marker_line != line)
      is_start=(index(marker_line, "### >>> MERVLAN START:") == 1)
      is_end=(index(marker_line, "### <<< MERVLAN END:") == 1)
      if (is_start || is_end) {
        any++
        if (marker_indented) { fail("marker_shape_unknown"); next }
        if (!parse_marker(line)) next
        if (is_start) {
          if (opened) { fail("marker_nested_or_crossed"); next }
          opened=1; open_dest=marker_dest; open_tpl=marker_tpl; open_md5=marker_md5; open_kind=marker_kind
          open_line=NR; body=""
        } else {
          if (!opened) { fail("marker_end_without_start"); next }
          if (marker_dest != open_dest || marker_tpl != open_tpl || marker_md5 != open_md5 || marker_kind != open_kind) { fail("marker_pair_mismatch"); opened=0; next }
          payload_state=validate_payload(open_kind, open_tpl, body)
          if (!payload_state) fail("marker_payload_invalid")
          if (open_kind == "manager") manager_count++
          if (open_kind == "addon") addon_count++
          if (open_kind == "event") event_count++
          if ((request == "services-start" && open_kind == "manager") || (request == "services-start-addon" && open_kind == "addon") || (request == "service-event" && open_kind == "event")) {
            requested_count++
            if (payload_state == 2) requested_legacy++
            if (requested_count == 1) { target_start=open_line; target_end=NR }
          }
          opened=0; body=""
        }
        next
      }
      if (index(marker_line, "###") == 1 && index(marker_line, "MERVLAN") > 0) { any++; fail("marker_shape_unknown"); next }
      if (marker_line ~ /^##[[:space:]]*[^#].*MERVLAN/ || marker_line ~ /^#[[:space:]]*[^#].*MERVLAN.*(START|END)/) { any++; fail("marker_shape_unknown"); next }
      if (opened) body=body line "\n"
    }
    END {
      if (opened) fail("marker_start_without_end")
      if (requested_count > 1 || manager_count > 1 || addon_count > 1 || event_count > 1) fail("marker_duplicate")
      if (problem != "") printf "invalid|%s|%d|%d|%d\n", problem, target_start, target_end, any
      else if (requested_count == 1 && requested_legacy == 1) printf "legacy|legacy_replaceable|%d|%d|%d\n", target_start, target_end, any
      else if (requested_count == 1) printf "present||%d|%d|%d\n", target_start, target_end, any
      else printf "absent||0|0|%d\n", any
    }
  ' "$_mbhs_path" 2>/dev/null)
  _mbhs_rc=$?
  [ "$_mbhs_rc" -eq 0 ] || {
    MERV_BOOT_HOOK_REASON=hook_inspection_failed
    MERV_BOOT_HOOK_STATE=unknown
    printf 'unknown\n'
    return 0
  }
  _mbhs_state=${_mbhs_scan%%|*}
  _mbhs_tail=${_mbhs_scan#*|}
  MERV_BOOT_HOOK_REASON=${_mbhs_tail%%|*}
  _mbhs_tail=${_mbhs_tail#*|}
  MERV_BOOT_HOOK_START_LINE=${_mbhs_tail%%|*}
  _mbhs_tail=${_mbhs_tail#*|}
  MERV_BOOT_HOOK_END_LINE=${_mbhs_tail%%|*}
  _mbhs_tail=${_mbhs_tail#*|}
  _mbhs_any=${_mbhs_tail%%|*}
  IFS= read -r _mbhs_first < "$_mbhs_path"
  _mbhs_cr=$(printf '\r')
  case "$_mbhs_first" in *"$_mbhs_cr") _mbhs_first=${_mbhs_first%"$_mbhs_cr"} ;; esac
  case "$_mbhs_first" in '#!/bin/sh'|'#!/bin/ash') : ;;
    *) MERV_BOOT_HOOK_REASON=hook_shebang_invalid; MERV_BOOT_HOOK_STATE=invalid; printf 'invalid\n'; return 0 ;;
  esac
  [ -x "$_mbhs_path" ] || { MERV_BOOT_HOOK_REASON=hook_not_executable; MERV_BOOT_HOOK_STATE=invalid; printf 'invalid\n'; return 0; }
  case "$_mbhs_state" in
    present) MERV_BOOT_HOOK_REASON=present ;;
    absent) MERV_BOOT_HOOK_REASON=absent ;;
    legacy) MERV_BOOT_HOOK_REASON=legacy_replaceable; _mbhs_state=invalid ;;
    invalid) : ;;
    *) MERV_BOOT_HOOK_REASON=hook_state_invalid; _mbhs_state=unknown ;;
  esac
  MERV_BOOT_HOOK_STATE="$_mbhs_state"
  printf '%s\n' "$_mbhs_state"
}

merv_boot_verify_baseline() {
  MERV_BOOT_VERIFY_REASON=''
  _mbvb_role="${1:-}"
  _mbvb_services="${2:-${SERVICES_START:-$MERV_BOOT_SCRIPTS_ROOT/services-start}}"
  _mbvb_event="${3:-${SERVICE_EVENT_WRAPPER:-$MERV_BOOT_SCRIPTS_ROOT/service-event}}"
  _mbvb_settings="${4:-${SETTINGS_FILE:-$MERV_BASE/settings/settings.json}}"
  _mbvb_base="${5:-$MERV_BASE}"
  case "$_mbvb_role" in main|node) ;; *) MERV_BOOT_VERIFY_REASON=role_invalid; return 1 ;; esac
  merv_boot_read_role "$_mbvb_settings" "$_mbvb_base" >/dev/null || {
    MERV_BOOT_VERIFY_REASON="role_unknown:${MERV_BOOT_ROLE_REASON:-unknown}"
    return 1
  }
  _mbvb_observed="$MERV_BOOT_ROLE"
  [ "$_mbvb_observed" = "$_mbvb_role" ] || { MERV_BOOT_VERIFY_REASON=role_mismatch; return 1; }
  merv_boot_hook_state "$_mbvb_services" services-start-addon "$_mbvb_base" >/dev/null
  _mbvb_addon="$MERV_BOOT_HOOK_STATE"
  [ "$_mbvb_addon" = present ] || {
    MERV_BOOT_VERIFY_REASON="addon_${_mbvb_addon}"
    return 1
  }
  merv_boot_hook_state "$_mbvb_event" service-event "$_mbvb_base" >/dev/null
  _mbvb_event_state="$MERV_BOOT_HOOK_STATE"
  [ "$_mbvb_event_state" = present ] || {
    MERV_BOOT_VERIFY_REASON="event_${_mbvb_event_state}"
    return 1
  }
  return 0
}

# Select rollback compatibility from the restored tree itself. A missing
# library identifies a pre-integrity tree; a real readable library requires
# current verification. Symlinks and unexpected objects fail closed.
merv_boot_rollback_legacy_mode() {
  MERV_BOOT_ROLLBACK_ALLOW_LEGACY=''
  MERV_BOOT_ROLLBACK_REASON=''
  _mbrlm_root="${1:-}"
  _mbrlm_settings="$_mbrlm_root/settings"
  _mbrlm_library="$_mbrlm_settings/lib_boot_integrity.sh"
  [ -n "$_mbrlm_root" ] && [ ! -L "$_mbrlm_root" ] && [ -d "$_mbrlm_root" ] || {
    MERV_BOOT_ROLLBACK_REASON=restored_tree_unavailable
    return 1
  }
  [ ! -L "$_mbrlm_settings" ] && [ -d "$_mbrlm_settings" ] || {
    MERV_BOOT_ROLLBACK_REASON=settings_directory_unsafe
    return 1
  }
  [ -r "$_mbrlm_settings" ] && [ -x "$_mbrlm_settings" ] || {
    MERV_BOOT_ROLLBACK_REASON=settings_directory_uninspectable
    return 1
  }
  if [ -L "$_mbrlm_library" ]; then
    MERV_BOOT_ROLLBACK_REASON=integrity_library_symlink
    return 1
  elif [ -f "$_mbrlm_library" ]; then
    _mbrlm_mode_readable=$(ls -ld "$_mbrlm_library" 2>/dev/null | awk '
      NR == 1 {
        p = substr($1, 1, 10)
        if (substr(p, 1, 1) == "-" &&
            (substr(p, 2, 1) == "r" || substr(p, 5, 1) == "r" || substr(p, 8, 1) == "r")) print "yes"
      }
    ')
    [ -r "$_mbrlm_library" ] && [ "$_mbrlm_mode_readable" = yes ] || {
      MERV_BOOT_ROLLBACK_REASON=integrity_library_unreadable
      return 1
    }
    MERV_BOOT_ROLLBACK_ALLOW_LEGACY=0
  elif [ -e "$_mbrlm_library" ]; then
    MERV_BOOT_ROLLBACK_REASON=integrity_library_unsafe
    return 1
  else
    MERV_BOOT_ROLLBACK_ALLOW_LEGACY=1
  fi
  return 0
}

# Classify the complete command portion from cru's listing. Merlin's cru stores
# the job ID as a trailing #id# token. Keep the direct and schedule-only forms
# used by isolated fixtures, plus the historical name-prefixed fixture form;
# production output must use the exact MerVLAN job marker. Any use of the
# current-base executable with a malformed argument list is invalid residue.
merv_boot_cron_listing_state() {
  MERV_BOOT_CRON_LISTING_STATE=unknown
  _mbcle_listing="${1:-}"
  _mbcle_command="${2:-}"
  [ -n "$_mbcle_command" ] || return 1
  _mbcle_state=$(printf '%s\n' "$_mbcle_listing" | LC_ALL=C awk -v command="$_mbcle_command" '
    {
      line=$0
      sub(/\r$/, "", line)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "" || line ~ /^#/) next
      n=split(line, field, /[[:space:]]+/)
      command_at=0
      command_count=0
      for (i=1; i<=n; i++) if (field[i] == command) { command_at=i; command_count++ }
      if (command_at == 0) next
      if (command_count == 1 &&
          ((n == 2 && command_at == 1 && field[2] == "cron") ||
           (n == 7 && command_at == 6 && field[7] == "cron") ||
           (n == 8 && command_at == 7 && field[1] == "mervlan_health" && field[8] == "cron") ||
           (n == 8 && command_at == 6 && field[7] == "cron" && field[8] == "#mervlan_health#"))) found=1
      else malformed=1
    }
    END { if (malformed) print "invalid"; else if (found) print "present"; else print "absent" }
  ' 2>/dev/null) || return 1
  case "$_mbcle_state" in present|invalid|absent) ;; *) return 1 ;; esac
  MERV_BOOT_CRON_LISTING_STATE="$_mbcle_state"
  return 0
}

# Read the manager-owned cron entry without guessing when the scheduler cannot
# be queried. Callers may display unknown as a status or require a proven state.
merv_boot_cron_state() {
  MERV_BOOT_CRON_STATE=unknown
  MERV_BOOT_CRON_REASON=''
  _mbcs_cru="${1:-${MERV_BOOT_CRU_BIN:-${CRU_BIN:-}}}"
  _mbcs_base="${2:-$MERV_BASE}"
  [ -n "$_mbcs_base" ] || { MERV_BOOT_CRON_REASON=base_unknown; return 1; }
  [ -n "$_mbcs_cru" ] || {
    _mbcs_cru=$(merv_cmd cru 2>/dev/null || printf '')
    [ -n "$_mbcs_cru" ] || [ ! -x /usr/sbin/cru ] || _mbcs_cru=/usr/sbin/cru
  }
  [ -n "$_mbcs_cru" ] && [ -x "$_mbcs_cru" ] || {
    MERV_BOOT_CRON_REASON=cru_unavailable
    return 1
  }
  _mbcs_list=$("$_mbcs_cru" l 2>/dev/null)
  _mbcs_rc=$?
  [ "$_mbcs_rc" -eq 0 ] || { MERV_BOOT_CRON_REASON=listing_failed; return 1; }
  _mbcs_entry="${_mbcs_base%/}/functions/heal_event.sh"
  merv_boot_cron_listing_state "$_mbcs_list" "$_mbcs_entry" || {
    MERV_BOOT_CRON_REASON=listing_inspection_failed
    return 1
  }
  MERV_BOOT_CRON_STATE="$MERV_BOOT_CRON_LISTING_STATE"
  MERV_BOOT_CRON_REASON="$MERV_BOOT_CRON_LISTING_STATE"
  printf '%s\n' "$MERV_BOOT_CRON_STATE"
  return 0
}

merv_boot_verify_local() {
  MERV_BOOT_VERIFY_REASON=''
  _mbvl_expected="${1:-}"
  _mbvl_role="${2:-}"
  _mbvl_scripts="${8:-$MERV_BOOT_SCRIPTS_ROOT}"
  _mbvl_services="${3:-${SERVICES_START:-$_mbvl_scripts/services-start}}"
  _mbvl_event="${4:-${SERVICE_EVENT_WRAPPER:-$_mbvl_scripts/service-event}}"
  _mbvl_settings="${5:-${SETTINGS_FILE:-$MERV_BASE/settings/settings.json}}"
  _mbvl_cru="${6:-${MERV_BOOT_CRU_BIN:-${CRU_BIN:-}}}"
  _mbvl_base="${7:-$MERV_BASE}"
  # Only rollback/legacy-restore callers may opt in. The scanner still reports
  # these historical blocks as invalid; this predicate accepts only the exact
  # shipped legacy payload shapes, and only when an enabled manager is expected.
  _mbvl_allow_legacy="${9:-0}"
  case "$_mbvl_expected" in 0|1) ;; *) MERV_BOOT_VERIFY_REASON=expectation_invalid; return 1 ;; esac
  case "$_mbvl_role" in main|node) ;; *) MERV_BOOT_VERIFY_REASON=role_invalid; return 1 ;; esac
  case "$_mbvl_allow_legacy" in 0|1) ;; *) MERV_BOOT_VERIFY_REASON=legacy_mode_invalid; return 1 ;; esac
  [ "$_mbvl_allow_legacy" = 0 ] || [ "$_mbvl_role" = main ] || {
    MERV_BOOT_VERIFY_REASON=legacy_mode_role_invalid
    return 1
  }
  merv_boot_read_preference "$_mbvl_settings" >/dev/null || {
    MERV_BOOT_VERIFY_REASON="preference_unknown:${MERV_BOOT_PREFERENCE_REASON:-unknown}"
    return 1
  }
  _mbvl_saved="$MERV_BOOT_PREFERENCE"
  [ "$_mbvl_saved" = "$_mbvl_expected" ] || { MERV_BOOT_VERIFY_REASON=preference_mismatch; return 1; }
  merv_boot_verify_baseline "$_mbvl_role" "$_mbvl_services" "$_mbvl_event" "$_mbvl_settings" "$_mbvl_base" || {
    MERV_BOOT_VERIFY_REASON="${MERV_BOOT_VERIFY_REASON:-baseline_mismatch}"
    return 1
  }
  merv_boot_hook_state "$_mbvl_services" services-start "$_mbvl_base" >/dev/null
  _mbvl_manager="$MERV_BOOT_HOOK_STATE"
  if [ "$_mbvl_manager" = invalid ] && \
     [ "${MERV_BOOT_HOOK_REASON:-}" = legacy_replaceable ] && \
     [ "$_mbvl_allow_legacy" = 1 ] && [ "$_mbvl_expected" = 1 ]; then
    # A known pre-current manager is usable while the old tree is being
    # restored. It remains invalid in ordinary status and target verification.
    _mbvl_manager=present
  fi
  if [ "$_mbvl_manager" = invalid ] || [ "$_mbvl_manager" = unknown ]; then
    MERV_BOOT_VERIFY_REASON="manager_$_mbvl_manager"
    return 1
  fi
  if [ "$_mbvl_expected" = 1 ] && [ "$_mbvl_manager" != present ]; then
    MERV_BOOT_VERIFY_REASON=manager_mismatch
    return 1
  fi
  if [ "$_mbvl_expected" = 0 ] && [ "$_mbvl_manager" != absent ]; then
    MERV_BOOT_VERIFY_REASON=manager_mismatch
    return 1
  fi
  merv_boot_cron_state "$_mbvl_cru" "$_mbvl_base" >/dev/null || {
    MERV_BOOT_VERIFY_REASON=cron_unknown
    return 1
  }
  _mbvl_cron="$MERV_BOOT_CRON_STATE"
  [ "$_mbvl_cron" != invalid ] || {
    MERV_BOOT_VERIFY_REASON=cron_invalid
    return 1
  }
  if [ "$_mbvl_expected" = 1 ] && [ "$_mbvl_cron" != present ]; then
    MERV_BOOT_VERIFY_REASON=cron_mismatch
    return 1
  fi
  if [ "$_mbvl_expected" = 0 ] && [ "$_mbvl_cron" != absent ]; then
    MERV_BOOT_VERIFY_REASON=cron_mismatch
    return 1
  fi
  MERV_BOOT_VERIFY_REASON=verified
  return 0
}
