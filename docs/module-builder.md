# Visual module builder

Open your existing workspace with `nix run . -- edit /absolute/path/home.sbd`.
Press `B` or run `M-x stringbed-builder` to create a module definition. This draft
is separate from the workspace: saving it does not add an instance or change a pin.

## Create a reusable module

1. Give the form a name such as `git-tools` and a short description. Choose the
   system or home scope used for previews.
2. Choose **Add parameter**. Name it `enabled`, leave its type as `boolean`,
   choose a default, and add a description for its control.
3. Choose **Add assignment**, then **Find applicable option**. Search for
   `programs.git.enable` and select it from the pinned scope. Bind its value to
   **Parameter: enabled**. Prepare the workspace input lock first if needed.
4. Optionally choose **Compose loaded form**, select `package`, and set its
   `attribute` binding to the literal string `git`. Other forms expose their
   declared fields; each accepts a literal or one of your parameters.
5. Add your note, documentation URLs and upstream source URLs. Rows have move
   and remove controls; sections fold independently. Use `TAB` or the mouse
   to navigate the VUI controls.
6. Choose **Preview expansion** (`C-c C-c`). Inspect the generated Nix definitions
   and Racket source. **Validate with Nix** also checks emitted values against
   the selected scope's pinned option types. The preview uses parameter defaults.
7. Choose **Save working bundle** (`C-c C-s`) and a new directory outside the
   immutable extension store. Later saves update that directory using its recorded
   revision. Choose **Pin reviewed bundle** (`C-c C-p`) and an extension identity
   after reviewing the current preview and saved content.
8. Choose **Use this form** (`C-c C-u`) to configure an instance. Apply it to the
   workspace draft, review the workspace diff, then save the workspace separately.

Invalid text remains visible and blocks preview/save instead of submitting an
older valid value. Changes to the module or workspace make its preview stale.
Native option checks do not cover every module assertion or interaction; use the
workspace evaluate/build actions for those. No builder action activates a machine.

## Reopen and refine

Use `M-x stringbed-builder-open` to reopen a working bundle. Use
`M-x stringbed-builder-derive` to select a pinned builder form and create a working
derivative in a new directory. Edit, preview, save and explicitly repin it.
Repinning an existing extension identity replaces its bundle only after the current
workspace validates with the candidate registry. An incompatible change preserves
the previous pin, registry and workspace revision.

**Open editable Racket** opens generated source in a working directory. If you
hand-edit it, the builder refuses to regenerate over the changed source. Keep it
as a handwritten extension or restore the generated version before visual editing.
Arbitrary handwritten Racket remains inspectable, without an inferred visual graph.

Pinning and trusted preview can execute captured Racket extensions. Content hashes
detect changes; they do not establish trust. Inspection reads data only.

## Schema 1

```json
{
  "schema": 1,
  "kind": "my-tools",
  "description": "My reusable tools",
  "parameters": [
    {"name": "enabled", "type": "boolean", "default": true, "description": "Enable Git"}
  ],
  "assignments": [
    {"path": ["programs", "git", "enable"], "value": {"parameter": "enabled"}}
  ],
  "compositions": [
    {"id": "git", "kind": "package", "source": {"kind": "builtin"},
     "bindings": {"attribute": {"literal": "git"}}}
  ],
  "note": "Personal reason for this module",
  "docs": ["https://nix.dev/"],
  "sources": ["https://git-scm.com/docs"]
}
```

Parameters use the existing `string`, `boolean`, `integer`, `port`, `attribute`
and recursive JSON `value` descriptors. A binding has exactly one `literal` or
`parameter` tag. Definition paths are literal segments; dotted strings normalize
to segments. Defaults, parameter references, duplicate names, child binding keys,
self-composition and supported values are validated before saving. Nix option
existence/type checks and full evaluation are separately labelled protocol actions.

External composition sources are
`{"kind":"bundle","sha256":"<bundle identity>","entry":"relative-entry.rkt"}`.
The builder captures the entire verified source bundle under
`dependencies/<sha256>/`, preserving helpers and nested captured dependencies.
Generated imports are relative; the original source directory is unnecessary.
This captures declared bundles, not arbitrary code's deliberately external imports.
Trusted preview/pinning can execute those captured extensions; inspection cannot.

Generated Racket depends on the existing extension API, plus exact selected
captured modules. Builtin composition records `builtinSha256` and verifies the
installed builtin source at load time, so upgrades cannot silently change meaning.
The explicit **Refresh built-in identity** action updates the draft's direct builtin identity;
preview/save then adopts that changed meaning. Ordinary saves never refresh it,
and captured child modules retain their own identities. The generated module does
not depend on the builder runtime or evaluate supplied source strings.

## Persistence and derivatives

A new working directory can be saved directly. Repeated saves require
`expectedRevision`, the complete directory digest returned by inspection/save.
Source/spec drift and stale revisions refuse overwrite. Unknown files are kept.
Saving stages a complete directory, retains the previous directory as a backup,
and uses a recovery receipt across the two renames. An interrupted ambiguous save
requires inspection of that receipt; it is never silently discarded.

`.stringbed/extensions` snapshots remain immutable. Save a working derivative
elsewhere, preview it, then explicitly repin/reload. Reading a snapshot returns
`editable: false`; saving a derivative can reuse all captured dependencies.

## Racket interface

| Function | Contract |
|---|---|
| `validate-builder-spec` | Spec → normalized data spec |
| `refresh-builder-builtins` | Spec → draft spec with current direct builtin identity; no writes |
| `builder-spec->forms` | Spec, `#:registry` → descriptor list; validates child defaults |
| `builder-expand` | Spec, sample values, scoped workspace, registry → assignment/import structs |
| `preview-builder` | Same inputs → normalized spec, Racket, definition data, structural status |
| `generate-builder-source` | Spec → deterministic Racket source; does not execute it |
| `read-builder-bundle` | Directory → spec, source digest, whole-directory revision, dependency roots, editability |
| `save-builder-bundle!` | Spec, directory; optional `#:registry`, `#:dependencies`, `#:source-directory`, `#:expected-revision` → refreshed inspection and backup path |

Dependency roots are a hash from bundle SHA-256 strings to directory paths.
`exn:fail:builder` carries `code` and `field` for actionable form errors.
See [the structured protocol](emacs-protocol.md) for asynchronous UI operations.
