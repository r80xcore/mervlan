# Luna integration and trial sequence: mandatory checkpoints

This file converts the user's requested 8-step sequence into *separate STOP/PASS gates*. **No hardware operation is authorized merely by receiving this ZIP.**

1. **Integrate Repair locally:** on the exact `pre_v0.53.29-RC3-repair-test` checkout, apply the 592-line R2 as source (`functions/update_mervlan_repair.sh`), then review/reapply the isolated scratch cleanup, while preserving hard fixture-only publication refusal. Verify manifest-byte equality, archive validation, protected-data, rollback, CLI/bootstrap contract, WebUI entrypoint. Verify `sh -n`, BusyBox ash, new tests and full repository maintained gate.
2. **Integrate minimal runtime guards locally:** adapt reference Heal and Manager patches to the actual source with exact context and independently test source/initialization ordering, runtime lock acquisition and cleanup. Do NOT merge incomplete P0-C event gate. Assess whether inline urgent ebtables shield operation can remain independent, and how later Heal is rescheduled if maintenance blocked. `update_wait_for_runtime_idle` cannot just be sourced by Repair.
3. **Commit/push test branch only after an explicit QC checkpoint:** clean staged diff, precise file/hash inventory, full host test PASS, review of GUI/Update ABI and known emergency recovery limitations. **If real-router publication is still blocked, commit only experimental/staged code; do NOT replace the working production Repair entrypoint with a deliberately nonfunctional one.** Do not push old experiment evidence or unintended changes. Never push a candidate that has a hidden allow-production bypass. Commit and push don't authorize deployment.
4. **Controlled Repair test #1:** first perform a synthetic `/tmp` fixture run on XT8 with BusyBox 1.25.1 and monitored memory, off the active addon. A real 58-file Repair against `/jffs` requires a separate, isolated/offline target, wired/oob access, exported verified install backup and independent recovery plan, coordinated writers proven, baseline mem/tmp/JFFS sample, user go-ahead. Do NOT remove `coordination_preflight` before these conditions. STOP on any failure/timeout/memory drop.
5. **Normal Update to test branch:** only after an isolated Repair PASS and restored system baseline. Never use Update as an automatic next step after an ambiguous Repair result; verify expected new branch HEAD and no unresolved owner/ledger/temp state. Monitor memory/temp/observability.
6. **Repair test #2 after Update:** verify installed generation, repeat safe recovery fixture then controlled trial if independently authorized. Measure file changes, elapsed/CPU/memory/tmp and cleanup state.
7. **Normal Update test #2:** use established CLI/update path and ensure cleanup-on-success / preserve-on-error policy is proven, no stale `updates.*` accumulating. Verify node workflow separately if enabled.
8. **GUI Update with Repair-before-Update:** last, not first. Must exercise handler's `repairmain_vlanmgr` or `repairdev_vlanmgr` action lock, WebUI progress token, final action acknowledgement after ownership release, correct repair source selection (GUI currently chooses `main`/`dev`, NOT an arbitrary RC3 test branch) and updater handoff, and refusal/failure propagation. The current lean R2 does NOT yet implement the accepted WebUI progress/finalization ABI. STOP until adapted and proven synthetically, then explicitly authorize an isolated GUI test.

### Before any hardware test (including isolated device)

- Record current branch/commit, current MAIN/NODE versions, last-good backup, UIs and wired fallback.
- Verify not performing the test through the only live Wi-Fi/SSH management path; use wired/OOB access.
- Read-only size/health: `df -k /tmp /jffs`, `free`, `du -sk /tmp/mervlan_tmp/updates.* /tmp/mervlan_lean.* /tmp/mervlan_repair.* 2>/dev/null`, `/proc/meminfo`, owner/quiesce state and firmware event handling. Do not use these wildcards for removal.
- Collect logs off device before reboot; local `/tmp` evidence will disappear after a reboot.
- Never automatically delete preserved directories, ownership records, node state or DHCP/guard markers.
- Ensure no helper is silently stopping firmware-event shielding.

### Release categories

`HOST PASS` = eligible to **consider** commit after independent QC.
`TARGET FIXTURE PASS` = target-shell compatibility measured only.
`ISOLATED DEVICE PASS` = controlled addon publication on an out-of-service device.
`HOUSEHOLD MAIN PASS` = separate supervised operational release assessment.
`GUI PASS` = separate dispatcher / WebUI contract acceptance.

No category implies the next automatically.
