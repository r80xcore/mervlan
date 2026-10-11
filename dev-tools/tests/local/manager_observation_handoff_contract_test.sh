#!/bin/sh
# The strict quiescence inventory must see the next observation owner before
# the manager releases its global action owner.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
MANAGER="$ROOT/functions/mervlan_manager.sh"

awk '
  /release_script_lock manager-only/ { manager_release = NR }
  /request snapshot/ { requests[++request_count] = NR }
  /release_script_lock action-only/ { action_releases[++release_count] = NR }
  /run-wait/ { run_wait = NR }
  END {
    if (!manager_release || request_count != 3 || release_count != 5 || !run_wait ||
        !(manager_release < requests[1] && requests[1] < action_releases[1] &&
          action_releases[2] < requests[2] && requests[2] < action_releases[3] &&
          requests[3] < action_releases[4] && action_releases[4] < run_wait &&
          run_wait < action_releases[5])) exit 1
  }
' "$MANAGER" || {
  printf '%s\n' 'FAIL: manager releases action ownership before publishing observation work' >&2
  exit 1
}

printf '%s\n' 'PASS: manager observation generation is visible before action-owner release'
