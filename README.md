# Stringbed

A programmable Racket workbench for Nix configuration. Add packages, compose
modules, attach your notes, and inspect authored intent alongside Nix's evaluated
configuration. Nix retains its module, package and build semantics.

**0.2 development workbench:** durable workspaces, pinned extension bundles,
NixOS and Home Manager scopes, CLI/full-screen TUI/native GUI, discovery,
explicit lifecycle plans, and an independent fleet library. Automated fixtures
exercise these components; reconstructing an EmptyNet machine together is the
next user verification pass. See [architecture.md](architecture.md) for component
contracts, reasoning, limitations and validation boundaries.

## Start

Install Racket with GUI libraries; install Nix for evaluation/builds. From a checkout:

```sh
racket stringbed/main.rkt init home.sbd
racket stringbed/main.rkt edit home.sbd '(meta user "alice")'
racket stringbed/main.rkt edit home.sbd '(meta home-directory "/home/alice")'
racket stringbed/main.rkt edit home.sbd '(add package "search")'
racket stringbed/main.rkt edit home.sbd '(set "search" attribute "ripgrep")'
racket stringbed/main.rkt edit home.sbd '(note "search" "Search my research projects.")'
racket stringbed/main.rkt tui home.sbd
racket stringbed/main.rkt gui home.sbd
```

CLI edits save immediately. GUI/TUI edits remain drafts until Save; undo survives
reopening. Choose the actual platform, paths and state version before deployment.
Defaults are example values, not detected machine facts. `nix run` packages the
command; `nix develop` supplies the development environment.

## Export and inspect

```sh
racket stringbed/main.rkt edit home.sbd '(export "export-1")'
racket stringbed/main.rkt lock export-1
racket stringbed/main.rkt search export-1 ripgrep
racket stringbed/main.rkt options export-1 programs.git
racket stringbed/main.rkt explain export-1 programs.git.enable
racket stringbed/main.rkt check export-1
racket stringbed/main.rkt build export-1
```

Exports are ordinary standalone flakes. Existing output directories are never
overwritten. Reuse a prior lock with `(export "export-2" "export-1/flake.lock")`.
Search tries exact package attributes first; broader search can be expensive.
`check` evaluates without building; `build` never activates.

| Shared command | Purpose |
|---|---|
| `(add package "id")`, `(set "id" attribute "fd")` | Add/configure a package |
| `(add module "id")`, `(input fleet "path:/absolute/fleet-library")` | Import independent module providers |
| `(note "id" "Reason")`, `(docs "id" ("URL"))` | Personal annotation and upstream links |
| `(meta target nixos)` | Choose the system adapter |
| `(home alice "/home/alice" "24.11")` | Declare an integrated Home Manager scope |
| `(scope "id" "home:alice")` | Assign a node to that home |
| `(why "id")`, `(nix)`, `(source)` | Authored provenance, Nix projection, editable data |
| `(package-search "export-1" "ripgrep")` | Query the pinned package input |
| `(option-search "export-1" "git" "home:alice")` | Discover scoped Nix option metadata |
| `(evaluated-why "export-1" "programs.git.enable" "home:alice")` | Inspect effective Nix values |
| `(remove "id")`, `(undo)`, `(save)` | Remove, restore, persist |

Integrated homes and system nodes share one configuration but retain separate
option namespaces. See [integrated example](examples/integrated.sbd).

## Program and extend

```sh
racket stringbed/main.rkt generate examples/programmatic.rkt generated.sbd
racket stringbed/main.rkt --extension extensions/web-service.rkt gui examples/server.sbd
racket stringbed/main.rkt pin home.sbd my-forms /absolute/portable-bundle main.rkt
racket stringbed/main.rkt verify home.sbd
```

A bundle exports `forms`; use `stringbed/extension` for the shared API. Pinning
captures every file in the declared directory, including helpers/resources. Keep
`.stringbed` beside the workspace when moving it. Explicit development extensions
and UI plugins (`--plugin`) are trusted Racket. Reload replaces their registry;
failed reload leaves the current editor usable. Opening an editor loads pinned executable
bundles, so only edit workspaces whose code you trust. `show FILE` reads workspace
data without loading any extension or plugin. Generators may use arbitrary
Racket; generated data records its source but does not invert the computation.
See [extension API](docs/extensions.md).

Structured notes/docs are preserved by edits. Canonical saves normalize raw
Racket comments/formatting; exact previous bytes are retained in
`.stringbed/sources/<sha256>`. `migrate FILE` explicitly upgrades schema 1 with an
exact `.v1.bak`; reading old workspaces does not silently migrate them.

## Lifecycle

`inspect [USER@HOST]` reads host/kernel/current generation facts. `observe` reads
adapter-specific generation state. An explicit plan binds saved source, locked
export, built closure and expected target generation:

```sh
racket stringbed/main.rkt --kind home --home-profile /absolute/hm-profile \
  plan home.sbd export-1 plan.json
racket stringbed/main.rkt status plan.json
# Explicit operations on the target recorded in the plan:
racket stringbed/main.rkt apply plan.json
racket stringbed/main.rkt rollback plan.json
```

For NixOS use `--kind nixos`; remote targets/builders are separate `--target
USER@HOST` and `--builder USER@HOST` options before `plan`. Planning builds and
observes; applying activates. Do not use example profiles on a real host. Unknown
outcomes require observation and reconciliation, not blind retry. These adapters
still require a disposable booted-system rehearsal before real fleet cutover.

## Reusable modules and next verification

[packages/fleet-library](packages/fleet-library) is an independent, extraction-ready
flake with opt-in shell/development, SSH, containers, remote desktop, EXWM,
package-service and sops integrations. It has no dependency on Stringbed or
EmptyNet. Machine identities and topology remain in consuming profiles; package
implementations remain with their producers.

- [Architecture and implementation reasoning](architecture.md)
- [Validation evidence](docs/validation.md)
- [Roadmap and complete EmptyNet migration plan](docs/roadmap.md)
- [Capability ownership ledger](packages/fleet-library/MIGRATION.md)

Run `bash tests/check.sh` for local automated tests (Racket, Nix and Xvfb required).
The full Nix fixture check is `bash tests/fleet-library.sh`.
NWM inspired source/structure interaction; no implementation was copied.
