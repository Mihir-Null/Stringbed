# From prototype to EmptyNet migration

The components through step 5 are implemented in the 0.2 workbench. This is not
a deployment cutover. The original gates below remain acceptance criteria:
source-span preservation, Darwin/full closure execution and booted-machine
activation are not claimed complete. See [validation](validation.md) and the
[architecture](../architecture.md) for actual evidence and deviations.

The current pass is the **Emacs frontend checkpoint** after hands-on review
exposed ambiguous defaults and incomplete discovery/typed editing. Verify the
[complete interaction](emacs.md) on the existing review workspace before resuming
joint recreation of actual EmptyNet modules and one machine. Preserve that
workspace; do not reinitialize it. No live activation follows from frontend review.

| Milestone | Deliverable | Exit gate |
|---|---|---|
| 0 — authoring prototype | Data model, library DSL, descriptors, CLI/menu/native GUI, Nix export, authored why, read-only inspection | Core tests, external extension, GUI interaction, parser/evaluator tests |
| 1 — durable language/workspace | Extension identities/hashes and version locking; workspace schema migrations; generator/source maps; document-preserving source edits; persistent undo/history; live reload with registry replacement | Reopen elsewhere with exact meaning; incompatible/missing extensions explicit; edits survive rename and migration |
| 2 — Nix ecosystem integration | Pinned package/option search, NixOS + standalone/integrated Home Manager adapters, arbitrary module references, types/defaults/documentation, evaluated origins, conflict explanation | Real NixOS and Darwin/Linux home fixtures evaluate/build; no hidden fleet input |
| 3 — complete interfaces | Full-screen TUI, custom widget/command hooks, source/structure navigation, diagnostics, diff and package-removal decisions | External extension introduces syntax/editor/command without patching core; complete edit flow in both interfaces |
| 4 — operational lifecycle | Desired/built/activated/observed manifests, SSH snapshot protocol, build/target separation, plan/apply/rollback, sops and SSH adapters | Disposable VM remote deployment, disconnect/retry, failed switch and rollback tests; secrets absent from artifacts/logs |
| 5 — extract reusable fleet library | Generic modules and small compositions; migration inventory; package producer contracts | Generic consumer fixtures work without any EmptyNet usernames, paths, inventory or repositories |
| 6 — shadow all existing targets | Per-machine workspaces, pinned inputs and parity report | Old/new evaluations and closures compared; every difference explained; successful restore rehearsal |
| 7 — staged fleet cutover | Migrate homes and hosts individually, preserve rollback | Per-host behavior checks and owner-approved activation; independent machine recovery |
| 8 — retire legacy source | Archive Org-generated system, remove duplicate authority and obsolete explorer/just tooling | Every target recovered from new workspace; fleet library has no machine-specific reverse dependencies |

## Complete migration plan

### A. Refresh and freeze the baseline
At migration time inspect current EmptyNet, kittymacs and agentic-stack revisions.
The architecture map from 17 November is a starting point, not an enduring source
of truth. Record each running generation, hardware facts, package closure,
services, user/home configuration, network exposure, secret references and
out-of-band Proxmox procedures. Back up machine workspace source and encrypted
secrets; test recovery before moving authority.

### B. Assign every existing piece an owner

| Existing responsibility | Destination |
|---|---|
| Nix packaging, reusable upstream module APIs | Package-producing repository |
| General authoring, provenance, checks, build/remote orchestration | Stringbed adapters and tools |
| Reusable fleet capabilities and small role compositions | New fleet-library repository (name remains a user decision) |
| Hostnames, users, endpoint bindings, hardware/disk settings, selected roles | Each machine's local versioned workspace |
| Event-bus/approval/dashboard/CI package implementations | Independent package sources; generic fleet module consumes them |
| sops integration | Generic adapter plus fleet policy; encrypted material/recipient decisions remain explicitly owned |
| SSH integration | Generic module; target identities, access grants and known hosts remain workspace/fleet policy |
| Nix/Guix/Home Manager tutorials | Links to upstream documentation |
| Personal rationale, deviations and operational notes | Stable-ID annotations beside relevant composition |
| Existing explorer | Retired after new interfaces cover navigation and why |
| just recipes | Stringbed commands/adapters; retain coverage rather than blindly rename commands |

Some existing modules will split across these owners. For example, the event bus's
implementation, reusable service module, fleet composition and McMissile bindings
are separate responsibilities. Do not move everything from agentic-stack into
Stringbed. Runtime fleet services are not editor infrastructure.

### C. Extract leaf capabilities before compositions
Separate shell conveniences, editor integration, containers, remote desktop and
secret support. Remove hardcoded account access from EXWM. Replace cross-module
shell option reads with an explicit shared interface. Give host metadata one owner
and pass narrow endpoint/identity values rather than the complete inventory.
Each library capability gets a minimal non-EmptyNet consumer fixture. Packages
must build/test independently of the fleet library and Stringbed.

### D. Create machine workspaces and retain originals
Start with a throwaway Linux Home Manager workspace, then shadow real homes.
Represent the owner and agent homes independently but compose their deployment
through a NixOS adapter when appropriate. Keep each workspace's inputs and
extensions pinned. Store source locally with history and an off-machine recovery
copy. Preserve stateVersion and hardware facts; do not generate those from guesses.

Initial target inventory: McQueenix (WSL), Mack (services VM), McMissile (agent VM),
Sandia-Mac (standalone home), and documented/manual Radiator Springs,
StripWeathers and ChickHicks. Do not pretend the latter three are already NixOS
systems. Proxmox hooks and device commands need explicit non-Nix adapters or
preserved procedures, not a fictional Nix closure.

### E. Shadow evaluation and parity
For each target compare old and new effective options, packages, service units,
accounts/groups, filesystem layout, exposed ports, activation actions, sops
ownership and cross-host endpoints. Evaluate/build from the same input locks
first. Classify differences as equivalent, deliberate improvement or defect.
Exercise macOS on a Darwin runner/host; Linux evaluation alone cannot prove its
activation behavior. Use build-host/target-host separation for small VMs.

### F. Rehearse and cut over in dependency order
1. Disposable homes/VMs: prove install, update, failed activation, disconnect and rollback.
2. McQueenix development home, then WSL system, with previous generations retained.
3. Mack: stage services/data backups and test DNS, proxies, media, Guacamole and deployment access.
4. McMissile: migrate last among core Linux machines because agents, event bus,
   approvals and local CI coordinate other targets. Keep an independent admin
   recovery path; test owner and agent identities separately.
5. Sandia-Mac: separate approval/maintenance window and corporate boundary; validate
   certificates, proxy, Podman and editor activation locally on the Mac.
6. Proxmox/device procedures: preserve VMIDs and resource hooks, then migrate only
   operations whose adapter has equivalent checks and recovery. Never combine a
   storage-layout change with the configuration-source migration.

The exact order may change after the runtime dependency audit. In particular,
Mack fronts McMissile, so both sides of that connection must be tested before
retiring either old configuration. Activation approval is per target and concrete
plan; creating this prototype authorizes no fleet activation.

### G. Acceptance and retirement
For every target: identify the active workspace/lock/tool versions, reproduce its
build, restore its source from backup, prove its rollback path, and confirm that
an everyday edit can be located with why/source navigation. Retain old generations
through a stability window chosen during cutover. Archive the old EmptyNet commit
and migration ledger, then remove duplicate Org/Nix authority, old generation CI,
justfile and explorer. Keep only concise personal notes and upstream references.

Completion means the fleet no longer requires the old EmptyNet tree, package
repositories have no fleet reverse dependencies, and every machine can be edited
and recovered independently using its workspace plus pinned reusable sources.
