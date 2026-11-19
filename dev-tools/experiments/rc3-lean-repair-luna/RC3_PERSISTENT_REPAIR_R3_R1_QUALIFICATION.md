# RC3 standalone Emergency Repair R3-R1 qualification

## A. Verdict

**PASS for host qualification, pending independent Luna QC.** The two defects reproduced on the preserved bytes. R3-R1 refused the same fixtures without replacing an installed file. XT8 timing, exact vendor applets and JFFS2 power-loss behavior remain unqualified.

## B. Identities and scope

The checkout is `pre_v0.53.29-RC3-repair-test` at `321d5afac2b4de9441846014e9dddb80e701ae8d`, with origin `git@github.com:r80xcore/mervlan.git`. All requested identities matched before editing. The original R3 candidate and accepted R2 executable were preserved as byte-exact evidence. [Initial status](../../evidence/rc3-r3-r1-host-qualification/git-status-initial.txt)

| Artifact | SHA-256 |
| --- | --- |
| Accepted R2 Repair | `acdb9ffa862cfda43019f77ac6749eb670ea0f48f584bae543727afc1b96d57e` |
| Original R3 Repair | `c3a56c942f3551c1d5fe0c2534d96b57144e0b3a1dba3365c3c18ac28da732b9` |
| Corrected R3-R1 Repair | `94008a3215dd6c94bb2d539b9c0bfa931f7ef4c0b86fcc781cdee60cc255ce10` |
| Trusted manifest | `3475336656abe00c73d86526f7a385ff7b7328abd9c2a4d3b58f008e40d30c15` |
| Normal Update | `7bb9dcdd0593d156f1a0d7ff15002790a3fff3759c655d7513251d0038440fff` |
| R3-to-R3-R1 patch | `ca4e5a1583b8b45776207f973d1b120bb76c9f78581e38121ef21acd20e5e679` |

| File | Change in this round |
| --- | --- |
| `functions/update_mervlan_repair.sh` | Private classification record, selective prepublication revalidation, and absolute writer path handling |
| `dev-tools/tests/local/repair_sequential_scan_contract_test.sh` | Absolute path, exception, malformed proc and sequential-observation regressions |
| `dev-tools/experiments/rc3-lean-repair-luna/tests/test_standalone_persistent_repair.py` | Independent race injectors, late noncanonical writer, action parent, content-only repair and backup interruption fixtures |
| `dev-tools/experiments/rc3-lean-repair-luna/tests/benchmark_r3_repair.py` | Three-engine rotating comparisons using the preserved R3 executable |
| `dev-tools/experiments/rc3-lean-repair-luna/RC3_PERSISTENT_REPAIR_R3_R1_QUALIFICATION.md` | This report |
| `dev-tools/evidence/rc3-r3-r1-host-qualification/` | Sources, focused patch, status and host evidence |

Production changes are confined to standalone Repair. The R3 report, earlier evidence and unrelated working-tree edits were preserved. [Exact patch](../../evidence/rc3-r3-r1-host-qualification/r3-to-r3-r1.patch)

## C. Selective classification race

Original R3 checked whether a target still belonged in the replacement set. Two different invalid contents could satisfy that same condition, so backup silently adopted the later version. The Luna `df` seam was recreated as described. It writes same-length bad B over bad A in `mervlan.asp` at the backup-root capacity check. The original R3 fixture committed and saved B as the original. R3-R1 exited nonzero and left B where the injector wrote it. Repair created no READY marker, flush or installed replacement in that fixture. [Original R3 reproduction](../../evidence/rc3-r3-r1-host-qualification/luna-df-original.log), [Corrected regression results](../../evidence/rc3-r3-r1-host-qualification/targeted-dash.log)

The private workspace holds one ordered record per manifest target. Each record includes the relative path, presence, original mode and size, original SHA-256 for present targets, approved source SHA-256 and selection bit. Complete byte comparison allows equal content to reuse the approved digest. A differing original gets its own digest at classification and again when captured. Backup independently compares current staged identity, installed state and selection to the record. The pre-READY check compares the entire installed cohort against the digest-verified backup, so a later copy can reveal changes to a path already copied. The normal per-rename installed-state check still uses the backup index. The no-op path repeats full verification and ownership checks and creates no persistent transaction.

| Injection | Corrected result |
| --- | --- |
| Backup-capacity `df`: invalid A to different invalid B of the same length | Refused before READY |
| Backup-capacity `df`: selected invalid to correct | Refused before READY |
| Backup-capacity `df`: selected mode mismatch to a different wrong mode | Refused before READY |
| Backup-capacity `df`: selected present to absent and selected absent to present | Both refused before READY |
| Backup-capacity `df`: unselected content or mode changes | Both refused before READY |
| Backup-capacity `df`: present to symlink | Refused before READY |
| Backup-capacity `df`: final classified entry changes | Refused before READY |
| During backup: selected content changes and an earlier, already copied unselected target changes | Both refused before READY |
| Mock sibling flush before the first rename: selected same-length content changes | Refused publication and preserved the interrupted journal |

Fixtures assert unchanged bytes, modes and inodes on paths outside the injector, no committed journal on refusal and preserved protected data. A separate control verified one content-only repair in addition to the mode-only, zero, ten, 58 and missing-target cases.

## D. Absolute writer path

The original absolute pass used canonical string equality. `functions/./heal_event.sh` missed that pass and was ineligible for the relative pass. R3-R1 applies the existing lexical dot-component normalization to plausible absolute arguments whose basename is in the recognized writer inventory. Ambiguous traversal and malformed candidates are refused. A normalized absolute match can block a writer. Only the previous recognized spellings can qualify for dispatcher exceptions. Sequential PID inspection, fresh cmdline reads, the inventory and generation checks remain in the existing scanner.

The historical R2 and R3 scanner fixtures both observed the injected `/./` command line and returned clear. R3-R1 refused it in initial admission, after acquisition and at publication. Other regressions passed for canonical absolute paths, multiple dot components including the prefix, bare and relative paths, an outside unknown script, `..`, repeated slashes, missing, unreadable and symlinked cmdlines, and malformed proc entries. The installed publication fixture refused a late noncanonical writer after the first rename. Canonical read-only and authenticated parent dispatchers still passed, and alternate spellings and a mixed dispatcher/writer command line refused. [Corrected scanner](../../evidence/rc3-r3-r1-host-qualification/scanner-corrected.log), [Historical R2](../../evidence/rc3-r3-r1-host-qualification/scanner-r2.log), [Historical R3](../../evidence/rc3-r3-r1-host-qualification/scanner-original-r3.log), [Action parent](../../evidence/rc3-r3-r1-host-qualification/action-parent.log)

## E. Recovery and durability

Persistent format 1, canonical ownership, source authentication, final full-cohort verification and the six high-headroom flushes retain their existing behavior. The low-storage path passed with 63 mock flushes for 58 replacements and 15 for ten selected replacements. The no-op used zero flushes.

Both repair modes exercised interruption before READY, during backup, after durable intent, immediately before and after a rename, with partial publication and during commit. An interrupted backup retained a prepared journal and no READY. Independent Recovery refused that incomplete bundle. Synchronous rollback and independent Recovery after private workspace loss passed. Corrupt backup payloads, index and journal refused, as did unknown installed and sibling states. The accepted byte-exact R2 helper restored an interrupted ten-target R3-R1 selective transaction, including absent-state handling, while untouched correct paths retained their original bytes, modes and inodes. Protected settings, SSH fixture trust and MAC Shield state were preserved. [Backup interruption](../../evidence/rc3-r3-r1-host-qualification/interrupted-backup.log)

## F. Host regression testing

Ubuntu 26.04.1 x86-64 exercised Dash and BusyBox 1.37.0 ash. Exact Dash execution used fixture archives containing the same engine bytes as the running executable. The BusyBox fixture adaptation changes the same-PID handoff to host ash and routes fixture applet shims explicitly. Its archive contains the exact adapted bytes and exercises the existing executable identity check. The work used isolated fixtures with mock sync.

The maintained gate passed 112 shell tests and five Node tests with zero failures, including 36 standalone default-Dash tests. Standalone selective Dash and both host BusyBox modes each passed their 35-case suites. Focused reruns passed the additional during-backup kill, authenticated parent spelling and all-record assertions under both shells. The expected historical scanner failures identify the original bypass. The original R3 capacity-injection run succeeds and commits B, which is the reproduced failure condition. The corrected fixture independently verifies all 58 private classification records against their initial sizes, modes, presence and SHA-256 values. [Dash selective](../../evidence/rc3-r3-r1-host-qualification/dash-selective.log), [BusyBox full](../../evidence/rc3-r3-r1-host-qualification/busybox-full.log), [BusyBox selective](../../evidence/rc3-r3-r1-host-qualification/busybox-selective.log), [Classification records](../../evidence/rc3-r3-r1-host-qualification/classification-records.log)

Reproduction commands from the checkout root follow.

```sh
E=dev-tools/evidence/rc3-r3-r1-host-qualification
T=dev-tools/experiments/rc3-lean-repair-luna/tests
PYTHONDONTWRITEBYTECODE=1 sh dev-tools/tests/local/run_all.sh
PYTHONDONTWRITEBYTECODE=1 FULL=0 python3 "$T/test_standalone_persistent_repair.py"
PYTHONDONTWRITEBYTECODE=1 MERVLAN_TEST_BUSYBOX=1 FULL=1 python3 "$T/test_standalone_persistent_repair.py"
PYTHONDONTWRITEBYTECODE=1 MERVLAN_TEST_BUSYBOX=1 FULL=0 python3 "$T/test_standalone_persistent_repair.py"
sh dev-tools/tests/local/repair_sequential_scan_contract_test.sh
sh dev-tools/tests/local/repair_sequential_scan_contract_test.sh "$E/original-r3.sh"
sh dev-tools/tests/local/repair_sequential_scan_contract_test.sh "$E/accepted-r2.sh"
PYTHONDONTWRITEBYTECODE=1 python3 "$T/benchmark_r3_repair.py" \
  --original-r3 "$E/original-r3.sh" --runs 3 --processes 32
sh -n functions/update_mervlan_repair.sh
busybox sh -n functions/update_mervlan_repair.sh
sh -n dev-tools/tests/local/repair_sequential_scan_contract_test.sh
busybox sh -n dev-tools/tests/local/repair_sequential_scan_contract_test.sh
git diff --check
git apply --reverse --check "$E/r3-to-r3-r1.patch"
```

The historical scanner invocations are expected to exit 1. Run the original-R3 capacity-race reproducer from the same checkout root.

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$T" python3 - "$E/original-r3.sh" <<'PYCODE'
import sys
from pathlib import Path
import test_standalone_persistent_repair as suite
suite.ENGINE = Path(sys.argv[1]).resolve()
suite.classification_race('invalid-to-invalid', historical=True)
PYCODE
```

## G. Performance requalification

The exact Dash engines ran from invocation through exit for three rotating triples with 32 synthetic process entries. The rotation gives each engine one first, second and third position in every workload. The mocked immutable archives use the same Git cohort and the matching exact engine as the single variant member. One mismatch is mode-only. Larger damaged fixtures add a missing target and same-size content damage. R2 republishes 58 files in every workload. The benchmarks use mock sync and compare host CPU and filesystem costs only.

| Workload | Engine | Observed wall time (s) | Median (s) | Classification (s) | Hash launches | Scanner calls | Replacements | Persistent payload bytes | Mock flushes |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Default full, all correct | R2 | 28.06, 13.28, 13.90 | 13.90 | — | 412 | 61 | 58 | 6,896,262 | 6 |
| Default full, all correct | R3 | 25.03, 19.37, 11.82 | 19.37 | — | 299 | 61 | 58 | 6,911,061 | 6 |
| Default full, all correct | R3-R1 | 25.18, 11.16, 14.74 | 14.74 | — | 299 | 61 | 58 | 6,921,222 | 6 |
| Selective no-op | R2 | 15.02, 12.75, 20.00 | 15.02 | — | 412 | 61 | 58 | 6,896,262 | 6 |
| Selective no-op | R3 | 2.38, 2.38, 4.40 | 2.38 | 1.124 | 0 | 3 | 0 | 0 | 0 |
| Selective no-op | R3-R1 | 2.65, 2.64, 2.87 | 2.65 | 1.658 | 2 | 3 | 0 | 0 | 0 |
| Selective, one mode mismatch | R2 | 27.89, 25.12, 21.92 | 25.12 | — | 412 | 61 | 58 | 6,896,263 | 6 |
| Selective, one mode mismatch | R3 | 11.21, 11.97, 11.18 | 11.21 | 1.044 | 128 | 4 | 1 | 3,683,399 | 6 |
| Selective, one mode mismatch | R3-R1 | 11.37, 13.68, 11.70 | 11.70 | 1.632 | 71 | 4 | 1 | 3,690,173 | 6 |
| Selective, ten mismatches | R2 | 26.50, 25.03, 26.25 | 26.25 | — | 408 | 61 | 58 | 6,857,747 | 6 |
| Selective, ten mismatches | R3 | 13.63, 14.14, 13.54 | 13.63 | 1.050 | 153 | 13 | 10 | 4,705,669 | 6 |
| Selective, ten mismatches | R3-R1 | 15.12, 15.10, 14.21 | 15.10 | 1.634 | 113 | 13 | 10 | 4,712,443 | 6 |
| Selective, 58 mismatches | R2 | 24.31, 27.87, 27.41 | 27.41 | — | 408 | 61 | 58 | 6,857,747 | 6 |
| Selective, 58 mismatches | R3 | 23.22, 25.58, 25.50 | 25.50 | 1.479 | 297 | 61 | 58 | 6,872,546 | 6 |
| Selective, 58 mismatches | R3-R1 | 27.40, 28.37, 27.82 | 27.82 | 2.782 | 353 | 61 | 58 | 6,882,707 | 6 |

Classification time and operation counts come from the separate instrumented run of each workload. The whole-run medians use exact engine bytes without profiling wrappers. Hash counts include any capability probe. Persistent payload totals include the original payload, recovery helper, index, READY, journal image writes and publication siblings. Filesystem metadata and physical flash traffic are outside that count.

- Selective no-op changed from 2.38 to 2.65 seconds (+11.1%).
- Selective, one mode mismatch changed from 11.21 to 11.70 seconds (+4.4%).
- Selective, ten mismatches changed from 13.63 to 15.10 seconds (+10.9%).
- Selective, 58 mismatches changed from 25.50 to 27.82 seconds (+9.1%).

The no-op added 0.27 seconds median while keeping zero persistent writes and flushes. The dense case had the largest absolute selective increase, 2.32 seconds. Its instrumented classification rose from 1.479 to 2.782 seconds, and digest launches rose from 297 to 353. The workload has 56 content mismatches, one mode-only mismatch, and one missing target. Default-full wall times varied across trials, while both R3 variants recorded the same 299 hash launches, 61 scans and six flushes.

The selective correction adds one ordered stage-digest pass and exact original-state capture. The backup loop can reuse the staged digest for originally identical content after a fresh comparison. The pre-READY recheck adds one byte and mode comparison per present target. When every original differs, each needs an additional classification hash and there is no reuse of the approved digest for those originals. With an OpenSSL wrapper that rejects reverse format, the exact corrected no-op passed with 59 launches including the failed probe, and full repair passed with 413. Both used two synthetic PIDs. [OpenSSL fallback](../../evidence/rc3-r3-r1-host-qualification/openssl-fallback.log)

The smallest follow-up optimization if the selective classification cost matters on hardware is to retain the per-target staged sizes already measured during staging and reuse those sizes only after complete byte equality. Independent installed-state validation at backup capture and separate hashing for differing contents would remain in place.

[Raw benchmark data](../../evidence/rc3-r3-r1-host-qualification/benchmarks.json)

## H. Evidence

The evidence directory contains the byte-exact predecessors and corrected candidate, focused patch, benchmark JSON, fault logs and both working-tree status captures. The focused patch passed a reverse-application check. [Artifacts and checksums](../../evidence/rc3-r3-r1-host-qualification/)

## I. Remaining risks

- The BusyBox qualification used host ash and explicit fixture applet shims. The device uses vendor BusyBox 1.25.1. The scanner change uses POSIX shell lexical operations and adds no device utility.
- The exact fixture tested both native batch output and the existing per-file OpenSSL fallback. Vendor OpenSSL command availability and output compatibility remain unqualified. A fallback no-op must compute the approved source digests individually.
- The transaction retains the existing observation and mutation boundaries. The correction detects changed state between classification and backup and verifies selected targets against the backup index before renaming. It does not establish an atomic filesystem snapshot against an unrelated writer.
- Host faults and mocked flush counts model transaction ordering. Actual XT8 latency, flash write amplification and power-loss recovery remain unqualified.

## J. Luna QC recommendation

The exact R3-R1 bytes above are ready for independent host QC. Re-run the original capacity-wrapped mutation on those bytes, then exercise the already-copied target and final-entry races. Compare canonical and alternate-spelled dispatcher commands through the existing exception checks. Verify the exact R2 helper against a sparse R3-R1 bundle interrupted with an absent target among the published files. The evidence directory contains the two predecessors, focused patch and raw outputs for that review. [Host evidence](../../evidence/rc3-r3-r1-host-qualification/)
