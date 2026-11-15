# XT8 private-fixture hardware acceptance — 2026-11-15

**Decision: ACCEPTED — PASS**, limited to the isolated synthetic `/tmp`
fixture. No installed MerVLAN entrypoint was run, and no file under
`/jffs/addons/mervlan` was modified.

## Target and inputs

- Device: MAIN, ASUS RT-AX95Q / ZenWiFi XT8; ASUSWRT-Merlin, BusyBox 1.25.1.
- Candidate: `update_mervlan_repair_R2_32MiB_preflight.sh`, SHA-256
  `88e9854aeacd3d03dd83041addcffdcbb2d8e2207688e7a4b21fd14bd54d55dc`.
- Synthetic bundle: SHA-256
  `04e84ea97047157705cf3aa1c42b20e61d0871f941cab60b3bf11274eec2e05f`.
- Runner: `run_xt8_fixture_qualification_64MiB_runner.sh`, SHA-256
  `46bb8ed927a367127d00911474cb6b15079501f3d58e6fd9287fb05c18474cb9`.
- The final read-only preflight passed BusyBox/ash, all runner-required
  utilities, OpenSSL SHA-256, product ID, RAM and `/tmp` checks. The target
  did not provide `cksum`; the runner does not require it. An earlier
  preflight attempt stopped on that unavailable utility, and an intermediate
  utility-probe attempt reported false missing-command results. Neither ran
  the candidate. The corrected final preflight passed before fixture
  execution.

## Fixture results

| Case | Result | Elapsed | Peak private workspace | After | Ownership |
|---|---|---:|---:|---:|---|
| Successful replacement | Exit 0; 58/58 files verified | 81 s | 12,100 KiB | 0 | Released |
| Injected publication failure | Expected nonzero action result after 12 replacements; complete rollback verified | 69 s | 12,104 KiB | 12,104 KiB retained as rollback evidence | Released |

Rollback checks matched the full pre-run and post-run synthetic file lists,
contents and modes. The test changed no unrelated synthetic destination. The
injected failure occurred on publication attempt 13. The retained ledger,
backup and logs are intentional recovery evidence and were not removed.

## Timing and resource observations

The candidate phase log attributes the successful 81 seconds as follows:

| Phase | Elapsed marker | Approximate phase time |
|---|---:|---:|
| Local synthetic archive copy | 0 s | under 1 s |
| Archive validation (59 members, 6,000,640 uncompressed bytes) | 2 s | 2 s |
| Stage 58 files / 3,481,458 bytes | 25 s | 23 s |
| Admission and process scan | 31 s | 6 s |
| Backup 58 original files / 2,757,149 bytes | 56 s | 25 s |
| Second preflight and fixture quiescence | 57 s | 1 s |
| Publish and verify all 58 files | 79 s | 22 s |
| Final verification and exit | 80 s | 1 s |

Rollback used 27 seconds through backup, failed after 12 replacements at
64 seconds, and verified rollback by 69 seconds. These logs point to per-file
staging, backup comparison, publication and verification as the main runtime
cost. No additional benchmark or optimization was run.

The final read-only target preflight recorded 146,720 KiB `MemAvailable` and
240,080 KiB free in `/tmp`. Immediately before the runner, MAIN recorded
139,128 KiB and 232,460 KiB. The runner sampled live `/proc/meminfo` and
`df` about once per second:

- Success case: 135,112 KiB at first sample; minimum 121,608 KiB available
  and 215,840 KiB free `/tmp`; after cleanup 134,232 KiB and 227,940 KiB.
- Rollback case: 130,756 KiB at first sample; minimum 114,584 KiB available
  and 211,836 KiB free `/tmp`; after the case 115,416 KiB and 211,976 KiB.
- A separate post-run read-only check recorded 115,536 KiB available RAM and
  211,960 KiB free `/tmp`.
- Process rows sampled: 140–142 during success and 140–151 during rollback.

The rollback workspace is retained tmpfs data, measured at 12,104 KiB. The
roughly 23,600 KiB change in `MemAvailable` from immediately before the
runner to the separate post-run check is not explained by that retained disk
workspace and is not a direct measure of fixture memory. It is an observed,
unattributed availability change; the run showed no OOM or reachability loss.
The runner's external live sampler remained above the candidate's 32,768 KiB
minimum throughout. The candidate's fixture memory input is a per-case
`/proc/meminfo` snapshot, so its own second preflight reads that snapshot;
live threshold coverage here comes from the runner's continuous target-side
samples.

## Reachability and evidence

Controller ping was 5/5 before and after; SSH returned `SSH_OK` before and
after. Wi-Fi client-side observation was omitted because it was unavailable;
that supplementary observation was not an acceptance criterion. Router-side
process, memory and filesystem diagnostics are retained.

The complete remote fixture capture remains on MAIN at
`/tmp/mervlan_lean_fixture.xt8.1794768459.9917`. A verified local copy,
including the runner, controller reachability and preflight logs, is retained
under the ignored path
`dev-tools/evidence/rc3-xt8-fixture-qualification-2026-11-15/`. The original
remote evidence was not deleted. Its `SHA256SUMS.local` is SHA-256
`c3de8111c601adb110a1695e196046b40b3b3854ea0200b36bd2eeac72f9916a`; the
controller-observation manifest is
`bba494fcce596e074f603cbdc149822ed77a4cebd7a7069141a72bfb4c680e58`.

This pass qualifies only the two requested isolated fixture cases on this
hardware/software combination. It does not enable real installed-file
publication or waive the candidate's fixture-only publication gate.
