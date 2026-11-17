# Development state

Mode: delegated implementation, based on the design agreed in chat.
Current assignment: first authoring prototype, not fleet deployment.

Accepted boundaries: Nix semantics remain upstream; Stringbed owns editing and
operations; fleet-specific choices remain outside the tool. Default forms are
extensible examples. Data workspaces and trusted executable extensions are separate.

Next assignment: durable workspace and extension provenance/version locking,
followed by full NixOS/Home Manager integration fixtures. The roadmap contains
migration gates and per-target rollback requirements.

Open decisions: public project license; fleet-library repository name; extension
package distribution and trust policy; desired custom UI plugin interface; remote
protocol and source storage conventions. No credentials or private configuration files copied into this
public prototype.
