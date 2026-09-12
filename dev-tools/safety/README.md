# Test safety helpers

Safety helpers protect deliberately disruptive live tests. They are copied by
development `Sync Nodes` only when needed by the router-capable test flow.
They are not production runtime dependencies and must not be used to bypass
the human-preparation requirement for disruptive tests.

For a controlled MAIN WAN Native qualification, use an operator-side ICMP/TCP
observer before the transition. When present, the local
`observe_wan_native_main.ps1` is an optional operator-local lab tool; it is
intentionally not shipped as repository product source, so a fresh clone may
not contain it. Detailed high-rate evidence belongs on the operator PC, not on
JFFS.

Read the guard script's usage before arming it. Verify the exact target and
management path first, arm a bounded recovery deadline, run one prepared test,
then disarm only after post-test verification. A guard does not make an
unprepared Apply safe.
