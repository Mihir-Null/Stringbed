#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for suite in core durability nix-query lifecycle ui-extension tui workbench nix-integration; do
  racket -l raco test "tests/$suite.rkt"
done
bash tests/cli.sh
python3 tests/tui-pty.py
xvfb-run -a racket tests/gui-smoke.rkt
