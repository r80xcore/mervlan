# MerVLAN RC3 — Luna: Lean Repair and Minimal Runtime Guard Integration

Role: independent senior POSIX/BusyBox shell engineer, safety QA, and release coordinator. Implement narrowly, verify exact source generation and report PASS/PARTIAL/STOP at each gate. Do not rewrite 592-line R2 or invent an ownership framework.

**READ FIRST:** README.md, audit/SOURCE_AUDIT_AND_FINDINGS.md, audit/INTEGRATION_AND_TEST_GATES.md, audit/LOCAL_TEST_REPORT.md, repository AGENTS.md and dev-tools/RULES.md if present.

Repository: `r80xcore/mervlan`. Required branch: `pre_v0.53.29-RC3-repair-test`. Expected old HEAD: `ea79c37d9517160a648883306154241685f8f41b`. Do not pretend an older source archive is current. Preserve uncommitted changes, status and worktrees.

## Material supplied

- `candidates/update_mervlan_repair_R2_accepted.sh`: accepted R2 SHA-256 `f3b74696...e09439186`, deliberately fixture-only.
- `candidates/update_mervlan_repair_R2_cleanup_candidate.sh`: limited scratch-cleanup enhancement, SHA in SHA256SUMS.
- `patches/01_repair_prepublication_scratch_cleanup.diff`: exact R2-to-cleanup patch.
- `patches/02_heal_maintenance_guards_REFERENCE.diff`, `03_manager_maintenance_guards_REFERENCE.diff`, `04_update_cleanup_exit_status_REFERENCE.diff`: real source-derived suggested implementation, built/syntax-checked against an **older RC3-dev archive**, NOT the exact current branch. First compare with current source and reconcile; never force-apply.
- `reference/P0C_641_unqualified.sh`: partial idle adapter for research only, NOT production.
- `tests/test_lean_repair.py`: previous 67-case host suite; `tests/test_prepublication_cleanup.py` passed 3/3 on cleanup candidate; `tests/test_update_exit_trap_semantics.sh` PASS Dash & ash. Full suite rerun on cleanup candidate stopped after 41 PASS due time limit; not a final PASS.

## Work order

**A. Repository integrity.** Verify checkout, SHA/manifest, compare R1 production entry to R2 source and identify exact CLI/API/UI compatibility. Report any HEAD drift and halt unsafe overwrites. Run `sha256sum -c SHA256SUMS` in this folder.

**B. Host integration in an isolated worktree.** First retain the currently functional R1 Emergency Repair entrypoint. Place new R2 as an EXPERIMENTAL candidate (or integrated under test-only path), not at the functional installed entrypoint while `coordination_preflight` forbids hardware. Review the 14–17-line scratch cleanup patch and apply if tests support it. No silent removal of evidence bearing non-empty ledger or uncertain owner.

**C. Minimal Heal + Manager guards.** Use the supplied reference diffs as suggested code. Adapt to current complete sources, ensure fail-closed classifier availability and a second check *after the actual runtime lock*. Audit that parent/child handoff and EXIT cleanup release lock without deadlocking. Early library source side effects must be assessed; do not claim the guard covers them without evidence. No changes to wireless algorithms.

**D. Event handler.** Preserve the urgent inline ebtables shield. Source-level audit whether this operation may safely run independently of file publication. Verify deferred Heal is not silently lost on refusal: cron alone is not automatically assured replay. Do not introduce a P0-C mutex prototype or a new scheduler. If event delivery cannot be proven, STOP real publication and recommend isolated maintenance alternative.

**E. Update memory and cleanup.** Review the provided EXIT-trap failure propagation patch. On Dash/BusyBox an EXIT trap returning 1 does not necessarily change the shell process status; independently reproduce and cover actual Update's `cleanup_tmp` error. Qualify successful `updates.$$` scratch cleanup, preservation on rollback failure, no automatic deletion of foreign/retained state, and size/headroom accounting of old workspaces. Capture actual source lines and logs. Do not use broad `/tmp` cleanup commands.

**F. Repair/UI/bootstrap ABI.** WebUI Repair-before-Update invokes existing dispatcher and uses parent action locks, WebUI progress and terminal acknowledgements. Lean R2 doesn't implement WebUI progress/finalization. Maintain/restore these only by a narrow, tested adapter. The user wants the RC3 TEST BRANCH; the normal GUI repair action selects `main` or `dev`, not the custom test branch. Prove intended selection instead of silently installing `dev`. Bound the HELP SSH bootstrap separately. Preserve same-snapshot source authenticity constraints.

**G. Full host qualification.** Run all 67 lean tests against ACTUAL candidate, new cleanup tests, trap test, maintained project gate, Dash/Busybox ash, negative concurrency reproductions, interrupt/rollback/crash evidence, and complete 58-file fixture. Measure /tmp peak and retained scratch before/after multiple runs. On FAIL stop and report exact case; do not paper over with bypass flags. Run target BusyBox 1.25.1 probes only under separate read-only approval.

**H. Git gate.** After clean local PASS and user review, create one scoped commit/push ONLY on `pre_v0.53.29-RC3-repair-test` without touching release branches. If real publication is still disabled, commit experimental references and/or qualified companions only; DO NOT replace the functional current Repair entrypoint with a deliberately blocked script. No silent push without disclosing exact diff/hash/test outcome.

**I. Hardware and GUI tests (future gated steps, NOT authorized by this prompt):** After separately approved recovery plan, isolated wired device first: hardware /tmp fixture, controlled Repair trial, normal Update to test branch, second Repair, second normal Update, GUI Repair-before-Update LAST. Stop after any error, unverified cleanup, memory headroom drop, Wi-Fi/SSH anomaly, or unresolved owner. Never do the whole sequence unattended. No production MAIN/NODE work, service restart, Apply/Sync/Heal/Update on router, reboot, commit or push until respective explicit stage is authorized.

## Required report

1. Current branch/HEAD/status and observed source identities; 2. exact file modifications/diffs; 3. evidence that working rescue remains available during development; 4. guards and event delivery proof or identified gap; 5. Update and Repair scratch cleanup failure/success matrices; 6. complete test matrix including target vs host distinctions; 7. GUI/bootstrap contract; 8. SHA256 inventory and changed-line count; 9. explicit PASS/PARTIAL/STOP for HOST, COMMIT, FIXTURE, LIVE REPAIR, UPDATE, GUI; 10. minimal remaining next action.

**The goal is to finish a dependable small file-replacement utility, not build a new framework.**
