# Testing and evidence

Use for tests, debugging, guarded recovery, or live validation.

- Maintained deterministic tests: `dev-tools/tests/router/mervlan_selftest.sh`.
- Live disruption safety guard: `dev-tools/safety/mervlan_live_test_guard.sh`.
- Add permanent runtime regression cases to `dev-tools/tests/router/mervlan_selftest.sh`; temporary PC-only harnesses belong in `dev-tools/tests/local/`.
- Use `dev-tools/docs/92-test-workflows.md` for exact commands and selection.
  Run static/local checks before router checks, and router/node checks before
  asking for a human disruptive test.
- Run the narrow affected self-test first. Run broad tests only when the change justifies them; do not repeat successful soak tests without a relevant new symptom.
- Lab observation (2026-07-27): the full `mervlan_selftest.sh all` run exceeded
  a 180-second host command limit while older DHCP/heal cases were still
  running. Treat that result as inconclusive, retain its output, verify that
  child processes and test state are clean, and use focused affected cases for
  a reliable pass/fail result.
- Runtime state: `/tmp/mervlan_tmp/{logs,locks,results,client_collection}`. Self-test state: `/tmp/mervlan_tmp/selftest.<run-id>`.
- Put router/AP evidence under `/tmp/mervlan_tmp/evidence/<run-id>/<device>/<stage>/`, download it to `dev-tools/evidence/<run-id>/`, verify it, and delete the remote directory only after successful verification.
- Raw PC evidence under `dev-tools/evidence/` is ignored; never stage or deploy
  it. Keep only the workflow README in that directory. If a sanitized summary
  is intentionally retained, place it in an appropriate non-evidence document
  rather than weakening the raw-evidence ignore rule.
- Record target, command/action, expected result, actual result, duration, PASS/FAIL/PARTIAL, before/during/after state, and fixes/retests.
- Prefer disruptive tests on a configured non-primary node when one is
  available; main-router disruption requires explicit approval. On each
  installation, identify and document the equivalent test target before using
  this recommendation.
- Before guarded kill/stale-lock work, verify exact PID plus process start identity and arm the live-test guard.
- Stop and preserve evidence on unexpected `br0` leak, persistent outage, stale Hold/lock, inconsistent state, failed recovery, or loss of management access.
- Cold boots require the user. If the selected test node is unavailable beyond
  the agreed diagnostic window, request a physical power cycle from the user.
- A node-only selftest must not fail merely because the main-router
  `execute_nodes.sh` orchestration helper is absent; classify required files by
  execution role.
- After every UI/API test, verify terminal backend state and UI state; never
  accept a spinner disappearing as proof of success.
