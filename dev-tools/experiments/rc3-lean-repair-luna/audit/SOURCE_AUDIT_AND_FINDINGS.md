# Source audit / engineering decisions (2026-11-14)

Evidence source for exact test-branch HEAD `ea79c37d9517160a648883306154241685f8f41b`: GitHub connector read-only fetch. Those sources are **not** identical to the locally supplied `pre_v0.53.29-RC3-dev.zip`, so reference diffs 02–04 MUST be rebased/audited against the current test checkout.

## Confirmed mechanisms

1. `functions/update_mervlan.sh` acquires the exact canonical maintenance owner via `merv_owner_lock_acquire` around line 1486; it publishes `merv_update_quiesce_begin` around 1760, then calls `update_wait_for_runtime_idle`, which checks manager/event, action, observation and DHCP/boot-shield states. This is not a generic lock-only guarantee.
2. `settings/lib_update_state.sh`'s `merv_update_mutation_blocked` blocks **live/unknown/malformed** canonical ownership, but returns *unblocked* for verified `dead/reused` owners without durable journal/quiesce state. Standalone Repair's RAM-backed ledger cannot rely on this for reboot integrity.
3. `functions/heal_event.sh` invokes the mutation blocker around line 45, **after loading libraries**, using a conditional that skips the blocker when its function is absent. It then performs DHCP hold reconciliation and later `wl`/`brctl` mutations. It acquires `vlan_event.lock` around line 273. An initial passing check can race later maintenance admission. It may launch a manager asynchronously and wait for handoff.
4. `functions/mervlan_manager.sh` has a similarly fail-open `type ... &&` guard around line 86. It acquires `mervlan_manager.lock` around line 512; check again after lock acquisition, before mutation, while ensuring the existing EXIT release works.
5. `functions/service-event-handler.sh` event branch performs inline `ebtables` DHCP/MERV_QT/MERV_MAC shield restoration around lines 1592–1624, then asynchronously launches Heal around 1640. Blocking these inline rules risks leaving clients unprotected. The handler also dispatches GUI Repair with token/ack and parent-owned action locks; the standalone R2 has no qualified WebUI JSON progress contract.
6. `functions/update_mervlan.sh`'s `cleanup_tmp` deletes `TMP_BASE` (usually `/tmp/mervlan_tmp/updates.$$`) when not preserving evidence. On incomplete recovery/pool work it deliberately keeps TMP/JFFS. The plain `trap cleanup_tmp EXIT` at historical source position can mask a cleanup failure as a zero process exit code. Demonstrated under Dash and BusyBox ash: an EXIT trap returning 1 after a successful body still exits 0. The patch alters trap plumbing, not any cleanup deletion rule.
7. Accepted 592-line R2 script, by contrast, cleans WORK on committed success and retains WORK after failure; repeated failures **before first publication** can accumulate extracted archives because there is no ledger to block retries. `01` only proposes cleanup of its own private uncommitted workspace after lock release; failure after TX has started retains all records for recovery.
8. R2 itself has a *hard test-fixture-only `coordination_preflight`*. Installation will not make a real router run possible. This is intentional and MUST be preserved until a trusted runtime quiescence proof or approved offline test-mode contract exists.

## Priority blockers (do not paper over)

- The reference guards do not by themselves close the race at the **earliest source/init side effect** nor do they cover every manager/Heal descendant. Audit the real complete source and scope before authorizing publication.
- A newly downloaded Repair script cannot make a previously installed handler/Heal cooperative. Guarded new files are not proof for the first repair run.
- Existing firmware-event shielding must continue; a `cru` periodic Heal tick is *not* a proven lossless bounded replay of a specific event. Explicitly qualify before GUI tests.
- A 58-file cohort is not atomically replaced; failure/power loss can leave a mixed cohort and `/tmp` evidence vanishes on reboot. Treat as known risk during **isolated** test; do not claim unattended release readiness.
- Update's failure evidence may be large and preserved intentionally. The correct RAM policy is bounded preflight, successful cleanup, visible retained-byte reporting, independent backup, and authorized review before deletion—not indiscriminate `rm -rf /tmp/mervlan_tmp`.
- The lean script embeds the manifest and does not execute a downloaded successor. **Promotion risk:** replacing the current R1 `functions/update_mervlan_repair.sh` with the fixture-gated lean version would temporarily REMOVE working emergency capability; keep R1 in production until R2 has a qualified real admission path. Verify compatibility with Update/GUI and exact sourced branch; no automatic repair-before-update until service-event action acknowledgement and finalization are proven. Current WebUI Repair labels only map to `main` or `dev`; an RC3 custom test branch is CLI-only by documented contract, so do not assume GUI test uses that branch.

## Important prior reference signatures

- R2: `f3b74696b91d4492571b5c49315ac17cde53b6c85bd45591ac52359e09439186`
- 641-line P0-C-R2 adapter: `04b21cec39352952cdffbb97cd5aa9a9c04e6fedab5462531044b9d0d27dd677` (unqualified; retained as evidence)
- Target original BusyBox `/bin/sh`: 1.25.1; host BusyBox 1.37 is only a partial surrogate.

## Other audit requests for Luna

Audit `update_mervlan.sh` handling of all preserved temp `updates.*` directories, `RAW_ARCHIVE` disposal and exit-trap result; size the actual `/tmp`, `/jffs`, current install, archived originals and every retained workspace on target **read only** before any live test; no destructive cleanup without explicit approval. Verify existing `docs/HELP.md` bootstrap still uses long per-attempt curl retries; update its budget separately. Audit WebUI `dispatch_if_executable` progress/ack/lock ownership and `Repair before Update` chaining with synthetic UI tokens. Never assume a CLI PASS proves GUI success.
