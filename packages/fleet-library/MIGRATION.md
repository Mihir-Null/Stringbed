# EmptyNet extraction ledger

Source reviewed: `Mihir-Null/EmptyNet` main `749205720978f4782eec80f31166f4e34aaa343c`. This is a capability ownership ledger, not a claim that every historical implementation was ported. “Generalized” means a reusable primitive is implemented here; original defaults and service behavior still require deliberate reconstruction and comparison.

| Source/capability | Disposition | Destination and remaining work |
|---|---|---|
| `base-nixos.nix` baseline packages, Nix features, GC | Generalized | `fleet.base`; packages/retention are explicit, no global personal policy |
| `base-home.nix`, `profiles-standard-home.nix`, `profiles-dev-home.nix` | Generalized subset | Home shell/developer composition; compare original package inventory during migration |
| `shell-fish-home.nix`, `shell-zsh-home.nix`, `shell-starship.toml` | Generalized subset / personal policy deferred | Both shells and aliases supported; prompt/theme/keybindings belong to profile or separate shared composition |
| `emacs-home.nix` / kittymacs | Package producer | Consumer passes editor package; distribution, plugins and editor documentation remain upstream |
| `containers-nixos.nix` | Generalized | Podman/Cockpit; workload images, ports, mounts and resource policy remain machine data |
| `remote-desktop-nixos.nix`, `exwm-nixos.nix` | Generalized subset | XRDP and explicit editor/account wrapper; Tailscale certificate renewal and desktop plugins deferred to dedicated optional modules |
| SSH server and deployment keys | Generalized | Explicit `fleet.ssh`; keys/accounts/root access policy supplied locally |
| sops secret references across homes/machines | Generalized | `fleet.secrets` for system references, upstream sops module for home; encrypted files/recipients remain outside tool and library |
| `claude-stack-home.nix`, `claude-stack-hosts.toml` | Producer plus host policy | Agent tooling and package outputs stay in agentic-stack; endpoint catalog/account roles supplied by profile |
| Event bus, credential broker, remote-control, orchestrator, secret-page, dashboard, local-ci | Package producer / deferred adapters | Generic package service adapter available; application-specific lifecycle, authentication, schema and dependencies are NOT ported |
| MCP providers, Anthropic/OpenAI/ChatGPT/device credentials | Producer / secret policy | Provider integrations stay upstream; runtime paths via sops, consent/device enrollment remains separate |
| mcmissile agent/orchestrator home configurations | Host policy deferred | Recompose using independent package/module imports and home options; no personal home copied |
| `mack.nix`: media stack, Recyclarr, bootstrap, game servers, Pi-hole, Guacamole | Workload modules deferred | Preserve upstream services/OCI definitions in a future shared module set; storage/users and public exposure remain host policy |
| Mack Cockpit/Podman | Generalized | `fleet.containers`, workloads intentionally separate |
| Mack Caddy/cloudflared/DNS | Host/network policy deferred | Domains, tunnels, credentials and ingress topology require explicit local profile |
| mcmissile Ollama, nix-ld, Guix, ttyd, ntfy | Upstream modules / deferred composition | Import upstream NixOS options directly; no duplicate service abstraction required |
| mcmissile Proxmox wrapper/API token | Producer plus host policy | Wrapper upstream; endpoint, authorization and token references in local profile |
| Tailscale connectivity/order/cert issuance | Upstream module / deferred composition | Explicit network identity and renewal policy; generic runtime adapter accepts ordering |
| `mack-hardware.nix`, disko, QEMU, WSL | Host/platform policy | Hardware/platform modules referenced by local machine; never inferred by this library |
| zram, resource slices, timezone, firewall, networking | Host policy | Explicit machine configuration, optionally future independently parameterized compositions |
| `mihir-home.nix`, `mihir-nixos.nix`, `mihir-darwin.nix`, `sandia-mac.nix` | Personal/platform policy deferred | No identities copied; nix-darwin support requires a separate platform verification pass |
| `mack-home.nix`, `mcmissile-home.nix`, `mcqueenix-home.nix`, `mcqueenix.nix`, `wsl-nixos.nix` | Host composition deferred | Recreate with user during first joint verification, compare effective options and package closures |
| Org/tangle provenance, explorer, profile/module catalogs | Stringbed responsibility | Annotations and provenance live in local profile/tool; upstream explanations become links |

## Migration gate

1. Select one real machine with the user and record current evaluated system/home options and package closure.
2. Reconstruct its reusable module compositions and local hardware/accounts/network/secret references without activation.
3. Classify each difference as intended simplification, missed behavior or producer-owned dependency. Add narrowly scoped shared adapters only when repeated policy justifies them.
4. Build system/home closures; review credentials, boot/storage and remote access on that target before planning a reversible deployment.
5. Expand to remaining machines, separating macOS/WSL verification from Linux desktop/server checks. Retire old literate/tangle/explorer workflows only after parity and rollback are demonstrated.
