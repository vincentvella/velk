# velk

A Zig 0.16 terminal AI harness — Anthropic-first, multi-provider, with MCP, vim
mode, and OSC-52 clipboard. No runtime, single static binary.

> [!WARNING]
> Pre-1.0. The CLI surface, session format, and config layout will change. Pin
> a tag if you want stability.

## Install

### Homebrew

```sh
brew tap vincentvella/velk
brew install velk
```

### Pre-built binaries

Grab a tarball for your platform from the
[releases page](https://github.com/vincentvella/velk/releases). Each release
publishes `darwin-arm64`, `darwin-x64`, `linux-arm64`, `linux-x64` plus matching
`.sha256` files.

### Build from source

Requires Zig **0.16.0** exactly.

```sh
git clone https://github.com/vincentvella/velk.git
cd velk
zig build -Doptimize=ReleaseFast
./zig-out/bin/velk --version
```

## Quick start

Set an API key for whichever provider you're using, then run a one-shot prompt
or drop into the TUI.

```sh
export ANTHROPIC_API_KEY=sk-ant-...
# export OPENAI_API_KEY=sk-...   # if using --provider openai

# one-shot
velk "write a haiku about zig"

# interactive TUI
velk
```

## Usage

```
velk [flags] [prompt]

Flags:
  -m, --model <id>          model id (default: claude-opus-4-7)
  -s, --system <text>       system prompt override
      --max-tokens <n>      response cap (default: 4096)
      --provider <name>     anthropic | openai | openrouter
  -S, --session <name>      load/save chat under XDG_DATA_HOME/velk/sessions
      --mcp '<command>'     spawn an MCP server (repeatable, max 16)
      --no-tui              plain stdout — pipe-friendly
      --unsafe              allow tool access outside CWD
  -V, --version
  -h, --help
```

If no prompt is given, velk launches the TUI.

## Features

- **Anthropic + OpenAI** with a normalized provider interface; OpenRouter and
  other OpenAI-compatible gateways via `OPENAI_BASE_URL`.
- **Streaming** via Anthropic SSE / OpenAI chunked responses.
- **Tool-use loop** with built-in `read_file`, `write_file`, `edit`, `bash`,
  `ls`, `grep`. `bash` runs in its own process group so Ctrl-C kills the whole
  subtree (no orphaned `sleep`s).
- **MCP client** — `--mcp 'npx -y @modelcontextprotocol/server-filesystem .'`
  spawns the server, lists its tools, and merges them into the registry
  prefixed `mcp{N}_<name>`.
- **TUI** built on [libvaxis](https://github.com/jcollie/libvaxis) (jcollie's
  Zig 0.16 port). Mouse selection, OSC-52 copy, edge-drag autoscroll,
  multi-turn history.
- **Vim mode** in the input box — modal (insert / normal / visual / visual-line)
  with `hjkl`, `w`/`b`, `0`/`$`, `g`/`G`, `Ctrl-u`/`Ctrl-d`, `v`/`V`, `y` to
  yank via OSC-52.
- **Mid-turn Ctrl-C abort** — the agent runs on its own task via
  `Io.concurrent`; cancellation is sub-millisecond even mid-thinking and
  reaches all the way down to running tool subprocesses.
- **Session persistence** — `--session foo` reloads the conversation from
  `$XDG_DATA_HOME/velk/sessions/foo.json` on next launch.
- **Input history** persisted to `$XDG_STATE_HOME/velk/history.txt`
  (Up/Down to recall, capped at 1000 entries).
- **Prompt caching** (Anthropic) — automatic top-level `cache_control: ephemeral`,
  active above the model's minimum cacheable prefix (4096 tokens for Opus 4.5+,
  2048 for Sonnet 4.6, 1024 for older).
- **Cost tracking** — per-turn input/output/cache token counts and a USD figure
  for models in the built-in price table.
- **Retry/backoff** on 429/5xx during request setup (3× with 1s/2s/4s
  exponential, capped at 30s).

## Environment

| Var                  | Purpose                                                 |
| -------------------- | ------------------------------------------------------- |
| `ANTHROPIC_API_KEY`  | Anthropic auth                                          |
| `OPENAI_API_KEY`     | OpenAI / OpenRouter / other OAI-compatible gateway auth |
| `ANTHROPIC_BASE_URL` | Override Anthropic base URL (e.g. point at the mock server) |
| `OPENAI_BASE_URL`    | Override OpenAI base URL (defaults to api.openai.com)   |
| `XDG_DATA_HOME`      | Where sessions live (defaults to `~/.local/share`)      |
| `XDG_STATE_HOME`     | Where input history lives (defaults to `~/.local/state`)|

## Development

```sh
zig build test       # unit tests
zig build smoke      # CLI smoke tests (no API)
zig build check      # test + smoke
zig build mock       # mock model server — replays canned SSE
                     # responses so you can run velk without burning tokens
scripts/install-hooks.sh   # one-time: install pre-commit hook
```

CI runs `zig build test` + `zig build smoke` on every push and PR
(`.github/workflows/ci.yml`); release tarballs are still cut on `v*`
tags by `release.yml`. See [AGENTS.md](AGENTS.md) for the mock-server
workflow and project conventions.

## Project status

See [ROADMAP.md](ROADMAP.md) for the full plan. Phases 0-8 are shipped in
v0.0.1; Phases 9-16 are upcoming.

## License

[Apache-2.0](LICENSE) © Vincent Vella
