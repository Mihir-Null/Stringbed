# Prototype architecture

## Intent and decisions
Stringbed is an extensible Racket authoring environment over Nix. The initial language is an example vocabulary, not a restriction on future languages. Nix owns option merging, evaluation and builds. Machine workspaces own choices; reusable packages must not depend on fleet data.

Accepted: data workspaces, explicit trusted Racket extensions, one command/model API for all interfaces, per-node Nix modules and provenance, ordinary generated flakes. Deferred: arbitrary source round-trip, package discovery, complete evaluated provenance, live activation, extension dependency locking and sandboxing. Rejected: reimplementing Nix evaluation; inferring editable source from arbitrary generated values.

The central model is a versioned hash with target metadata and a list of stable-ID nodes. Nodes contain a kind, parameter hash, note and documentation links. A descriptor supplies fields, validation through field types, and expansion to Nix assignments/imports. Extensions return descriptors; registry construction is explicit. Expansion can use arbitrary Racket. Interfaces edit descriptor parameters and show generated output. Unknown kinds survive reading but block validation/compilation until their extension is supplied.

Workspaces are data, not executable Racket. Reader extensions and graph input are disabled. Extension loading is explicit and trusted code execution. Workspace files do not automatically load code. Compiler output is a projection; never edit it as source. Nix expressions are explicit typed values in the extension API; ordinary strings are escaped.

## Responsibilities
- `model.rkt`: data reading, invariants, immutable edits, persistence and history.
- `extension.rkt`: descriptor API, registry, type validation and Nix value structures.
- `builtins.rkt`: default language, implemented using that API.
- `compiler.rkt`: deterministic Nix emission and authored provenance.
- `session.rkt`: common operations for CLI/TUI/GUI.
- `operations.rkt`: process boundaries and read-only inspection.
- `main.rkt`, `tui.rkt`, `gui.rkt`: user interfaces; no independent compiler semantics.

## Implementation gates
1. Data and extension invariants, escaping, unknown-kind handling.
2. Actual external descriptor, Nix generation and provenance.
3. Shared editing commands, undo, persistence/conflict rejection.
4. CLI, terminal menu and native GUI smoke tests.
5. Nix parsing/evaluation, repository CI and migration roadmap.

## Evidence and critique
NWM inspires source/structure navigation, not reused parser code: its parser drops comments. Notes are first-class data here. Nix module merge semantics remain upstream. Racket permits custom language modules and dynamic extension loading. External modules are executable code: this prototype does not claim they are sandboxed. Generated Racket computations expose parameters, not fictitious reversible edits of their outputs.

References: https://github.com/soymou/NWM ; https://docs.racket-lang.org/guide/languages.html ; https://nixos.org/manual/nixos/stable/#sec-writing-modules ; https://docs.racket-lang.org/gui/
