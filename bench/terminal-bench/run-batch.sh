#!/usr/bin/env bash
# Helper: run a batch of Terminal-Bench tasks and tail the agent log
# for each one as the run completes. Saves summary + full per-task
# trajectories to runs/<timestamp>/.
#
# Usage: ./run-batch.sh task1 task2 task3 ...
set -euo pipefail

TB_DIR="${TB_DIR:-/Users/vince/Workspace/terminal-bench}"
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_FLAGS=()
for t in "$@"; do TASK_FLAGS+=(--task-id "$t"); done

cd "$TB_DIR"
PYTHONPATH="$ADAPTER_DIR" uv run tb run \
    --agent-import-path velk_agent:VelkAgent \
    "${TASK_FLAGS[@]}" \
    --dataset-path original-tasks \
    --n-concurrent 1

# Print tail of each task's agent.log so you can watch what happened
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
