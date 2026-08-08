# Project Overview

MerVLAN is an Asuswrt-Merlin addon that assigns configured SSIDs and Ethernet
interfaces to VLANs while protecting the default `br0` bridge. It also
observes active clients, merges router/node inventories, and exposes action
state through the WebUI.

The main router is the coordinator and source of merged state. It owns the
WebUI, shared settings, local VLAN mutation, node SSH/orchestration, and final
client publication. AiMesh nodes receive a curated runtime subset, apply only
their local VLAN configuration, and publish local observation artifacts; a
node is not a second source checkout or a second owner of merged client JSON.

The runtime separates mutation from observation. An ASP/service action starts a
validated worker; the parent owns action serialization, safety state, progress,
aggregation, and the terminal result. VLAN mutation runs under DHCP Hold,
MAC Shield, quarantine, and bridge guards and must verify final placement and
exact security rules before releasing protection. Observation is requested
after the configuration boundary and is serialized by `post_apply_worker.sh`.
Client data is atomically published as complete generations, so a failed
generation leaves the previous readable result intact.

Every asynchronous action has an authenticated owner and an explicit terminal
outcome. Busy, malformed, unknown-owner, invalid-parent, timeout, and cleanup
failures are reported as failures or inconclusive states; a detached process or
missing marker is never completion. The three Apply modes (local, nodes-only,
and main-plus-nodes) converge on one final observation generation.

Update/restore is a stronger maintenance boundary. Update owns a journal,
maintenance lock, and quiesce marker; ordinary mutation and observation are
blocked until terminal cleanup. Boot recovery is permitted only for a matching
interrupted journal and live recovery parent. Standalone Recovery preserves
rollback trees and requires explicit validation/confirmation for restore.

The repository contains production runtime plus developer-only `dev-tools/`.
Developer documentation, plans, evidence, local tests, and specifications are
not runtime dependencies and are not copied to devices except for the two
explicit executable test/safety tools on development branches.
