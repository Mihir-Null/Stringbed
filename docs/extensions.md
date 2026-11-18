# Extension API

A trusted module exports `forms`, a list of `form` values from
`stringbed/extension`. A form contains kind, description, fields and a
`(params workspace) -> definitions` function. Fields specify name, type, default
and help text. Types are string, attribute, boolean, integer, port and recursive
`value` data (strings, booleans, integers, lists and attribute sets).

Expansion returns `assignment` or `nix-import` values. Assignments use literal
attribute-name segments. `nix-expr` and `nix-path` are explicit trusted capabilities;
normal data is escaped by the compiler. Keep expansion deterministic and free of
side effects. Nix owns merging and errors; `_file` labels carry stable node IDs.
The workspace passed to a home-scoped form has target `home` and that home's metadata.

For portable bundles use `(require stringbed/extension)`, not relative paths that
escape the bundle. `pin FILE ID DIRECTORY ENTRY` captures every file in DIRECTORY;
keep it small and exclude generated files yourself. Snapshots verify before every
load. Development `--extension` paths are relative to the workspace. Reload uses
fresh namespaces and rejects duplicate kinds before replacing the active registry.
Hashes do not sandbox code or pin deliberately imported external dependencies.

## UI plugins

Export `ui-plugin`, a `plugin` struct from `stringbed/ui-extension`:

```racket
(plugin
 (hash 'my-command (lambda (session registry arguments) ...))
 (hash 'my-kind (lambda (parent session registry node-id execute) ...))
 (hash 'my-kind (lambda (session registry node-id ask execute) ...)))
```

The three hashes hold command, GUI editor and TUI editor handlers. Commands cannot
shadow reserved core operations. Editors should use the execute callback to retain
validation, undo and diff behavior. Explicit plugins load with `--plugin FILE`;
reload replaces complete plugin/registry values. Pinned form bundles can also export
`ui-plugin`; the editor loads it from the verified snapshot. A UI-only bundle must
still export an empty `forms` list. These hooks are trusted programs,
not restricted widget descriptions. CLI plugin commands use the same dispatcher.

`dsl.rkt` supplies optional constructors/compose helpers for arbitrary generators.
`generate` records the generator entry path/hash, then materializes ordinary data.
It does not reverse edits into the generator or claim a complete source closure.

See [architecture](../architecture.md) for trust boundaries and
[examples/extensions/web-service.rkt](../examples/extensions/web-service.rkt)
for a minimal form. Keep upstream explanations in links and personal rationale in
node annotations.
