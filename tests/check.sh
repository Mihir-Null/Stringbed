#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for suite in core durability nix-query query-context protocol module-builder protocol-builder lifecycle ui-extension tui workbench nix-integration; do
  racket -l raco test "tests/$suite.rkt"
done
bash tests/cli.sh
python3 tests/tui-pty.py
xvfb-run -a racket tests/gui-smoke.rkt
emacs --batch -Q -L emacs -l tests/emacs-test.el -l tests/vui-test.el -l tests/builder-ui-test.el -f ert-run-tests-batch-and-exit
python3 tests/emacs-pty.py
python3 tests/builder-pty.py
