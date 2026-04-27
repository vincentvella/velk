#!/usr/bin/env python3
"""
velk mock model server — replays canned API responses so we can run velk
during development (and CI) without burning API tokens.

Usage:
    scripts/mock-server.py [--port 8765] [--fixtures tests/fixtures]

Then point velk at it:
    ANTHROPIC_BASE_URL=http://127.0.0.1:8765/v1/messages \
        ANTHROPIC_API_KEY=sk-fake \
        ./zig-out/bin/velk "anything"

    OPENAI_BASE_URL=http://127.0.0.1:8765/v1/chat/completions \
        OPENAI_API_KEY=sk-fake \
        ./zig-out/bin/velk --provider openai "anything"

How fixtures are picked
-----------------------
1. If the request has an `X-Mock-Scenario: <name>` header, we serve
   `<fixtures>/<provider>/<name>.sse`.
2. Otherwise we look at the last user message; if its lowercased text
   contains a fixture filename's stem (minus `.sse`), we serve that.
   Example: a fixture named `haiku.sse` matches a prompt containing "haiku".
3. Otherwise we serve `default.sse`.

Fixture format
--------------
Plain Server-Sent Events. We send each fixture verbatim, byte-for-byte,
so a recorded transcript from a real API works with no preprocessing.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Optional


class Handler(BaseHTTPRequestHandler):
    fixtures_root: Path = Path("tests/fixtures")
    chunk_delay_ms: int = 0

    # ─── routing ────────────────────────────────────────────────

    def _do_POST_impl(self):  # original handler, dispatched from do_POST
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body) if body else {}
        except json.JSONDecodeError:
            payload = {}

        if self.path.startswith("/v1/messages"):
            provider = "anthropic"
        elif self.path.startswith("/v1/chat/completions"):
            provider = "openai"
        else:
            self.send_error(404, f"unknown path: {self.path}")
            return

        scenario_dir = self.fixtures_root / provider
        if not scenario_dir.exists():
            self.send_error(500, f"no fixtures for {provider} at {scenario_dir}")
            return

        fixture_path = self._pick_fixture(scenario_dir, payload)
        if fixture_path is None:
            self.send_error(
                500,
                f"no fixture matched and no default.sse in {scenario_dir}",
            )
            return

        self._log(f"{self.command} {self.path} → {fixture_path.name}")
        self._serve_sse(fixture_path)

    def do_GET(self):  # noqa: N802
        if self.path == "/_health":
            self.send_response(200)
            self.send_header("content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok\n")
            return
        self.send_error(404, f"GET not handled: {self.path}")

    def do_POST(self):  # noqa: N802 — keep override above intact via dispatch
        if self.path == "/_shutdown":
            self.send_response(200)
            self.send_header("content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"shutting down\n")
            # server.shutdown() must be called from a thread other
            # than the one currently serving — otherwise it deadlocks.
            import threading
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        self._do_POST_impl()

    # ─── fixture selection ──────────────────────────────────────

    def _pick_fixture(self, scenario_dir: Path, payload: dict) -> Optional[Path]:
        # 1. Explicit header override. May be a flat file or the name
        #    of a multi-step *directory* — see step picking below.
        scenario = self.headers.get("x-mock-scenario")
        if scenario:
            multi = scenario_dir / scenario
            if multi.is_dir():
                return self._pick_step(multi, payload)
            candidate = scenario_dir / f"{scenario}.sse"
            if candidate.exists():
                return candidate
            self._log(f"  X-Mock-Scenario={scenario} — not found, falling back")

        # 2. Substring-match against the last user message. Match
        #    directories first (multi-step scenarios), then files.
        prompt = self._last_user_text(payload).lower()
        if prompt:
            for d in sorted(scenario_dir.iterdir()):
                if not d.is_dir():
                    continue
                if d.name.lower() in prompt:
                    return self._pick_step(d, payload)
            for f in sorted(scenario_dir.glob("*.sse")):
                if f.stem == "default":
                    continue
                if f.stem.lower() in prompt:
                    return f

        # 3. default.sse
        default = scenario_dir / "default.sse"
        return default if default.exists() else None

    @staticmethod
    def _pick_step(dir_: Path, payload: dict) -> Optional[Path]:
        """Multi-step scenario: serve step (k+1).sse where k = number
        of `tool_result` blocks emitted *since the most recent fresh
        user text turn*. Walking back from the end and stopping at a
        text-only user message scopes the count to the current
        scenario, so prior tool turns in the same session don't
        bleed into this scenario's step index."""
        msgs = payload.get("messages") or []
        tool_results = 0
        for m in reversed(msgs):
            if m.get("role") != "user":
                continue
            content = m.get("content")
            if isinstance(content, str):
                # Plain user text — start of this scenario. Stop.
                break
            if not isinstance(content, list):
                continue
            has_tool_result = False
            has_text = False
            for block in content:
                if isinstance(block, dict):
                    t = block.get("type")
                    if t == "tool_result":
                        tool_results += 1
                        has_tool_result = True
                    elif t == "text":
                        has_text = True
            # A user message containing only text marks the start of
            # the current scenario; everything before it is history.
            if has_text and not has_tool_result:
                break
        step = tool_results + 1
        candidate = dir_ / f"{step}.sse"
        if candidate.exists():
            return candidate
        # Fall back to the highest-numbered file we have so the
        # caller still gets *something* on overflow.
        steps = sorted(dir_.glob("*.sse"), key=lambda p: int(p.stem) if p.stem.isdigit() else 0)
        return steps[-1] if steps else None

    @staticmethod
    def _last_user_text(payload: dict) -> str:
        msgs = payload.get("messages") or []
        for msg in reversed(msgs):
            if msg.get("role") != "user":
                continue
            content = msg.get("content")
            if isinstance(content, str):
                return content
            if isinstance(content, list):
                # Anthropic content blocks: pick the first text block.
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        return block.get("text", "")
        return ""

    # ─── streaming ──────────────────────────────────────────────

    def _serve_sse(self, fixture_path: Path):
        body = fixture_path.read_bytes()
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        # Close after each request so the client sees EOF and stops
        # reading. Python's BaseHTTPRequestHandler defaults to HTTP/1.1
        # keep-alive otherwise, which makes velk's stream reader hang
        # waiting for bytes the mock will never send.
        self.send_header("connection", "close")
        self.close_connection = True
        self.end_headers()

        # Stream in event-sized chunks so velk's parser exercises its
        # incremental path. Split on the SSE blank-line boundary.
        delay = self.chunk_delay_ms / 1000.0
        for chunk in body.split(b"\n\n"):
            if not chunk:
                continue
            try:
                self.wfile.write(chunk + b"\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
            if delay:
                time.sleep(delay)

    # ─── logging ────────────────────────────────────────────────

    def log_message(self, format, *args):  # noqa: A002 (override)
        # Quieter than the default; we already log what matters via _log.
        return

    def _log(self, msg: str):
        print(f"mock: {msg}", file=sys.stderr, flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--port", type=int, default=int(os.environ.get("MOCK_PORT", "8765")))
    p.add_argument(
        "--fixtures",
        type=Path,
        default=Path(os.environ.get("MOCK_FIXTURES", "tests/fixtures")),
    )
    p.add_argument(
        "--chunk-delay-ms",
        type=int,
        default=int(os.environ.get("MOCK_CHUNK_DELAY_MS", "0")),
        help="sleep N ms between SSE events to simulate latency",
    )
    args = p.parse_args()

    if not args.fixtures.exists():
        print(f"mock: fixtures dir not found: {args.fixtures}", file=sys.stderr)
        sys.exit(1)

    Handler.fixtures_root = args.fixtures
    Handler.chunk_delay_ms = args.chunk_delay_ms

    server = HTTPServer(("127.0.0.1", args.port), Handler)
    print(
        f"mock: listening on http://127.0.0.1:{args.port}  "
        f"(fixtures: {args.fixtures})",
        file=sys.stderr,
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("mock: shutting down", file=sys.stderr)
        server.shutdown()


if __name__ == "__main__":
    main()
