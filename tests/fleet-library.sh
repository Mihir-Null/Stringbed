#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Explicit path keeps this nested independent flake out of parent Git filtering.
"${NIX:-nix}" --extra-experimental-features 'nix-command flakes' flake check --no-build "path:$root/packages/fleet-library"
system=$("${NIX:-nix}" --extra-experimental-features 'nix-command flakes' eval --impure --raw --expr builtins.currentSystem)
"${NIX:-nix}" --extra-experimental-features 'nix-command flakes' build --no-link "path:$root/packages/fleet-library#checks.$system.module-contract"
