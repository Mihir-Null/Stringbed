#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Pin the generic combined fixture to the same independently tested library inputs.
racket -e '(require "stringbed/model.rkt" "stringbed/compiler.rkt" "stringbed/session.rkt")
(define w (read-workspace "examples/integrated.sbd"))
(define pinned (hash-set w (quote inputs)
  (hash (quote nixpkgs) "github:NixOS/nixpkgs/d5cc6833999746cffdfe0598f7bc801a57b887a9"
        (quote home-manager) "github:nix-community/home-manager/5b76c5b8eec25fdbce4f43309b3ee10584374a26")))
(export-workspace pinned (load-registry) (vector-ref (current-command-line-arguments) 0)
 #:lock-file "packages/fleet-library/flake.lock")' -- "$work/export"
# Extra unrelated lock nodes are harmless; normalize root mapping before read-only queries.
racket stringbed/main.rkt lock "$work/export"
STRINGBED_INTEGRATION_FLAKE="$work/export" racket -l raco test tests/nix-query.rkt
racket -l raco test tests/query-types.rkt
