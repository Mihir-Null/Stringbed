# Emacs workbench

Open an existing workspace with `nix run . -- edit /absolute/path/home.sbd`.
Keep its adjacent `.stringbed` directory: it contains history, trusted extension
snapshots and query locks. Opening does not rewrite the workspace or change IDs.

## Select, configure, inspect and save

1. Press `?`, then `L` to prepare the initial input lock, or `I` to use an existing
   exported `flake.lock`. Subsequent queries reuse it without updating inputs.
2. Press `a` and enter a package name or description. Select a catalogue row;
   `RET` shows metadata and documentation, and `a` adds the actual package.
   Stringbed generates an internal ID; it never substitutes an unrelated default.
3. Back in the workspace, press `o` to discover options for the chosen scope.
   Inspect an option with `RET`, change its typed value, then choose **Validate
   and apply** or press `C-c C-c`. Invalid values leave the draft unchanged.
4. Select an entry and use `n` for your note or `D` for documentation URLs.
   Use `w` for provenance, `p` for that entry's Nix, and `f` for its Racket
   implementation. `C-u w` requests evaluated provenance from the current pin.
5. Use `l` for loaded forms, their parameters and implementation revisions.
   Existing extension forms can create new instances through generated controls.
6. Press `d` to review changes, then `s` to save. Use `? r` to reopen and `u`
   to undo; save again to persist the undo. `? E`, `? v` and `? b` export,
   evaluate and build. The frontend has no activation command.

Use `TAB` to fold workspace and provenance sections, mouse buttons to activate
controls, and catalogue column headings to sort. `C-c C-k` cancels pending
discovery, provenance, evaluation or build queries. Edits finish their validation
before another edit can proceed; cancellation does not undo a completed edit.

Broad nixpkgs searches may be expensive. A failed search offers an exact
attribute lookup. Results and errors identify their scope and query context;
late results cannot overwrite a newer edit or search. A package may have no
matching Nix module options; application flags are a separate source of metadata.
The package catalogue describes upstream nixpkgs for the pinned system, including
source locations. Scope-specific overlays and package configuration are not yet
reflected in that catalogue; option discovery uses the actual selected scope.

## In your existing Emacs

Install [Magit Section](https://docs.magit.vc/devel/magit-section/) and optionally
[Transient](https://magit.vc/manual/transient/), add `emacs/` to `load-path`, then:

```elisp
(require 'stringbed)
;; When the stringbed executable is on exec-path:
(setq stringbed-command '("stringbed" "serve"))
;; Or use a checkout directly:
;; (setq stringbed-command '("racket" "/absolute/Stringbed/stringbed/main.rkt" "serve"))
```

Run `M-x stringbed-open`. The same package works in graphical and terminal
Emacs and does not depend on Kittymacs. Nix consumers can include
`packages.${system}.emacs-package` in an Emacs package environment. The standalone
launcher supplies pinned dependencies, a minimal configuration and terminal mouse
support without loading your personal initialization file.

## Trust, values and scope

Opening an editable workspace loads trusted Racket extension code. Use a prefix
argument with `stringbed-open` for data-only inspection; the CLI `show FILE` also
reads data without executing extensions. Integrity hashes verify content, not trust.

Boolean, enum, numeric, string and nullable values have controls. Lists and
attribute sets use a JSON editor; advanced Nix types may also require this view.
JSON `false`, `null`, `[]` and `{}` remain distinct. No wire value is executable
Racket or raw Nix. Nix checks the selected option's type; full evaluation remains
separate because module assertions and interactions involve the whole workspace.

Provenance separates authored selections, personal annotations, expansion and
evaluated results. Integrated Home Manager definition origins remain incomplete.
The language browser does not reconstruct arbitrary Racket as a visual graph.
Editing pinned implementations requires a working derivative and explicit repin;
a visual module-definition builder is a later step.

Canonical save preserves structured data and makes exact byte backups, but
normalizes raw source comments/layout. See [architecture](../architecture.md)
and [validation](validation.md) for these boundaries and executed checks.
