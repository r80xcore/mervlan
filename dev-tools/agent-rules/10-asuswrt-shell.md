# ASUSWRT shell runtime

Use when editing or reviewing runtime shell files.

- Production runs on ASUSWRT BusyBox `/bin/sh`; write POSIX shell only.
- Do not use Bash arrays, `wait -n`, process substitution, `flock`, or assumed GNU options.
- Run `sh -n` on every changed shell file. A Windows/Git Bash pass does not prove BusyBox compatibility.
- On Windows, if a native POSIX shell is unavailable, use an installed
  Ubuntu/WSL2 environment for shell validation, for example:
  `wsl.exe -d Ubuntu --exec sh -lc 'busybox sh -n path/to/file.sh'` from the
  repository root. Probe WSL first; if it is unavailable, use an available
  POSIX/BusyBox shell or disposable Linux environment, and do not claim
  BusyBox compatibility without an equivalent check.
- If WSL launch or service access fails, Git for Windows `sh -n` is a useful
  POSIX syntax fallback, but it is not BusyBox validation. If router deployment
  is not authorized, report BusyBox validation as unavailable; after an
  authorized deployment, use router-side `/bin/sh -n`.
- The Codex host may limit a foreground command to about one minute. If the broad self-test exceeds that limit, do not call it failed without a test result; run the narrow affected test first and capture a longer suite separately when justified.
- Before depending on a router command or option, verify it read-only on the target: `nohup`, `timeout`, `mktemp`, `/proc`, `find`, `tar`, or similar.
- A validated ASUSWRT BusyBox observation found that `/bin/sh` did not provide
  the `command` builtin; probe required utilities by direct invocation and
  handle nonzero results instead of assuming `command -v` exists.
- A validated ASUSWRT BusyBox observation found no `timeout` or `mktemp`
  applet. The installed `_merv_timeout_run` fallback
  completed `dbclient` in about 1s when output was redirected to a file, but
  took exactly 10s inside `$()` because its background watchdog inherited the
  command-substitution pipe. Redirect watchdog stdout/stderr to `/dev/null`;
  retain the hard timeout. Dropbear emitted `failed creating //.ssh` only with
  `HOME=/`; a writable temporary HOME removed that warning without changing
  connection success.
- Validate numeric values before arithmetic, timeouts, `sleep`, PID use, or path construction.
- Do not use `$$` alone for a temporary filename in concurrent code; BusyBox subshells may share it.
- Use temporary-file-plus-same-directory-`mv` for shared state publication.
- Never source markers, status files, or result files as shell code. Parse and validate them as untrusted text.
