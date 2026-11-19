# RC3 standalone Emergency Repair R3-R2 qualification

## A. Verdict

**PASS for the focused host correction.** R3-R2 rejects extra and malformed staged digest output before accepting a selective classification. It is ready for independent Luna QC. Exact XT8 firmware, timing and flash behavior remain unqualified.

## B. Verified identities and files

Branch `pre_v0.53.29-RC3-repair-test` was at `321d5afac2b4de9441846014e9dddb80e701ae8d`. Origin identified `r80xcore/mervlan`. The committed R2 engine, original R3, working R3-R1, trusted manifest and normal Update all matched the requested identities before editing. [Initial working-tree status](../../evidence/rc3-r3-r2-host-qualification/git-status-initial.txt)

| Artifact | SHA-256 |
| --- | --- |
| Accepted R2 Repair | `acdb9ffa862cfda43019f77ac6749eb670ea0f48f584bae543727afc1b96d57e` |
| Original R3 Repair | `c3a56c942f3551c1d5fe0c2534d96b57144e0b3a1dba3365c3c18ac28da732b9` |
| Preserved R3-R1 | `94008a3215dd6c94bb2d539b9c0bfa931f7ef4c0b86fcc781cdee60cc255ce10` |
| Corrected R3-R2 | `d5aca0951a9bfb6134b97184ffbf975b2ea0da9cf6a3f55d88d7266f1571acd1` |
| Focused patch | `f67edc00ac0c23ac622046f470db3e95963a7a3d51e691fdd75d6cfa8f8ceb1c` |
| Trusted manifest | `3475336656abe00c73d86526f7a385ff7b7328abd9c2a4d3b58f008e40d30c15` |
| Normal Update | `7bb9dcdd0593d156f1a0d7ff15002790a3fff3759c655d7513251d0038440fff` |

| File | Change in this round |
| --- | --- |
| `functions/update_mervlan_repair.sh` | Build and compare the exact private staged digest output in `select_publication()` |
| `dev-tools/experiments/rc3-lean-repair-luna/tests/test_staged_hash_output.py` | Backend wrappers, exact-byte captures and host regression assertions |
| `dev-tools/experiments/rc3-lean-repair-luna/RC3_PERSISTENT_REPAIR_R3_R2_QUALIFICATION.md` | This report |
| `dev-tools/evidence/rc3-r3-r2-host-qualification/` | Preserved and corrected executables, focused patch, paired benchmark runner, captures and logs |

[Preserved R3-R1](../../evidence/rc3-r3-r2-host-qualification/original-r3-r1.sh) · [Corrected R3-R2](../../evidence/rc3-r3-r2-host-qualification/corrected-r3-r2.sh) · [Focused patch](../../evidence/rc3-r3-r2-host-qualification/r3-r1-to-r3-r2.patch)

## C. Root cause and correction

R3-R1 read 58 digest/path records in trusted manifest order and checked each line against the current path and backend separator. It accepted classification after the 58th line without validating the rest of `stage.hashes`.

R3-R2 writes the canonical bytes for each individually validated record into a second file in the private workspace. It checks the count and uses one `cmp -s` to require byte equality with the complete backend output. Reconstruction emits the validated hexadecimal digest, the backend-specific separator, the exact manifest path and one newline. The comparison covers bytes that shell `read` can discard, including NUL inside a record. It completes before status `SELECT` and before the engine enters either the no-op success or transaction creation path.

The original backend nonzero check still applies before record parsing. The selected-state record, scanner, source identity check, persistent index, recovery format and durability order are retained.

## D. Luna positive control

The exact preserved R3-R1 executable ran a correct 58-target fixture using a wrapped `sha256sum`. The wrapper emitted genuine digest output followed by one additional line. The capture verified the genuine output against all 58 source digests and observed the appended bytes. R3-R1 returned 0 and reported a selective no-op. The corrected executable returned 1 on the equivalent fixture, with zero installed replacements, persistent transactions or flushes. [Historical run and captures](../../evidence/rc3-r3-r2-host-qualification/historical/sha256sum/extra-invalid/) · [Corrected run and captures](../../evidence/rc3-r3-r2-host-qualification/matrix/sha256sum/extra-invalid/)

## E. Malformed-output matrix

Dash ran the exact corrected executable twice per corruption, once with each backend isolated in the fixture PATH. The tests independently reconstructed genuine expected backend output from the fixture bytes and trusted path order. For every refusal they compared the emitted capture to the intended byte edit and to the file the engine received. Every rejection returned 1 before SELECT or success, retained installed bytes, modes and inodes, and preserved protected files. The backup root and mock flush counter stayed absent.

| Injected condition | SHA-256 sum | OpenSSL reverse |
| --- | --- | --- |
| Extra valid digest record | Refused | Refused |
| Extra invalid record | Refused | Refused |
| Extra empty lines, two LF bytes | Refused | Refused |
| Trailing newline, one LF byte | Refused | Refused |
| Unterminated trailing record | Refused | Refused |
| Trailing NUL | Refused | Refused |
| Trailing binary data | Refused | Refused |
| Missing final record | Refused | Refused |
| Truncated final record | Refused | Refused |
| Duplicate record in the expected sequence | Refused | Refused |
| Reordered records | Refused | Refused |
| Digest reported with a wrong path | Refused | Refused |
| Nonhex digest | Refused | Refused |
| Valid bytes from a backend that exits nonzero | Refused | Refused |
| Embedded NUL in an expected record | Refused | Refused |
| Exactly 58 valid records, one newline per record | Accepted | Accepted |

The OpenSSL individual fallback probe was forced to fail. The resulting 58 individual staged hash calls produced the exact expected bytes, and the healthy no-op succeeded with zero persistent writes and flushes. [Matrix transcript](../../evidence/rc3-r3-r2-host-qualification/matrix.log) · [Raw matrix captures](../../evidence/rc3-r3-r2-host-qualification/matrix/) · [Byte-count and suffix audit](../../evidence/rc3-r3-r2-host-qualification/capture-audit.log) · [Fallback capture](../../evidence/rc3-r3-r2-host-qualification/individual-capture/)

## F. Previous-defect regressions

The preserved original R3 again accepted same-length invalid B at the capacity-check seam and saved B as the original. R3-R2 refused that seam as well as present-to-absent changes, changes to previously correct targets, mid-backup modifications to both the active target and an already copied target, and a selected-target change immediately before the rename checks. The focused run also exercised the remaining classification-race cases. [Historical capacity race](../../evidence/rc3-r3-r2-host-qualification/luna-df-positive-control.log) · [Critical corrected regressions](../../evidence/rc3-r3-r2-host-qualification/critical-regressions.log)

The historical R2 and R3 scanners reproduced the `/./` writer bypass. The corrected scanner passed the sequential and normalized absolute-path suite under Dash and host BusyBox ash. It preserved the canonical read-only dispatcher exception and refused alternate spellings that would have inherited an exception. Standalone tests likewise preserved the authenticated action-parent exception and refused its alternate spelling. [Historical R2 scanner](../../evidence/rc3-r3-r2-host-qualification/scanner-accepted-r2.log) · [Historical R3 scanner](../../evidence/rc3-r3-r2-host-qualification/scanner-original-r3.log) · [Corrected scanner](../../evidence/rc3-r3-r2-host-qualification/scanner-corrected.log)

## G. Host and Recovery checks

The maintained local gate passed 112 shell tests and five Node tests with zero failures. Its default Dash Repair suite, the separate selective Dash suite and both host BusyBox suites each passed 36 tests. [Maintained gate](../../evidence/rc3-r3-r2-host-qualification/local.log) · [Dash selective](../../evidence/rc3-r3-r2-host-qualification/dash-selective.log) · [BusyBox full](../../evidence/rc3-r3-r2-host-qualification/busybox-full.log) · [BusyBox selective](../../evidence/rc3-r3-r2-host-qualification/busybox-selective.log)

The standalone fixtures use exact executable bytes as members of their immutable snapshot archives. Dash ran the production bytes. The established BusyBox fixture substitutes host ash for the same-PID handoff and explicitly routes fault shims. Its archive contains the exact adapted executable and exercises the same identity check.

The format-1 recovery matrix uses the exact accepted R2 helper against interrupted sparse publication. It checks restored originals after private workspace loss, unchanged correct target inodes, and preservation of protected state. Full and selective coverage includes all 58 final targets, six fast-path mock flushes, and low-headroom streaming with 63 flushes for full publication and 15 for ten selected replacements.

Reproduction commands from the checkout root follow.

```sh
E=dev-tools/evidence/rc3-r3-r2-host-qualification
T=dev-tools/experiments/rc3-lean-repair-luna/tests
C=$(mktemp -d)
PYTHONDONTWRITEBYTECODE=1 python3 "$T/test_staged_hash_output.py" \
  --historical "$E/original-r3-r1.sh" --capture-dir "$C/historical"
PYTHONDONTWRITEBYTECODE=1 python3 "$T/test_staged_hash_output.py" --capture-dir "$C/matrix"
PYTHONDONTWRITEBYTECODE=1 sh dev-tools/tests/local/run_all.sh
PYTHONDONTWRITEBYTECODE=1 FULL=0 python3 "$T/test_standalone_persistent_repair.py"
PYTHONDONTWRITEBYTECODE=1 MERVLAN_TEST_BUSYBOX=1 FULL=1 python3 "$T/test_standalone_persistent_repair.py"
PYTHONDONTWRITEBYTECODE=1 MERVLAN_TEST_BUSYBOX=1 FULL=0 python3 "$T/test_standalone_persistent_repair.py"
sh dev-tools/tests/local/repair_sequential_scan_contract_test.sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$T" python3 "$E/benchmark-pair.py"
```

Both shell syntax checks, Python AST parsing, the reverse patch check and `git diff --check` passed.

## H. Performance

Three alternating pairs per workload ran the exact executables under Dash with 16 synthetic process entries and mocked flushes. Each variant used the same Git cohort with its own executable as the one substituted archive member. The one-mismatch fixture changes mode only. Timing went from invocation through exit. Separate instrumented runs counted operations.

| Workload | Engine | Observed wall time (s) | Median (s) | Classification (s) | Comparisons | Hash launches | Scans | Copies | Replacements | Mock flushes |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Selective no-op | R3-R1 | 3.43, 2.45, 2.45 | 2.45 | 0.714 | 194 | 2 | 3 | 70 | 0 | 0 |
| Selective no-op | R3-R2 | 3.22, 2.49, 2.48 | 2.49 | 0.741 | 195 | 2 | 3 | 70 | 0 | 0 |
| Selective one mismatch | R3-R1 | 6.27, 6.37, 6.11 | 6.27 | 1.039 | 373 | 71 | 4 | 130 | 1 | 6 |
| Selective one mismatch | R3-R2 | 6.23, 6.14, 6.12 | 6.14 | 1.023 | 374 | 71 | 4 | 130 | 1 | 6 |
| Selective ten mismatches | R3-R1 | 7.98, 7.16, 7.25 | 7.25 | 1.394 | 370 | 113 | 13 | 138 | 10 | 6 |
| Selective ten mismatches | R3-R2 | 7.06, 6.77, 7.75 | 7.06 | 1.631 | 371 | 113 | 13 | 138 | 10 | 6 |
| Default full | R3-R1 | 20.25, 19.66, 20.45 | 20.25 | — | 256 | 299 | 61 | 187 | 58 | 6 |
| Default full | R3-R2 | 21.89, 21.60, 21.57 | 21.60 | — | 256 | 299 | 61 | 187 | 58 | 6 |

Every selective case added exactly one comparison. Hash launches, scans, copies, replacements and flushes matched across each pair of instrumented runs. The default-full path showed the same operation counts. The whole-file check runs only during selective classification. Selective no-op added 0.04 seconds to the measured median and still performed zero replacements or flushes. The one- and ten-mismatch medians stayed within the observed host variation. [Raw benchmark data](../../evidence/rc3-r3-r2-host-qualification/benchmarks.json)

Default full measured 20.25 versus 21.60 seconds median in the first set. A second three-pair run reversed the starting order. It measured 20.57 seconds for R3-R1 (20.11–20.78) and 21.20 seconds for R3-R2 (20.56–21.32), a 0.63-second gap. Both sets skipped selective classification and recorded 256 comparisons. Stage, backup and publication intervals varied between the uninstrumented samples. The instrumented publication phase ran faster on R3-R2 in both windows. The default-full wall gap remains unattributed to a code path. [Default-full repeat](../../evidence/rc3-r3-r2-host-qualification/benchmark-default-repeat.json)

## I. Preservation

The checkout retains its original branch and committed HEAD. The engine correction is unstaged and the new test and report are untracked. There was no commit or push. The original R3-R1 bytes and its existing qualification evidence were preserved and the prior evidence checksum list still verifies. Host-only fixtures supplied all execution evidence. [Final working-tree status](../../evidence/rc3-r3-r2-host-qualification/git-status-final.txt) · [Evidence checksums](../../evidence/rc3-r3-r2-host-qualification/SHA256SUMS)

## J. Luna QC recommendation

Review the exact corrected digest above and rerun the extra-line, NUL and nonzero-exit captures against both batch backends. Confirm that the whole-file comparison precedes acceptance and that an interrupted sparse transaction remains recoverable by the accepted R2 helper. Keep the candidate uncommitted pending Luna approval.
