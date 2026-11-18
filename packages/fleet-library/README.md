# Fleet library

Extraction-ready Nix flake. Copy this directory into its own repository without changing imports. Its only inputs are nixpkgs, Home Manager and sops-nix; it knows nothing about Stringbed, EmptyNet, agentic-stack, or a particular machine. All `fleet.*` capabilities are opt-in. The `developer` composition is an explicit opt-in import.

Import `nixosModules.default` into a NixOS configuration and `homeManagerModules.default` (or `developer`) into Home Manager. Declare accounts, hardware, state versions, identities, endpoints and dependency pins in the consuming machine profile. Keep package construction in producer repositories; pass their packages to `fleet.runtimeServices` or import their upstream Nix modules directly.

```nix
{
  imports = [ inputs.fleet.nixosModules.default ];
  fleet.ssh.enable = true;
  fleet.ssh.authorizedKeys.alice = [ "ssh-ed25519 ..." ];
  fleet.containers.enable = true;
  fleet.runtimeServices.event-bus = {
    package = inputs.event-bus.packages.${pkgs.system}.default;
    user = "service-user";
    environmentFiles = [ config.sops.secrets.event-bus-env.path ];
  };
}
```

The snippet deliberately requires separately declared accounts and secrets. The runtime adapter wraps a package executable; it does not recreate an event bus, credential broker or orchestration protocol. Services with richer requirements should expose their own upstream NixOS module.

| Export | Responsibility |
|---|---|
| `nixosModules.base` | Flake support, explicitly selected packages, optional garbage collection |
| `nixosModules.ssh` | Explicit server/key/firewall policy; consumer-owned accounts |
| `nixosModules.containers` | Podman and optional Cockpit; no workloads or exposed ports |
| `nixosModules.remote-desktop` | XRDP session command and optional runtime TLS paths |
| `nixosModules.exwm` | Account-checked editor session wrapper; includes remote-desktop module; requires consumer EXWM configuration |
| `nixosModules.runtime-services` | Package-to-systemd adapter with account and runtime environment references |
| `nixosModules.secrets` | sops-nix plus `fleet.secrets` encrypted-file references |
| `homeManagerModules.default` | Opt-in shells, aliases, development tools and consumer editor package |
| `homeManagerModules.developer` | Shell/development composition, still overrideable with normal Nix priorities |
| `homeManagerModules.secrets` | Unmodified upstream sops-nix Home Manager module |

`fleet.exwm.package` must provide an editor/configuration that actually starts EXWM. The wrapper does not install a personal Emacs distribution. XRDP certificate issuance/renewal, ACLs and firewall exposure remain explicit machine policy. sops options accept encrypted source paths and runtime key references, never plaintext secret contents. Home Manager intentionally uses upstream `sops.*` options instead of a second compatibility layer.

## Verification

`nix flake check` evaluates the generic NixOS/Home Manager fixture contract and builds a small proof artifact. `nix build .#fixture-system` and `nix build .#fixture-home` are separate full closure builds. No command activates either fixture. Fixtures use the invented account `fixture`; they do not model a real fleet machine. Reconstructing a real machine and reviewing evaluated options/closures together is the next migration gate.

The library uses Nix's existing module merge, priority and assertion semantics. It adds only convenient opt-in vocabulary; Stringbed's DSL must emit ordinary module imports and settings, preserving escape hatches and keeping this package usable without Stringbed.

Validation in the development workspace: host NixOS and Home Manager derivation
checks passed; x86_64/aarch64 contract evaluation passed; the contract artifact and
full generic Home Manager closure built. No fixture was activated. The home
fixture disables upstream manual generation to avoid a documentation builder's
Unix-socket requirement in this environment; consumer defaults are unchanged.
Local builds needed `--option sandbox-paths '' --option sandbox false` because the
workspace's Nix sandbox mapping referenced a missing bash-static. Normal hosts
should retain their sandbox defaults. Full NixOS closure and runtime activation
remain separate gates; combined all-system full evaluation exceeded workspace memory.
