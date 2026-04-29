"""Terminal-Bench adapter for velk.

velk runs *inside* the per-task Docker container and drives its own
`bash` tool there, which matches Terminal-Bench's tmux-based execution
model: the harness types the agent command into tmux, the agent process
spawns child shells in the same container, the harness collects logs
when the command's tmux block returns.

Usage:

    cd /path/to/terminal-bench
    export ANTHROPIC_API_KEY=sk-ant-...
    uv run tb run \\
        --agent-import-path /path/to/velk/bench/terminal-bench/velk_agent.py:VelkAgent \\
        --task-id hello-world

Or import inside the bench's working tree as `velk_tb.velk_agent:VelkAgent`.
"""

from __future__ import annotations

import os
import shlex
from pathlib import Path

from terminal_bench.agents.installed_agents.abstract_installed_agent import (
    AbstractInstalledAgent,
)
from terminal_bench.terminal.models import TerminalCommand


class VelkAgent(AbstractInstalledAgent):
    """Drop velk into a Terminal-Bench run.

    What this does:
    - Installs the prebuilt static linux-musl velk binary into
      `/usr/local/bin/velk` inside the task container at task start.
    - Forwards `ANTHROPIC_API_KEY` (default) into the container so velk
      can talk to the API. Set `VELK_PROVIDER=openai` + `OPENAI_API_KEY`
      in your shell to switch providers; both env vars get copied in.
    - Runs `velk --no-tui --mode bypass --max-iterations <N>
      --max-cost <USD> '<prompt>'` as a single tmux command. `--mode
      bypass` skips the diff approval gate (no human in the loop under
      a bench harness); `--max-iterations` defaults to 50, `--max-cost`
      to 1.00, both overridable via env.

    Velk's bash tool spawns shells with `pgid=0` so a SIGKILL on the
    pgid cleans up reparented grandchildren — important when a task
    leaves long-running daemons (servers, watchers) behind.
    """

    @staticmethod
    def name() -> str:
        return "velk"

    @property
    def _env(self) -> dict[str, str]:
        env = {}
        # Anthropic by default; swap to openai with VELK_PROVIDER=openai.
        for key in (
            "ANTHROPIC_API_KEY",
            "OPENAI_API_KEY",
            "OPENROUTER_API_KEY",
            "VELK_VERSION",
            "VELK_RELEASE_BASE",
        ):
            if key in os.environ:
                env[key] = os.environ[key]
        return env

    @property
    def _install_agent_script_path(self) -> Path:
        return Path(__file__).parent / "velk-setup.sh.j2"

    def _run_agent_commands(self, instruction: str) -> list[TerminalCommand]:
        provider = os.environ.get("VELK_PROVIDER", "anthropic")
        model = os.environ.get(
            "VELK_MODEL",
            {
                "anthropic": "claude-opus-4-7",
                "openai": "gpt-5",
                "openrouter": "openai/gpt-5",
            }.get(provider, "claude-opus-4-7"),
        )
        max_iters = os.environ.get("VELK_MAX_ITERATIONS", "50")
        max_cost = os.environ.get("VELK_MAX_COST", "1.00")
        max_turn_ms = os.environ.get("VELK_MAX_TURN_MS", "600000")

        # System prompt nudging the model into autonomous-task mode.
        # Empirical findings shaping this phrasing:
        # 1. With no system prompt, frontier models default to a
        #    "chat with the user" demeanor — they list commands
        #    and ask for confirmation instead of executing.
        # 2. A soft "you are unattended" prompt isn't enough on
        #    AWS-themed or other irreversible-feeling tasks — the
        #    model still hedges. Stating that the environment is
        #    isolated/sandboxed (which any disposable container is
        #    — `docker run --rm` semantics) breaks the hedging
        #    without revealing anything bench-specific.
        # The phrasing avoids: task-specific guidance, tool-name
        # hints (already in the API's `tools[]`), the words
        # "Terminal-Bench" / "benchmark" / "test", or any framing
        # that would let the model game tests it can see.
        # Override via $VELK_BENCH_SYSTEM if you want different framing.
        # Single-line: tmux types the whole `velk --system '<prompt>'`
        # command line as keystrokes; embedded literal newlines come
        # out as shell continuation prompts (`> `) and the shell
        # ends up parsing the prompt as multiple separate inputs.
        # Use `; ` as a soft separator instead.
        system_prompt = os.environ.get(
            "VELK_BENCH_SYSTEM",
            (
                "You are running in non-interactive (headless) mode. "
                "Do not ask the user for input or confirmation; "
                "do not describe what you would do — execute the work "
                "through tool calls. Generally you can freely take "
                "local, reversible actions like editing files or "
                "running shell commands; make reasonable decisions "
                "autonomously. Report errors clearly but continue "
                "working. End your turn after the task is complete."
            ),
        )

        cmd = (
            f"velk --no-tui"
            f" --provider {shlex.quote(provider)}"
            f" --model {shlex.quote(model)}"
            f" --mode bypass"
            f" --system {shlex.quote(system_prompt)}"
            f" --max-iterations {shlex.quote(max_iters)}"
            f" --max-cost {shlex.quote(max_cost)}"
            f" --max-turn-ms {shlex.quote(max_turn_ms)}"
            f" {shlex.quote(instruction)}"
        )
        return [
            TerminalCommand(
                command=cmd,
                min_timeout_sec=0.0,
                max_timeout_sec=float("inf"),
                block=True,
                append_enter=True,
            )
        ]
