#!/usr/bin/env python3
"""Linux PTY regression: ANSI editor exits cleanly and restores terminal state.

Run from any directory. Set RACKET to the desired Racket executable.
"""
import os
from pathlib import Path
import pty
import select
import shlex
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[1]
COMMAND = shlex.split(os.environ.get("RACKET", "racket")) + [str(ROOT / "stringbed/main.rkt")]
TIMEOUT = float(os.environ.get("STRINGBED_TEST_TIMEOUT", "90"))


def main():
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    process = None
    output = bytearray()
    try:
        with tempfile.TemporaryDirectory(prefix="stringbed-tui-pty-") as directory:
            workspace = str(Path(directory) / "workspace.rktd")
            subprocess.run(COMMAND + ["init", workspace], cwd=ROOT, check=True,
                           capture_output=True, timeout=TIMEOUT)
            process = subprocess.Popen(
                COMMAND + ["tui", workspace], cwd=ROOT,
                stdin=slave, stdout=slave, stderr=slave,
                env=dict(os.environ, TERM="xterm"))
            deadline = time.monotonic() + TIMEOUT
            while b"\x1b[?1049h" not in output:
                if process.poll() is not None:
                    raise AssertionError("editor exited before entering alternate screen")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("editor did not enter alternate screen")
                if select.select([master], [], [], min(remaining, 0.2))[0]:
                    output.extend(os.read(master, 65536))
            os.write(master, b"d")
            while b"No unsaved changes." not in output:
                if time.monotonic() >= deadline:
                    raise TimeoutError("draft diff did not render")
                if process.poll() is not None:
                    raise AssertionError("editor exited while rendering draft diff")
                if select.select([master], [], [], 0.2)[0]:
                    output.extend(os.read(master, 65536))
            os.write(master, b"q")
            process.wait(timeout=10)
            while select.select([master], [], [], 0.1)[0]:
                output.extend(os.read(master, 65536))
            assert process.returncode == 0, f"editor exit code: {process.returncode}"
            assert b"\x1b[?1049l" in output, "alternate screen was not closed"
            assert b"\x1b[?25h" in output, "cursor visibility was not restored"
            assert termios.tcgetattr(slave) == original, "terminal settings changed after exit"
        print("PTY smoke passed: draft diff, clean quit, cursor and terminal restoration")
    except BaseException:
        print(output.decode(errors="replace"))
        raise
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=10)
        os.close(master)
        os.close(slave)


if __name__ == "__main__":
    main()
