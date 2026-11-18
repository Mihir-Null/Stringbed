# Workbench validation

Validated on Linux with Racket 8.16 and Nix 2.26.3. These are executed local
checks; GitHub CI is a separate result attached to the pull request.

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
