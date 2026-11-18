# Development state

Current assignment: implementation through roadmap step 5, before the first
joint EmptyNet reconstruction. Root `architecture.md` is the design authority.

Implemented: schema migration/history/backups, extension snapshots/reload,
Nix scopes/discovery/evaluated inspection, common CLI/TUI/GUI commands and UI
plugins, explicit build/activation plans and recovery state, independent fleet
capabilities and extraction ledger. See validation for evidence and remaining
environmental gates; implementation is not fleet deployment approval.

Next: recreate selected real EmptyNet modules and one machine together, record
friction/parity findings, iterate, then execute the remaining staged migration
plan. No real machine configuration was replaced in this development pass.

Decisions remaining for that work: fleet-library repository name, public license,
extension distribution/signing policy, complete machine backup conventions,
Darwin execution and disposable NixOS activation rehearsal.
