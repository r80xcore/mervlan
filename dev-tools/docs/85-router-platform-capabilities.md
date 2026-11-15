# Historical router platform capabilities

This is a carried-forward **RC2 historical evidence profile**, not a fresh
RC3 check. It records results from one device identified as NODE1: an
RT-AX95Q / ZenWiFi XT8 on Gnuton/Merlin 3.0.0.4 build 388.9, extension
2-gnuton2 (`388.9_2-gnuton2`). It does not qualify MAIN, RC3, another node,
another firmware build, or a later upgrade. Internal addresses and hostnames
are intentionally omitted.

The P1 inventory was collected 2026-10-28. Accepted historical archive names
and SHA-256 values are retained here for provenance. The raw archives and
experiment sources are not in this checkout; these notes do not reconstruct
or rerun them. A historical acceptance record is not current target evidence.

## Evidence terms

| State | Meaning in this profile |
|---|---|
| AVAILABLE | An executable path, validated compiled applet name, readable metadata, or specified version response was observed in the named discovery domain. This does not qualify arbitrary options or behavior. |
| NOT_FOUND | Absent only from the tested executable search paths (`/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`) or validated BusyBox applet list. It is not a host-wide absence claim. |
| UNKNOWN | Evidence was unavailable or inconclusive. Do not interpret it as absence. |
| NOT_TESTED | The behavior was not executed, even if a provider was AVAILABLE. |
| QUALIFIED BEHAVIOR | Only the exact command/options, input, output, and exit status reviewed in the scoped test are qualified. |

## Historical P1 inventory

The recorded decision was **PLATFORM-P1 independent QC PASS**, limited to
read-only Group A inventory. Archive:
`platform-node1-P1-20261028T082355Z-e6e04a89.tar.gz`;
SHA-256:
`b8f82f72ea9f42ac3655fc16b8e2ead0958e0d4f080bcfe665616d5dd58c8b04`.
Its 60-entry manifest was checked during collection and again in RC2-D0. The
record named `group-a.stdout`, `group-a.stderr`, `group-a.exit`,
`pc-applets.tsv`, `provider-matrix.tsv`, and `execution-record.json` as raw
evidence authority.

| Item | Historical observation | Limit |
|---|---|---|
| Device | NODE1, RT-AX95Q / ZenWiFi XT8 | One device only; MAIN and other nodes were not inventoried. |
| Firmware | Gnuton/Merlin 3.0.0.4 build 388.9, extension 2-gnuton2 | A different build needs new evidence. |
| BusyBox | Version 1.25.1; 156 compiled applet names validated from complete BusyBox output by a trusted PC-side validator | Version alone does not establish any applet or option set. |
| `/bin/sh` | Symlink to the same BusyBox inode | Bounded shell/process behavior was exercised in T9. Full `ash` semantics remain NOT_TESTED. This does not establish standalone `busybox ash` command availability. A compiled `bash` name does not mean GNU Bash. |
| `/tmp` | Physical directory; tmpfs mount observed | T9 added bounded private-root, hardlink, and replacement observations. Power-loss durability remains NOT_TESTED. |
| `/proc` | Mounted/readable; self and PID 1 stat captured | T9 added bounded identity, child/wait, and postflight checks. PID reuse, general ancestry, and failure/race coverage remain unqualified. |
| Kernel | UNKNOWN | The approved inventory did not collect `uname` release/architecture. An older kernel observation was not reconfirmed. |
| `hexdump` | AVAILABLE as a validated BusyBox applet and `/usr/bin` path | P2 qualifies only the exact formats below. Other options remain NOT_TESTED. |
| OpenSSL | AVAILABLE at `/usr/sbin/openssl`; version 1.1.1w (11 Sep 2023), version query exit 0 | P2 qualifies only the exact SHA-256 `abc` vector below. Arbitrary hashing workflows remain unqualified. |
| `usleep` | AVAILABLE as a PC-validated compiled BusyBox applet | T9 ran `/bin/busybox usleep 10000`; precision and strict elapsed-time bounds were not measured. |
| `md5sum` | AVAILABLE as executable path and compiled applet | Hash behavior NOT_TESTED; MD5 is not a SHA-256 substitute. |
| SSH clients | `/usr/bin/ssh` and `/usr/bin/dbclient` version calls reported Dropbear v2025.87, exit 0 | Router-client authentication, transport, and option behavior NOT_TESTED. |
| `scp` / `dropbear` | Executable paths observed | SCP transport and the running server implementation/version NOT_TESTED. |

## Historical discovery gaps

| Name | Tested executable directories | Validated BusyBox applet list |
|---|---|---|
| `od` | NOT_FOUND | NOT_FOUND |
| `sha256sum` | NOT_FOUND | NOT_FOUND |
| `cksum` | NOT_FOUND | NOT_FOUND |
| `stat` | NOT_FOUND | NOT_FOUND |
| `timeout` | NOT_FOUND | NOT_FOUND |
| `mktemp` | NOT_FOUND | NOT_FOUND |
| `id` | NOT_FOUND | NOT_FOUND |
| `whoami` | NOT_FOUND | NOT_FOUND |

Other observed executable paths do not prove substitutes exist. In particular,
P1 did not qualify hashing or `hexdump` behavior. Historical command-builtin
introspection was UNKNOWN for some builtins, including `command`; do not turn
that uncertainty into a general absence claim. Earlier `command` failure is a
separately scoped observation.

## Historical P2 qualified behavior

The recorded decision was **PLATFORM-P2 independent QC PASS**, limited to two
behavioral checks run once on NODE1 on 2026-10-28. Archive:
`platform-node1-P2-20261028T101906Z-e55b3dc2.tar.gz`;
SHA-256:
`203a667bae9205902caf10df72661f485f2b3b9c4f57ec43a196948c6483daea`.
Raw binary frames were compared on the PC before output validation; SSH exit
was 0, provider statuses were 0, stderr was empty, and capture was complete.

| Exact command | Qualified input and result |
|---|---|
| `/bin/busybox hexdump -v -e '16/1 "%u " "\n"' data.bin` | 51 bytes: `[0,1,2,3,9,10,13,31,32,65,127,128,254,255,65,65]` repeated three times, followed by `[0,31,255]`. Four newline-terminated rows contained 16/16/16/3 exact ordered decimal tokens; final-row trailing spaces were permitted. |
| `/bin/busybox hexdump -v -e '3/1 "%02x " "\n"' abc` | Exact three-byte `abc`; output `61 62 63` followed by newline. |
| `/usr/sbin/openssl dgst -sha256 abc` | Exact three-byte `abc`; exact output and final newline: `SHA256(abc)= ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`. |

P2 does not qualify arbitrary formats, all binary lengths, other hash vectors,
filesystem atomicity, ownership lifecycles, or an adapted A3 probe. SHA-256
callers still need a qualified provider, checked status, exact algorithm, and
complete expected output. MD5/CRC must not silently replace SHA-256.

## Historical RC2 A3-T9 probe (not a current platform qualification)

The RC2-D0 record reports **A3-T9 independent QC PASS** for one invocation on
NODE1, 2026-10-28 16:56:19–16:56:30 UTC: exit 0 and exactly 56 ordered PASS
assertions. Archive:
`a3t9-node1-20261028T165545Z-f6919f69.tar.gz`;
SHA-256:
`1e68adbd21f66c4b4f4ccd4c5cb58f3701736bb4e786667fb70157fe1b2a05ba`.
The retained record identifies the isolated T8-Q1 derivative and its source
hashes; the source files are not present in this checkout.

| Historical source file | Reviewed SHA-256 |
|---|---|
| `owner_common.sh` | `b4e9fba1119e357ce7faa46d83ff5bb5b9f982f84d3087c419e3332afe2411ff` |
| `candidate_hardlink.sh` | `e37964b41dfb28e6f2a0d816f515a29d765c5db967107ee6b66f940e793f3153` |
| `probe.sh` | `b5bf4fab3d2423803cd7bf7ea289e21b2f02fb826f85b96b3d773da99845b401` |

Within a private `/tmp` fixture, the probe exercised bounded shell/process
behavior, source hashes, wait status, live PID/PPID/state/start parsing,
unavailable-proc-root refusal, hardlink admission/replacement, exact byte
checks, noclobber preservation, competing-owner denial, direct-child
grant/completion, release, and malformed-record/object refusals. It did not
prove complete router race/recovery behavior, target PID reuse, clean-reboot
reconciliation, arbitrary descendants, production entrypoint coverage,
generic deployment hashing, or full MerVLAN integration. These results do not
qualify RC3 code or authorize a new connection or test.

## Use limits

P1, P2, and T9 are historical observations for the named NODE1 hardware/build.
They apply automatically to neither RC3, MAIN, other nodes, nor later firmware.
Read-only inventories and behavioral qualifications are distinct; a new
behavioral test needs its own scope, authorization, and evidence/cleanup plan.
Do not add a runtime dependency on this document or a development harness.
