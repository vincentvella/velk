#!/usr/bin/env bash
# Live-tail the agent.log of whichever Terminal-Bench task is
# currently running. As tasks complete and the next container
# spins up, the tail auto-switches. Polls every second.
#
# Usage: ./watch-batch.sh
#
# Env knobs:
#   TB_DIR  terminal-bench checkout (default: ~/Workspace/terminal-bench)
set -euo pipefail

TB_DIR="${TB_DIR:-$HOME/Workspace/terminal-bench}"

trap 'echo; echo "watch: exit"; kill $TAIL_PID 2>/dev/null || true; exit 0' INT TERM

CURRENT_LOG=""
TAIL_PID=""
LAST_TASK=""

find_active_log() {
    # The active container's name is `<task>-1-of-1-<runid>`.
    local name task run
    name="$(docker ps --format '{{.Names}}' --filter 'name=-1-of-1-' | head -1)"
    [ -z "$name" ] && return 1
    # Strip the -1-of-1-<runid> suffix to get the task id.
    task="${name%%-1-of-1-*}"
    run="${name##*-1-of-1-}"
    local log="$TB_DIR/runs/$run/$task/$task.1-of-1.$run/sessions/agent.log"
    if [ -f "$log" ]; then
        echo "$task|$log"
        return 0
    fi
    return 1
}

echo "watch: polling for active bench task (Ctrl-C to exit)"
while true; do
    if active="$(find_active_log)"; then
        task="${active%%|*}"
        log="${active##*|}"
        if [ "$log" != "$CURRENT_LOG" ]; then
            # Active task changed — kill old tail, start new one.
            if [ -n "$TAIL_PID" ]; then kill "$TAIL_PID" 2>/dev/null || true; fi
            CURRENT_LOG="$log"
            echo
            echo "═══════════════════════════════════════════════════════════════════"
            echo "  watch: $task"
            echo "  $log"
            echo "═══════════════════════════════════════════════════════════════════"
            tail -F -n +1 "$log" 2>/dev/null &
            TAIL_PID=$!
            LAST_TASK="$task"
        fi
    else
        # No active container. If we just had one running, dump the
        # final result and wait for the next one (or exit if no
        # batch is running).
        if [ -n "$CURRENT_LOG" ] && [ -n "$LAST_TASK" ]; then
            sleep 2  # let the harness flush the last lines
            kill "$TAIL_PID" 2>/dev/null || true
            CURRENT_LOG=""
            TAIL_PID=""
            # Find the result for the just-completed task.
            run_dir="$(ls -td "$TB_DIR"/runs/*/ 2>/dev/null | head -1)"
            if [ -n "$run_dir" ]; then
                rj="$run_dir$LAST_TASK/$LAST_TASK.1-of-1.$(basename "$run_dir")/results.json"
                if [ -f "$rj" ]; then
                    verdict="$(python3 -c 'import sys,json; d=json.load(sys.stdin); print("✓" if d["is_resolved"] else "✗", d.get("failure_mode","-"))' < "$rj")"
                    echo
                    echo "═══════════════════════════════════════════════════════════════════"
                    echo "  $LAST_TASK  →  $verdict"
                    echo "═══════════════════════════════════════════════════════════════════"
                fi
            fi
            LAST_TASK=""
        fi
    fi
    sleep 1
done
