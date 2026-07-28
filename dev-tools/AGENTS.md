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

- On Windows, prefer WSL2 Ubuntu for POSIX shell checks and local test
  harnesses. Verify the distro reports `VERSION 2` with `wsl.exe --list
  --verbose`.
- Use PowerShell and native OpenSSH for Windows-side deployment, SSH, and
  evidence transfer workflows.
- WSL2 checks do not replace final ASUSWRT BusyBox validation on the router.
- Never run disruptive Apply, Restore, Update, or recovery actions without the
  required human preparation and approval.
- After each implementation round, run the relevant validations and review the
  changed code and callers for regressions before continuing.
- `dev-tools/` is for development/test branches. Before preparing a main or
  release branch, verify that developer-only files are excluded explicitly.

If an AI tool does not automatically discover this nested `AGENTS.md`, tell it
explicitly to read `dev-tools/AGENTS.md`. A tool-specific adapter may point to
this file, but `dev-tools/AGENTS.md` and `dev-tools/agent-rules/` remain the
source of truth.
