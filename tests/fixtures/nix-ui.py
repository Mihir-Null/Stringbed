#!/usr/bin/env python3
"""Deterministic Nix protocol fixture for interactive Emacs tests only.

It supplies bounded package/option metadata; it does not evaluate Nix. Real Nix
semantics are verified separately by nix-query/integration tests.
"""
import json
from pathlib import Path
import re
import sys

args = sys.argv[1:]
package = {"attribute": "bat", "pname": "bat", "version": "0.fixture",
           "description": "A cat clone with syntax highlighting",
           "homepage": ["https://github.com/sharkdp/bat"], "position": ""}
option = {"path": "programs.bat.enable", "type": "boolean", "control": {"kind": "boolean"},
          "description": "Enable the bat pager", "default": False, "declarations": []}
if "flake" in args and "lock" in args:
    ref = next(value for value in args if value.startswith("path:"))
    (Path(ref.removeprefix("path:")) / "flake.lock").write_text(json.dumps({"version": 7, "nodes": {}}))
elif "search" in args:
    print(json.dumps({"legacyPackages.x86_64-linux.bat": package}))
elif "eval" in args and "--expr" in args:
    expression = args[args.index("--expr") + 1]
    if "candidate =" in expression:
        match = re.search(r"candidate = (.*?); checked =", expression)
        print(json.dumps({"exists": True, "valid": bool(match and match[1] in ("true", "false")), "type": "boolean"}))
    elif "p = lib.attrByPath" in expression:
        print(json.dumps(package))
    elif "matches =" in expression:
        print(json.dumps([option]))
    elif "else describe option" in expression:
        print(json.dumps(option))
    else:
        raise SystemExit("Unsupported fixture Nix expression")
else:
    raise SystemExit(f"Unsupported fixture Nix command: {args}")
