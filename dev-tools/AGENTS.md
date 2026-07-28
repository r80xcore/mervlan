# MerVLAN agent entry point

This is the only portable entry point for an AI coding agent working with the
MerVLAN developer bundle.

## Required reading order

1. Read `agent-rules/00-project-safety.md`.
2. Read `agent-rules/05-developer-reference.md`.
3. Read only the additional rule files and developer notes routed by the task.
4. Use `docs/README.md` as the normal developer-document navigation map.

The rules define mandatory operating constraints. The developer notes explain
the addon, its ownership boundaries, runtime flows, limitations, tests, and
deployment procedures. Do not load every document by default; follow the
focused route and return for more context when a contract or safety boundary
is unclear.

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
