# RC3 standalone Emergency Repair performance R2

## Verdict

**PARTIAL for the XT8 target.** The candidate makes a structural reduction in flash barriers and journal writes. Completion within 120 seconds, the 60-second stretch goal and power-loss behavior on JFFS2 remain unmeasured. This is a host-qualified candidate for independent review.

The November 18 XT8 checkpoint remains the immutable d97a2ceff369a5cdcc4c216beb61a41aa0a7b3b4 device baseline. It completed in 1,829 seconds. The log recorded backup READY at 60 seconds, the last replacement at 1,789 and SUCCESS at 1,821. The log gives no per-flush latency or contemporaneous process count. Its journal-dependent growth was addressed by R1, which measured 38.00 seconds on the host. R2 retains the R1 indexed validator verbatim. The separate R1 report remains in the local experiment evidence and is outside this R2 checkpoint.

## What the candidate removes

| Successful fresh Repair with all 58 originals present | R1 | R2 batch | R2 low-space fallback |
| --- | ---: | ---: | ---: |
| Global sync calls | 64 | 6 | 63 |
| Persistent atomic journal rewrites after prepared | 118 | 2 | 2 |
| Journal validations | 119 | 3 | 3 |
| SHA-256 launches | 528 | 412 | 470 |
| Full legacy scans | 61 | 61 | 61 |
| Peak replacement siblings | 1 | 58 | 1 |

- **Write-ahead intent.** Before creating a sibling or changing an installed target, the engine atomically writes state=publishing and all 58 pending records and flushes that journal. The READY digest already binds the entire backup index. Recovery uses that index, the journal lifecycle state and observed destination and sibling bytes and modes. Per-file done records never decided which targets to restore. Only after final content, mode, ownership and protected-state verification and a successful data flush does the engine atomically write all 58 done records and state=committed together. A separate barrier flushes the committed journal. The format, sizes, lifecycle names and parser are compatible with the retained format-1 helpers. Success still leaves 58 pending and 58 done records. The new record order expresses complete intent before publication and complete verification at commit. Per-file progress is still available from PUBLISH log messages. Logical journal-image bytes written drop from 236,905 to 6,023, excluding the initial prepared image and filesystem metadata.
- **Replacement durability.** On the fast path all same-directory siblings are copied, hashed against the verified index and checked for mode. One sync flushes all those siblings before the first rename, including data and mode under the same sync assumption as R1. Each rename checks the flushed sibling against the private staged bytes and expected mode again, validates the old destination against the index, and runs the existing ownership and legacy-process checks. After each rename the installed file is still hashed against the index and checked for mode. Each rename remains individually atomic on its target filesystem.
- **Capacity.** The fast path requires the second preflight to report the existing 8 MiB free-space floor plus the staged byte count rounded up to KiB and 1 MiB of extra headroom. This is an admission estimate, with copy errors still handled by the failure path. The November 18 pre-publication sample had 25,780 KiB free and 3,399,269 staged bytes, which would have cleared the 12,536 KiB threshold at that checkpoint. Lower headroom retains the original one-sibling footprint and flushes each sibling before its rename.
- **Handoff.** The private /tmp marker is written atomically and consumed immediately by the same PID through exec. The executable, marker, source reference and same-snapshot identity checks remain. A power loss before that exec can only lose pre-transaction scratch. The installed targets, ownership and backup have not been touched, so the old global flush at that point served no recovery barrier.
- **SHA-256.** The backup index still records the original and replacement hashes and binds them to READY. Backup originals pass payload verification before READY and after it, before any publication. The batch path eliminates two rereads of the staged replacement bytes. It checks every copied sibling against the indexed SHA-256 before the common flush and before any rename, and hashes each installed destination afterward. The low-space path retains a full staged-file verification before streaming, eliminating only one redundant pass. Recovery validates the persistent backup and classifies destinations and scratch against its index, so it can restore known evidence even when the private stage has disappeared or become unreadable.
- **Legacy writers.** Canonical locks protect cooperating writers. A legacy writer can launch or exec between two renames and ignore those locks. Checking once per batch, caching by PID or PID/start, or pre-reading all process arguments changes which writers the engine can see at a later mutation boundary. The existing sequential reads, scans and lock checks remain. The new race fixture introduces a writer after the first rename and verifies that the second destination stays original. A genuine reduction requires enforceable writer exclusion across the installed and historical entrypoints, with evidence from the target.

The fast path accounts for all six barriers in order. Backup payload and prepared state are flushed before READY. READY is flushed before transaction intent. Intent is flushed before creating siblings. Siblings are flushed before rename. Verified destinations are flushed before committed state. Committed state is flushed before successful release.

## Interruption argument

| Interruption window | Evidence and recovery behavior |
| --- | --- |
| Before READY is flushable | No target or sibling has been changed. Incomplete backup evidence refuses recovery. |
| After READY, before durable intent | Originals remain in place. Prepared may be recovered. A visible publishing image already covers the complete cohort. |
| While writing siblings, before their flush | No installed target has changed on the batch path. Recovery can remove verified siblings. An unknown or partial sibling forces refusal, with the original installed cohort still intact. The low-space path keeps the prior one-sibling crash behavior. |
| After sibling flush, between target renames | Backup and whole-cohort intent are durable before the first rename. Each rename points at a preflushed inode. Independent recovery classifies old, replacement and missing destinations, with any remaining valid siblings allowed. It refuses unknown bytes, mode or path types before restoring. Recovery can act on any known combination without per-file journal progress. |
| After all replacements but before verified files are flushed | The journal remains publishing. A mixed set of durable rename effects is treated as an interrupted transaction. |
| After the verified-data flush, while publishing committed state | The verified replacements were flushed first. Recovery either sees publishing and can roll back or sees a complete committed image and refuses rollback. The prior journal image survives a failed prefix copy. |
| During rollback | Rollback still verifies the persistent backup and all destination states, flushes each restore sibling before its rename and verifies the restored cohort before recording rolled-back. A second Recovery can resume from known evidence. |

This argument relies on the original filesystem contract for a successfully flushed sibling and atomic same-filesystem rename. The larger batch deliberately moves unflushed sibling creation before any installed replacement. It does not make conflicting writers or arbitrary filesystem corruption recoverable. Fault injection exercises process interruption and observable filesystem states. It cannot demonstrate flash ordering after real power loss.

## Host measurements

Two alternating pairs ran the exact R1 and R2 engines on the same 58-target fixture. It used 3,622,812 synthetic original bytes, the immutable source cohort with only the engine member changed, 64 synthetic process entries, the OpenSSL fallback and counted mock sync. The benchmark separately profiles exact operation counts. The engine member grows by 1,474 bytes while the other 57 replacements remain identical.

| Wall-time metric | R1 median | R2 median | Difference |
| --- | ---: | ---: | ---: |
| Full transaction | 28.34 s | 17.58 s | 10.76 s lower (38.0%) |
| Backup READY to final replacement | 19.24 s | 11.96 s | 7.28 s lower (37.8%) |
| Start to backup READY | 8.32 s | 4.85 s | 3.46 s lower |
| Independent recovery of fully published, uncommitted fixture | 16.75 s | 18.08 s | 1.33 s higher |

The R1 transaction samples were 29.27 and 27.41 seconds. The paired R2 samples were 15.77 and 19.38 seconds. Host load varied. In the separately instrumented runs, scan time alone varied from 6.84 to 10.83 seconds with identical scan counts, and instrumented R2 publication ran slower. Counts are the stronger result here. Profiling confirmed 119 to 3 journal validations, 118 to 2 rewrites, 64 to 6 flush calls and 528 to 412 hashes. Recovery retained the same 60 scans, 60 mock flushes and 470 hashes. The timing samples do not establish a recovery performance change.

An independent two-pair reproduction on November 18 used these exact engine hashes and the same 58-target fixture, 64 synthetic process entries and mocked flushes. It measured R1 at 39.18 seconds median and R2 at 33.53 seconds median (14.4% lower); READY-to-last-replacement medians were 26.76 and 22.37 seconds. The operation counts matched the table above. These wall times differ from the earlier pair and are host-only; the repeat confirms a modest improvement in this run, not a stable percentage or XT8 projection.

Reproduce the controlled host comparison with the exact R1 engine copy, which the harness SHA-256 verifies.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 dev-tools/experiments/rc3-lean-repair-luna/tests/benchmark_persistent_repair.py \
  --baseline-engine /tmp/mervlan-repair-r1-288be05c.sh --runs 2
```

The maintained local gate ran with `PYTHONDONTWRITEBYTECODE=1 sh dev-tools/tests/local/run_all.sh` and passed with 112 shell tests, five Node tests and zero failures. The standalone suite passed all 23 tests, including the extended crash matrix and partial-sibling allocation/interruption cases. Host /bin/sh and BusyBox shell syntax checks passed for both changed shell files. Git diff whitespace checks and the reverse application check of the R1-to-R2 source patch passed.

Other isolated validation covered the count of 63 barriers in the low-space fallback, a legacy writer starting between renames, and a modeled interruption with both names for a verified sibling inode and a missing originally present destination. The R1 recovery engine read that R2 format-1 transaction and restored exact original bytes, modes and absent-state semantics. A host BusyBox ash fixture with an explicit mock sync passed full publication and synchronous rollback after an injected failure. A damaged preflush sibling forced Recovery and new Repair to refuse with the installed original cohort intact.

## Target budget and proposed measurements

The candidate removes **58 global barriers and 116 journal rewrites** on the high-headroom path independently of CPU speed. The data flush and flash programming costs remain, and a single batch flush can take longer than a one-file flush. The retained log cannot quantify how much of either total consists of per-call overhead or writeback. Applying host percentages to 1,829 seconds would combine different bottlenecks and workloads.

The remaining successful fast path has six global flushes, 61 scans, 412 hashes and a full cohort of copies and verifications. If all costs other than process scanning total 60 seconds on XT8, the 120-second target allows about **0.98 seconds per scan**. With 45 seconds of other costs, the 60-second stretch goal allows about **0.25 seconds per scan**. These are conditional budgets. Neither limit can be established from the retained log. Even with zero other work, the scans alone exhaust 120 seconds at 1.97 seconds per scan and 60 seconds at 0.98 seconds per scan. The old 60-second time to READY and 32-second final interval include work changed by R1 and R2, so they do not provide a lower bound for the candidate.

With separate authorization, use a private /tmp directory and bounded native-firmware tests. Record BusyBox identity, test the exact validator applet invocations, count numeric proc entries without collecting command lines, time ten scans of isolated synthetic cmdline fixtures at representative counts, time SHA-256 launch and read costs over the 58-file size distribution, and run the full candidate fixture with a counted mock sync. Keep all synthetic state and writes under /tmp. Compare captured phase times against the budgets above. A global sync can flush real JFFS even when invoked from /tmp, so this private probe uses no real sync. Measure real JFFS2 flush cost and candidate durability only in a separately authorized storage trial. Further reductions depend on the measured limiter:

- Keep the backup-payload and READY barriers separate so the marker follows durable backup data. Keep the verified-data and commit barriers separate so a surviving committed marker cannot suppress rollback of an incompletely flushed tree. The durable intent barrier prevents interrupted sibling creation from being mistaken for a harmless prepared transaction. A narrower filesystem-specific flush would need equivalent inode and directory ordering proven on the vendor build.
- If staging all siblings proves too expensive for JFFS2 headroom, bounded groups of eight could keep the same full journal intent and require 13 barrier calls on success. Each group would need its own verified-sibling flush. The tradeoff is additional barriers and the possibility of an interrupted later staging group while earlier replacements are already visible. R2 currently keeps two paths with the same supported preflight floor.
- If hashing is the dominant remaining cost, the two 58-file reads of persistent backup payloads are candidates for bounded multi-file OpenSSL invocations, one per verification boundary. This could save up to 114 process launches. It requires proving exact output-to-path correspondence on the target, retaining mode and size checks and preserving immediate per-file checks around installed mutations.
- If legacy scans dominate, removing them requires an enforceable writer gate covering the historical executable cohort. The scanner cannot establish such exclusion using a previous scan or a stable PID/start tuple.

## Source identities and independent Luna QC

| Artifact | SHA-256 |
| --- | --- |
| R1 accepted engine | `288be05cf5aeb30d73791dc81d9bac28acf826b80c32f51b227b9c3f18bba94e` |
| R2 engine | `acdb9ffa862cfda43019f77ac6749eb670ea0f48f584bae543727afc1b96d57e` |
| R1-to-R2 engine patch | `94063c8b0bc6bef5c90b5116b477ffe9c76784ad5d00223721893e40e9cf0bc7` |
| Trusted manifest | `3475336656abe00c73d86526f7a385ff7b7328abd9c2a4d3b58f008e40d30c15` |
| Normal Update | `7bb9dcdd0593d156f1a0d7ff15002790a3fff3759c655d7513251d0038440fff` |

The production delta from R1 adds 78 lines and removes 36, growing the engine from 1,423 to 1,465 lines. It changes staged-size accounting, backup verification of the private stage, the existing journal writer, publication and the same-process scratch handoff. It introduces a staging loop and a batch-rename loop inside the existing transaction. It uses the same command set and persisted format. The focused tests and benchmark were extended around those boundaries. The maintained scanner test now checks the ordering in the batch rename loop. The R1 report and existing checkout changes remain intact.

Luna review should trace the two index readers against the same trusted cohort, the 58 exact records in each journal rewrite, the low-space fallback and the common sibling flush. Verify that backup READY and durable intent precede staging, and that the verified-data barrier precedes committing. Review pre-rename ownership and legacy scans, including the second-rename race. Check known mixed rename states and refusal on unknown preflush scratch. The device performance and durability gate includes exact-firmware shell and applet behavior, flash headroom under genuine JFFS2 writeback and cleanup, and separately authorized storage evidence.

Use an explicit test-only sync function calling an absolute mock when profiling the target shell. A preliminary host BusyBox ash probe resolved sync as an applet despite PATH shadowing. The corrected isolated host probe explicitly bound every sync to the counter. A copy of the candidate adapted for that probe may exercise shell behavior, while the measured host comparison uses exact candidate bytes without that adaptation.

The validated immutable snapshot must carry the eventual candidate bytes to pass the existing exact executable identity check. The old immutable commit establishes the reference checkpoint and cannot supply the R2 executable.
