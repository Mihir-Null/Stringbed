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
