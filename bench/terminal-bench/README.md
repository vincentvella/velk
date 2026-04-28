# velk on Terminal-Bench

Adapter for running velk against
[Terminal-Bench](https://github.com/laude-institute/terminal-bench).
velk runs inside the per-task Docker container and drives its own
`bash` tool there, matching the bench's tmux execution model
(same shape as `claude-code`, `codex`, `aider`).

## Files

- **`velk_agent.py`** — `VelkAgent(AbstractInstalledAgent)`. The
  Python class Terminal-Bench loads via `--agent-import-path`.
- **`velk-setup.sh.j2`** — installer template. Downloads the
  static linux-musl velk tarball from a GitHub release and drops
  it at `/usr/local/bin/velk`.

## Quickstart

```sh
git clone https://github.com/laude-institute/terminal-bench
cd terminal-bench && uv sync

export ANTHROPIC_API_KEY=sk-ant-...
export VELK_VERSION=0.0.3   # or whatever's current

PYTHONPATH=/abs/path/to/velk/bench/terminal-bench \
    uv run tb run \
        --agent-import-path velk_agent:VelkAgent \
        --task-id hello-world \
        --dataset-path original-tasks
```

For a full sweep, drop `--task-id …`.

## Configuration

The adapter reads these env vars:

| var                      | default                          | what                                                                |
| ------------------------ | -------------------------------- | ------------------------------------------------------------------- |
| `VELK_PROVIDER`          | `anthropic`                      | `anthropic` / `openai` / `openrouter`                               |
| `VELK_MODEL`             | provider-default (Opus 4.7 / GPT-5) | model id                                                            |
| `VELK_MAX_ITERATIONS`    | `50`                             | tool-use rounds per turn                                            |
| `VELK_MAX_COST`          | `1.00`                           | session-wide USD cap                                                |
| `VELK_MAX_TURN_MS`       | `600000` (10 min)                | per-turn wall-clock cap                                             |
| `VELK_BENCH_SYSTEM`      | (built-in)                       | override the autonomous-mode system prompt                          |
| `VELK_VERSION`           | `0.0.3`                          | release tag without leading `v`                                     |
| `VELK_RELEASE_BASE`      | `github.com/vincentvella/velk/releases/download/v$VERSION` | self-host the binary |
| `ANTHROPIC_API_KEY`      | —                                | required for `anthropic`                                            |
| `OPENAI_API_KEY`         | —                                | required for `openai` / `openrouter`                                |

## What the adapter passes to velk

Beyond the prompt, model, and provider, the adapter always sets:

- `--no-tui` — headless mode (the bench drives velk via tmux, not a TTY).
- `--mode bypass` — skips the diff-approval gate; without this the
  agent would block waiting for an approval that never comes.
- `--max-iterations`, `--max-cost`, `--max-turn-ms` — runaway
  protection.
- `--system <prompt>` — see below.

## Default system prompt

```
You are running unattended. No human is available to answer
questions or confirm actions. Make reasonable choices and execute
them through tool calls. End your turn when the task is complete.
```

Override via `VELK_BENCH_SYSTEM`.

## Notes

- The setup script appends a trailing newline to `/etc/resolv.conf`
  if it's missing one. Zig 0.16's stdlib resolv.conf parser doesn't
  tolerate files without trailing newlines, and several bench
  containers ship the file that way. Without this, velk fails to
  resolve DNS and exits before the first turn.
- The setup script captures the caller's CWD on entry and restores
  it on exit so velk launches from `/app` (the tmux session's
  working dir), not from the install tmpdir.
- MCP servers, hooks, and skills aren't wired. Extend
  `_run_agent_commands` and the setup template if a benchmark needs
  them.
- The setup script prefers the static `linux-musl` tarball and
  falls back to the gnu build if the musl artifact is missing.
