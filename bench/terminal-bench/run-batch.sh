#!/usr/bin/env bash
# Helper: run a batch of Terminal-Bench tasks and tail the agent log
# for each one as the run completes. Saves summary + full per-task
# trajectories to runs/<timestamp>/.
#
# Usage: ./run-batch.sh task1 task2 task3 ...
#
# Env knobs:
#   TB_DIR              terminal-bench checkout (default: ~/Workspace/terminal-bench)
#   VELK_VERSION        velk release tag without `v` (default: 0.0.4)
#   BATCH_TIMEOUT_SEC   abort the whole batch after this many seconds
#                       (default: 600 per task × N tasks)
set -euo pipefail

if [ "$#" -eq 0 ]; then
    echo "usage: $0 task1 [task2 ...]" >&2
    exit 2
fi

TB_DIR="${TB_DIR:-$HOME/Workspace/terminal-bench}"
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export VELK_VERSION="${VELK_VERSION:-0.0.4}"

TASK_FLAGS=()
for t in "$@"; do TASK_FLAGS+=(--task-id "$t"); done

# Per-task wall-clock guardrail. tb run + the agent itself can hang
# if the binary trips on an env quirk; without an outer timeout the
# helper would block indefinitely. 10 min/task is generous.
PER_TASK_SEC=600
BATCH_TIMEOUT_SEC="${BATCH_TIMEOUT_SEC:-$(( PER_TASK_SEC * $# ))}"

cd "$TB_DIR"
echo "▶ velk=v${VELK_VERSION}  tasks=$*  timeout=${BATCH_TIMEOUT_SEC}s"

# macOS doesn't ship `timeout`; use coreutils' `gtimeout` if installed.
TIMEOUT_BIN=""
if command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=gtimeout
elif command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN=timeout
fi

run_tb() {
    PYTHONPATH="$ADAPTER_DIR" uv run tb run \
        --agent-import-path velk_agent:VelkAgent \
        "${TASK_FLAGS[@]}" \
        --dataset-path original-tasks \
        --n-concurrent 1
}

cleanup_containers() {
    # Kill any per-task containers the harness orphaned.
    for t in "$@"; do
        docker ps -q --filter "name=^${t}-" 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1 || true
    done
}

if [ -n "$TIMEOUT_BIN" ]; then
    if ! "$TIMEOUT_BIN" --kill-after=30 "${BATCH_TIMEOUT_SEC}" bash -c "$(declare -f run_tb); run_tb"; then
        rc=$?
        echo "⚠  tb run exited rc=$rc (likely timeout); cleaning up orphan containers"
        cleanup_containers "$@"
        exit "$rc"
    fi
else
    run_tb
fi

# Print tail of each task's agent.log so you can watch what happened.
RUN=$(ls -td "$TB_DIR"/runs/*/ | head -1)
echo
echo "=================================================================="
echo "  Tails from $RUN"
echo "=================================================================="
for t in "$@"; do
    f=$(echo "$RUN"/"$t"/"$t".1-of-1.*/sessions/agent.log)
    if [ -f "$f" ]; then
        result=$(cat "$(dirname "$f")"/../results.json | python3 -c 'import sys,json; d=json.load(sys.stdin); print("✓" if d["is_resolved"] else "✗", d.get("failure_mode","-"))')
        echo
        echo "── $t  $result ──"
        tail -25 "$f"
    fi
done
