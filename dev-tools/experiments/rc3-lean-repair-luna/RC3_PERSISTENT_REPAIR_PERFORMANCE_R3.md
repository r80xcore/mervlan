# MerVLAN RC3 standalone Emergency Repair R3

## Engineering verdict

**PARTIAL.** R3 implements full and selective Repair in the existing standalone engine and retains independent format-1 Recovery. Selective host qualification passed, and the default full publication phase improved in both host comparisons. Default full end-to-end timing was mixed across runs. The XT8 120-second target and 60-second stretch target remain unqualified. This work used isolated host fixtures and mocked flushes. The November 18 R2 XT8 result supplied for this assignment was 408.141 seconds end to end, with approximately 331 seconds in publication. Those intervals do not isolate the scanner, flash, storage reads or utility startup as the device bottleneck.

## Baseline and artifacts

The checkout branch was `pre_v0.53.29-RC3-repair-test` at `321d5afac2b4de9441846014e9dddb80e701ae8d`. Origin pointed to `git@github.com:r80xcore/mervlan.git`. The working Repair, manifest and normal Update matched the requested identities before editing. The manifest has two header lines and 58 targets. The byte-exact R2 engine was extracted from the accepted commit for testing. The historical copy named `update_mervlan_repair_R2_accepted.sh` under the experiment's candidates directory has a different digest. The benchmark takes R2 directly from Git.

| Artifact | SHA-256 |
| --- | --- |
| Accepted R2 Repair | `acdb9ffa862cfda43019f77ac6749eb670ea0f48f584bae543727afc1b96d57e` |
| R3 Repair | `c3a56c942f3551c1d5fe0c2534d96b57144e0b3a1dba3365c3c18ac28da732b9` |
| Trusted manifest | `3475336656abe00c73d86526f7a385ff7b7328abd9c2a4d3b58f008e40d30c15` |
| Normal Update | `7bb9dcdd0593d156f1a0d7ff15002790a3fff3759c655d7513251d0038440fff` |
| Focused production patch | `31f803cfaefcda1889f8aa848e444403c62384a1d442d3f3784709a8cad19f81` |

The starting checkout had modifications in three developer guides, the XT8 trial note and `functions/mervlan_boot_wrap.sh`. It also had untracked attachments, historical audit and test material, and boot test fixtures. The R3 edits leave those files and the existing checked-in R2 evidence intact. The focused production patch, exact baseline and initial and final porcelain status are in the evidence directory. [Host evidence](../../evidence/rc3-r3-host-qualification-20261118/)

## Implementation

| Modified or added file | Change |
| --- | --- |
| `functions/update_mervlan_repair.sh` | Selective mode, verified no-op, backup digest batching, cheaper local ownership validation and scanner parsing |
| `dev-tools/tests/local/repair_sequential_scan_contract_test.sh` | Fresh per-shell fixtures and expanded R2/R3 scanner comparisons |
| `dev-tools/experiments/rc3-lean-repair-luna/tests/test_standalone_persistent_repair.py` | Sparse and full repairs, recovery, fault injection, mode and shell coverage |
| `dev-tools/experiments/rc3-lean-repair-luna/tests/benchmark_persistent_repair.py` | Parameterized archive reference and phase instrumentation reused by the R3 comparison |
| `dev-tools/experiments/rc3-lean-repair-luna/tests/benchmark_r3_repair.py` | Alternating R2/R3 workloads, independent profiles and scanner probes |
| `dev-tools/experiments/rc3-lean-repair-luna/RC3_PERSISTENT_REPAIR_PERFORMANCE_R3.md` | Qualification and Luna handoff |

- Unset `FULL` and explicit `FULL=1` republish all 58 files. Both modes use the existing immutable download, compiled manifest, exact executable comparison, same-process handoff and complete staged syntax and content checks. A Repair invocation with any other value besides `0` or `1`, including an empty value, is rejected. Recovery derives its operation from persisted evidence independently of `FULL`.
- `FULL=0` classifies every target under action, maintenance and Manager ownership and after a legacy-writer scan. It distinguishes missing files, byte mismatches and mode mismatches from comparison errors or unsafe paths and objects. The 58-entry backup index must agree with the selection before publication. Each selected target retains its own old-state, ownership, legacy-writer and post-rename checks. Final verification checks content and mode across the full cohort.
- A zero-change classification checks transaction admission, repeats preflight and full installed-state verification under ownership, then releases the locks. A fresh no-op creates no backup root, persistent transaction or sibling and performs zero installed replacements and global flushes.
- A non-no-op retains a complete format-1 backup and journal. Journal intent and completion still cover the 58-entry cohort. The private selection only drives sibling preparation and publication. Recovery recognizes unchanged originals by bytes and mode and skips restoring them. Fast-path admission uses the selected bytes for sibling headroom. The low-space path keeps one sibling and one corresponding flush at a time.
- The scanner retains fresh sequential reads and the established path, identity and dispatcher logic. When the complete successful read contains no `.sh` substring, no current writer path can match, so both argument passes can be skipped. The scanner still launches one `tr` for each inspected PID. Upstream BusyBox 1.25.1 ash does not implement the delimiter option on `read`. Using it would introduce an unqualified firmware dependency, and scanning a cached candidate list would move observations earlier. [BusyBox 1.25.1 ash source](https://raw.githubusercontent.com/mirror/busybox/1_25_1/shell/ash.c#L12224)
- Ownership checks read the running shell's generation once and parse each canonical owner file freshly against its expected PID, start time and nonce. The authenticated action-parent path and release keep their independent generation and liveness checks. Size reads check `wc` directly and trim spaces in shell.
- Each persistent backup pass verifies its canonical ordered digest/path output in one invocation when the available backend supports the expected format. OpenSSL's reverse format is capability-checked and has the original per-path fallback. Both passes still check file type, size and mode for every original. Per-path hashing around publication, the READY digest bindings and complete final byte comparisons remain in place. Backend selection is a capability decision within the process. File and process state is read again at every existing boundary.

## Durability and format-1 compatibility

The fast path retains six flushes in this order.

1. Backup payload, index, helper and prepared journal.
2. READY with manifest, index and helper digests.
3. Complete publishing-intent journal.
4. Verified same-directory replacement siblings.
5. Verified installed files and rename effects.
6. Committed journal.

The low-space path uses the same sequence with one sibling flush per replacement, giving 63 flushes for 58 replacements and 15 for ten. After interruption, the entire cohort and known scratch states must be classified before Recovery mutates an installed path. An unrecognized partial sibling, unknown installed bytes or invalid evidence still causes refusal. The exact R2 helper was tested as a separately trusted executable against a sparse R3 publishing bundle while the R3 helper recorded by READY stayed in place. Tests compare pre-run bytes, modes and absent states, and retain the inodes of untouched correct paths.

## Scanner measurements

Each sample is elapsed time across five complete scans divided by five. The exact engines alternated order for three samples per workload. Fixtures contained ordinary two-argument processes with no writer candidates. These samples include shell startup amortized over five scans, file type and readability checks, every sequential cmdline read and any shell parsing. There was concurrent host test activity. The 140-PID Dash samples show substantial variability.

| Shell and fixture | R2 median (observed range) | R3 median (observed range) |
| --- | ---: | ---: |
| Dash, 64 PIDs | 264 ms (255–316) | 250 ms (248–276) |
| Dash, 140 PIDs | 593 ms (591–605) | 693 ms (567–735) |
| BusyBox 1.37.0 ash, 64 PIDs | 93.4 ms (90.4–95.2) | 74.9 ms (74.7–77.0) |
| BusyBox 1.37.0 ash, 140 PIDs | 189.0 ms (185.4–207.4) | 154.5 ms (148.6–154.6) |

An exploratory test replacing the direct command substitution with an explicit `exec tr` had no consistent benefit across the large process lists. It was dropped. The supported scanner change is a reduction in parsing work and leaves launch count unchanged. Both exact engines pass the same sequential late-writer, bare and normalized relative path, read-only exception and unavailable-cmdline regressions in Dash and host BusyBox ash. [Scanner data](../../evidence/rc3-r3-host-qualification-20261118/scanner-final.json)

## End-to-end performance

The benchmark ran the exact engines from invocation through process exit under Dash. Each workload used three alternating pairs and 140 synthetic processes. The Git snapshot fixtures vary only in the Repair executable member needed for each engine to authenticate its own bytes. Each damaged fixture includes a mode-only mismatch, and workloads with multiple defects include a missing target and same-size bad content. R2 ignores `FULL` and republishes everything in each workload. Each timed run verifies the resulting files, modes, inode changes, protected state and commit or no-op state. Host load varied during the run.

| Workload | R2 observed s | R2 median s | R3 observed s | R3 median s | R3 vs R2 |
| --- | --- | ---: | --- | ---: | ---: |
| Default full, all correct | 23.27, 21.43, 25.69 | 23.27 | 24.94, 24.28, 19.60 | 24.28 | +4.3% |
| Explicit full, ten defects | 21.99, 39.98, 28.88 | 28.88 | 19.73, 23.15, 20.11 | 20.11 | -30.4% |
| Selective, all correct | 30.46, 37.22, 28.97 | 30.46 | 4.20, 3.45, 3.18 | 3.45 | -88.7% |
| Selective, one mode defect | 42.08, 32.97, 42.32 | 42.08 | 12.59, 12.18, 12.31 | 12.31 | -70.7% |
| Selective, ten defects | 41.91, 40.46, 41.60 | 41.60 | 16.61, 16.68, 16.67 | 16.67 | -59.9% |
| Selective, 58 defects | 29.01, 40.89, 45.51 | 40.89 | 32.42, 25.70, 43.55 | 32.42 | -20.7% |

The default-full workload was then repeated for three alternating pairs with the same 140-process fixture. R2 took 46.18, 45.48 and 45.50 seconds. R3 took 40.78, 40.84 and 41.13 seconds. The median improved from **45.50 to 40.84 seconds (10.2%)**, and the READY-to-last-replacement median improved from **33.82 to 30.10 seconds (11.0%)**. Absolute times differed markedly between benchmark windows. The initial comparison's 4.3% total slowdown and the repeat's 10.2% improvement establish variability in total host wall time. The default-full publication interval improved in both windows. [Default-full repeat data](../../evidence/rc3-r3-host-qualification-20261118/benchmark-default-repeat.json)

### Phase wall times

Seconds shown are medians of the exact, uninstrumented runs. The second phase ends at READY, or at classification on the no-op. The publication interval is READY through the last replacement. The final interval includes full verification, ownership release and process cleanup, plus the data and commit barriers when there was a transaction.

| Workload | Engine | Invocation to staged | Staged to READY or select | READY to last replaced | Final interval |
| --- | --- | ---: | ---: | ---: | ---: |
| Default full, all correct | R2 | 1.11 | 3.66 | 16.93 | 0.85 |
| Default full, all correct | R3 | 1.49 | 3.57 | 15.46 | 0.74 |
| Explicit full, ten defects | R2 | 1.94 | 5.09 | 20.62 | 1.13 |
| Explicit full, ten defects | R3 | 1.14 | 3.29 | 14.83 | 0.77 |
| Selective, all correct | R2 | 1.27 | 3.89 | 23.76 | 0.89 |
| Selective, all correct | R3 | 1.43 | 1.23 | — | 0.79 |
| Selective, one mode defect | R2 | 1.94 | 7.25 | 31.10 | 1.49 |
| Selective, one mode defect | R3 | 1.94 | 7.13 | 1.85 | 1.37 |
| Selective, ten defects | R2 | 1.91 | 7.13 | 31.14 | 1.53 |
| Selective, ten defects | R3 | 2.00 | 7.46 | 5.94 | 1.37 |
| Selective, 58 defects | R2 | 1.41 | 6.36 | 31.69 | 1.42 |
| Selective, 58 defects | R3 | 1.91 | 6.47 | 24.81 | 1.52 |

### Profile and operation counts

One separately instrumented run per engine and workload recorded command launches and function elapsed times. The wrappers add process and logging overhead. Nested elapsed times overlap. Ownership time is aggregate `owner_ok` time, including the canonical owner file checks it invokes. Digest launches include the OpenSSL capability probe where present.

| Workload | Engine | Scans / s | Cmdline tr | Hash launches | owner_ok calls / s | Copies total / persistent | Replaces | Flushes | Journal validations / rewrites |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Default full, all correct | R2 | 61 / 18.51 | 8540 | 412 | 62 / 1.62 | 187 / 117 | 58 | 6 | 3 / 2 |
| Default full, all correct | R3 | 61 / 21.56 | 8540 | 299 | 62 / 1.40 | 187 / 117 | 58 | 6 | 3 / 2 |
| Explicit full, ten defects | R2 | 61 / 22.79 | 8540 | 408 | 62 / 1.95 | 186 / 116 | 58 | 6 | 3 / 2 |
| Explicit full, ten defects | R3 | 61 / 20.00 | 8540 | 297 | 62 / 1.29 | 186 / 116 | 58 | 6 | 3 / 2 |
| Selective, all correct | R2 | 61 / 22.34 | 8540 | 412 | 62 / 1.87 | 187 / 117 | 58 | 6 | 3 / 2 |
| Selective, all correct | R3 | 3 / 0.88 | 420 | 0 | 4 / 0.07 | 70 / 0 | 0 | 0 | 0 / 0 |
| Selective, one mode defect | R2 | 61 / 37.20 | 8540 | 412 | 62 / 3.23 | 187 / 117 | 58 | 6 | 3 / 2 |
| Selective, one mode defect | R3 | 4 / 2.32 | 560 | 128 | 6 / 0.24 | 130 / 60 | 1 | 6 | 3 / 2 |
| Selective, ten defects | R2 | 61 / 32.32 | 8540 | 408 | 62 / 2.69 | 186 / 116 | 58 | 6 | 3 / 2 |
| Selective, ten defects | R3 | 13 / 4.24 | 1820 | 153 | 15 / 0.31 | 138 / 68 | 10 | 6 | 3 / 2 |
| Selective, 58 defects | R2 | 61 / 40.95 | 8540 | 408 | 62 / 3.57 | 186 / 116 | 58 | 6 | 3 / 2 |
| Selective, 58 defects | R3 | 61 / 37.58 | 8540 | 297 | 63 / 2.50 | 186 / 116 | 58 | 6 | 3 / 2 |

These payload byte counts include repeated journal image writes. They exclude directory metadata, allocation rounding, write amplification and compression. Private temporary payload is the compressed archive, extracted cohort, staged cohort and protected snapshot combined. The phase metadata, lock files and utility memory are additional. Peak on-flash sibling bytes represent concurrently staged paths on the measured high-headroom path. Mock sync measures call count only. Syscall tracing was unavailable in the sandbox.

| Workload | Engine | Persistent payload bytes written | Journal image bytes written | Peak sibling bytes | Private temp payload bytes | Final / classification checks |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Default full, all correct | R2 | 6,896,262 | 6,047 | 3,405,520 | 9,451,231 | 58 / 0 |
| Default full, all correct | R3 | 6,911,061 | 6,047 | 3,410,453 | 9,462,408 | 58 / 0 |
| Explicit full, ten defects | R2 | 6,857,747 | 6,047 | 3,405,520 | 9,451,231 | 58 / 0 |
| Explicit full, ten defects | R3 | 6,872,546 | 6,047 | 3,410,453 | 9,462,408 | 58 / 0 |
| Selective, all correct | R2 | 6,896,263 | 6,047 | 3,405,520 | 9,451,231 | 58 / 0 |
| Selective, all correct | R3 | 0 | 0 | 0 | 9,462,408 | 58 / 58 |
| Selective, one mode defect | R2 | 6,896,263 | 6,047 | 3,405,520 | 9,451,231 | 58 / 0 |
| Selective, one mode defect | R3 | 3,683,399 | 6,047 | 182,790 | 9,462,408 | 58 / 58 |
| Selective, ten defects | R2 | 6,857,747 | 6,047 | 3,405,520 | 9,451,231 | 58 / 0 |
| Selective, ten defects | R3 | 4,705,669 | 6,047 | 1,243,576 | 9,462,408 | 58 / 58 |
| Selective, 58 defects | R2 | 6,857,747 | 6,047 | 3,405,520 | 9,451,231 | 58 / 0 |
| Selective, 58 defects | R3 | 6,872,546 | 6,047 | 3,410,453 | 9,462,408 | 58 / 58 |

For the default full workload, individual digest function time was 2.65 s for R2 and 2.11 s for R3. R3 does the two digest batches inside its backup-verification timings. The combined elapsed time of both backup-payload verification passes was 2.00 s and 1.31 s, respectively. Aggregate mode-check time was 2.91 s and 3.37 s. Both profiles counted 192 canonical owner record parses and 256 comparisons. The 62 ownership checks each remove three redundant self-generation reads in the self-owned fixture. Copying and renames are included in the stage, backup and publication phase measurements. These profiles do not resolve each file operation's elapsed time separately.

The strongest mechanistic reductions are the two backup digest batches, removal of redundant self-generation reads and space-removal processes, and reduced sparse publication. File copying remains substantial for any non-no-op because the format-1 backup preserves the complete original cohort. The 61 full-path legacy scans and per-PID tool startup remain visible. Upstream BusyBox 1.25.1 also counts `wc -c` input by reading bytes, so host metadata timings with the host `wc` do not establish the cost of repeated router size checks. [BusyBox 1.25.1 wc source](https://raw.githubusercontent.com/mirror/busybox/1_25_1/coreutils/wc.c#L118)

Run the comparison and scanner probe from the checkout root.

```sh
R3_DIR=dev-tools/experiments/rc3-lean-repair-luna/tests
PYTHONDONTWRITEBYTECODE=1 python3 "$R3_DIR/benchmark_r3_repair.py" --runs 3
PYTHONDONTWRITEBYTECODE=1 python3 "$R3_DIR/benchmark_r3_repair.py" --runs 3 --case default_correct
PYTHONDONTWRITEBYTECODE=1 python3 "$R3_DIR/benchmark_r3_repair.py" --scanner-only
```

[Exact timing and profile data](../../evidence/rc3-r3-host-qualification-20261118/benchmark-final.json)

## Functional qualification

Host Ubuntu 26.04.1 x86-64 ran Dash and BusyBox 1.37.0 ash. The maintained local gate passed 112 shell tests and five Node tests with zero failures. Both shell syntax checks passed for the engine and scanner test. Python source parses, the production patch reverse-check and `git diff --check` passed.

| Scope | Coverage and outcome |
| --- | --- |
| Exact candidate in Dash | The local gate's default-mode standalone suite and the separate selective suite each passed 32 tests. The additional unknown installed-state refusal passed in both modes. The R3 additions passed no-op, sparse replacement counts and inode checks, stale no-op revalidation, same-size content damage, mode-only correction, missing-file recovery, refusal on unsafe states and mock resource limits. A separate rerun passed the expanded durable-intent interruption matrix in both modes. |
| BusyBox ash | 31 cases passed in each mode, plus separate predecessor preservation and unknown installed-state cases. The fixture adaptation chooses BusyBox for same-PID re-exec and explicitly routes applet fault injectors to private mocks. The fixture archives contain the exact adapted executable and retain the byte equality check. |
| Recovery | Both repair modes exercised pre-READY and post-READY loss, durable intent, sibling creation and flush, immediately before and after a rename, partial publication, failed final verification, interrupted commit, synchronous rollback and independent Recovery. Backup, index, READY, helper and journal corruption refused. Unknown scratch and unknown installed bytes also refused. Mixed-state recovery after private workspace loss passed for the candidate, and the exact R2 helper restored a sparse R3 transaction. |
| Protected and predecessor state | Protected settings, placeholder SSH trust, MAC Shield and other fixture state were retained. A real R2 committed bundle and a digest-valid R1-style journal fixture remained byte- and inode-identical across a later R3 repair. The R1 fixture models the older record order. |
| Storage fallback | Full 58-target fallback used 63 mock flushes. Sparse ten-target fallback used 15 and left correct targets' inodes in place. Headroom refusal covered memory, temporary and destination floors. |
| Hash fallback | A wrapper rejected the OpenSSL `-r` probe. The exact candidate completed full repair using one failed probe and 412 individual digest launches. |

Reproduction commands from the checkout root follow.

```sh
R3_DIR=dev-tools/experiments/rc3-lean-repair-luna/tests
PYTHONDONTWRITEBYTECODE=1 sh dev-tools/tests/local/run_all.sh
sh dev-tools/tests/local/repair_sequential_scan_contract_test.sh
sh dev-tools/tests/local/repair_sequential_scan_contract_test.sh   dev-tools/evidence/rc3-r3-host-qualification-20261118/r2-engine.sh
PYTHONDONTWRITEBYTECODE=1 FULL=1 python3 "$R3_DIR/test_standalone_persistent_repair.py"
PYTHONDONTWRITEBYTECODE=1 FULL=0 python3 "$R3_DIR/test_standalone_persistent_repair.py"
PYTHONDONTWRITEBYTECODE=1 MERVLAN_TEST_BUSYBOX=1 FULL=1   python3 "$R3_DIR/test_standalone_persistent_repair.py"
PYTHONDONTWRITEBYTECODE=1 MERVLAN_TEST_BUSYBOX=1 FULL=0   python3 "$R3_DIR/test_standalone_persistent_repair.py"
sh -n functions/update_mervlan_repair.sh
busybox sh -n functions/update_mervlan_repair.sh
sh -n dev-tools/tests/local/repair_sequential_scan_contract_test.sh
busybox sh -n dev-tools/tests/local/repair_sequential_scan_contract_test.sh
git diff --check
```

Use `MERVLAN_TEST_NAMES` with a comma-separated list of test names for the focused reruns. [Test evidence](../../evidence/rc3-r3-host-qualification-20261118/)

## Remaining risks and Luna QC

- The short-circuit improves parsing work on ordinary command lines. Per-PID `tr` startup and each new full scan remain in the mutation path. An exact-firmware operation profile would be needed to attribute that cost separately from OpenSSL, file metadata, copying and JFFS2 writeback. A verified observation is still subject to the original interval between scan and rename.
- Backup and journal flush ordering is modelled with phase-specific faults. Host filesystems and mock flushes cannot establish XT8 JFFS2 behavior after power loss, nor do they establish actual flash or RAM headroom. The complete backup remains the main fixed persistent write for sparse changes.
- Luna should verify the candidate SHA-256 and focused patch above, then reproduce the exact-byte fixture comparison and sparse interruption tests. Trace the private selection against both index cursors, confirm the pre-rename checks when a selected target becomes correct or a writer arrives, and inspect the validated backup hash ordering and its per-file fallback on capability failure. Review mixed-state handling and untouched inodes with both recovery engines. The eventual immutable source used for Repair must contain the exact candidate bytes.
- Scope of this evidence is host implementation and qualification. The exact candidate is available in the working tree for offline independent review.
