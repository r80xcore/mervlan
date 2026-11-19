# Luna independent R3-R2 host qualification

**Verdict: PASS — host qualified; conditional Git promotion authorized.**

This qualifies the exact R3-R2 source for promotion to the RC3 test branch and a separately authorized controlled XT8 trial. It does not qualify router execution, XT8 runtime, or physical JFFS2 power-loss behavior.

## Source identity

| Item | SHA-256 / commit |
|---|---|
| Accepted R2 commit | `321d5afac2b4de9441846014e9dddb80e701ae8d` |
| Accepted R2 Repair | `acdb9ffa862cfda43019f77ac6749eb670ea0f48f584bae543727afc1b96d57e` |
| Original R3 Repair | `c3a56c942f3551c1d5fe0c2534d96b57144e0b3a1dba3365c3c18ac28da732b9` |
| Corrected R3-R1 Repair | `94008a3215dd6c94bb2d539b9c0bfa931f7ef4c0b86fcc781cdee60cc255ce10` |
| Qualified R3-R2 Repair | `d5aca0951a9bfb6134b97184ffbf975b2ea0da9cf6a3f55d88d7266f1571acd1` |
| R3-R1 → R3-R2 patch | `f67edc00ac0c23ac622046f470db3e95963a7a3d51e691fdd75d6cfa8f8ceb1c` |
| Complete R2 → R3-R2 Repair diff | `f6fbb925322cca72995c759ce9bdea2c03977a1caa8013177260dc4823ffddda` |
| Trusted manifest | `3475336656abe00c73d86526f7a385ff7b7328abd9c2a4d3b58f008e40d30c15` |
| Normal Update | `7bb9dcdd0593d156f1a0d7ff15002790a3fff3759c655d7513251d0038440fff` |

The working Repair matched the qualified candidate; the manifest and Normal Update matched the supplied identities. The complete candidate diff was reviewed against the accepted R2 commit. No unrelated production path or manifest contract changed.

## Staged-output correction

The original R3-R1 positive control accepted the injected extra record and returned a successful selective no-op. R3-R2 refuses the same fixture.

R3-R2 consumes exactly 58 manifest-ordered digest/path records, validates each digest and path association, writes each validated record to the private expected-output file, checks every expected-file write, then compares the complete expected and backend files with `cmp -s`. Unexpected bytes (including NUL and unterminated tails), missing or reordered records, and a nonzero final comparison all fail before persistent transaction creation. File descriptors 6 and 7 are scoped to the redirected compound loop. An injected expected-file write failure and an injected `cmp` status 2 both refused under Dash and adapted host BusyBox ash.

Independent candidate matrix: 15 malformed-output cases under native SHA-256 batching and 15 under OpenSSL reverse-format batching were refused. Cases included extra valid/invalid records, empty and extra lines, unterminated/truncated records, missing records, duplicate/reordered records, wrong path association, nonhex digests, NUL/binary output, embedded NUL, and backend failure. Valid native/OpenSSL output was accepted; forced individual-hash fallback validated all 58 paths. Every malformed case showed zero installed replacements, zero persistent backups, zero global flushes and no protected-state change. Captured wrapper output was checked against the test's intended malformed bytes and the engine's staged output, avoiding false passes from an earlier unrelated refusal. Raw captures are retained byte-for-byte in the two compressed capture archives alongside their per-case hashes.

## Earlier STOP defects and transaction safety

The classification-race suite passed 12 injected transitions, including invalid-A to different same-length invalid-B, invalid-to-correct, mode changes, present/absent changes, a formerly correct target changing, symlink replacement, final-target mutation, backup-loop mutation, and pre-rename mutation. The candidate refused instead of adopting changed state. `selective_originals_match()` rechecks the cohort against verified backups before READY; publication retains its per-target old-state checks and final all-target verification. Post-check same-UID filesystem races are not claimed to be atomically excluded.

The absolute `/./` legacy-writer bypass reproduced against accepted R2 and original R3 controls. R3-R2 passes the sequential scanner contract under Dash and host BusyBox ash, including canonical and noncanonical absolute/bare/relative paths, late writers, ambiguous paths, proc-entry failures, canonical read-only dispatcher and authenticated-parent exceptions, and mixed command lines. Noncanonical spellings cannot use dispatcher exceptions. The scanner still starts external `tr` per PID.

Lock/ownership review found fresh process identity and lock-record parsing, PID/generation/nonce comparisons, ownership revalidation before mutation, and fail-closed malformed/replaced records intact. Unknown scripts do not gain dispatcher status. No false exception was found.

## Hashing, publication and Recovery

Native hashing, OpenSSL reverse-format batching, and individual fallback were exercised. Backend failures and incomplete output refused. Batch hashing changes process-launch count only; digest/path checks and all 58 source/installed verifications remain. Exact XT8 vendor OpenSSL output is not available on this host; capability probing and safe individual fallback remain the compatibility path.

The separate Repair suites passed with `FULL=1` (36 tests), `FULL=0` (36 tests), and unset `FULL` (2 focused tests). They cover complete full republication, sparse selective publication, healthy no-op with zero replacements/backups/flushes, complete final verification, ownership, protected settings, SSH trust and MAC Shield fixtures, original-absent states, six high-headroom flush barriers, low-storage fallback, corrupt/ambiguous evidence refusal, and interruption/rollback/commit boundaries.

The exact accepted R2 Recovery helper recovered an interrupted sparse R3-R2 transaction after private workspace loss, including restoration of an originally absent selected path. Untouched correct files retained their original bytes, modes and inodes where applicable. Recovery used persistent format-1 evidence. Host fault injection is not evidence of physical power-loss durability on JFFS2.

Maintained gate: `sh dev-tools/tests/local/run_all.sh` passed with 112 shell tests, 5 Node tests and zero failures. Shell syntax passed under host `/bin/sh` and host BusyBox ash; Python source parsing and `git diff --check` passed.

The BusyBox run used host BusyBox 1.37 with an in-memory shell-handoff/applet adaptation for the harness. It is not execution under the XT8's exact BusyBox ash 1.25.1.

## Paired performance

Independent alternating R3-R1/R3-R2 fixtures used 16 synthetic processes, three repetitions per variant, and invocation-to-exit timing. The extra byte comparison added one `cmp` call per selective invocation.

| Workload | R3-R1 median | R3-R2 median | Difference |
|---|---:|---:|---:|
| Selective no-op | 5.41 s | 5.49 s | +0.08 s |
| Selective one mismatch | 13.49 s | 13.61 s | +0.12 s |
| Selective ten mismatches | 15.22 s | 15.33 s | +0.11 s |
| Default FULL=1, correct cohort | 22.39 s | 22.91 s | +0.52 s |

A reversed-order repeated full run measured 22.31 s for R3-R1 and 22.20 s for R3-R2, so the initial +0.52 s did not reproduce as a consistent regression. FULL=1 does not call `select_publication()`; full-path operation counts were identical. On the 16-process instrumented fixture, the full path had 61 process scans, 976 external `tr` invocations, 299 hash launches, 58 target replacements, two journal appends, three journal validations, and six global flushes. Selective no-op had zero replacements, persistent writes and flushes. Absolute host times depend on fixture and process load and are not XT8 predictions or proof of the 120-second hardware target.

## Promotion guard

The exact staged path inventory is recorded in `STAGED_FILE_LIST.txt`. Immediately before promotion, the GitHub branch read reported `pre_v0.53.29-RC3-repair-test` at accepted R2 commit `321d5afac2b4de9441846014e9dddb80e701ae8d`. Local HEAD was the same commit; the original 206-entry porcelain status was unchanged by QC. No router or device was contacted.
