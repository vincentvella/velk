# AGENTS.md

Project context for AI coding agents working in this repo. Keep this file
short — facts that aren't derivable from reading the code or `git log`.

## What this is

`velk` — a terminal AI harness in Zig 0.16 (Anthropic-first, multi-provider,
MCP, vim-mode TUI). Single static binary, no runtime.

## Toolchain

- **Zig 0.16.0 exactly.** The `std.Io` API and `std.json.Stringify` shape
  changed in 0.16; do not assume 0.13 / 0.14 stdlib.
- **Dependencies** are pinned in `build.zig.zon`:
  - `vaxis` — jcollie's Zig 0.16 fork of libvaxis (TUI)
  - `mvzr` — regex used by the `grep` tool
- **libc is linked** (`exe.root_module.link_libc = true` in `build.zig`)
  because we call `std.c.{write,_exit,kill}` for OSC-52 output and process-group
  termination.

## Common commands

```sh
zig build                                # debug build → zig-out/bin/velk
zig build -Doptimize=ReleaseFast         # release build
zig build test                           # unit tests
zig build smoke                          # CLI smoke tests (no API)
zig build tui-test                       # python pty harness — drives the TUI + slash commands
zig build check                          # test + smoke + tui-test
zig build mock                           # start the python mock model server
zig build -Dtarget=x86_64-linux          # cross-compile (Zig native)
```

`scripts/install-hooks.sh` installs a pre-commit hook that runs
`zig build check`. Run it once per fresh clone.

There is no separate lint or formatter step beyond `zig fmt`.

## Local development without burning tokens

`scripts/mock-server.py` (also `zig build mock`) is a stdlib-only Python
HTTP server that replays canned SSE responses from `tests/fixtures/`.
Point velk at it via `ANTHROPIC_BASE_URL` or `OPENAI_BASE_URL`:

```sh
zig build mock &     # listens on http://127.0.0.1:8765
ANTHROPIC_BASE_URL=http://127.0.0.1:8765/v1/messages \
    ANTHROPIC_API_KEY=sk-fake \
    ./zig-out/bin/velk "anything"
```

Fixture picking: an `X-Mock-Scenario: <name>` header wins; otherwise the
mock substring-matches the user prompt against fixture filenames
(`tests/fixtures/anthropic/haiku.sse` matches a prompt containing
"haiku"); finally falls back to `default.sse`. Drop a recorded
real-API SSE transcript into the fixtures dir to add a scenario — the
mock streams it byte-for-byte.

## Layout

```
src/
  main.zig          entry: arg parse → provider → agent loop or TUI
  cli.zig           hand-rolled arg parser; module-scope mcp_storage
  provider.zig      normalized Request/Message/ContentBlock + Provider iface
  agent.zig         tool-use loop (stream → tool_use → tool_result → repeat)
  tool.zig          Tool interface + registry
  tools.zig         built-ins: read_file/write_file/edit/bash/ls/grep
  session.zig       multi-turn message history + persistence
  persist.zig       XDG paths for sessions + history
  cost.zig          per-model price table + USD calc
  tui.zig           libvaxis frontend, vim mode, three arenas
  anthropic/        Anthropic Messages API client + SSE
  openai/           OpenAI Chat Completions client
  mcp/              JSON-RPC 2.0 client over child stdio
  mcp.zig           bridges MCP tools into the registry as mcp{N}_<name>
brew/               Homebrew formula + tap publishing instructions
.github/workflows/  release.yml — matrix build on v* tags
ROADMAP.md          phased plan (gitignored — local working doc)
```

## Conventions and gotchas

- **Three arenas in the TUI** (`tui.zig`): `tui_arena` for state, `lines_arena`
  reset (not deinit) per render, per-call scratch. Mixing them caused mouse-
  selection UAFs — keep them separate.
- **Worker thread vs main**: the agent runs on `Io.concurrent`. The worker uses
  the gpa-backed thread-safe allocator; the main thread owns `tui_arena`. Never
  let the worker touch TUI state directly — post events to the vaxis loop.
- **`provider.textMessage` dupes the text.** A previous bug let prompt strings
  freed mid-turn dangle in `sess.messages`. Anything stored on the session
  must be arena-owned, not borrowed from caller scope.
- **`bash` runs in a new process group** (`pgid: 0`). On cancel we
  `kill(-pgid, SIGKILL)` so reparented grandchildren (e.g. `sleep` from
  `sleep 30 && echo`) don't outlive the abort. Don't replace this with
  `std.process.run`.
- **MCP tools are prefixed `mcp{N}_<name>`** to dodge collisions with built-ins
  (e.g. filesystem-server's `edit` vs ours).
- **Anthropic prompt caching has model-dependent minimums**: 4096 tokens for
  Opus 4.5/4.6/4.7, 2048 for Sonnet 4.6, 1024 for older. Prefix below the
  threshold won't engage caching even though the request is well-formed.
- **OpenAI gpt-5+ requires `max_completion_tokens`**, not `max_tokens` — see
  `openai/types.zig`.
- **No `--no-verify` on git commits.** If a hook fails, fix it.
- **Slash-command args are slices into `tui.input.items`.** Always dupe
  `parsed.name` and `parsed.args` into the tui arena BEFORE calling
  `tui.input.clearRetainingCapacity()` — otherwise the next keystroke
  overwrites the bytes the handler is reading. Caught by the pty
  harness as `Model set to ����`.
- **TUI lifecycle under a pty hangs in macOS `E` state.** Returning
  from `tui.run()` (via `/exit`, Ctrl-D, or any other path) leaves
  vaxis's kqueue reader thread blocking `loop.stop()` long enough that
  even SIGKILL takes seconds to actually reap the process. Real
  terminal use is unaffected. The pty harness compensates by not
  asserting on /exit's exit code; the dispatcher is proven via the
  other slash assertions.

## Testing

Each phase ships with Zig `test` blocks alongside the code under test. Run
`zig build test` before declaring done. Don't defer tests to a follow-up.

## Roadmap

Phases tracked in `ROADMAP.md` (gitignored). Tick items off
**immediately** on completion — don't batch updates.

## Out of scope (for now)

- Gemini provider (skipped pending demand)
- Windows support (POSIX-only — we use process groups, OSC-52, XDG paths)
- Async runtime beyond `std.Io.concurrent`
