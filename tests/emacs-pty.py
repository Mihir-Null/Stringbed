#!/usr/bin/env python3
"""Exercise the real standalone terminal Emacs with keyboard input.

Requires Emacs + magit-section + pinned VUI and Racket. STRINGBED_EMACS / STRINGBED_RACKET
select executables. Uses a disposable copy of the old schema-1 example and
a synthetic Nix executable fixture for deterministic catalogue/type results.
"""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import shlex
import struct
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[1]
TIMEOUT = float(os.environ.get("STRINGBED_TEST_TIMEOUT", "90"))


class Terminal:
    def __init__(self, workspace, directory):
        self.master, self.slave = pty.openpty()
        self.original = termios.tcgetattr(self.slave)
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 140, 0, 0))
        self.output = bytearray()
        self.snapshot_path = Path(directory) / "screen.json"
        self.snapshot_path.unlink(missing_ok=True)
        observer = Path(directory) / "observe.el"
        observer.write_text(
            "(require 'json)\n"
            "(run-with-timer 0 0.1\n"
            " (lambda ()\n"
            "  (unless (active-minibuffer-window)\n"
            "   (with-current-buffer (window-buffer (selected-window))\n"
            "    (let ((data `((mode . ,(symbol-name major-mode)) (text . ,(buffer-string))\n"
            "                  (name . ,(buffer-name)) (point . ,(point))\n"
            "                  (vui . ,(and (derived-mode-p 'vui-mode) (vui-get-instance) t))\n"
            "                  (field . ,(and (derived-mode-p 'vui-mode) (vui-field-at) t))\n"
            "                  (key . ,(and (derived-mode-p 'vui-mode) (format \"%s\" (vui-key-at))))\n"
            "                  (diagnostic . ,(when-let ((log (get-buffer \" *Stringbed diagnostics*\"))) (with-current-buffer log (buffer-string))))\n"
            "                  (pending . ,(if stringbed--connection (hash-table-count (stringbed--connection-pending stringbed--connection)) 0))\n"
            "                  (status . ,(and stringbed--connection (stringbed--connection-status stringbed--connection))))))\n"
            f"      (with-temp-file {json.dumps(str(self.snapshot_path) + '.tmp')} (insert (json-encode data)))\n"
            f"      (rename-file {json.dumps(str(self.snapshot_path) + '.tmp')} {json.dumps(str(self.snapshot_path))} t))))))\n")
        emacs_driver = Path(directory) / "observed-emacs"
        emacs_driver.write_text("#!/bin/sh\nexec " + shlex.quote(os.environ.get("STRINGBED_EMACS", "emacs"))
                                + ' "$@" --load ' + shlex.quote(str(observer)) + "\n")
        emacs_driver.chmod(0o755)
        def controlling_terminal():
            os.setsid()
            fcntl.ioctl(self.slave, termios.TIOCSCTTY, 0)

        self.process = subprocess.Popen(
            [str(ROOT / "scripts/stringbed-emacs"), str(workspace)], cwd=ROOT,
            stdin=self.slave, stdout=self.slave, stderr=self.slave, preexec_fn=controlling_terminal,
            env=dict(os.environ, TERM="xterm-256color", STRINGBED_EMACS=str(emacs_driver),
                     PATH=str(Path(directory) / "bin") + os.pathsep + os.environ["PATH"]))

    def drain(self, seconds=0.1):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            if select.select([self.master], [], [], min(0.05, max(0, until - time.monotonic())))[0]:
                self.output.extend(os.read(self.master, 65536))

    def send(self, keys):
        os.write(self.master, keys.encode() if isinstance(keys, str) else keys)
        self.drain()

    def command(self, name):
        self.send(b"\x1bx" + name.encode() + b"\r")

    def buffer(self, name):
        self.send(b"\x18b" + name.encode() + b"\r")

    def snapshot(self):
        self.drain(0.15)
        deadline = time.monotonic() + TIMEOUT
        while not self.snapshot_path.exists():
            if self.process.poll() is not None:
                raise AssertionError("Emacs exited while observing the UI")
            if time.monotonic() > deadline:
                raise TimeoutError("Emacs did not respond to observation command")
            self.drain()
        return json.loads(self.snapshot_path.read_text())

    def wait(self, predicate, description):
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            state = self.snapshot()
            if (state.get("status") or "").startswith("Disconnected:"):
                raise AssertionError(f"Backend disconnected while waiting for {description}: {state.get('diagnostic') or state['status']}")
            if predicate(state):
                return state
            self.drain(0.2)
        raise AssertionError(f"Timed out waiting for {description}: {state}")

    def find(self, text):
        self.send(b"\x1b<\x13" + text.encode() + b"\r")

    def close(self):
        self.send(b"\x18\x03")
        self.process.wait(timeout=10)
        self.drain()
        assert self.process.returncode == 0, self.process.returncode
        assert termios.tcgetattr(self.slave) == self.original, "Emacs changed terminal settings"

    def cleanup(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=10)
        os.close(self.master)
        os.close(self.slave)


def main():
    print("Emacs PTY: starting standalone editor with real backend and synthetic Nix fixture", flush=True)
    terminal = None
    with tempfile.TemporaryDirectory(prefix="stringbed-emacs-pty-") as directory:
        workspace = Path(directory) / "old workspace.sbd"
        original = (ROOT / "examples/home.sbd").read_bytes()
        workspace.write_bytes(original)
        fixture_bin = Path(directory) / "bin"
        fixture_bin.mkdir()
        shutil.copy2(ROOT / "tests/fixtures/nix-ui.py", fixture_bin / "nix")
        try:
            terminal = Terminal(workspace, directory)
            terminal.drain(1)
            state = terminal.wait(lambda s: s["mode"] == "stringbed-mode" and "demo-home" in s["text"] and s["pending"] == 0, "workspace tree")
            assert "home" in state["text"] and "ripgrep" in state["text"]
            root_buffer = state["name"]
            terminal.command("stringbed-prepare-inputs")
            terminal.wait(lambda s: "Pinned inputs" in s["text"] and s["pending"] == 0, "explicit input pin")
            terminal.buffer(root_buffer)
            terminal.send(b"asyntax highlighting\r")
            state = terminal.wait(lambda s: s["mode"] == "stringbed-catalog-mode" and "bat" in s["text"] and s["pending"] == 0, "description package search")
            assert "syntax highlighting" in state["text"]
            catalogue_buffer = state["name"]
            terminal.send(b"\x1b<\r")
            terminal.wait(lambda s: "https://github.com/sharkdp/bat" in s["text"], "package metadata")
            terminal.buffer(catalogue_buffer)
            terminal.send(b"\x1b<a")
            terminal.wait(lambda s: s["pending"] == 0, "selected package addition")
            terminal.buffer(root_buffer)
            terminal.wait(lambda s: "bat" in s["text"], "package in workspace")
            terminal.send(b"opager\r")
            terminal.wait(lambda s: s["mode"] == "stringbed-catalog-mode" and "programs.bat.enable" in s["text"] and s["pending"] == 0, "option discovery")
            terminal.send(b"\x1b<\r")
            state = terminal.wait(lambda s: s["mode"] == "stringbed-form-mode" and "programs.bat.enable" in s["text"], "Boolean option control")
            assert state["vui"] and "boolean" in state["text"], "Option form is not mounted in VUI"
            terminal.send(b"\x1b<\t\r\x03\x03")
            terminal.wait(lambda s: s["pending"] == 0 and s["status"] == "Ready", "typed option validation")
            terminal.buffer(root_buffer)
            terminal.wait(lambda s: "programs.bat.enable" in s["text"] and "true" in s["text"], "configured module option")
            terminal.send(b"s")
            terminal.wait(lambda s: s["pending"] == 0 and "unsaved" not in s["text"], "selected configuration save")
            assert '(attribute . "bat")' in workspace.read_text()
            assert '"programs.bat.enable"' in workspace.read_text()
            terminal.find("ripgrep")
            terminal.send(b"\t\t\r")
            state = terminal.wait(lambda s: s["mode"] == "stringbed-form-mode", "typed package form")
            assert "displayName" in state["text"] and "attribute" in state["text"]
            terminal.send(b"\x1b<\t")
            assert terminal.snapshot()["field"], "TAB did not enter a VUI text field"
            terminal.send(b"\x03\x11")
            terminal.wait(lambda s: s["mode"] == "stringbed-mode", "return to workspace")
            terminal.find("ripgrep")
            terminal.send(b"n")
            terminal.wait(lambda s: "Personal note" in s["text"] and s["mode"] == "stringbed-form-mode", "note form")
            terminal.send(b"\x1b<\t")
            state = terminal.snapshot()
            assert state["field"] and state["key"] == "text", f"TAB did not focus the note field: {state}"
            terminal.send(b"\x01\x0b")
            state = terminal.snapshot()
            assert state["field"] and state["key"] == "text", f"Clearing the note lost VUI field focus: {state}"
            terminal.send(b"Terminal checkpoint note\x03\x03")
            terminal.wait(lambda s: s["pending"] == 0 and s["status"] == "Ready", "note validation")
            terminal.command("stringbed-save")
            terminal.wait(lambda s: s["pending"] == 0 and s["status"] == "Ready", "save")
            assert "Terminal checkpoint note" in workspace.read_text(), "note was not persisted"
            terminal.send(b"\x03\x11")
            terminal.wait(lambda s: s["mode"] == "stringbed-mode", "saved workspace")
            terminal.find("ripgrep")
            terminal.send(b"w")
            state = terminal.wait(lambda s: "Selection and scope" in s["text"] and "Evaluation and freshness" in s["text"], "structured provenance")
            assert "Terminal checkpoint note" in state["text"]
            provenance_buffer = state["name"]
            terminal.send(b"f")
            terminal.wait(lambda s: s["name"] == "builtins.rkt" and "#lang racket/base" in s["text"], "Racket implementation navigation")
            terminal.buffer(provenance_buffer)
            terminal.send(b"p")
            state = terminal.wait(lambda s: "pkgs.ripgrep" in s["text"] and s["pending"] == 0, "selected Nix")
            assert "programs.git.enable" not in state["text"], "selected preview included another node"
            terminal.close()
            terminal.cleanup()
            terminal = Terminal(workspace, directory)
            terminal.drain(1)
            state = terminal.wait(lambda s: s["mode"] == "stringbed-mode" and "Terminal checkpoint note" in s["text"], "reopened workspace")
            terminal.send(b"u")
            terminal.wait(lambda s: "Terminal checkpoint note" not in s["text"] and s["pending"] == 0, "persistent undo")
            terminal.send(b"s")
            terminal.wait(lambda s: s["pending"] == 0 and "saved" in s["text"] and "unsaved" not in s["text"], "undo save")
            assert "Terminal checkpoint note" not in workspace.read_text()
            backups = list((workspace.parent / ".stringbed" / "sources").glob("*"))
            assert any(path.read_bytes() == original for path in backups), "original workspace bytes not backed up"
            terminal.close()
            print("Emacs PTY passed: real backend + synthetic Nix fixture; standalone launch, description search, package selection, VUI Boolean option, tree/VUI fields, note/save, provenance/source, selected Nix, reopen/undo, original backup, terminal restoration")
        except BaseException:
            if terminal:
                print(re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", terminal.output.decode(errors="replace"))[-6000:])
            raise
        finally:
            if terminal:
                terminal.cleanup()


if __name__ == "__main__":
    main()
