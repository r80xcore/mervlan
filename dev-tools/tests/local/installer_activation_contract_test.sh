#!/bin/sh
# Focused contract coverage for staged installer activation diagnostics and
# pre-admission workspace ownership.  The fixtures never touch live addon
# paths or the router.
set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
INSTALL="$ROOT/install.sh"
WORK="${TMPDIR:-/tmp}/mervlan-installer-activation.$$"
trap 'rm -rf "$WORK"' 0 1 2 3 15
mkdir -p "$WORK" || exit 1

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

extract_function() {
    _eif_file=$1
    _eif_name=$2
    _eif_out=$3
    awk -v name="$_eif_name" '
        $0 ~ "^" name "\\(\\) \\{" { emit=1 }
        emit {
            print
            opens=gsub(/\{/, "{")
            closes=gsub(/\}/, "}")
            depth+=opens-closes
            if (depth == 0) exit
        }
    ' "$_eif_file" >"$_eif_out" || return 1
    [ -s "$_eif_out" ]
}

for expected in \
  'staged activation: staged support cohort revalidation failed' \
  'staged activation: active target skeleton is missing or unsafe' \
  'staged activation: active target path chain is unsafe' \
  'staged activation: cp -a and tar fallback activation failed' \
  'staged activation: activated tree validation failed' \
  'staged activation: staging workspace cleanup failed'; do
    grep -Fq "$expected" "$INSTALL" || fail "activation diagnostic missing: $expected"
done
grep -Fq 'pre-admission staging workspace cleanup failed' "$INSTALL" ||
    fail 'pre-admission cleanup diagnostic missing'

HELPERS="$WORK/helpers.sh"
: >"$HELPERS"
for helper in \
  cleanup_install_download_work install_pre_admission_stage_failure \
  install_pre_admission_exit_handler install_activation_failure \
  install_activate_staged_package install_stage_target_before_admission; do
    extract_function "$INSTALL" "$helper" "$WORK/$helper.sh" || fail "extract $helper"
    cat "$WORK/$helper.sh" >>"$HELPERS" || fail "assemble $helper"
done

# A pre-admission failure removes only the workspace owned by that attempt.
TEST_ROOT="$WORK/pre-admission"; mkdir -p "$TEST_ROOT/runtime/install.older"
if TEST_ROOT="$TEST_ROOT" HELPERS="$HELPERS" sh -c '
  . "$HELPERS" || exit 1
  TMP_DIR="$TEST_ROOT/runtime"
  MODE=full
  MERV_INSTALL_SUPPORT_HANDOFF=0
  INSTALL_STAGE_ONLY=0
  RESULT_DETAIL=""
  install_path_chain_safe() { return 0; }
  download_mervlan() {
    INSTALL_DOWNLOAD_WORK="$TMP_DIR/install.12345"
    mkdir -p "$INSTALL_DOWNLOAD_WORK" || return 1
    printf owned >"$INSTALL_DOWNLOAD_WORK/owned"
    return 1
  }
  install_stage_target_before_admission >/dev/null 2>&1 && exit 2
  [ ! -e "$TMP_DIR/install.12345" ] || exit 3
  [ -d "$TMP_DIR/install.older" ] || exit 4
'; then :; else fail 'pre-admission owner cleanup fixture failed'; fi
printf 'PASS: pre-admission failure retires only its owned workspace\n'

# A staged child that fails before its normal EXIT handler is installed owns
# the handoff workspace and must clean it through the bounded pre-admission
# path as well.
TEST_ROOT="$WORK/handoff"; mkdir -p "$TEST_ROOT/runtime/install.67890/root"
if TEST_ROOT="$TEST_ROOT" HELPERS="$HELPERS" sh -c '
  . "$HELPERS" || exit 1
  TMP_DIR="$TEST_ROOT/runtime"
  MODE=full
  MERV_INSTALL_SUPPORT_HANDOFF=1
  MERV_INSTALL_HANDOFF_ADOPTED=1
  INSTALL_STAGE_ONLY=0
  INSTALL_DOWNLOAD_WORK="$TMP_DIR/install.67890"
  MERV_INSTALL_STAGED_ROOT="$INSTALL_DOWNLOAD_WORK/root"
  install_support_cohort_valid() { return 1; }
  install_stage_target_before_admission >/dev/null 2>&1 && exit 2
  [ ! -e "$TMP_DIR/install.67890" ] || exit 3
'; then :; else fail 'handoff pre-admission cleanup fixture failed'; fi
printf 'PASS: staged handoff failure retires its private workspace\n'

# Cohort failure is reported before any active-tree copy.
if HELPERS="$HELPERS" sh -c '
  . "$HELPERS" || exit 1
  MODE=full; INSTALL_STAGED_READY=1
  INSTALL_STAGED_ROOT=/tmp/staged; INSTALL_STAGED_WORK=/tmp/install.1
  INSTALL_DOWNLOAD_WORK=/tmp/install.1; MERV_BASE=/tmp/active
  installer_record() { :; }
  install_support_cohort_valid() { return 1; }
  install_activate_staged_package >/dev/null 2>&1 && exit 2
  [ "$RESULT_DETAIL" = "staged activation: staged support cohort revalidation failed" ]
'; then :; else fail 'cohort diagnostic fixture failed'; fi
printf 'PASS: staged cohort revalidation failure is attributable\n'

# Both activation copy mechanisms failing is distinct from validation failure.
TEST_ROOT="$WORK/copy-failure"; mkdir -p "$TEST_ROOT/stage" "$TEST_ROOT/active"
if TEST_ROOT="$TEST_ROOT" HELPERS="$HELPERS" sh -c '
  . "$HELPERS" || exit 1
  MODE=full; INSTALL_STAGED_READY=1
  INSTALL_STAGED_ROOT="$TEST_ROOT/stage"; INSTALL_STAGED_WORK="$TEST_ROOT/install.2"
  INSTALL_DOWNLOAD_WORK="$TEST_ROOT/install.2"; MERV_BASE="$TEST_ROOT/active"
  installer_record() { :; }
  install_support_cohort_valid() { return 0; }
  install_path_chain_safe() { return 0; }
  normalize_install_script_permissions() { :; }
  cp() { return 1; }
  tar() { return 1; }
  install_activate_staged_package >/dev/null 2>&1 && exit 2
  [ "$RESULT_DETAIL" = "staged activation: cp -a and tar fallback activation failed" ]
'; then :; else fail 'copy fallback diagnostic fixture failed'; fi
printf 'PASS: activation copy failure identifies both copy paths\n'

# A complete copy followed by active-tree validation failure is reported
# separately, and no cleanup is mistaken for validation success.
TEST_ROOT="$WORK/validation-failure"; mkdir -p "$TEST_ROOT/stage" "$TEST_ROOT/active"
printf package >"$TEST_ROOT/stage/install.sh"
if TEST_ROOT="$TEST_ROOT" HELPERS="$HELPERS" sh -c '
  . "$HELPERS" || exit 1
  MODE=full; INSTALL_STAGED_READY=1
  INSTALL_STAGED_ROOT="$TEST_ROOT/stage"; INSTALL_STAGED_WORK="$TEST_ROOT/install.3"
  INSTALL_DOWNLOAD_WORK="$TEST_ROOT/install.3"; MERV_BASE="$TEST_ROOT/active"
  installer_record() { :; }
  install_support_cohort_valid() { return 0; }
  install_path_chain_safe() { return 0; }
  normalize_install_script_permissions() { :; }
  install_tree_valid() { return 1; }
  install_activate_staged_package >/dev/null 2>&1 && exit 2
  [ "$RESULT_DETAIL" = "staged activation: activated tree validation failed" ]
'; then :; else fail 'post-copy validation diagnostic fixture failed'; fi
printf 'PASS: activated-tree validation failure is attributable\n'

# Cleanup failure remains a hard failure after a valid activation.
TEST_ROOT="$WORK/cleanup-failure"; mkdir -p "$TEST_ROOT/stage" "$TEST_ROOT/active"
printf package >"$TEST_ROOT/stage/install.sh"
if TEST_ROOT="$TEST_ROOT" HELPERS="$HELPERS" sh -c '
  . "$HELPERS" || exit 1
  MODE=full; INSTALL_STAGED_READY=1
  INSTALL_STAGED_ROOT="$TEST_ROOT/stage"; INSTALL_STAGED_WORK="$TEST_ROOT/install.4"
  INSTALL_DOWNLOAD_WORK="$TEST_ROOT/install.4"; MERV_BASE="$TEST_ROOT/active"
  installer_record() { :; }
  install_support_cohort_valid() { return 0; }
  install_path_chain_safe() { return 0; }
  normalize_install_script_permissions() { :; }
  install_tree_valid() { return 0; }
  cleanup_install_download_work() { return 1; }
  install_activate_staged_package >/dev/null 2>&1 && exit 2
  [ "$RESULT_DETAIL" = "staged activation: staging workspace cleanup failed" ]
'; then :; else fail 'activation cleanup diagnostic fixture failed'; fi
printf 'PASS: activation workspace cleanup failure is attributable\n'

printf 'INSTALLER_ACTIVATION_CONTRACT_OK\n'
