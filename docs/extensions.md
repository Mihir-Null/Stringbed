# Extension API v0

A trusted Racket module exports `forms`, a list of `form` values from
`stringbed/extension.rkt`. `form` contains a symbolic kind, description, field list
and `(lambda (params workspace) ...)` expansion function. Every form uses this
same API, including built-ins.

`field` holds a symbolic name, type, default and description. Supported field types
are `string`, `attribute`, `boolean`, `integer`, `port`, and `value` (string, boolean,
integer or list of strings). Descriptors drive GUI fields and terminal prompts.
Unknown fields and invalid values are rejected before an edit is committed.

Expansion returns `assignment` values (list of literal attribute-name segments,
value) or `nix-import` values (trusted Nix expression string). Values include
strings, booleans, integers, lists, and explicit `nix-expr` references. Never put
untrusted input into raw expressions; ordinary strings are escaped. Each generated
definition is a separate Nix module carrying `_file = "stringbed:NAME/ID"`, letting
Nix own merging and conflicts. `why` reports authored definitions, not final
winning evaluated values.

The registry is an explicit value, constructed with `make-registry`; duplicate
kinds fail. Use `load-registry` for built-ins plus trusted external modules. Module
loading uses Racket's normal dynamic-require cache; restart the interface after
changing extension code in v0. Live reload/versioning is a later milestone.

The first descriptor editor is generic. Custom widgets and extension-defined
commands are not registered through v0 descriptors. The interfaces themselves can
be replaced: import model/session/compiler, construct a registry, and drive
`execute!`. This preserves semantic operations without requiring a particular UI.

Programmable authoring uses `dsl.rkt`, which returns ordinary workspace data.
Arbitrary Racket generators are supported through explicit `generate`. Data files
never evaluate code. Generated forms are materialized copies; their relationship
to generator source must currently be retained by the user, not inferred.

Extensions should accept explicit parameters, avoid global state and side effects
in expansion, and depend on generic Nix interfaces. Deterministic output is an
extension contract, not a sandbox-enforced guarantee. The shipped fixture is
independent of EmptyNet, agentic-stack and kittymacs.
