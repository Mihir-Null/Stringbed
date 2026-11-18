# Stringbed architecture

## Scope of this development pass

The current checkpoint adds VUI forms and a visual module builder to the Emacs
workbench. Package discovery, typed option checks and readable provenance remain
the foundation; reusable modules can now have an editable data definition and an
inspectable Racket implementation. Machine reconstruction is paused for hands-on
review. No live fleet activation, migration or deletion is part of this pass.

The product is a programmable environment for authoring and operating Nix
configuration. Its default vocabulary is extensible Racket, not a closed schema
for everything users may express. Nix retains package/module/evaluation/build
semantics; interfaces edit source intent and reveal generated and evaluated views.

## Decisions and alternatives

| Decision | Reason | Alternative rejected or deferred |
|---|---|---|
| Data workspace + trusted executable extensions | Preserve predictable structured edits while permitting arbitrary Racket generators | Making every workspace execute arbitrary code on inspection |
| Content-addressed local extension snapshots | Capture the complete declared bundle, including helper code, and verify before loading | Pinning only the entry file, which misses dependency changes |
| Fresh extension namespaces with shared API identities | Reload code without mixing old definitions into new registries | Mutable global plugin registration |
| Persistent journal keyed by workspace content | Restore undo across sessions and recognize concurrent changes | A GUI-only ephemeral history |
| Explicit NixOS and Home Manager scopes | Their option namespaces and activation lifecycles differ | Pretending all modules share one universal option namespace |
| Native Nix evaluation for winning values and origins | Respect Nix types, merge priorities, conditions and module imports | Implementing a competing Racket module evaluator |
| Common command model plus UI plugins | Every interface can edit the same intent; domain editors live with extensions | A central switch per GUI/TUI feature |
| Immutable deployment plans and state journals | Bind execution to a reviewed build and expected current generation | Re-evaluating mutable source at activation time |
| Independent fleet-library package | Package producers must remain usable without the fleet or editor | Moving agent runtime implementations into Stringbed itself |

## Authority and dependency direction

Machine workspaces own selections, identities, paths, topology, encrypted secret
references and notes. The fleet library owns reusable opt-in capabilities. Package
repositories own reusable software and generic integration. Stringbed owns editing,
provenance and lifecycle tooling. The tool must not require a user's fleet.

Generated Nix, option indexes, previews and manifests are projections. Authored
workspace data, extension bundles and Nix locks are the reproducibility inputs.
A generated node is edited through its authored parameters or generator source;
no interface claims to invert arbitrary Racket computation.

## Component contracts

This document is updated with verified implementation details as the components
are integrated. Each component's failure modes, state transitions and evidence
must be recorded here before the pass is described as complete.

### Data, source and durability

`model.rkt` owns schema validation, stable node IDs, annotations, sessions and
atomic persistence. Schema 2 adds authored/generator provenance; schema 1 stays
readable until explicit migration creates an exact `.v1.bak`. The reader accepts
one data object and disables executable reader extensions and cyclic graphs.
Unknown form kinds can still be inspected as data; expansion fails explicitly.

A session holds a semantic draft, undo history and the exact source/journal
baseline it opened. Saving takes a cooperating-writer directory lock, compares
both baselines, stores exact old bytes in `.stringbed/sources/<sha256>`, writes
history for the new content hash, then atomically replaces source. Reopening
selects history by the source digest. This ordering avoids a crash leaving a new
source with only old history. Noncooperating external writers remain outside the
lock protocol; atomic replacement is not a distributed database transaction.

Notes and documentation URLs are model fields and survive all interfaces.
Arbitrary Racket comments/layout are **not span-preserved** on canonical save;
exact old source remains recoverable by digest. This is a deliberate remaining
part of the original document-preservation milestone, not a claim that a
pretty-printer is a lossless editor. Moving a workspace with its `.stringbed`
directory preserves history and snapshots; renaming a file requires moving its
per-filename lock/history association. Do not infer identity from a display name.

`dsl.rkt` is an ordinary Racket library of replaceable constructors. Generators
materialize a workspace and record their entry path and hash. That provenance is
navigation/audit information, not proof of hermetic execution: arbitrary Racket
may read other files, environment variables or the network. Editing a materialized
node does not rewrite its generator. A future source-span editor should extend
this contract rather than inventing a reversible mapping for arbitrary code.

### Extension identity and reload

`extension.rkt` is the shared runtime API: field/form descriptors and typed Nix
assignment/import/expression/path values. Sharing its module instance matters:
Racket struct predicates from independent namespaces otherwise reject each
other's values. `durability.rkt` loads fresh extension namespaces with that API
attached. The UI plugin loader likewise shares its canonical API/session types.

`pin` snapshots the entire explicitly selected directory, including helper code
and resources. A deterministic file manifest produces its SHA-256 identity;
symlinks and traversal entries are refused. The workspace lock records entry
point, manifest, Racket version and API digest. Every locked load verifies the
snapshot; source changes require an explicit repin. It does not silently fetch
missing code or downgrade a lock. The folder should be a portable bundle, not an
entire development checkout with build artifacts.

These are integrity/reproducibility controls, not a sandbox or signature system.
Code can deliberately import outside its bundle. Opening an editor executes its
trusted pinned forms; explicit development extensions/plugins also execute code.
`show FILE` is the non-executing inspection path. Distribution, signatures and
full dependency closure pinning remain separate work. Live reload constructs a
new registry/plugin pair before replacing the active pair; failure preserves the
old editor state. Extensions cannot silently replace reserved core commands.

### Compilation and the Nix boundary

`compiler.rkt` validates forms, expands each node once per export, and emits both
Nix and authored provenance from that same expansion snapshot. Stable `_file`
labels identify `stringbed:WORKSPACE/NODE` in Nix's own definition diagnostics.
Values escape strings/interpolation and quote attribute paths. Raw Nix expressions
and paths are explicit trusted extension capabilities; ordinary option data can
contain nested lists and attribute sets.

NixOS nodes default to `system`; standalone Home Manager nodes default to `home`.
Integrated NixOS homes use `home:USER` and explicit home metadata. Home-scoped
expansion receives a Home Manager context, so a package becomes `home.packages`
without accidentally writing system packages. This is scope adaptation, not a
second module merge implementation. Each generated module uses native Nix
imports, conditions, priorities, types and assertions.

An export contains `configuration.nix`, `flake.nix`, optional `homes/USER.nix`,
`provenance.json` and `target.json`. The target manifest includes platform, adapter,
homes and the canonical workspace digest. Export destinations must be new;
optional lock reuse copies the prior Nix lock. Exported flakes require no Stringbed
runtime. Keeping machine intent local does not mean losing its recovery copy:
back up the workspace, `.stringbed`, exported lock and tool revision together.

`nix-query.rkt` queries the locked exported flake, never an ambient channel.
Exact package attribute lookup avoids evaluating all of nixpkgs; nonexact/regex
search uses Nix's package search and can be resource-heavy. Option discovery
projects descriptions, types, defaults and declaration locations. Evaluated why
uses Nix's effective configuration and definition locations. Function/deep values
are marked unavailable; module evaluation conflicts remain errors.

Integrated home schema metadata does not expose full evaluated definition origins.
Its effective values come from the containing NixOS evaluation; results explicitly
set `definitionsComplete = false`. Even complete `definitionsWithLocations` is
not a causal graph of every conditional dependency. Authored why and evaluated why
are separate views for this reason. No hand-maintained option catalogue competes
with the pinned input's API.

### Interfaces and programmatic commands

#### Emacs checkpoint decisions

The visible concepts are a workspace, its system/home scopes, selected packages
and module options, personal annotations, and authored versus evaluated results.
Stable internal IDs identify entries; display names and package attributes do not
replace those IDs. Existing IDs and extension references must survive opening and
saving. Selecting a package must add that package; selecting an option must supply
a value checked against the selected scope's pinned Nix option type.

| Decision | Reason | Alternative |
|---|---|---|
| Ordinary Emacs package plus pinned terminal launcher | Reuse the user's editor or launch a predictable standalone interface | Separate new terminal and graphical implementations would duplicate interaction behavior |
| `magit-section` trees, VUI forms, `tabulated-list-mode`, `transient` | Each buffer has one rendering/focus owner; keyed VUI controls retain in-progress edits | Mixing VUI and tui.el in the same form would duplicate state and focus ownership |
| Versioned UTF-8 JSON Lines | Both runtimes have data parsers; booleans, null, arrays and objects have an explicit shared vocabulary | Native s-expression readers differ in booleans, hash syntax and executable reader extensions |
| Racket session is the edit authority | Existing validation, undo and atomic persistence remain shared | A second Elisp configuration model would drift |
| Immutable query snapshots and exact lock reuse | Background results can identify their source and pin; edits cannot silently update inputs | Ambient nixpkgs channels or mutable export directories hide revision changes |
| Explicit initial input locking | The user can see when moving input references are resolved | Automatic locking during a package search obscures reproducibility |

`protocol.rkt` maps structured requests to Racket operations. Session tokens and
revisions bind every edit; delayed query results retain the revision they queried.
The client discards stale presentation results. Work runs off the Emacs command
loop with request correlation, status and cancellation. Cancellation is best
effort and must not claim to undo a completed edit. See the
[wire contract](docs/emacs-protocol.md).

`query-context.rkt` owns disposable, source-bound exports and metadata caches.
The workspace's authored inputs and accepted lock identify query semantics.
Package metadata, Nix module options and application-specific flags remain
distinct. Option controls are derived from upstream metadata; complex/dynamic
types retain an advanced value editor and Nix remains the semantic validator.
Package metadata is the pinned upstream `legacyPackages` set for the target
system; scope-specific overlays and nixpkgs configuration are not projected into
that catalogue yet. Option metadata is evaluated in the selected module scope.

The frontend exposes export, evaluation and build, with no activation operation.
Trusted Racket still executes when loading forms; a data-only route remains
available. Immutable pinned bundles are inspected at their recorded source;
derivative editing and repinning must be explicit. A language browser can show
parameters and expansion without claiming to invert arbitrary Racket programs.

Verification proceeds through protocol and query contracts, typed forms and
stale responses, preservation/reopen/undo, then an actual terminal Emacs session.
The standalone launcher and package integration are separate checks. A green
batch Elisp load is not evidence that focus, navigation or interaction works.

#### Visual module definitions

`module-builder.rkt` owns the versioned data definition and its deterministic
Racket projection. A definition declares typed parameters, option assignments
and compositions of loaded forms, with notes and documentation links. Bindings
are tagged literal values or parameter references; strings are never evaluated
as Racket or Nix source. The builder validates names, bindings and parameter
types before generating a bundle. Native Nix validation remains a separate,
explicit check against the selected scope and input lock.

VUI owns the full editing buffer. Raw malformed text remains visible and blocks
submission; the client must not silently submit an earlier valid value. The
backend owns structural validation, expansion, source generation and persistence.
JSON false, null, empty arrays and empty objects keep their distinct meanings.

Saved bundles contain the data definition and ordinary generated `main.rkt`.
External compositions capture verified dependency bundles and use relative
imports. Generated code shares the canonical extension API rather than copying
its structures. Builtin compositions record their implementation digest; a
changed builtin implementation requires explicit regeneration. The generated
module does not depend on the mutable visual-builder runtime.

Opening a builder definition reads data and verifies its source identity. Hand
changes to generated source are not reverse-engineered or overwritten. Editing
an immutable pinned bundle requires a working derivative. Repeated saves use an
expected bundle revision, stage the new content, preserve unrelated files, and
retain a recoverable previous directory. Saving a definition does not pin it or
change workspace instances.

Pinning stages a verified immutable snapshot and constructs a candidate registry.
The current workspace must validate with that registry before the extension lock
and live registry are adopted. A stale lock or failed load/validation leaves the
old lock, registry and workspace revision intact. This is an explicit executable
extension trust boundary, separate from editing the data-only definition.

See the [module builder walkthrough](docs/module-builder.md) and
[wire contract](docs/emacs-protocol.md) for the public operations.

#### Shared and legacy interfaces

`session.rkt` is the editing command boundary. Each edit computes a candidate,
validates/expands it, and commits only on success. Stable IDs connect parameters,
notes, docs, source and provenance. `main.rkt` exposes those commands to scripts;
only actual CLI changes trigger automatic save, even with persistent undo history.

`gui.rkt` provides descriptor-generated fields, filtering, source editing,
structured diff, Nix/why previews and custom editors. `tui.rkt` provides a
full-screen ANSI editor on a terminal, restoring terminal state on exit, and a
line/menu fallback for pipes. Both support trusted plugin commands/editors and
reload. Removal is a desired-configuration edit with confirmation/diff and undo;
it does not uninstall software from the current machine. Nix activation decides
what changes on the running system.

`ui-extension.rkt` defines command and editor hooks. A GUI editor receives parent,
session, registry, node ID and execution callback; a TUI editor receives those
model objects plus prompt/execute callbacks. Plugin command handlers receive
session, registry and arguments. Plugins can reprogram interactions without
modifying a central core dispatch branch. Trusted plugins can bypass contracts
if deliberately written to do so; this extensibility is not an untrusted addon API.

### Operations and lifecycle

`operations.rkt` owns argv process execution, bounded output/time, SSH target
validation and shell quoting. Remote commands require a shell, so each word is
quoted independently. SSH uses batch mode and normal host-key verification.
Process failure output is withheld from exceptions because it may contain secrets.
The runner is injectable for deterministic failure tests; this is not a replacement
for real SSH and booted-machine integration tests.

`lifecycle.rkt` separates immutable intent from mutable observations:

```mermaid
stateDiagram-v2
    [*] --> Built: build locked export and observe target
    Built --> Activating: verify source, export and generation
    Activating --> Activated: observe expected generation
    Activating --> Unknown: error or lost connection
    Built --> Failed: failure before mutation
    Activated --> RollingBack: verify current generation
    RollingBack --> RolledBack: observe prior generations
    RollingBack --> Unknown: error or lost connection
```

A plan binds exact source bytes, the entire locked export, canonical authored
model identity, target/profile, adapter, built closure and prior selected/active
generations. Wrong adapter/source combinations fail before build. Builds select
`packages.<target-system>.default` explicitly, so a remote builder need not match
the editor's platform. A `PLAN.result` GC root retains the new closure. Plans are
read-only JSON with a content digest; the digest detects accidental edits, not
malicious forgery or authorization. `PLAN.journal.json` records state transitions.

Apply revalidates fingerprints, takes operation/target locks, checks generation
preconditions, copies the closure if remote, rechecks, verifies its activation
entry, selects the profile, activates, and verifies observed state. The build
host and activation host are independent. NixOS uses noninteractive sudo plus
`switch-to-configuration`; Home Manager requires an explicit profile and its
versioned activation driver. Forward and rollback generations must expose
`gen-version >= 1`; unsupported old generations fail before profile mutation.
Existing profiles are required: initial installation
onto a bare machine is not an activation adapter. Lifecycle currently accepts
Linux targets; Darwin execution remains a separate adapter validation gate. Stringbed does not guess a user's profile location.

Rollback is permitted from verified activation and restores the prior active and
selected generations. It does not require the original source to remain available.
After a disconnect or partial switch, state is unknown: inspect/reconcile before a
fresh plan. This conservative rule avoids calling a failed command a successful
rollback. Target-side locks serialize cooperating Stringbed operations across
plans/callers; unrelated nixos-rebuild/home-manager commands do not honor them.
Owned locks are released after known pre-mutation failures. An uncertain activation
or acquisition/release retains a lock; inspect the target and any still-running
process before removing it. There is no automatic claim that uncertainty means the remote process stopped.

`encrypted-secret-metadata` hashes an apparently encrypted SOPS document without
decrypting it. It is a format heuristic, not proof that every field is encrypted.
The fleet's sops adapters refer to encrypted inputs/runtime key paths. User source
can still contain an accidental secret; Stringbed cannot guarantee secrecy for
arbitrary notes, extension output or literal Nix values. Secret decryption and
recipient enrollment remain upstream/runtime concerns.

### Fleet library and migration boundary

`packages/fleet-library` is independently consumable and ready to extract into its
own repository. Its inputs are nixpkgs, Home Manager and sops-nix; no Nix code
imports Stringbed, EmptyNet or agentic-stack. `fleet.*` features are opt-in and
machine accounts/endpoints are explicit consumer inputs. The developer composition
is a small ordinary module that consumers can override with Nix priorities.

Generic SSH, containers, shell/development, remote desktop, EXWM session,
package-service and secret capabilities reproduce reusable *interfaces*, not a
copy of an existing machine. The service adapter consumes producer packages;
complex applications should publish their own Nix module. It does not absorb the
event bus, agent runtime or credential broker into the editor. The capability
ledger assigns every reviewed EmptyNet area to tool, library, producer, machine
policy or retained procedure, including areas not reimplemented in this pass.

The next user-led pass is to review the Emacs interaction on the preserved
workspace, then recreate actual modules and one machine and evaluate parity.
That review may change this example DSL. Full fleet
shadowing, activation and retirement follow the gates in `docs/roadmap.md`.
No existing host's source or running configuration is changed by these fixtures.

## Verification and remaining gates

`docs/validation.md` records executed tests separately from aspirational exit
criteria. Unit/process tests cover persistence, corruption/concurrency, scope
adaptation, extensions, command atomicity and lifecycle failures. Real Nix checks
exercise integrated scopes and the independent generic fleet consumer. GUI, PTY
and disposable SSH checks exercise actual platform boundaries.

Remaining release gates include source-span-preserving edits, complete extension
closure/trust distribution, Darwin execution, booted NixOS/Home Manager deployment
rehearsal and actual EmptyNet parity. The components through step 5 are implemented;
these original roadmap acceptance criteria must not be marked passed by injected
runners or Linux-only evaluation. Source normalization and the integrated-home
provenance limitation are exposed behaviors to assess in the joint pass.

## Upstream references

- [Racket namespaces and module instances](https://docs.racket-lang.org/guide/mk-namespace.html)
- [Racket JSON data representation](https://docs.racket-lang.org/json/)
- [Magit Section as an independent package](https://docs.magit.vc/devel/magit-section/)
- [Terminal mouse support](https://www.gnu.org/software/emacs/manual/html_node/emacs/Text_002dOnly-Mouse.html)
- [VUI](https://github.com/d12frosted/vui.el/tree/004dd852746d8af838107dd7e3f44c5bbea04d79) — pinned form renderer
- [Racket GUI](https://docs.racket-lang.org/gui/)
- [Nix manual](https://nix.dev/manual/nix/latest/)
- [NixOS manual: modules](https://nixos.org/manual/nixos/stable/#sec-writing-modules)
- [Home Manager manual](https://nix-community.github.io/home-manager/)
- [sops-nix](https://github.com/Mic92/sops-nix)
- [NWM](https://github.com/soymou/NWM)

These links own the external concepts. This document records Stringbed's choices,
contracts and remaining limitations rather than reproducing upstream tutorials.
