# MerVLAN agent rules

This is the canonical policy directory for the development bundle. Start at
`../RULES.md`; it is the only portable agent entry point. Read only the rule
files relevant to the task; do not load every file by default.

## Start and route

1. Read `00-project-safety.md` for every task.
2. Read `05-developer-reference.md` for repository navigation and focused
   `dev-tools/docs/` routing.
3. Add the rules for the affected subsystem: shell, locks, SSH, logging,
   testing, product behavior, or node orchestration.
4. Use the developer notes for system context and the rules for mandatory
   operating constraints.

The rules are intentionally token-conservative: read the relevant first-level
notes and exact code references first, then return for more context when a
contract or safety boundary is unclear. Never omit a relevant safety check to
save tokens.

Do not create a second copy of these rules. If a tool-specific adapter is
needed, point it to `../RULES.md`.
