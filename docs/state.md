# Development state

Current assignment: VUI forms and the visual module builder following hands-on review.
Root `architecture.md` is the design authority. Machine reconstruction is paused
until the existing review workspace has passed the [interaction walkthrough](emacs.md).

Implemented: schema migration/history/backups, extension snapshots/reload,
Nix scopes/discovery/evaluated inspection, common CLI/TUI/GUI commands and UI
plugins, explicit build/activation plans and recovery state, independent fleet
capabilities and extraction ledger. See validation for evidence and remaining
environmental gates; implementation is not fleet deployment approval.

The new package uses a versioned asynchronous JSON protocol, preserves existing
workspace IDs/history, discovers pinned packages/options and validates typed
option edits with Nix. VUI owns forms; Magit Section owns trees and provenance;
tabulated lists own catalogues. The visual module builder declares parameters,
assignments and compositions, saves data definitions with generated Racket, and
pins validated bundles explicitly. See the [builder walkthrough](module-builder.md).

Next: review the preserved `mcqueenix-review/home.sbd` workspace in Emacs, record
remaining friction, then recreate selected real EmptyNet modules and one machine.
No real machine configuration was replaced in this pass. Keep the workspace and
its `.stringbed` state; do not rerun `init` or migrate it just to use the frontend.

Decisions remaining for that work: fleet-library repository name, public license,
extension distribution/signing policy, complete machine backup conventions,
Darwin execution and disposable NixOS activation rehearsal.
