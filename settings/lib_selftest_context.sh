#!/bin/sh
# Explicit private fixture context for lock/ownership self-tests.
#
# Production behavior never follows TEST_RUN or a supplied fake path. A test
# harness must create a mode-0700 fixture root and this mode-0600 context file,
# then export its exact path before loading ownership libraries.

[ -n "${LIB_SELFTEST_CONTEXT_LOADED:-}" ] && return 0 2>/dev/null || :
LIB_SELFTEST_CONTEXT_LOADED=1

merv_selftest_context_private_mode() {
  _msc_path=${1:-}
  _msc_type=${2:-}
  [ -n "$_msc_path" ] && [ ! -L "$_msc_path" ] || return 1
  _msc_mode=$(LC_ALL=C ls -ldn "$_msc_path" 2>/dev/null | awk 'NR == 1 { print $1 }') || return 1
  case "$_msc_type:$_msc_mode" in
    directory:drwx------|file:-rw-------) return 0 ;;
    *) return 1 ;;
  esac
}

merv_selftest_context_root_safe() {
  _msc_root=${1:-}
  case "$_msc_root" in
    /tmp/mervlan_tmp/selftest.*|/tmp/mervlan-*|/tmp/mervlan_*) ;;
    *) return 1 ;;
  esac
  case "$_msc_root" in
    *..*|*//*|*/|*[!A-Za-z0-9_./-]*) return 1 ;;
  esac
  _msc_current=/
  _msc_rest=${_msc_root#/}
  while [ -n "$_msc_rest" ]; do
    case "$_msc_rest" in
      */*) _msc_component=${_msc_rest%%/*}; _msc_rest=${_msc_rest#*/} ;;
      *) _msc_component=$_msc_rest; _msc_rest= ;;
    esac
    case "$_msc_component" in ''|.|..) return 1 ;; esac
    _msc_current="$_msc_current$_msc_component"
    [ ! -L "$_msc_current" ] || return 1
    if [ "$_msc_current" != "$_msc_root" ]; then
      [ -d "$_msc_current" ] || return 1
    fi
    _msc_current="$_msc_current/"
  done
  merv_selftest_context_private_mode "$_msc_root" directory
}

merv_selftest_context_valid() {
  _msc_context=${MERVLAN_SELFTEST_CONTEXT:-}
  case "$_msc_context" in */.mervlan-selftest-context) ;;
    *) return 1 ;;
  esac
  _msc_root=${_msc_context%/.mervlan-selftest-context}
  merv_selftest_context_root_safe "$_msc_root" || return 1
  merv_selftest_context_private_mode "$_msc_context" file || return 1
  _msc_size=$(wc -c < "$_msc_context" 2>/dev/null | tr -d '[:space:]') || return 1
  case "$_msc_size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_msc_size" -le 256 ] 2>/dev/null || return 1
  _msc_line1= _msc_line2= _msc_extra=
  {
    IFS= read -r _msc_line1 || return 1
    IFS= read -r _msc_line2 || return 1
    IFS= read -r _msc_extra && return 1
  } < "$_msc_context"
  [ "$_msc_line1" = 'format=mervlan-selftest-context-v1' ] || return 1
  [ "$_msc_line2" = "root=$_msc_root" ] || return 1
  MERV_SELFTEST_CONTEXT_ROOT=$_msc_root
  return 0
}

merv_selftest_context_path_allowed() {
  _msc_path=${1:-}
  [ -n "$_msc_path" ] || return 1
  merv_selftest_context_valid || return 1
  case "$_msc_path" in
    "$MERV_SELFTEST_CONTEXT_ROOT"|"$MERV_SELFTEST_CONTEXT_ROOT"/*) ;;
    *) return 1 ;;
  esac
  case "$_msc_path" in
    *..*|*//*|*[!A-Za-z0-9_./:-]*) return 1 ;;
  esac
  return 0
}

# Called only by a test harness after it has privately created its fixture
# root. It never creates or chmods that root on the harness's behalf.
merv_selftest_context_create() {
  _msc_root=${1:-}
  merv_selftest_context_root_safe "$_msc_root" || return 1
  _msc_context="$_msc_root/.mervlan-selftest-context"
  [ ! -e "$_msc_context" ] && [ ! -L "$_msc_context" ] || return 1
  _msc_tmp="$_msc_context.tmp.$$"
  [ ! -e "$_msc_tmp" ] && [ ! -L "$_msc_tmp" ] || return 1
  ( umask 077
    printf 'format=mervlan-selftest-context-v1\nroot=%s\n' "$_msc_root" > "$_msc_tmp"
  ) 2>/dev/null || { rm -f "$_msc_tmp" 2>/dev/null || :; return 1; }
  chmod 600 "$_msc_tmp" 2>/dev/null || { rm -f "$_msc_tmp" 2>/dev/null || :; return 1; }
  mv "$_msc_tmp" "$_msc_context" 2>/dev/null || {
    rm -f "$_msc_tmp" 2>/dev/null || :
    return 1
  }
  MERVLAN_SELFTEST_CONTEXT=$_msc_context
  export MERVLAN_SELFTEST_CONTEXT
  merv_selftest_context_valid
}
