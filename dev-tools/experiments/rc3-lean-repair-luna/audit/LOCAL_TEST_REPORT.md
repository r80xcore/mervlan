# Independent local test status

- Exact accepted R2 source candidate hash verified: `f3b74696b91d4492571b5c49315ac17cde53b6c85bd45591ac52359e09439186`.
- Scratch-cleanup candidate: `sh -n` and BusyBox ash `-n` PASS.
- `tests/test_prepublication_cleanup.py`: 3/3 PASS (failed fetch clears scratch; successful transaction clears scratch; failed publication retains ledger).
- `tests/test_update_exit_trap_semantics.sh`: PASS Dash and BusyBox ash (baseline EXIT-trap masks cleanup failure; proposed propagation changes process status).
- Reference patches 02–04 applied cleanly to the locally supplied **different** RC3-dev source snapshot and passed `sh -n` + host BusyBox ash `-n`. This does NOT validate exact current test-branch sources or target BusyBox 1.25.1.
- R2 67-test suite was started against cleanup candidate and passed the first 41 cases before the available execution window ended. **DO NOT CLAIM independent 67/67** for cleanup candidate. The unchanged accepted R2 has historical 67/67 evidence, which is not a substitute for candidate requalification.
- No target router contacted. No actual network transfer, ebtables, Heal, Update, Apply, Sync, service restart, git commit or push.

Required before integration: complete 67/67 suite; full maintained gate on actual checkout; source-derived negative races; GUI token/finalization and CLI repair-before-update tests; memory/cleanup and target BusyBox read-only probes; inspect any absent / blocked source paths. Report pass/fail per *candidate* and exact SHA.
