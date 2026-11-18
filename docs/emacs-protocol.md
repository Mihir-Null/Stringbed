# Emacs protocol, version 1

`stringbed serve` exchanges one UTF-8 JSON object per line on stdin/stdout.
Messages are data; neither endpoint evaluates received source. Diagnostics use
stderr. Every request has `v: 1`, unique string/integer `id`, `method`, and object
`params`. Except `open`, requests include the returned `session` token and current
integer `revision`. Responses echo `v`, `id`, `session`, and captured `revision`,
with either `result` or `error: {code, message, field?, node?}`. Progress messages
also echo those fields and carry `event: "progress", message`. Mutation conflicts
return `stale-revision`; `workspace` accepts an older revision for a matching
session and returns the current draft without discarding unsaved edits. Query responses describe
the snapshot queried; clients discard responses older than their current revision.

JSON strings, booleans, finite numbers, arrays, objects and null are the shared
value vocabulary. Object keys are strings; workspace/form kind symbols become
strings. Nix expressions and Racket procedures are never accepted as wire values.

| Method | Params | Result |
|---|---|---|
| `open` | `path`, optional `dataOnly` boolean | workspace view |
| `workspace` | `{}` | workspace view |
| `forms` | `{}` | array of `{kind,description,fields:[{name,type,default,description}],source:{path,sha256},locked}` |
| `context` | optional `lockFile`, `initialize` (default false) | query context metadata |
| `package-search` | `term`, optional `mode` (`search` or `exact`), `scope` | `{items:[package metadata],context,cached}` |
| `option-search` | `term`, `scope` | `{items:[option metadata],context,cached}` |
| `option-detail` | `path`, `scope` | option metadata with control/type/declarations |
| `add-package` | `attribute`, `scope`, optional `displayName` | workspace view, with `selectedId` |
| `add-option` | `path`, `value`, `scope`, optional `displayName` | workspace view, with `selectedId` |
| `add` | `kind`, object `values`, `scope`, optional `displayName` | workspace view, with `selectedId` |
| `edit` | `node`, object `values`, optional `displayName`, `scope` | workspace view |
| `note` | `node`, `text` | workspace view |
| `docs` | `node`, array `links` | workspace view |
| `remove` | `node` | workspace view |
| `save`, `undo` | `{}` | workspace view |
| `provenance` | `node`, optional `evaluated` boolean | `{node,selection,relationship,authored,implementation,definitions,evaluation,raw}` |
| `nix` | optional `node`, `scope` | `{text,scope,node}` (node restricts preview) |
| `diff` | `{}` | `{text,changes:[{id,label,status,before,after}]}` |
| `export` | `directory` | `{directory,workspaceSha256,lockSha256}` |
| `evaluate`, `build` | `{}` | backend result, never activation |
| `builder/new` | optional `kind` | `{spec,forms,editable:true}` |
| `builder/inspect` | `kind` or `directory` | data inspection: `{spec?,forms,source,directory?,revision?,editable,immutable,reason?,extensionId?}` |
| `builder/preview` | `spec`, optional `values`, `scope`, `sourceDirectory`, `validate` | `{spec,racket,definitions,diagnostics,validation,nativeValidation,forms}` |
| `builder/save` | `spec`, `directory`, optional `sourceDirectory`, `expectedRevision` | saved bundle metadata, `revision`, `sourceSha256`, `reviewDigest`, optional `backupDirectory` |
| `builder/derive` | loaded generated `kind`, new `directory` | saved working derivative metadata plus `extensionId` |
| `builder/pin` | `directory`, `extensionId`, `reviewDigest` | `{workspace,forms,bundle:{directory,entry,sha256}}`, advances session revision |
| `builder/reload` | `{}` | `{workspace,forms}`, advances session revision |
| `builder/refresh-builtins` | `spec` | `{spec,message}`, refreshes only direct builtin identity in the returned draft |
| `cancel` | `request` request ID | `{cancelled:boolean}` |

A workspace view is `{path,name,target,system,dirty,undoAvailable,readOnly,
scopes:[string],nodes:[node],diagnostics:[{node,field,message}],sourceRevision,
validation:{state:"structural-only",message}}`.
Each node is `{id,kind,displayName,scope,params,note,docs,valid}`; old IDs and
parameters are preserved. `valid` and diagnostics describe form structure only;
Nix evaluation is a separate explicit operation. Missing display names are presentation fallbacks, not
migrations. All mutations return a complete refreshed view. No new package or
option exists until its actual selection and typed value validate.

Queries run outside the mutation lock against an immutable workspace snapshot;
mutations serialize and validate their expected revision before commit. A slow
validated mutation rechecks its revision at commit. Cancellation is best effort
and never implies that an already completed mutation was undone. Cancelled queries
have a terminal error response. The protocol exposes no activation operation.

For a package, evaluated provenance queries the scope's `home.packages` or
`environment.systemPackages` option and labels the result a shared package
collection. It does not infer exact selected-package membership or causal origins.
Option nodes query their selected option directly.

Builder specifications use the data schema in [module-builder.md](module-builder.md).
Builder candidates carry `{kind,description,fields,source,available,reason}`;
`source` is `{kind:"builtin"}` or `{kind:"bundle",sha256,entry}`. Development
extensions without a captured bundle are unavailable for composition. Sources
are matched by exact identity, including the entry point. Two revisions of the
same child kind in one builder are rejected rather than silently conflated.

Inspection reads data and verifies receipts without executing code. A pinned
generated bundle has a `spec` but `editable:false`, `immutable:true`, and
`source.locked:true`; `builder/derive` makes a separate editable copy. Handwritten
Racket has no reconstructible spec and returns an explanatory `reason`.
Explicit trusted preview/save may load receipt-verified child dependencies from
`sourceDirectory` into a temporary registry, allowing a portable composition to
work without separately installing its children. Preview returns their resolved
field descriptors in `forms`; clients retain existing bindings while descriptors
are unavailable. This does not modify the active registry or evaluate received
Racket text. Generated `main.rkt` loads only on explicit pin/reload.

Preview always labels structural expansion separately from native Nix checks.
With `validate:true`, a prepared input context checks ordinary emitted assignment
paths and values in the selected scope. `nativeValidation.state` is
`not-evaluated`, `needs-lock`, `type-valid`, `partial`, `invalid`, or `error`; per-definition
results include diagnostic `field` paths. Executable Nix values/imports require
full workspace evaluation. Successful option type checks do not prove assertions,
merge compatibility, or activation behavior.
Unavailable query processes are errors, not evidence of an invalid option value.

Saving an existing working directory requires its last `revision` as
`expectedRevision`. Exact old contents receive a recoverable backup; external
source/spec changes and immutable snapshots are rejected. Saving a bundle does
not pin it or alter the workspace. `reviewDigest` is the entire saved bundle's
identity, distinct from `sourceSha256` for generated Racket alone.

Pinning checks the reviewed digest, session/revision, workspace source baseline,
and extension-lock baseline. While holding the cooperating-writer lock it loads
and validates a candidate registry and serializes its views before adopting the
new lock and registry. A rejected candidate preserves the prior lock, registry,
draft, history, and revision. Reload stages and validates the same way. These
actions do not save the workspace or enter its authored-edit undo history;
previous immutable bundles remain available. Snapshot integrity is not a sandbox
or proof of every dependency an arbitrary trusted Racket module might import.
