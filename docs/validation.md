# Prototype validation

Validated 17 November 2026 with Racket 8.16 and Nix 2.26.3 on Linux.

| Verification | Result |
|---|---|
| Core RackUnit tests | 13 test cases passed: reader boundaries, schema/ID rules, escaping, extension expansion, unknown forms, undo, save conflict, safe export, process arguments, lock behavior and single expansion snapshot |
| Nix integration | 8 checks passed: home/server module and flake parsing, strict Nix evaluation with fixture packages, string literal evaluation |
| Native GUI | Xvfb smoke passed: create/show window, edit a descriptor-generated field through its actual Set button, verify model, click Undo and verify restoration |
| CLI and terminal | Init, add/configure/note/why, draft undo/save, numeric menu add/configure/save, Racket generator, external extension and local read-only inspection passed |
| Real Home Manager | Generated home flake locked and passed `nix flake check --no-build --all-systems --no-update-lock-file`; activation derivation evaluated |
| Real NixOS options | Generated server extension evaluated through nixosSystem: nginx port 8080 and localhost document root `/srv/www` |

Real evaluation used nixpkgs `d5cc6833999746cffdfe0598f7bc801a57b887a9`
and Home Manager `5b76c5b8eec25fdbce4f43309b3ee10584374a26`.
The tool's own nixpkgs input is pinned in the committed flake.lock.

No complete system/home closure was built or activated. The server example does
not include boot/hardware configuration. No remote SSH target was contacted;
remote process arguments were tested with an injected runner. GUI testing covers
interaction with generated fields and undo, not every platform/dialog/accessibility
behavior. Darwin and ARM runtime behavior are unverified. GitHub CI status should
be checked on the PR independently of these local results.

A separate review found and corrected numeric menu dispatch, double-read save
baselines, export directory ownership, cross-system check flags, multiple expansion
snapshots, and invalid CLI exit behavior. These corrections have regression tests.

The development environment lacked preinstalled Racket/Nix. Relocated Debian
runtime packages were used for local verification; repository code and CI do not
depend on those environment-specific paths. A multi-file raco invocation spawned
children without the relocated runtime configuration and failed; running the
individual test files through the configured runtime succeeded. This was a local
runtime-layout limitation, not an ignored application test failure.
