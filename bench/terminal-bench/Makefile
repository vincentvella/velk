# Makefile for driving velk against Terminal-Bench from this dir.
#
# Common usage:
#
#   make run TASKS="hello-world create-bucket"   # batch + auto-tail
#   make watch                                   # tail the in-flight task
#   make tails                                   # dump tails from the most recent run
#   make status                                  # ✓/✗/… per task in the most recent run
#   make clean                                   # SIGKILL any orphan bench containers
#
# Env knobs (override on the command line: `make run TASKS=… VELK_VERSION=0.0.5-rc4`):
#   TB_DIR             terminal-bench checkout (default: $HOME/Workspace/terminal-bench)
#   VELK_VERSION       velk release tag without `v` (default: 0.0.5-rc3)
#   BATCH_TIMEOUT_SEC  outer timeout (default: 600 × N tasks)

TB_DIR ?= $(HOME)/Workspace/terminal-bench
VELK_VERSION ?= 0.0.5-rc3
ADAPTER_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

export TB_DIR
export VELK_VERSION

.PHONY: help run watch tails status clean

help:
	@echo "make run TASKS='task1 task2 …'   batch + auto-tail (foreground)"
	@echo "make watch                        tail the active bench task"
	@echo "make tails                        post-run tails of every task in the latest run"
	@echo "make status                       ✓/✗ per task in the latest run"
	@echo "make clean                        kill orphan bench containers"

# `make run TASKS="task1 task2 …"` — runs the batch in the background
# and tails the active task in the foreground. Hitting Ctrl-C stops
# the tail; the background batch keeps running and is reaped by
# run-batch.sh's outer timeout. Use `make tails` afterwards for the
# per-task summary.
run:
	@if [ -z "$(TASKS)" ]; then \
	    echo "usage: make run TASKS='task1 task2 …'"; exit 2; \
	fi
	@echo "▶ launching batch in the background; tail follows"
	@( "$(ADAPTER_DIR)/run-batch.sh" $(TASKS) > /tmp/tb-$(shell date +%s).log 2>&1 & echo $$! > /tmp/tb-pid )
	@sleep 2
	@$(MAKE) -s watch

watch:
	@"$(ADAPTER_DIR)/watch-batch.sh"

tails:
	@RUN=$$(ls -td $(TB_DIR)/runs/*/ 2>/dev/null | head -1); \
	if [ -z "$$RUN" ]; then echo "no runs yet"; exit 1; fi; \
	echo "Tails from $$RUN"; echo; \
	for d in $$RUN*/; do \
	    task=$$(basename "$$d"); \
	    [ "$$task" = "tb.lock" ] && continue; \
	    log=$$(ls $$d/*/sessions/agent.log 2>/dev/null | head -1); \
	    rj=$$(ls $$d/*/results.json 2>/dev/null | head -1); \
	    if [ -f "$$log" ] && [ -f "$$rj" ]; then \
	        verdict=$$(python3 -c 'import sys,json; d=json.load(sys.stdin); m="✓" if d["is_resolved"] else "✗"; print("%s %s" % (m, d.get("failure_mode","-")))' < "$$rj"); \
	        echo "── $$task  $$verdict ──"; \
	        tail -25 "$$log"; \
	        echo; \
	    fi; \
	done

status:
	@RUN=$$(ls -td $(TB_DIR)/runs/*/ 2>/dev/null | head -1); \
	if [ -z "$$RUN" ]; then echo "no runs yet"; exit 1; fi; \
	echo "Status of $$RUN"; \
	for d in $$RUN*/; do \
	    task=$$(basename "$$d"); \
	    [ "$$task" = "tb.lock" ] && continue; \
	    rj=$$(ls $$d/*/results.json 2>/dev/null | head -1); \
	    if [ -f "$$rj" ]; then \
	        python3 -c 'import sys,json; d=json.load(sys.stdin); m="✓" if d["is_resolved"] else "✗"; print("  %s  %-30s %s" % (m, d["task_id"], d.get("failure_mode","-")))' < "$$rj"; \
	    elif [ -d "$$d" ]; then \
	        echo "  …  $$task  (in progress)"; \
	    fi; \
	done

clean:
	@docker ps -q --filter "name=-1-of-1-" | xargs -r docker rm -f 2>&1 | head -10
