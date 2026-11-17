# Stringbed

An extensible Racket environment for authoring Nix configurations. Add a package,
configure a module, attach your own note, and see where each definition came from.
Nix continues to evaluate modules and build systems. Stringbed edits the desired
configuration; it does not install packages into the running system.

**Status: first working authoring prototype (0.1).** CLI, a menu-based terminal
editor and a native Racket GUI share one model and command API. Trusted extensions
add forms, fields, validation and expansion without editing interface dispatch.
This is not yet a production fleet manager or an EmptyNet migration.

## Start

Install Racket (including its GUI libraries). Nix is needed only for Nix operations.
From this checkout:

```sh
racket stringbed/main.rkt init my-home.sbd
racket stringbed/main.rkt edit my-home.sbd '(meta user "alice")'
racket stringbed/main.rkt edit my-home.sbd '(meta home-directory "/home/alice")'
racket stringbed/main.rkt edit my-home.sbd '(add package "search")'
racket stringbed/main.rkt edit my-home.sbd '(set "search" attribute "ripgrep")'
racket stringbed/main.rkt edit my-home.sbd '(note "search" "Fast search for my research projects.")'
racket stringbed/main.rkt edit my-home.sbd '(why "search")'
racket stringbed/main.rkt tui my-home.sbd
racket stringbed/main.rkt gui my-home.sbd
```

CLI edits save immediately. GUI/TUI edits are drafts until Save; Undo restores
previous draft states. Set the target system and state version to appropriate
values before using the output. New workspaces default to a Linux Home Manager
example, **not an automatically discovered account**. A macOS home needs, for
example, `(meta system "aarch64-darwin")` and the appropriate `/Users/...` path.

## Generate ordinary Nix

```sh
racket stringbed/main.rkt edit my-home.sbd '(export "my-home-export")'
racket stringbed/main.rkt lock my-home-export
racket stringbed/main.rkt check my-home-export
racket stringbed/main.rkt build my-home-export
```

Export creates a new directory (its parent must exist) with `configuration.nix`, `flake.nix` and authored
`provenance.json`; it refuses to overwrite existing output. Inputs are selected in
the workspace. `lock` fetches and pins them; check/build require that lock and do
not update it. Commit/retain the exported lock. Nix flags are passed as argument
arrays. `check` evaluates all systems without building; `build` builds `#default` without
activation. This prototype intentionally exposes no switch/deploy command.

The same export works with standard `nix flake check --no-build` and `nix build
.#default` from the export directory. No Stringbed runtime is needed by the Nix
module. The server example lacks hardware/boot configuration and is an authoring
example, not a deployable system.

## Extend the language

```sh
racket stringbed/main.rkt --extension extensions/web-service.rkt tui examples/server.sbd
racket stringbed/main.rkt --extension extensions/web-service.rkt gui examples/server.sbd
```

Extension paths are relative to the workspace, not the shell's working directory.
`examples/extensions/web-service.rkt` introduces a `web-service` form with port
and document-root fields. The GUI and terminal editor discover those fields;
expansion generates several Nix definitions. No new core parser or UI dispatch
branch is needed. Extensions are explicitly loaded **trusted executable Racket**.
They are not sandboxed and are not automatically loaded by workspace data.

For programmable composition, use the small library DSL in `stringbed/dsl.rkt`:

```sh
racket stringbed/main.rkt generate examples/programmatic.rkt generated.sbd
racket stringbed/main.rkt tui generated.sbd
```

The example uses a Racket loop and `compose` to generate a toolkit. Edit the Racket
source to change the generator. Materialized workspace edits are independent;
Stringbed does not claim to reverse arbitrary computations. The default vocabulary
and interfaces are ordinary replaceable Racket modules, not a closed language.
See [extension API](docs/extensions.md).

## Shared commands

| Command datum | Effect |
|---|---|
| `(list)`, `(kinds)` | Inspect nodes or available forms |
| `(add package "id")` | Add a stable-ID node with defaults |
| `(set "id" attribute "fd")` | Change a typed parameter |
| `(note "id" "Reason")`, `(docs "id" ("URL"))` | Edit personal notes and references |
| `(meta target nixos)` | Change target; extension-declared target constraints are checked |
| `(input source "github:owner/repo/REV")` | Declare a flake input |
| `(add module "id")` | Import a declared input's module; configure input and attribute fields |
| `(remove "id")`, `(undo)` | Remove a node or undo a draft edit |
| `(why "id")`, `(nix)`, `(source)` | Authored provenance, Nix projection or workspace data |
| `(validate)`, `(save)`, `(export "new-dir")` | Validate, persist, or generate |

Workspace source can also be edited in the GUI, then applied as a validated
transaction. Generated Nix is preview-only. Node notes survive data serialization;
comments outside the workspace datum are not preserved by the serializer.

## Inspect a machine

```sh
racket stringbed/main.rkt inspect
racket stringbed/main.rkt inspect alice@host
```

Inspection reports hostname, kernel and NixOS current/booted system symlinks when
present. SSH uses batch authentication and existing host-key policy. It does not
reconstruct original configuration, collect secrets, or report a complete service
inventory. No remote machine was contacted during development.

## Test

```sh
raco test tests/core.rkt
raco test tests/nix-integration.rkt
xvfb-run -a racket tests/gui-smoke.rkt  # Linux; on desktop use racket directly
bash tests/cli.sh
```

Nix integration parses and evaluates generated expressions with fixture inputs.
Real Home Manager and NixOS option evaluation were also verified locally; full
closure builds remain a separate integration gate. See [validation](docs/validation.md) for actual evidence and limitations.
The included flake also provides `nix run`, `nix develop` and core checks.

## Boundaries and next steps

No fleet names, personal paths or credentials are built into Stringbed. Workspaces
own deployment policy; external packages remain independently usable. Unknown
forms remain readable but block compilation until the extension is provided.
Save uses a cooperating-writer lock, detects external edits and atomically replaces
the file; arbitrary noncooperating writers can still race after that comparison.

Extension content/version pinning, custom widget hooks, full-screen TUI, evaluated
option provenance, package/option discovery, generation manifests and deployment
remain roadmap work. Workspaces are not yet complete reproducible deployment
records: retain the tool/extension revisions and exported `flake.lock` together.

- [Architecture and decisions](docs/architecture.md)
- [Roadmap and EmptyNet migration gates](docs/roadmap.md)
- [Session state](docs/state.md)

NWM inspired the structure/source interaction; no NWM implementation was copied.
Upstream documentation is linked from the design notes rather than reproduced.
