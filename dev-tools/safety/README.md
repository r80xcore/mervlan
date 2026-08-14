# Test safety helpers

Safety helpers protect deliberately disruptive live tests. They are copied by
development `Sync Nodes` only when needed by the router-capable test flow.
They are not production runtime dependencies and must not be used to bypass
the human-preparation requirement for disruptive tests.

For a controlled MAIN WAN Native qualification, run the PC-only
`observe_wan_native_main.ps1` before the transition. It writes timestamped
ICMP/TCP reachability samples to the operator PC without credentials or any
router-side mutation; detailed high-rate evidence belongs there, not on JFFS.

Read the guard script's usage before arming it. Verify the exact target and
management path first, arm a bounded recovery deadline, run one prepared test,
then disarm only after post-test verification. A guard does not make an
unprepared Apply safe.
