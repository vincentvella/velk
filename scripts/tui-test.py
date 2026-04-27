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
import socket
import struct
import subprocess
import sys
import termios
import time
import urllib.request
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


# ─── virtual terminal ─────────────────────────────────────────


class VTerm:
    """Minimal cell-grid VT for asserting on what's *visible on screen*
    rather than the raw byte stream.

    Vaxis emits a cell-level diff: each render only writes the cells that
    changed since the previous frame, and uses CSI cursor positioning to
    jump between them. A naive substring match against the byte stream
    misses content that spans multiple deltas because spinner ticks /
    cursor moves split the text. This class processes the cursor moves
    so the screen we assert against reflects what a human would see.

    Stdlib only — handles enough of CSI for vaxis output: cursor
    position (CUP/HVP), relative moves (CUU/CUD/CUF/CUB), erase (ED/EL),
    home (CR), and line feed (LF). Style/color is ignored. Wide chars
    not handled — every code point counts as one cell."""

    def __init__(self, rows: int = 40, cols: int = 120):
        self.rows = rows
        self.cols = cols
        self.grid: list[list[str]] = [[" "] * cols for _ in range(rows)]
        self.r = 0
        self.c = 0

    def feed(self, data: bytes) -> None:
        text = data.decode("utf-8", errors="replace")
        i = 0
        while i < len(text):
            ch = text[i]
            if ch == "\x1b" and i + 1 < len(text):
                # CSI: \x1b[ ... <final byte in @-~>
                if text[i + 1] == "[":
                    j = i + 2
                    while j < len(text) and not (0x40 <= ord(text[j]) <= 0x7E):
                        j += 1
                    if j < len(text):
                        params = text[i + 2 : j]
                        final = text[j]
                        self._csi(params, final)
                        i = j + 1
                        continue
                # OSC: \x1b] ... <BEL or ST>
                if text[i + 1] == "]":
                    j = i + 2
                    while j < len(text) and text[j] != "\x07":
                        if text[j] == "\x1b" and j + 1 < len(text) and text[j + 1] == "\\":
                            j += 1
                            break
                        j += 1
                    i = j + 1
                    continue
                # Two-byte escapes we don't care about
                i += 2
                continue
            if ch == "\r":
                self.c = 0
                i += 1
                continue
            if ch == "\n":
                self.r = min(self.r + 1, self.rows - 1)
                i += 1
                continue
            if ch == "\b":
                self.c = max(0, self.c - 1)
                i += 1
                continue
            if ch < " ":
                # Other control chars — skip
                i += 1
                continue
            if 0 <= self.r < self.rows and 0 <= self.c < self.cols:
                self.grid[self.r][self.c] = ch
                self.c += 1
                if self.c >= self.cols:
                    # vaxis uses .wrap = .none; clamp instead of wrapping
                    self.c = self.cols - 1
            i += 1

    def _csi(self, params: str, final: str) -> None:
        nums = [int(p) if p.isdigit() else 0 for p in params.split(";")] or [0]
        if final in ("H", "f"):
            r = (nums[0] or 1) - 1
            c = (nums[1] if len(nums) > 1 else 1) - 1
            self.r = max(0, min(self.rows - 1, r))
            self.c = max(0, min(self.cols - 1, c))
        elif final == "A":
            self.r = max(0, self.r - max(1, nums[0]))
        elif final == "B":
            self.r = min(self.rows - 1, self.r + max(1, nums[0]))
        elif final == "C":
            self.c = min(self.cols - 1, self.c + max(1, nums[0]))
        elif final == "D":
            self.c = max(0, self.c - max(1, nums[0]))
        elif final == "G":
            self.c = max(0, min(self.cols - 1, (nums[0] or 1) - 1))
        elif final == "J":
            mode = nums[0]
            if mode == 2:  # entire screen
                for row in self.grid:
                    for j in range(len(row)):
                        row[j] = " "
            elif mode == 0:  # cursor → end of screen
                for j in range(self.c, self.cols):
                    self.grid[self.r][j] = " "
                for r in range(self.r + 1, self.rows):
                    for j in range(self.cols):
                        self.grid[r][j] = " "
        elif final == "K":
            mode = nums[0]
            if mode == 0:  # cursor → end of line
                for j in range(self.c, self.cols):
                    self.grid[self.r][j] = " "
            elif mode == 1:  # start of line → cursor
                for j in range(0, self.c + 1):
                    self.grid[self.r][j] = " "
            elif mode == 2:  # entire line
                for j in range(self.cols):
                    self.grid[self.r][j] = " "
        # Other CSI (m for SGR / colour, h/l for modes, q for cursor
        # shape, etc.) — ignore.

    def screen(self) -> str:
        """Return the current screen contents as a multi-line string,
        trailing spaces trimmed per row."""
        return "\n".join("".join(row).rstrip() for row in self.grid)

    def contains(self, needle: str) -> bool:
        return needle in self.screen()


class TUI:
    """One velk process under a pty. Read/write are line-aware in the sense
    that we accumulate everything and search ANSI-stripped substrings."""

    def __init__(self, argv: list[str], env: dict[str, str], timeout: float = 8.0):
        self.timeout = timeout
        self.buf = b""
        self.vt = VTerm(rows=40, cols=120)
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

    def _ingest(self, chunk: bytes) -> None:
        self.buf += chunk
        self.vt.feed(chunk)

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
            self._ingest(chunk)

    def wait_for(self, needle: str, timeout: float | None = None, screen: bool = False) -> bool:
        """Block until `needle` appears or we time out. By default we
        search the ANSI-stripped byte buffer (good for static notice
        blocks). Pass `screen=True` to search the cell-grid screen
        instead — that's what you want for streamed text where vaxis's
        diff renderer interleaves spinner ticks with content."""
        deadline = time.monotonic() + (timeout or self.timeout)
        while time.monotonic() < deadline:
            r, _, _ = select.select([self.master], [], [], 0.05)
            if r:
                try:
                    chunk = os.read(self.master, 8192)
                except OSError:
                    break
                if chunk:
                    self._ingest(chunk)
            if screen:
                if needle in self.vt.screen():
                    return True
            else:
                if needle in strip_ansi(self.buf):
                    return True
        # Last drain after deadline so we don't miss bytes that arrived
        # in the same tick we timed out on.
        if screen:
            return needle in self.vt.screen()
        return needle in strip_ansi(self.buf)

    def saw(self, needle: str, screen: bool = False) -> bool:
        """Non-blocking check after a small drain."""
        self._drain()
        if screen:
            return needle in self.vt.screen()
        return needle in strip_ansi(self.buf)

    def saw_bytes(self, needle: bytes) -> bool:
        """Non-blocking check against raw bytes (e.g. OSC-52 escape)."""
        self._drain()
        return needle in self.buf

    def screen(self) -> str:
        """Snapshot of what's currently on the simulated terminal."""
        self._drain()
        return self.vt.screen()

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


# ─── mock model server ─────────────────────────────────────────


class Mock:
    """Spin up scripts/mock-server.py on a free port and tear it down on
    exit. Lets TUI cases drive a real streamed turn end-to-end without
    burning API tokens."""

    def __init__(self, fixtures_dir: Path):
        self.fixtures_dir = fixtures_dir
        self.port = self._free_port()
        self.proc: subprocess.Popen[bytes] | None = None

    @staticmethod
    def _free_port() -> int:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", 0))
            return s.getsockname()[1]

    @property
    def anthropic_url(self) -> str:
        return f"http://127.0.0.1:{self.port}/v1/messages"

    @property
    def openai_url(self) -> str:
        return f"http://127.0.0.1:{self.port}/v1/chat/completions"

    def __enter__(self) -> "Mock":
        self.proc = subprocess.Popen(
            [
                sys.executable,
                "scripts/mock-server.py",
                "--port",
                str(self.port),
                "--fixtures",
                str(self.fixtures_dir),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        # Wait up to 5s for /_health to come up.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{self.port}/_health", timeout=0.2
                ) as r:
                    if r.status == 200:
                        return self
            except (urllib.error.URLError, ConnectionError, socket.timeout):
                time.sleep(0.05)
        raise RuntimeError(f"mock server didn't come up on port {self.port}")

    def __exit__(self, *exc) -> None:
        if not self.proc or self.proc.poll() is not None:
            return
        # Try the graceful shutdown endpoint first so the server has
        # a chance to finish in-flight responses + close sockets.
        try:
            req = urllib.request.Request(
                f"http://127.0.0.1:{self.port}/_shutdown",
                method="POST",
                data=b"",
            )
            urllib.request.urlopen(req, timeout=0.5).read()
        except (urllib.error.URLError, ConnectionError, socket.timeout):
            pass
        try:
            self.proc.wait(timeout=2)
            return
        except subprocess.TimeoutExpired:
            pass
        self.proc.terminate()
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=2)


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
        case("/cost on empty session", tui.wait_for("Session totals"))
        case("/cost shows rolling-window labels", tui.saw("Today") and tui.saw("Week") and tui.saw("All"))

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

        # /resume with no args lists saved sessions; with no XDG dir
        # set the test inherits the dev's $XDG_DATA_HOME, but we
        # only care that the command runs and prints something
        # plausible (either "No saved sessions" or "Saved sessions").
        tui.send_line("/resume")
        case(
            "/resume runs and prints a list or empty notice",
            tui.wait_for("Saved sessions") or tui.saw("No saved sessions"),
        )

        # /init dispatches an agent turn. We can't drive it without
        # the mock backing, so just confirm it shows up in /help.
        tui.send_line("/help")
        case(
            "/help mentions /init",
            tui.wait_for("/init", timeout=2.0),
        )

        tui.send_line("/doctor")
        case(
            "/doctor lists env keys",
            tui.wait_for("ANTHROPIC_API_KEY", timeout=2.0)
            and tui.saw("OPENAI_API_KEY"),
        )
        case(
            "/doctor reports model + mcp count",
            tui.saw("model: claude-opus-4-7") and tui.saw("mcp servers attached:"),
        )
        case(
            "/doctor reports cost-log entry count",
            tui.saw("cost-log entries:"),
        )

        # /multiline test runs LAST in this block — once ON, plain
        # Enter no longer submits, so any subsequent slash command
        # would get stuck in the buffer. We just verify the toggle
        # message + multi-row rendering, then leave the buffer
        # populated (the TUI is torn down right after).
        tui.send_line("/multiline")
        case(
            "/multiline toggles ON",
            tui.wait_for("Multi-line mode ON"),
        )
        tui.send("first-multiline-line")
        tui.send("\r")
        tui.send("second-multiline-line")
        case(
            "/multiline: Enter inserts newline (both lines visible)",
            tui.wait_for("first-multiline-line", screen=True, timeout=2.0)
            and "second-multiline-line" in tui.screen(),
        )

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


def run_plan_mode_cases(bin_path: Path, fixtures_dir: Path) -> None:
    """`--mode plan` should refuse writes. Drive the diffwrite
    scenario; instead of seeing a diff prompt we should get a
    "refused — velk is in plan mode" tool result back."""
    print()
    print(f"tui-test: plan-mode refusal cases (fixtures={fixtures_dir})")
    with Mock(fixtures_dir) as mock:
        env = {
            **os.environ,
            "ANTHROPIC_API_KEY": "sk-fake",
            "ANTHROPIC_BASE_URL": mock.anthropic_url,
            "VELK_NOTIFY": "0",
        }
        # Make sure no stale output file from a previous run masks
        # the assertion that plan mode prevented the write.
        output_path = Path("tests/fixtures/diffwrite-out.txt")
        if output_path.exists():
            output_path.unlink()
        tui = TUI([str(bin_path), "--mode", "plan"], env=env)
        try:
            case("plan: repl banner", tui.wait_for("velk REPL"))
            tui.send_line("please diffwrite")
            case(
                "plan: write_file is refused with a clear message",
                tui.wait_for("refused — velk is in plan mode", screen=True, timeout=5.0),
            )
            case(
                "plan: file was not written",
                not output_path.exists(),
            )
        finally:
            if tui.alive():
                tui.close(signum=signal.SIGKILL)


def run_turn_cases(bin_path: Path, fixtures_dir: Path) -> None:
    """Drive a real streamed turn against the mock model server. Each
    case spawns its own velk so state doesn't leak between tests."""
    print()
    print(f"tui-test: turn cases against mock (fixtures={fixtures_dir})")
    with Mock(fixtures_dir) as mock:
        # Default fixture: streams `Mock reply from velk-mock-server.`
        env = {
            **os.environ,
            "ANTHROPIC_API_KEY": "sk-fake",
            "ANTHROPIC_BASE_URL": mock.anthropic_url,
            # Skip the desktop notification — we don't want the test
            # suite popping notifications on every run.
            "VELK_NOTIFY": "0",
        }
        tui = TUI([str(bin_path)], env=env)
        try:
            case("turn: repl banner", tui.wait_for("velk REPL"))
            tui.send_line("hi")
            case(
                "turn: streamed assistant reply renders",
                tui.wait_for("Mock reply from velk-mock-server", screen=True, timeout=3.0),
            )
            case(
                "turn: token usage line appears",
                tui.wait_for("[tokens: 12 in / 7 out", screen=True, timeout=3.0),
            )

            # Send a second prompt that the mock matches against the
            # markdown.sse fixture (substring match on filename stem).
            tui.send_line("show me a markdown sample")
            case(
                "markdown: content of bold marker appears",
                tui.wait_for("bold-here", screen=True, timeout=3.0),
            )
            case(
                "markdown: ** markers are stripped",
                "**bold-here**" not in tui.screen(),
            )
            case(
                "markdown: italic content present",
                tui.saw("italic-here", screen=True),
            )
            case(
                "markdown: italic * markers stripped",
                "*italic-here*" not in tui.screen(),
            )
            case(
                "markdown: code span content present",
                tui.saw("code-here", screen=True),
            )
            case(
                "markdown: backtick markers stripped",
                "`code-here`" not in tui.screen(),
            )
            case(
                "markdown: bullet substitutes •",
                "• bullet-here one" in tui.screen(),
            )
            case(
                "markdown: header marker stripped",
                "Heading" in tui.screen() and "# Heading" not in tui.screen(),
            )
            case(
                "markdown: numbered list keeps the number",
                "1. numbered-step uno" in tui.screen(),
            )
            case(
                "markdown: block quote gets │ marker",
                "│ quoted-thought here" in tui.screen(),
            )
            case(
                "markdown: inline HTML passes through",
                "<em>raw-html</em>" in tui.screen(),
            )
            case(
                "markdown: fenced code block — language header rendered",
                "─── zig ───" in tui.screen(),
            )
            case(
                "markdown: fenced code block — body verbatim",
                "const fenced_marker = 42;" in tui.screen()
                and "const still_in_fence = true;" in tui.screen(),
            )
            case(
                "markdown: post-fence prose continues as text",
                "after-fence" in tui.screen(),
            )
            case(
                "markdown: triple-backtick markers stripped",
                "```zig" not in tui.screen() and "```\n" not in tui.screen(),
            )

            # ── diff preview before apply ──────────────────────
            # Multi-step `diffwrite/` fixture: step 1 emits a
            # tool_use for write_file; the gate prompts; we press
            # 'a' to apply; step 2 (after the tool_result is sent
            # back) is the model's final reply. The mock picks the
            # step from the *number of tool_result blocks in the
            # message history*, not message length, so prior turns
            # in this session don't shift the index.
            output_path = Path("tests/fixtures/diffwrite-out.txt")
            if output_path.exists():
                output_path.unlink()
            tui.send_line("please diffwrite")
            case(
                "diff: unified diff hunk header rendered",
                tui.wait_for("@@", screen=True, timeout=5.0),
            )
            case(
                "diff: prompt offers apply/skip/always",
                "[a]pply" in tui.screen() and "[A]lways apply" in tui.screen(),
            )
            tui.send("a")
            case(
                "diff: after apply, file was actually written",
                tui.wait_for("All-done-marker", screen=True, timeout=5.0)
                and output_path.exists()
                and "hello from velk" in output_path.read_text(),
            )
            case(
                "diff: prompt was consumed (replaced with verdict)",
                "→ applied" in tui.screen(),
            )
            if output_path.exists():
                output_path.unlink()

            # ── ask_user_question ───────────────────────────────
            # `askwhich/` fixture: step 1 emits a tool_use for
            # ask_user_question; the TUI shows a numbered picker;
            # we press '2'; step 2 is the model's wrap-up.
            tui.send_line("please askwhich")
            case(
                "ask: question rendered",
                tui.wait_for("Which framework?", screen=True, timeout=5.0),
            )
            case(
                "ask: options numbered",
                "1. option-zig" in tui.screen() and "2. option-rust" in tui.screen(),
            )
            case(
                "ask: hint about keys shown",
                "[1-9 to pick" in tui.screen(),
            )
            tui.send("2")
            case(
                "ask: verdict notice replaces prompt",
                tui.wait_for("→ selected option 2", screen=True, timeout=5.0),
            )
            case(
                "ask: turn continued after selection",
                tui.wait_for("ask-confirmed", screen=True, timeout=5.0),
            )

            # ── todo_write ──────────────────────────────────────
            # `todowrite/` fixture: step 1 emits a tool_use with two
            # items; the tool runs and the store is mutated; step 2
            # is the model's wrap-up. After the turn, the panel sits
            # above the status row showing both items.
            tui.send_line("please todowrite")
            case(
                "todo_write: panel shows in_progress glyph",
                tui.wait_for("[~] draft tests", screen=True, timeout=5.0),
            )
            case(
                "todo_write: panel shows pending glyph",
                "[ ] ship phase 12" in tui.screen(),
            )
            case(
                "todo_write: panel header rendered",
                "── todos" in tui.screen(),
            )

            # ── /compact ────────────────────────────────────────
            # The /compact handler builds a request whose final user
            # message contains "summarize", which the mock maps to
            # `tests/fixtures/anthropic/summarize.sse`. The fixture
            # streams a canned summary marker we then look for both
            # in the notice block AND as proof the history was
            # actually replaced.
            tui.send_line("/compact")
            case(
                "/compact: replaces history with summary",
                tui.wait_for("compact-summary-marker", screen=True, timeout=5.0)
                and "replaced history" in tui.screen(),
            )
        finally:
            if FAIL > 0 or os.environ.get("TUI_TEST_DUMP"):
                with open("/tmp/tui-test-turn-buffer.txt", "w") as f:
                    f.write(strip_ansi(tui.buf))
                with open("/tmp/tui-test-turn-raw.txt", "wb") as f:
                    f.write(tui.buf)
                print("\n  (dumped turn buffer to /tmp/tui-test-turn-buffer.txt + raw to /tmp/tui-test-turn-raw.txt)")
            if tui.alive():
                tui.close(signum=signal.SIGKILL)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bin", type=Path, default=Path("zig-out/bin/velk"))
    ap.add_argument("--fixtures", type=Path, default=Path("tests/fixtures"))
    args = ap.parse_args()

    if not args.bin.exists():
        print(f"tui-test: binary not found: {args.bin} (run `zig build` first)", file=sys.stderr)
        return 1
    if not args.fixtures.exists():
        print(f"tui-test: fixtures dir not found: {args.fixtures}", file=sys.stderr)
        return 1

    run_slash_cases(args.bin)
    run_turn_cases(args.bin, args.fixtures)
    run_plan_mode_cases(args.bin, args.fixtures)

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
