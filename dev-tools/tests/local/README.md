# Local tests

These tests use isolated temporary state and should not contact router or AP
hardware. They exercise production libraries from the parent repository; they
do not duplicate those libraries under `dev-tools`.

Run every current local test sequentially from the repository root:

```sh
for test_script in dev-tools/tests/local/*_test.sh; do
    printf '%s\n' "== $test_script =="
    sh "$test_script" || exit $?
done
```

The glob includes every local test and compatibility wrapper currently checked
into this directory, including the focused audit-remediation contracts. The
loop is sequential so tests do not share mutable temporary state.

Each script derives `MERV_BASE` from its own location unless it is explicitly
set. It cleans its temporary state on exit; a failed or interrupted run still
requires a quick check for a leftover `/tmp/mervlan_tmp/selftest.*` directory.
