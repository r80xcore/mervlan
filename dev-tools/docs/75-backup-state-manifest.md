# Backup state manifest

MerVLAN backup archives intentionally retain a full addon snapshot.  That
snapshot is useful for integrity checking, emergency Recovery, diagnostics,
Undo Restore, Undo Update, and transactional rollback.  A normal user Restore
has a narrower contract: it activates the currently installed validated code
cohort and overlays only the state listed below.

## Authoritative normal-Restore state

| Archive member | Classification | Normal Restore handling |
|---|---|---|
| `settings/settings.json` | User configuration | Merged into the current settings defaults by `merv_settings_merge_preserved`; the current schema and keys remain authoritative. |
| `.ssh/vlan_manager` | Persistent identity | Copied only as a regular mode-600 file after private-key validation. |
| `.ssh/vlan_manager.pub` | Persistent identity | Copied only as a regular mode-644 file and required to match the private key. |
| `.backup_state/ssh_trust/known_hosts.v1` | Persistent trust | Validated in its private backup context, then published through the existing trust transaction. It is never placed in the active addon tree. |
| `tmp/mac_shield.db` | Persistent database | Overlaid when present and copied to the current runtime projection after activation. |
| `tmp/mac_shield_override.db` | Persistent database | Overlaid when present. |
| `tmp/client_name_override.db` | Persistent database | Overlaid when present. |

The three database members are optional for legacy compatibility.  If an old
archive does not contain one, normal Restore retains the current candidate's
copy rather than silently deleting current state.

## Members that are not normal-Restore state

`install.sh`, `uninstall.sh`, `changelog.txt`, `mervlan.asp`, every file under
`functions/`, `settings/` except `settings/settings.json`,
`templates/`, `www/`, `flags/`, documentation, licenses, and package metadata
are executable implementation, current defaults, derived projections, or
documentation.  They remain from the current validated cohort and are never
overlaid from a normal backup.

The reserved `.backup_state/` directory is backup-only payload.  Its trust
file is the authoritative source for the independent trust transaction, while
the directory itself is removed from every normal activation candidate.
Locks, recovery markers, temporary workspaces, generated public projections,
logs, node runtime files, and hardware-derived data are transient or
regenerable and are not normal-Restore inputs.

The archived `r80xcore-test` snapshot was audited against this manifest.  No
additional user-owned persistent member was found; unknown future members must
not be copied implicitly and require an explicit manifest update.

## Semantic boundary

Normal Restore is state-over-current-code.  Explicit Undo Restore, Undo
Update, and transactional rollback retain their existing full-tree semantics
because their purpose is to return to a previously active executable
installation.  A normal Restore from an older archive therefore keeps the
current reported version and current implementation while restoring and
migrating the archived user state.
