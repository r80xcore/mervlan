#!/bin/sh
set -eu
# Demonstrate that the plain EXIT trap can mask a cleanup failure.
for shell in dash ash; do
  if [ "$shell" = ash ] && ! command -v busybox >/dev/null 2>&1; then continue; fi
  if [ "$shell" = dash ]; then set -- /bin/sh; else set -- busybox ash; fi
  "$@" -c 'f(){ return 1; }; trap f EXIT; true' >/dev/null 2>&1 || {
    echo "FAIL $shell initial trap semantics unexpectedly changed"; exit 1;
  }
  if "$@" -c "f(){ return 1; }; trap 'rc=\$?; trap - EXIT; f || exit 1; exit \"\$rc\"' EXIT; true" >/dev/null 2>&1; then
    echo "FAIL $shell cleanup failure reported success"; exit 1
  fi
  echo "PASS $shell cleanup failure propagated"
done
