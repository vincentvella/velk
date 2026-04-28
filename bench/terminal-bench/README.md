# velk on Terminal-Bench

This directory has the adapter to run velk against
[Terminal-Bench](https://github.com/laude-institute/terminal-bench).
velk runs *inside* the per-task Docker container and drives its own
`bash` tool there, matching the bench's tmux-driven execution model.

## Files

- **`velk_agent.py`** — `VelkAgent(AbstractInstalledAgent)`. The
  Python class Terminal-Bench loads via `--agent-import-path`. ~75
  lines.
- **`velk-setup.sh.j2`** — installer script the harness `source`s
  inside the task container. Downloads the static linux-musl velk
  tarball from a GitHub release and drops it at `/usr/local/bin/velk`.
  Falls back to the gnu artifact if musl isn't in the release yet
  (still works on glibc distros).

## Prerequisites

- Terminal-Bench checked out and runnable (`uv run tb run --help`
  should work). See <https://github.com/laude-institute/terminal-bench>
  for setup.
- Docker running locally.
- A velk release on GitHub with at least the
  `velk-linux-{x64,arm64}.tar.gz` artifacts (the static-musl ones
  are preferred — they land in v0.0.2+ once the linux-musl matrix
  shipped in commit ac57b03 produces a tagged release). Override
  the version with `VELK_VERSION=0.0.2` (or whatever's current) in
  your shell.
- An `ANTHROPIC_API_KEY` (or `OPENAI_API_KEY` + `VELK_PROVIDER=openai`).

## Quickstart

```sh
export ANTHROPIC_API_KEY=sk-ant-...

# Run a single task end-to-end against velk.
cd /path/to/terminal-bench
uv run tb run \
    --agent-import-path /abs/path/to/velk/bench/terminal-bench/velk_agent.py:VelkAgent \
    --task-id hello-world

# Or run the full task suite (long).
uv run tb run \
    --agent-import-path /abs/path/to/velk/bench/terminal-bench/velk_agent.py:VelkAgent
```

## Knobs (env vars read by the adapter)

| var                      | default                          | what                                                                |
| ------------------------ | -------------------------------- | ------------------------------------------------------------------- |
| `VELK_PROVIDER`          | `anthropic`                      | `anthropic` / `openai` / `openrouter`                               |
| `VELK_MODEL`             | provider-default (Opus 4.7 / GPT-5) | model id                                                            |
| `VELK_MAX_ITERATIONS`    | `50`                             | tool-use rounds per turn before `IterationBudgetExceeded`           |
| `VELK_MAX_COST`          | `1.00`                           | session-wide USD cap; agent exits cleanly when exceeded             |
| `VELK_MAX_TURN_MS`       | `600000` (10 min)                | per-turn wall-clock cap                                             |
| `VELK_VERSION`           | `0.0.1`                          | release tag without leading `v`                                     |
| `VELK_RELEASE_BASE`      | `github.com/vincentvella/velk/releases/download/v$VERSION` | self-host the binary for offline / private benches |
| `ANTHROPIC_API_KEY`      | —                                | required for `anthropic` provider                                   |
| `OPENAI_API_KEY`         | —                                | required for `openai` / `openrouter`                                |

## What's wired

- **Permissions**: `--mode bypass` is hardcoded in the adapter so
  velk's diff-approval gate never blocks (no human in the bench
  loop).
- **Path safety**: velk's lexical CWD-only check stays on. Tasks
  that need to write outside `/app` (the typical bench workspace)
  must override; in practice tasks operate inside `/app` so this is
  fine.
- **Logging**: Terminal-Bench captures the tmux pane's stdout/stderr
  to its own logs dir. velk's own `[tokens: …]` line lands there
  per turn so cost/usage is auditable.

## Caveats

- **MCP servers / hooks / skills aren't wired**. The adapter doesn't
  pass `--mcp …` or set up `settings.json` inside the container. If
  a benchmark task needs those, extend `_run_agent_commands` and
  `velk-setup.sh.j2` accordingly.
- **No streaming output to the user during a run** — the bench
  harness collects everything at the end. velk still streams to
  stdout inside the container; the harness just buffers.
- **Static musl is strongly preferred** because Alpine-based bench
  base images don't ship glibc. If your bench tasks all use Debian/
  Ubuntu bases the gnu artifact is fine.

## Future hookups

- Once `release.yml` produces `velk-linux-{x64,arm64}-musl.tar.gz`
  on every tag (Phase 14, commit ac57b03), bump the default
  `VELK_VERSION` here.
- A native registration in Terminal-Bench upstream (`AgentName.VELK`
  + entry in `AGENT_NAME_TO_CLASS`) would let users say `--agent
  velk` instead of the import path. PR upstream when stable.
