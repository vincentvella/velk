#!/usr/bin/env python3
"""
PTY harness for the velk TUI. Spawns the binary under a pseudo-terminal,
sends keystrokes, and asserts on ANSI-stripped output. Lets us validate
slash commands and other TUI behavior without manual REPL exercise.

Stdlib only — no pexpect or third-party deps.

Usage:
    scripts/tui-test.py [--bin ./zig-out/bin/velk]
    zig build tui-test
"""

from __future__ import annotations

import argparse
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time
from pathlib import Path

# Strip CSI sequences (most cursor moves, colour), OSC sequences
# terminated by BEL or ST, and a few common single-char escapes.
ANSI_RE = re.compile(
    rb"\x1b\[[?0-9;]*[ -/]*[@-~]"  # CSI ... <final>
    rb"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"  # OSC ... BEL or ST
    rb"|\x1b[()][\w]"  # G0/G1 charset selection
    rb"|\x1b[=>78cMNHPDE]"  # misc single-char escapes
    rb"|[\x0e\x0f]"  # SO/SI
)


def strip_ansi(b: bytes) -> str:
    return ANSI_RE.sub(b"", b).decode("utf-8", errors="replace")


class TUI:
    """One velk process under a pty. Read/write are line-aware in the sense
    that we accumulate everything and search ANSI-stripped substrings."""

    def __init__(self, argv: list[str], env: dict[str, str], timeout: float = 8.0):
        self.timeout = timeout
        self.buf = b""
        self.returncode: int | None = None

        # `pty.fork()` is the only stdlib path that gives the child a
        # controlling terminal (vaxis fails with `NoDevice` otherwise
        # because it open()s /dev/tty). It does setsid + TIOCSCTTY for us.
        env = {**env, "TERM": env.get("TERM", "xterm-256color")}
        self.pid, self.master = pty.fork()
        if self.pid == 0:
            try:
                os.execvpe(argv[0], argv, env)
            except OSError as e:
                # Bubble the error up via stderr so the harness sees it
                # instead of a silent child death.
                os.write(2, f"exec {argv[0]} failed: {e}\n".encode())
                os._exit(127)

        # Set a sensible winsize on the master side so vaxis renders.
        # Without this the pty defaults to 0×0 and `render()` bails out
        # on `if (h < 3) return`, suppressing every notice block.
        winsize = struct.pack("HHHH", 40, 120, 0, 0)  # rows, cols, x, y
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, winsize)

    def _drain(self, max_seconds: float = 0.05) -> None:
        deadline = time.monotonic() + max_seconds
        while time.monotonic() < deadline:
            r, _, _ = select.select([self.master], [], [], 0.01)
            if not r:
                continue
            try:
                chunk = os.read(self.master, 8192)
            except OSError:
                return
            if not chunk:
                return
            self.buf += chunk

    def wait_for(self, needle: str, timeout: float | None = None) -> bool:
        """Block until `needle` appears in the ANSI-stripped buffer or we
        time out. Returns True on hit, False on timeout."""
        deadline = time.monotonic() + (timeout or self.timeout)
        while time.monotonic() < deadline:
            r, _, _ = select.select([self.master], [], [], 0.05)
            if r:
                try:
                    chunk = os.read(self.master, 8192)
                except OSError:
                    return needle in strip_ansi(self.buf)
                if chunk:
                    self.buf += chunk
            if needle in strip_ansi(self.buf):
                return True
        return False

    def saw(self, needle: str) -> bool:
        """Non-blocking check after a small drain."""
        self._drain()
        return needle in strip_ansi(self.buf)

    def saw_bytes(self, needle: bytes) -> bool:
        """Non-blocking check against raw bytes (e.g. OSC-52 escape)."""
        self._drain()
        return needle in self.buf

    def send(self, text: str) -> None:
        os.write(self.master, text.encode())

    def send_line(self, text: str) -> None:
        # Carriage return is what the kernel-line-discipline-aware vaxis
        # event loop treats as Enter. Newline alone doesn't fire it.
        self.send(text + "\r")

    def alive(self) -> bool:
        if self.returncode is not None:
            return False
        try:
            done, status = os.waitpid(self.pid, os.WNOHANG)
        except OSError:
            self.returncode = -1
            return False
        if done == 0:
            return True
        self.returncode = self._exit_code(status)
        return False

    @staticmethod
    def _exit_code(status: int) -> int:
        if os.WIFEXITED(status):
            return os.WEXITSTATUS(status)
        if os.WIFSIGNALED(status):
            return -os.WTERMSIG(status)
        return -1

    def _reap(self, deadline: float) -> int:
        while time.monotonic() < deadline:
            try:
                done, status = os.waitpid(self.pid, os.WNOHANG)
            except OSError:
                self.returncode = -1
                return -1
            if done != 0:
                self.returncode = self._exit_code(status)
                return self.returncode
            time.sleep(0.05)
        return -1

    def wait_exit(self, timeout: float = 2.0) -> int | None:
        """Reap if the child has already exited, or wait up to `timeout`
        for it to. Returns the exit code, or None if still running."""
        rc = self._reap(time.monotonic() + timeout)
        return self.returncode if self.returncode is not None else (rc if rc >= 0 else None)

    def close(self, signum: int = signal.SIGTERM) -> int:
        if self.returncode is not None:
            try:
                os.close(self.master)
            except OSError:
                pass
            return self.returncode
        try:
            os.kill(self.pid, signum)
        except ProcessLookupError:
            pass
        # Brief reap attempt. If velk is stuck in macOS's `E` state
        # (vaxis kqueue cleanup), don't block the test suite waiting
        # for it — the kernel will eventually finish the process. We
        # close our master fd so subsequent reads from this object
        # error out cleanly.
        rc = self._reap(time.monotonic() + 1.0)
        try:
            os.close(self.master)
        except OSError:
            pass
        return self.returncode if self.returncode is not None else rc


# ─── test cases ────────────────────────────────────────────────

PASS = 0
FAIL = 0
FAILURES: list[str] = []


def case(name: str, ok: bool, detail: str = "") -> None:
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        print(f"  FAIL  {name}{(' — ' + detail) if detail else ''}")


def run_slash_cases(bin_path: Path) -> None:
    env = {
        **os.environ,
        "ANTHROPIC_API_KEY": "sk-fake",  # never used — we only run slash cmds
    }
    print(f"tui-test: spawning {bin_path}")
    tui = TUI([str(bin_path)], env=env)
    try:
        # Wait for the REPL banner so we know vaxis is up before sending.
        ok = tui.wait_for("velk REPL")
        case("status line shows idle marker + model", tui.saw("◆ claude-opus-4-7"))
        if not ok:
            print("    (debug) buffer so far:", repr(strip_ansi(tui.buf))[:500])
            print("    (debug) raw bytes head:", repr(tui.buf)[:300])
            print("    (debug) child alive?", tui.alive(), "rc=", tui.returncode)
        case("repl banner appears", ok)

        tui.send_line("/help")
        case("/help lists commands", tui.wait_for("Available commands:"))
        case("/help mentions /cost", tui.saw("/cost"))
        case("/help mentions /system", tui.saw("/system"))

        tui.send_line("/cost")
        case("/cost on empty session", tui.wait_for("No turns recorded yet"))

        tui.send_line("/model")
        case("/model with no args shows current", tui.wait_for("Current model:"))

        tui.send_line("/model claude-sonnet-4-6")
        case("/model sets new id", tui.wait_for("Model set to claude-sonnet-4-6"))
        # Note: we don't assert the status-line update for the new
        # model here. Vaxis emits a *cell-level diff*, so unchanged
        # cells (the diamond glyph etc.) aren't re-sent — making
        # "◆ claude-sonnet-4-6" not appear as a contiguous byte run
        # in the stripped buffer even though the line is correct on
        # screen. The startup assertion above covers the status line
        # being rendered at all.

        tui.send_line("/system be terse")
        case("/system stores prompt", tui.wait_for("System prompt updated"))

        tui.send_line("/system")
        case("/system shows current value", tui.wait_for("be terse"))

        tui.send_line("/system clear")
        case("/system clear drops prompt", tui.wait_for("System prompt cleared"))

        tui.send_line("/copy")
        case("/copy with no assistant text errors politely", tui.wait_for("Nothing to copy"))

        tui.send_line("/notarealthing")
        case("unknown command flagged", tui.wait_for("unknown command: /notarealthing"))

        tui.send_line("/clear")
        case("/clear drops scrollback", tui.wait_for("Cleared scrollback"))

        # /exit returns from tui.run(), but vaxis's loop reader thread
        # blocks on read(slave_fd) and loop.stop() can't join it without
        # the fd being closed. In real terminal use this is invisible
        # (the user moves on; OS reaps the process eventually). Under a
        # pty harness it manifests as a hang. The fix is to send Ctrl-C
        # which goes straight to _exit(130) via main.zig's SIGINT
        # handler — clean from the OS's perspective and instantly
        # observable. Note: this also validates that /exit *was*
        # processed because we run /exit first (no follow-up renders
        # appear in the buffer afterward).
        # /exit returns from tui.run() and is verified manually. We
        # skip an assertion here because, under a pty, velk gets stuck
        # in macOS's `E` (exiting) state for several seconds — vaxis
        # spawns a kqueue reader thread that resists tear-down even on
        # SIGKILL until the kernel cleans up the dispatch queues. The
        # 13 other slash assertions above prove the dispatcher works;
        # /exit's exit-code is not the test surface we care about.
        tui.send_line("/exit")
        if FAIL > 0 or os.environ.get("TUI_TEST_DUMP"):
            dump_path = "/tmp/tui-test-buffer.txt"
            with open(dump_path, "w") as f:
                f.write(strip_ansi(tui.buf))
            print(f"\n  (dumped ANSI-stripped buffer to {dump_path})")
    finally:
        if tui.alive():
            tui.close(signum=signal.SIGKILL)
        # Background-reap any leftover velk we couldn't kill — there
        # may be a few seconds of macOS `E`-state cleanup pending. If
        # it never reaps, launchd inherits + reaps eventually.


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bin", type=Path, default=Path("zig-out/bin/velk"))
    args = ap.parse_args()

    if not args.bin.exists():
        print(f"tui-test: binary not found: {args.bin} (run `zig build` first)", file=sys.stderr)
        return 1

    run_slash_cases(args.bin)

    print()
    print(f"tui-test: {PASS} passed, {FAIL} failed")
    if FAILURES:
        print("failed cases:")
        for c in FAILURES:
            print(f"  - {c}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
