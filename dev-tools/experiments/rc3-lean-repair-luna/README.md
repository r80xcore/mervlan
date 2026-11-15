# MerVLAN RC3 — Lean Repair / Luna integration handoff

**Status: HOST-SIDE REVIEW PACKAGE ONLY. Isolated XT8 fixture qualification
passed on MAIN on 2026-11-15; do not run installed-file Repair on MAIN/NODE.**

This package is intentionally rooted at `dev-tools/experiments/rc3-lean-repair-luna/`.
**Unpack the ZIP at the ROOT of your checkout of `pre_v0.53.29-RC3-repair-test`.**
Do not unzip it inside `functions/` or the installed `/jffs/addons/mervlan/` tree.
It is staged data: extracting it does NOT alter production code.

Expected branch: `pre_v0.53.29-RC3-repair-test`.
Last verified HEAD: `ea79c37d9517160a648883306154241685f8f41b`.
Luna MUST report actual branch/HEAD, `git status --short`, and any drift before any integration.
The independent RC3-dev source archive used to build the three REFERENCE patches has DIFFERENT file identities from this test branch. Treat patches 02–04 as code proposals, not validated production changes.

## What to use

- `candidates/update_mervlan_repair_R2_accepted.sh`: byte-exact accepted 592-line lean R2 (SHA-256 `f3b74696...e09439186`). **Still refuses real-router publication.**
- `candidates/update_mervlan_repair_R2_cleanup_candidate.sh`: R2 + 14-line prepublication scratch cleanup; host regression smoke-tested. No removal of ledger-bearing workspaces.
- `patches/01_...diff`: applies AFTER the accepted R2 is installed at `functions/update_mervlan_repair.sh`.
- `patches/02_...REFERENCE.diff` and `03_...REFERENCE.diff`: fail-closed Heal/Manager guards, including a recheck after each runtime lock. Syntax-qualified against *different* RC3-dev source, not the exact test-branch HEAD.
- `patches/04_...REFERENCE.diff`: ensure Update reports cleanup trap failure as process failure. Syntax-qualified against *different* RC3-dev source; independent Dash/ash trap semantics reproduced.
- `reference/P0C_641_unqualified.sh` and adapter diff: **DO NOT PROMOTE**. The 49-line idle inventory was incomplete and source/fixture-only.
- `tests/`: accepted 67-test suite and new targeted scratch/EXIT-trap tests.
- `audit/`: key findings and exact acceptance plan.

## 32 MiB preflight candidate and XT8 fixture

- `candidates/update_mervlan_repair_R2_32MiB_preflight.sh` is the supplied
  cleanup candidate with named 32 MiB RAM, 64 MiB `/tmp`, and 8 MiB destination
  thresholds. It remains experimental and keeps the real-router publication
  block. It has not replaced either Repair entrypoint.
- `XT8_FIXTURE_QUALIFICATION_32MiB.md` and
  `scripts/run_xt8_fixture_qualification_64MiB_runner.sh` are the matching
  private-`/tmp` XT8 fixture procedure and runner. The two isolated cases
  passed on MAIN (RT-AX95Q, BusyBox 1.25.1); see
  `XT8_HARDWARE_ACCEPTANCE_2026-11-15.md` for measurements and evidence.
- The unversioned `XT8_FIXTURE_QUALIFICATION.md` is the earlier procedure; use
  the 32 MiB procedure for this candidate. The current runner snapshots fixture
  files with SHA-256 via `sha256sum` or OpenSSL and does not require `cksum`.
- Re-run all 67 candidate cases under one shell at a time from the repo root:

  ```sh
  MERV_TEST_ENGINE="$PWD/dev-tools/experiments/rc3-lean-repair-luna/candidates/update_mervlan_repair_R2_32MiB_preflight.sh" \
  MERV_TEST_CANDIDATE="$PWD/dev-tools/experiments/rc3-lean-repair-luna/candidates/update_mervlan_repair_R2_32MiB_preflight.sh" \
  python3 dev-tools/experiments/rc3-lean-repair-luna/tests/test_lean_repair.py --shell dash

  MERV_TEST_ENGINE="$PWD/dev-tools/experiments/rc3-lean-repair-luna/candidates/update_mervlan_repair_R2_32MiB_preflight.sh" \
  MERV_TEST_CANDIDATE="$PWD/dev-tools/experiments/rc3-lean-repair-luna/candidates/update_mervlan_repair_R2_32MiB_preflight.sh" \
  python3 dev-tools/experiments/rc3-lean-repair-luna/tests/test_lean_repair.py --shell busybox
  ```

## First commands (in your repository root; host only)

```sh
pwd
git status --short
git branch --show-current
git rev-parse HEAD
find dev-tools/experiments/rc3-lean-repair-luna -maxdepth 2 -type f | sort
sha256sum dev-tools/experiments/rc3-lean-repair-luna/candidates/*.sh
```

**Do not run `git apply` on all four patches automatically.** The accepted Repair R2 is not the current HEAD source. First copy/integrate R2 in a *clean isolated worktree or candidate copy* and prove its standalone/GUI compatibility. Then review the small cleanup diff. Review and adapt reference patches against verified current source independently.

## Gate for any router trial

Luna may commit/push only after a complete local PASS and a diff review, and only to the named test branch. Committing/pushing is not authorization to execute scripts on MAIN/NODE. The current candidate still has a deliberate real-router publication block. No one should remove it based on a marker string, boolean flag, or file-presence check. Refer to `audit/INTEGRATION_AND_TEST_GATES.md`.

## RAM rule

Successful Repair cleans private `/tmp/mervlan_lean.*` scratch. The cleanup candidate also removes *pre-publication* private scratch after error (only when no transaction ledger exists and no owner is held). It **retains** a transaction workspace after a failed publication or uncertain rollback, even if large. Update already removes `/tmp/mervlan_tmp/updates.$$` on ordinary success, but retains it on some failures. Preserved evidence must be inspected, measured and exported before any manual removal; never bulk-delete `/tmp/mervlan_tmp` or its locks.
