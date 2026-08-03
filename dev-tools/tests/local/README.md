# Local tests

These tests use isolated temporary state and should not contact router or AP
hardware. They exercise production libraries from the parent repository; they
do not duplicate those libraries under `dev-tools`.

Run them from the repository root:

```sh
sh dev-tools/tests/local/action_progress_test.sh
sh dev-tools/tests/local/loading_progress_test.sh
sh dev-tools/tests/local/apmo_override_contract_test.sh
sh dev-tools/tests/local/service_settings_contract_test.sh
sh dev-tools/tests/local/save_local_only_sync_test.sh
```

Each script derives `MERV_BASE` from its own location unless it is explicitly
set. It cleans its temporary state on exit; a failed or interrupted run still
requires a quick check for a leftover `/tmp/mervlan_tmp/selftest.*` directory.
