# MerVLAN agent entry point

This is the only portable entry point for an AI coding agent working with the
MerVLAN developer bundle.

## Required reading order

1. Read `agent-rules/00-project-safety.md`.
2. Read `agent-rules/05-developer-reference.md`.
3. For an unknown, cross-cutting, or unfamiliar task, read
   `agent-context.json` as the compact static source and task map.
4. Read only the additional rule files and developer notes routed by the task.
5. Use `docs/README.md` as the normal developer-document navigation map.

The rules define mandatory operating constraints. The developer notes explain
the addon, its ownership boundaries, runtime flows, limitations, tests, and
deployment procedures. Do not load every document by default; follow the
focused route and return for more context when a contract or safety boundary
is unclear.

`agent-context.json` is a deliberately small, manually maintained navigation
map for unknown or cross-cutting work. Use it to locate likely source files
and focused notes, not to infer behavior. It contains no credentials,
device-specific values, line counts, or test results. If it is stale or
conflicts with source, follow the current source/tests and update the map only
when a stable boundary or route moved.

In the map, each `task_routes` value is a layer ID. Resolve it through
`layers.<id>` and read that layer's `start`, then `next`, then `notes` as
needed. Treat `hard_constraints` as stop conditions and read the applicable
rule files for their full requirements. Use the exact source and test files to
confirm callers and behavior before editing.

## Environment guidance

### Host capability and permission handling

- Native Linux/Ubuntu is the default host for POSIX shell checks, local test
  harnesses, SSH, and evidence collection. From the repository root, verify
  the host with `uname -a; cat /etc/os-release` and probe required commands
  before using them. See `docs/platform-linux.md` for the package baseline.
- Probe capabilities, not only command names. For example, `unshare` may be
  installed while mount-namespace creation is denied by the kernel or runner;
  local tests must use their documented fallback or report the result as
  `INCONCLUSIVE`.
- Run `/bin/sh -n` and `busybox sh -n` for changed shell files, run the
  maintained local host suite, then use router-side `/bin/sh` and focused
  selftests for final ASUSWRT evidence.
- On Windows, use the conditional WSL2 workflow in
  `docs/platform-windows-wsl.md`. WSL2 is an optional Windows-host path, not a
  prerequisite for native Linux development.
- Never infer router capabilities from host utilities. Probe required tools
  and options on the target device before depending on them.
- Never run disruptive Apply, Restore, Update, or recovery actions without the
  required human preparation and approval.
- After each implementation round, run the relevant validations and review the
  changed code and callers for regressions before continuing.
- `dev-tools/` is for development/test branches. Before preparing a main or
  release branch, verify that developer-only files are excluded explicitly.

If an AI tool does not automatically discover this nested `RULES.md`, tell it
explicitly to read `dev-tools/RULES.md`. A tool-specific adapter may point to
this file, but `dev-tools/RULES.md` and `dev-tools/agent-rules/` remain the
source of truth.
