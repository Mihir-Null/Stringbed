#!/usr/bin/env python3
"""Real terminal VUI builder against the Racket backend and synthetic Nix catalogue.

Run with STRINGBED_EMACS and STRINGBED_RACKET as needed.  No user workspace or
machine activation is touched.  Inputs are ordinary keyboard actions, not Lisp.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("stringbed_emacs_pty", ROOT / "tests/emacs-pty.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
Terminal = module.Terminal
TIMEOUT = module.TIMEOUT


def activate(terminal, label):
    terminal.find(label)
    terminal.send(b"\x02\r")


def edit_field(terminal, label, text):
    terminal.find(label)
    terminal.send(b"\t\x01\x0b" + text.encode())
    terminal.drain(0.2)


def wait_prompt(terminal, text, start):
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        terminal.drain(0.1)
        output = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", terminal.output[start:].decode(errors="replace"))
        if text in output:
            return
        if terminal.process.poll() is not None:
            raise AssertionError("Emacs exited before prompt " + text)
    raise AssertionError("Prompt did not appear: " + text + "\n" + output[-2000:])


def main():
    terminal = None
    with tempfile.TemporaryDirectory(prefix="stringbed-builder-pty-") as directory:
        root = Path(directory)
        workspace = root / "workspace.sbd"
        workspace.write_bytes((ROOT / "examples/home.sbd").read_bytes())
        (root / "bin").mkdir()
        shutil.copy2(ROOT / "tests/fixtures/nix-ui.py", root / "bin/nix")
        bundle = root / "terminal-module"
        derivative = root / "derived-module"
        try:
            terminal = Terminal(workspace, directory)
            state = terminal.wait(lambda s: s["mode"] == "stringbed-mode" and s["pending"] == 0 and "demo-home" in s["text"], "workspace")
            root_buffer = state["name"]
            terminal.command("stringbed-prepare-inputs")
            terminal.wait(lambda s: "Pinned inputs" in s["text"] and s["pending"] == 0, "input context")
            terminal.buffer(root_buffer)
            terminal.send("B")
            state = terminal.wait(lambda s: s["mode"] == "stringbed-builder-mode" and "Visual module builder" in s["text"], "VUI builder")
            builder_buffer = state["name"]
            edit_field(terminal, "Form name", "terminal-module")
            activate(terminal, "Add parameter")
            terminal.wait(lambda s: "Parameter name" in s["text"], "parameter controls")
            edit_field(terminal, "Parameter name", "enabled")
            activate(terminal, "Add assignment")
            terminal.wait(lambda s: "Bound to enabled" in s["text"], "parameter binding")
            start = len(terminal.output)
            activate(terminal, "Find applicable option")
            terminal.send("pager\r")
            wait_prompt(terminal, "Map to Nix option", start)
            terminal.send("programs.bat.enable\r")
            terminal.wait(lambda s: "programs.bat.enable" in s["text"] and s["pending"] == 0, "applicable option mapping")
            activate(terminal, "Compose loaded form")
            terminal.send("package\r")
            terminal.wait(lambda s: "Includes package" in s["text"], "composition controls")
            edit_field(terminal, "Literal value", "git")
            edit_field(terminal, "Personal module note", "Created through terminal controls")
            terminal.send(b"\x03\x03")
            state = terminal.wait(lambda s: "Preview matches this draft" in s["text"] and s["pending"] == 0, "backend expansion preview")
            assert "pkgs.git" in state["text"] and '"programs"."bat"."enable" = true' in state["text"], state["text"]
            assert "Native Nix: not-evaluated" in state["text"]
            activate(terminal, "Validate with Nix")
            state = terminal.wait(lambda s: "Native Nix: partial" in s["text"] and s["pending"] == 0, "native option validation distinction")
            assert "programs.bat.enable — type-valid" in state["text"]
            terminal.send(b"\x03\x13")
            terminal.send(str(bundle) + "\r")
            terminal.wait(lambda s: "Saved the editable working bundle" in s["text"] and s["pending"] == 0, "working bundle save")
            first_source = (bundle / "main.rkt").read_bytes()
            assert (bundle / "builder.json").exists()
            edit_field(terminal, "Description", "Updated working module")
            terminal.send(b"\x03\x13")
            terminal.wait(lambda s: "Saved the editable working bundle" in s["text"] and s["pending"] == 0, "repeat save with revision")
            assert (bundle / "main.rkt").read_bytes() != first_source
            assert "Updated working module" in (bundle / "builder.json").read_text()
            terminal.send(b"\x03\x03")
            terminal.wait(lambda s: "Preview matches this draft" in s["text"] and s["pending"] == 0, "updated preview")
            terminal.send(b"\x03\x10\r")
            terminal.wait(lambda s: "Pinned reviewed bundle" in s["text"] and s["pending"] == 0, "explicit extension pin")
            snapshots = list((root / ".stringbed/extensions").glob("*/main.rkt"))
            assert snapshots, "pin did not create an immutable snapshot"
            old_snapshots = {str(path): path.read_bytes() for path in snapshots}
            terminal.send(b"\x03\x15")
            terminal.wait(lambda s: s["mode"] == "stringbed-form-mode" and "enabled" in s["text"], "configure new form instance")
            terminal.send(b"\x03\x03")
            terminal.wait(lambda s: s["mode"] == "stringbed-mode" and "terminal-module" in s["text"] and s["pending"] == 0, "new instance in workspace")
            terminal.send("s")
            terminal.wait(lambda s: s["pending"] == 0 and "unsaved" not in s["text"], "workspace save")
            assert "terminal-module" in workspace.read_text()
            terminal.command("stringbed-builder-open")
            terminal.send(str(bundle) + "\r")
            state = terminal.wait(lambda s: s["mode"] == "stringbed-builder-mode" and "Updated working module" in s["text"], "reopened visual definition")
            assert "Created through terminal controls" in state["text"]
            terminal.buffer(root_buffer)
            terminal.command("stringbed-builder-derive")
            terminal.send("terminal-module\r")
            terminal.send(str(derivative) + "\r")
            terminal.wait(lambda s: s["mode"] == "stringbed-builder-mode" and "Updated working module" in s["text"] and s["pending"] == 0, "working derivative of pinned module")
            edit_field(terminal, "Description", "Derivative edited separately")
            terminal.send(b"\x03\x13")
            terminal.wait(lambda s: "Saved the editable working bundle" in s["text"] and s["pending"] == 0, "derivative save")
            terminal.send(b"\x03\x03")
            terminal.wait(lambda s: "Preview matches this draft" in s["text"] and s["pending"] == 0, "derivative preview")
            terminal.send(b"\x03\x10\r")
            terminal.wait(lambda s: "Pinned reviewed bundle" in s["text"] and s["pending"] == 0, "explicit derivative repin")
            for path, content in old_snapshots.items():
                assert Path(path).read_bytes() == content, "immutable prior snapshot was modified"
            assert "Updated working module" in (bundle / "builder.json").read_text()
            assert "Derivative edited separately" in (derivative / "builder.json").read_text()
            terminal.buffer(root_buffer)
            terminal.close()
            print("Builder PTY passed: VUI keyboard fields, typed parameter, pinned option picker, composition binding, expansion/native validation, revision-guarded save twice, explicit pin/use, workspace persistence, reopen, derivative edit/repin, immutable snapshot preservation, terminal restoration")
        except BaseException:
            if terminal:
                print(re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", terminal.output.decode(errors="replace"))[-9000:])
            raise
        finally:
            if terminal:
                terminal.cleanup()


if __name__ == "__main__":
    main()
