# Local tests

These tests use isolated temporary state and should not contact router or AP
hardware. They exercise production libraries from the parent repository; they
do not duplicate those libraries under `dev-tools`.

Run the complete maintained local gate sequentially from the repository root:

```sh
sh dev-tools/tests/local/run_all.sh
```

The runner includes every maintained `*_test.sh` and checked-in `*_test.mjs`
file. It intentionally excludes historical `deep_audit_*.sh` fixtures and
fails when Node.js is unavailable, because those behavior tests are part of the
complete local gate. Tests remain sequential so they do not share mutable
temporary state.

Each script derives `MERV_BASE` from its own location unless it is explicitly
set. It cleans its temporary state on exit; a failed or interrupted run still
requires a quick check for a leftover `/tmp/mervlan_tmp/selftest.*` directory.
