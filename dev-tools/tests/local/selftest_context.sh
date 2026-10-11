#!/bin/sh
# Explicitly establish the production lock library's private fixture seam.
# Call only after creating the test's own temporary root.

merv_test_context_enable() {
  _mtc_base=${1:-}
  _mtc_root=${2:-}
  [ -n "$_mtc_base" ] && [ -d "$_mtc_root" ] || return 1
  chmod 700 "$_mtc_root" 2>/dev/null || return 1
  . "$_mtc_base/settings/lib_selftest_context.sh" 2>/dev/null || return 1
  merv_selftest_context_create "$_mtc_root"
}
