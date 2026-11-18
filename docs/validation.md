# Workbench validation

## Emacs checkpoint

The 0.3 pass adds an ordinary Emacs package and pinned terminal launcher. The
terminal test uses actual keyboard input and the real Racket backend, with an
explicit synthetic Nix executable for deterministic catalogue/type replies.
Real Nix semantics are checked separately; fixture replies are not evidence of
upstream package builds or machine activation.

| Verification | Evidence |
|---|---|
| Legacy preservation | Core, durability, existing queries, lifecycle, UI hooks, TUI and workbench suites; CLI/menu, real ANSI terminal restoration and native GUI interaction passed |
| Protocol | 12 cases: session/revision checks, auto IDs and actual package selection, typed rejection, JSON values, annotations/save/reopen/undo, old API locks, data-only unknown forms, sibling-sensitive expansion, stale queries/commits, cancellation races, lock cleanup and scoped package-collection provenance |
| Query contexts | 8 cases: explicit first pin, exact lock reuse, unchanged-input lock seeding, package cache reuse, tamper detection, field errors, safe evaluation/build dispatch and cancelled/concurrent preparation cleanup |
| Emacs | 18 ERT cases: JSON shape preservation, stale catalogue/forms, typed controls, legacy invalid values, field errors/keymaps, source protection, unsaved draft guards, actual before/after changes, multi-scope completion and real backend persistence |
| Terminal Emacs | Description search, package metadata and selection, Boolean option control, folding and widget focus, note/save, readable provenance, selected Nix, reopen/undo, exact original backup and terminal restoration |
| Native Nix types | Pinned Boolean, enum, integer, number, nullable, list and attribute-set controls; invalid scalar/nested values and unknown options rejected; throwing defaults remain inspectable |
| Native package/source | Exact ripgrep 15.2.0 lookup returned homepage and an existing absolute Nix source location |
| Native NixOS scope | `services.openssh.enable` discovered as Boolean and rejected value `5`; `networking.hostName` returned effective value and definition locations |
| Integrated Home Manager | `home:demo` option discovery and effective `programs.git.enable = true` passed; incomplete definition origins remain explicitly labelled |
| Packaging | An earlier checkpoint snapshot's pinned launcher built; packaged Emacs loaded Stringbed, Magit Section and Transient under `--quick`. Final source package build is a CI gate as described below |

The preceding PR revision's GitHub workflow failed because apt-installed Nix
could not access its daemon socket. CI now installs Nix explicitly and runs the
interface checks in `nix develop`, so Emacs package availability under `--quick`
does not depend on distribution site initialization. Remote CI results are
reported on the PR separately from these local checks.

The local execution environment lost parts of `/nix/store` after the successful
launcher build. A bounded repair did not recover the full closure. The final
source passed the tests above, but its exact packaged rebuild remains a remote
CI gate; an earlier snapshot's build is not labelled as that final rebuild.

```sh
nix develop --command bash tests/check.sh
bash tests/real-nix.sh  # scoped evaluation plus native query-type fixture
nix build .#emacs      # pinned standalone terminal launcher
```

Broad package searching evaluates upstream nixpkgs and can remain expensive;
the UI exposes progress, cancellation and exact lookup. Scope-specific overlays
are not represented in the upstream package catalogue. VUI focus experiments,
a visual module-definition builder and machine activation remain separate gates.

## Prior fleet-library baseline

Validated on Linux with Racket 8.16 and Nix 2.26.3. These are executed local
checks from the previous workbench milestone; GitHub CI is a separate result
attached to the pull request. They are not claims of fresh full closure builds
for the Emacs pass.

| Verification | Evidence |
|---|---|
| Core | 13 RackUnit cases: safe data reader, schema/IDs, escaping, expansion, undo, concurrent save detection, export consistency |
| Durability | 9 cases: explicit migration, exact backups, persistent history, source/journal conflicts, portable verified bundles, tampering, fresh API identities |
| Nix queries/compiler | 5 portable cases plus 1 real integration case: scoped export, canonical option paths, exact locked package metadata, evaluated why, fresh external path values |
| Lifecycle | 13 cases: adapter/source matching, cross-system selection, legacy HM rejection, stateful target locks, drift, apply/rollback, uncertain outcomes, process limits |
| UI plugins | 10 cases: dispatch, reserved commands, arity, diff/filter, fresh reload |
| TUI | 7 cases plus real PTY interaction: rendering/navigation/command behavior; alternate screen, diff/quit, exact terminal-state restoration |
| Workbench integration | 3 cases: home/scoped edits and nested data, persistent undo/read-only behavior, pinned form+UI bundle identity and optional UI export |
| Nix parser/evaluator | 8 checks on generated home/server modules and flakes, values and escaping |
| Native GUI | Real Xvfb interaction: descriptor edit, undo, plugin command, diff, source navigation and filtering |
| CLI/menu | Init/edit/note/why, numeric menu, undo/save, generators, external forms, inspection and invalid arguments |
| Disposable SSH | Real loopback sshd: quoting, exclusive lock collision, failure status and timeout; no activation |
| Independent fleet library | NixOS and Home Manager derivations evaluated; x86_64/aarch64 contract evaluation passed; x86_64 contract artifact built |
| Full generic home closure | `fixture-home` built successfully; no activation |

Real integrated evaluation and fleet fixtures use nixpkgs
`d5cc6833999746cffdfe0598f7bc801a57b887a9` and Home Manager
`5b76c5b8eec25fdbce4f43309b3ee10584374a26`, recorded in the library lock.
Integrated home `programs.git.enable` evaluated true; exact package lookup found
ripgrep 15.2.0; system hostname inspection returned native definition locations.
Integrated home definition origins remain explicitly incomplete in API results.

## Reproduce

```sh
bash tests/check.sh          # Racket, Nix, Python 3, Xvfb
bash tests/real-nix.sh       # locked system + integrated home queries
bash tests/fleet-library.sh # independent evaluation and small contract build
sudo bash tests/remote-fixture.sh  # disposable loopback sshd only
nix build path:./packages/fleet-library#fixture-home
```

For a full system closure, separately run
`nix build path:./packages/fleet-library#fixture-system`. Neither build activates.
Lifecycle activation tests use an injected runner with stateful generations and
locks. They do not prove real service/file activation or failure recovery in a
booted NixOS VM. That rehearsal, Darwin runtime behavior, and actual EmptyNet
reconstruction/parity remain gates before fleet cutover.

## Environment limits and failures investigated

The local runtime uses relocated Debian packages; individual configured Racket
invocations succeed. Concurrent edits initially left stale compiled dependency
caches; clearing them and rerunning the affected suites resolved those link errors.
No repository code depends on the temporary runtime paths.

This environment blocks Unix sockets. Xvfb therefore used loopback TCP; the home
fixture disables upstream manual generation, whose Python multiprocessing build
requires Unix sockets. The initial full home build failed at that documentation
builder; the final fixture home closure built successfully. This fixture choice
does not disable documentation in consumer machines.

Local Nix also had a missing `/usr/bin/bash-static` sandbox mapping. Builds passed
with the environment-only overrides `--option sandbox-paths '' --option sandbox
false`; project CI retains the host's normal sandbox settings. Exhaustive nixpkgs
search and combined all-system full derivation evaluation exceeded workspace
resources. Exact package lookup and separate host/ARM contract checks succeeded.
No full NixOS closure, Darwin closure, remote activation or live fleet operation
is claimed tested.

Independent review found and corrected wrong-adapter activation, stale export/source
pairing, evaluator/target architecture confusion, cross-plan lock races and leaks,
legacy Home Manager rollback capability, and extension struct identity. Regression
tests cover those boundaries. Scope and remaining design choices are recorded in
[architecture.md](../architecture.md).
