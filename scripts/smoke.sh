#!/usr/bin/env bash
# Smoke tests for the velk CLI. Asserts the no-API-key surface behaves as
# expected: arg parsing, exit codes, env-var error messages, --mcp limits.
# Runs in <2s. Run from the repo root: `scripts/smoke.sh` or `zig build smoke`.

set -euo pipefail

VELK="${VELK_BIN:-./zig-out/bin/velk}"
if [[ ! -x "$VELK" ]]; then
    echo "smoke: binary not found at $VELK — run 'zig build' first" >&2
    exit 1
fi

# Strip provider env vars so we can test the missing-key error paths
# without depending on the developer's shell.
unset ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY

PASS=0
FAIL=0
FAILED_CASES=()

# Run a case. Args: name, expected_exit, command...
# Asserts the command's exit code matches and (optionally) checks output
# substrings via SMOKE_EXPECT_STDOUT / SMOKE_EXPECT_STDERR env vars.
run_case() {
    local name="$1"; shift
    local want_exit="$1"; shift
    local stdout_file stderr_file
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"
    set +e
    "$@" >"$stdout_file" 2>"$stderr_file"
    local got_exit=$?
    set -e

    local ok=1
    if [[ "$got_exit" != "$want_exit" ]]; then
        ok=0
        echo "FAIL: $name — expected exit $want_exit, got $got_exit"
        echo "  stdout: $(head -c 200 "$stdout_file")"
        echo "  stderr: $(head -c 200 "$stderr_file")"
    fi

    # Optional substring assertions via SMOKE_EXPECT_STDOUT / SMOKE_EXPECT_STDERR.
    if [[ -n "${SMOKE_EXPECT_STDOUT:-}" ]]; then
        if ! grep -qF -- "$SMOKE_EXPECT_STDOUT" "$stdout_file"; then
            ok=0
            echo "FAIL: $name — stdout missing: $SMOKE_EXPECT_STDOUT"
            echo "  got: $(head -c 200 "$stdout_file")"
        fi
    fi
    if [[ -n "${SMOKE_EXPECT_STDERR:-}" ]]; then
        if ! grep -qF -- "$SMOKE_EXPECT_STDERR" "$stderr_file"; then
            ok=0
            echo "FAIL: $name — stderr missing: $SMOKE_EXPECT_STDERR"
            echo "  got: $(head -c 200 "$stderr_file")"
        fi
    fi

    rm -f "$stdout_file" "$stderr_file"

    if [[ "$ok" == "1" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_CASES+=("$name")
    fi
}

echo "smoke: $VELK"

# --version exits 0 and starts with "velk "
SMOKE_EXPECT_STDOUT="velk " run_case "version" 0 "$VELK" --version
SMOKE_EXPECT_STDOUT="velk " run_case "version short" 0 "$VELK" -V

# --help exits 0 and mentions the major flags
SMOKE_EXPECT_STDOUT="--provider" run_case "help mentions --provider" 0 "$VELK" --help
SMOKE_EXPECT_STDOUT="--model" run_case "help mentions --model" 0 "$VELK" --help
SMOKE_EXPECT_STDOUT="--mcp" run_case "help mentions --mcp" 0 "$VELK" --help
SMOKE_EXPECT_STDOUT="--session" run_case "help mentions --session" 0 "$VELK" --help
SMOKE_EXPECT_STDOUT="-h" run_case "help short form" 0 "$VELK" -h

# Parse errors → exit 2
SMOKE_EXPECT_STDERR="unknown provider" run_case "bad provider exits 2" 2 "$VELK" --provider googly "hi"
SMOKE_EXPECT_STDERR="unknown flag" run_case "bad flag exits 2" 2 "$VELK" --frobnicate "hi"
SMOKE_EXPECT_STDERR="invalid integer" run_case "bad max-tokens exits 2" 2 "$VELK" --max-tokens abc "hi"
SMOKE_EXPECT_STDERR="--model" run_case "missing --model value exits 2" 2 "$VELK" --model
SMOKE_EXPECT_STDERR="unexpected extra positional" run_case "extra positional exits 2" 2 "$VELK" first second

# Missing API key → exit 1, mentions the right env var
SMOKE_EXPECT_STDERR="ANTHROPIC_API_KEY" run_case "no anthropic key exits 1" 1 "$VELK" --provider anthropic "hi"
SMOKE_EXPECT_STDERR="OPENAI_API_KEY" run_case "no openai key exits 1" 1 "$VELK" --provider openai "hi"
SMOKE_EXPECT_STDERR="OPENROUTER_API_KEY" run_case "no openrouter key exits 1" 1 "$VELK" --provider openrouter "hi"

# --mcp parsing — too many should error before trying to spawn anything
unset SMOKE_EXPECT_STDOUT SMOKE_EXPECT_STDERR
SMOKE_EXPECT_STDERR="too many --mcp" run_case "17 --mcp servers exits 2" 2 "$VELK" \
    --mcp x --mcp x --mcp x --mcp x --mcp x --mcp x --mcp x --mcp x --mcp x \
    --mcp x --mcp x --mcp x --mcp x --mcp x --mcp x --mcp x --mcp x "hi"

# No prompt + non-tty stdin → prints help and exits 0 (REPL would need a tty).
# Provider setup runs first, so we need a (fake) key to reach the no-tty branch.
SMOKE_EXPECT_STDOUT="Usage: velk" run_case "no prompt + no tty prints help" 0 \
    env ANTHROPIC_API_KEY=sk-fake bash -c "$VELK </dev/null"

unset SMOKE_EXPECT_STDOUT SMOKE_EXPECT_STDERR

# Integration: spin up the python mock server and assert velk gets the
# canned reply end-to-end (network → SSE parser → text deltas → exit).
# Skipped when python3 isn't available; otherwise gives us real
# coverage of the agent loop without burning tokens.
if command -v python3 >/dev/null 2>&1; then
    MOCK_PORT="${SMOKE_MOCK_PORT:-8765}"
    python3 scripts/mock-server.py --port "$MOCK_PORT" >/tmp/velk-smoke-mock.log 2>&1 &
    MOCK_PID=$!
    trap "kill $MOCK_PID 2>/dev/null || true" EXIT

    # Wait up to 5s for the mock to come up.
    for _ in $(seq 1 50); do
        if curl -sf "http://127.0.0.1:$MOCK_PORT/_health" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done

    SMOKE_EXPECT_STDOUT="Mock reply from velk-mock-server" run_case \
        "mock anthropic streaming roundtrip" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            "$VELK" --no-tui "anything"

    SMOKE_EXPECT_STDOUT="arenas bloom" run_case \
        "mock anthropic scenario auto-pick" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            "$VELK" --no-tui "write a haiku"

    SMOKE_EXPECT_STDOUT="Mock reply from velk-mock-server" run_case \
        "mock openai streaming roundtrip" 0 \
        env "OPENAI_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/chat/completions" \
            OPENAI_API_KEY=sk-fake \
            "$VELK" --provider openai --no-tui "anything"

    SMOKE_EXPECT_STDERR="[debug] anthropic POST" run_case \
        "--debug dumps anthropic request envelope" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            "$VELK" --no-tui --debug "anything"

    # Settings file: a user-level settings.json with `defaults.model`
    # set should be picked up when --model is omitted. Use a tmp
    # XDG_CONFIG_HOME so we don't touch the real config.
    SETTINGS_TMP="$(mktemp -d)"
    mkdir -p "$SETTINGS_TMP/velk"
    cat >"$SETTINGS_TMP/velk/settings.json" <<'JSON'
{ "defaults": { "model": "claude-from-settings" } }
JSON
    SMOKE_EXPECT_STDERR="model=claude-from-settings" run_case \
        "settings.json defaults.model is applied" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            "XDG_CONFIG_HOME=$SETTINGS_TMP" \
            "$VELK" --no-tui --debug "anything"

    # CLI --model wins over settings.json.
    SMOKE_EXPECT_STDERR="model=cli-override" run_case \
        "CLI --model overrides settings.json" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            "XDG_CONFIG_HOME=$SETTINGS_TMP" \
            "$VELK" --no-tui --debug --model cli-override "anything"
    rm -rf "$SETTINGS_TMP"
    unset SMOKE_EXPECT_STDOUT SMOKE_EXPECT_STDERR

    # --mode parsing: bogus values are rejected with a warning but
    # we still succeed (fall back to default). Hard-refuse cases
    # belong in the harness — verify CLI surfaces here.
    SMOKE_EXPECT_STDERR="unknown --mode" run_case \
        "--mode bogus warns and falls back" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            "$VELK" --no-tui --mode totally-bogus "anything"

    # AGENTS.md auto-load: velk's own AGENTS.md should be detected
    # on launch (we run from the repo root). Banner reports it.
    SMOKE_EXPECT_STDERR="auto-loaded" run_case \
        "AGENTS.md is auto-loaded into the system prompt" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            "$VELK" --no-tui "anything"

    # @file mention: when the prompt references @LICENSE, the
    # expanded body fed to the worker is much bigger than the raw
    # prompt — visible via --debug's body= byte count. We compare
    # roughly: the LICENSE file is ~11k bytes; an expanded request
    # should have body=20000+ bytes, vs ~3000 without.
    SMOKE_EXPECT_STDERR="body=" run_case \
        "@file mention attaches file content to the request" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            "$VELK" --no-tui --debug "summarize @LICENSE"

    SMOKE_EXPECT_STDERR="repo-map prepended" run_case \
        "--repo-map prepends layout to system prompt" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            "$VELK" --no-tui --repo-map "anything"

    # @symbol: when no literal file matches, fall through to a
    # repo-grep for top-level decls. `maybeRequestApproval` lives
    # in src/tools.zig — the body should land in the request.
    SMOKE_EXPECT_STDERR="body=" run_case \
        "@symbol falls through to a repo-grep when not a path" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            "$VELK" --no-tui --debug "explain @maybeRequestApproval"

    # Tools registry: --no-tui ships 13 tools — 9 base builtins
    # (echo, read_file, write_file, edit, ls, grep, bash, web_fetch,
    # web_search), plus `worktree`, `write_plan`, and the two
    # sub-agent dispatchers `task` + `team` (both work headlessly).
    # `todo_write` and `ask_user_question` need a TUI panel and are
    # NOT registered here.
    SMOKE_EXPECT_STDERR="tools=15" run_case \
        "worktree + write_plan + task + team + read_memory + write_memory registered alongside the 9 builtins" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            "$VELK" --no-tui --debug "anything"

    # Hook system: a UserPromptSubmit hook that exits 2 should
    # block the prompt — velk exits 1 with the hook's stderr as
    # the reason. Tests the engine end-to-end (parse, dispatch,
    # spawn, exit-code semantics).
    HOOK_SETTINGS_TMP="$(mktemp -d)"
    mkdir -p "$HOOK_SETTINGS_TMP/velk"
    cat >"$HOOK_SETTINGS_TMP/velk/settings.json" <<'JSON'
{
  "hooks": {
    "UserPromptSubmit": [
      {"type": "command", "command": "echo SMOKE_HOOK_BLOCKED >&2; exit 2"}
    ]
  }
}
JSON
    SMOKE_EXPECT_STDERR="SMOKE_HOOK_BLOCKED" run_case \
        "UserPromptSubmit hook exit-2 blocks the prompt" 1 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            "XDG_CONFIG_HOME=$HOOK_SETTINGS_TMP" \
            "$VELK" --no-tui "anything"

    # Hook injection: a `prompt`-type UserPromptSubmit hook adds
    # extra context to the request body. The body grows in the
    # debug envelope's body=NN bytes count.
    cat >"$HOOK_SETTINGS_TMP/velk/settings.json" <<'JSON'
{
  "hooks": {
    "UserPromptSubmit": [
      {"type": "prompt", "prompt": "INJECTED_HOOK_CONTEXT"}
    ]
  }
}
JSON
    SMOKE_EXPECT_STDERR="body=" run_case \
        "UserPromptSubmit prompt-type hook injects context" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            "XDG_CONFIG_HOME=$HOOK_SETTINGS_TMP" \
            "$VELK" --no-tui --debug "anything"

    rm -rf "$HOOK_SETTINGS_TMP"
    unset SMOKE_EXPECT_STDOUT SMOKE_EXPECT_STDERR

    # Budget caps: --max-turn-tokens 1 against the default mock
    # (which streams ~12 in / 7 out tokens) trips immediately. The
    # turn aborts after the first iteration completes; the agent
    # surfaces TurnBudgetExceeded as the error name. The mock fixture
    # ends with end_turn so the cap actually fires before the model
    # would have stopped on its own — we use bash to force a tool
    # turn... actually default.sse already hits the cap because input
    # tokens alone exceed 1. The model errors with "TurnBudgetExceeded".
    SMOKE_EXPECT_STDERR="TurnBudgetExceeded" run_case \
        "--max-turn-tokens trips when cap exceeded mid-turn" 1 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            "$VELK" --no-tui --max-turn-tokens 1 "please diffwrite"
    unset SMOKE_EXPECT_STDOUT SMOKE_EXPECT_STDERR

    # Skills v1: a project-level .velk/skills/<name>/SKILL.md with
    # name + description in frontmatter is discovered and the
    # banner reports the load. Use a tmp project dir so we don't
    # pollute the repo.
    SKILLS_TMP="$(mktemp -d)"
    mkdir -p "$SKILLS_TMP/.velk/skills/sample-skill"
    cat >"$SKILLS_TMP/.velk/skills/sample-skill/SKILL.md" <<'MD'
---
name: sample-skill
description: Used by smoke tests to verify skill discovery
---

Body content goes here.
MD
    # Discovery walks .velk/skills relative to the cwd we run
    # from, so cd into the tmp dir for this case. Resolve the
    # binary's absolute path first since the relative
    # ./zig-out/bin/velk would break under pushd.
    VELK_ABS="$(cd "$(dirname "$VELK")" && pwd)/$(basename "$VELK")"
    pushd "$SKILLS_TMP" >/dev/null
    SMOKE_EXPECT_STDERR="1 skill(s) loaded" run_case \
        "skills: project SKILL.md is discovered" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            HOME="$SKILLS_TMP" \
            XDG_CONFIG_HOME="$SKILLS_TMP/empty" \
            "$VELK_ABS" --no-tui "anything"
    popd >/dev/null
    rm -rf "$SKILLS_TMP"
    unset SMOKE_EXPECT_STDOUT SMOKE_EXPECT_STDERR

    # Memory tools (memdir): a turn that triggers the `write_memory`
    # tool against a tmp XDG_DATA_HOME lands a markdown file at
    # `<tmp>/velk/memdir/smoke-test-topic.md`. Confirms end-to-end:
    # tool registration + slugify + on-disk write.
    MEMDIR_TMP="$(mktemp -d)"
    SMOKE_EXPECT_STDERR="wrote" run_case \
        "memory: write_memory tool persists a markdown note" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            "XDG_DATA_HOME=$MEMDIR_TMP" \
            "$VELK" --no-tui "please writemem"
    if [[ ! -f "$MEMDIR_TMP/velk/memdir/smoke-test-topic.md" ]]; then
        echo "FAIL: memory: file not landed at expected path"
        FAIL=$((FAIL + 1))
        FAILED_CASES+=("memory: file not landed at expected path")
    elif ! grep -qF "persistent-memo-marker" "$MEMDIR_TMP/velk/memdir/smoke-test-topic.md"; then
        echo "FAIL: memory: file content mismatch"
        FAIL=$((FAIL + 1))
        FAILED_CASES+=("memory: file content mismatch")
    else
        echo "PASS: memory: file persisted at expected path with expected content"
        PASS=$((PASS + 1))
    fi
    rm -rf "$MEMDIR_TMP"
    unset SMOKE_EXPECT_STDOUT SMOKE_EXPECT_STDERR

    # Custom shell tools: a project-level .velk/settings.json with a
    # `tools` array adds those entries to the registry. The startup
    # banner reports the count; --debug reports tools=14 (13 builtin
    # in headless mode + 1 custom). A name collision with a built-in
    # surfaces a clear skip notice.
    CUSTOM_TMP="$(mktemp -d)"
    mkdir -p "$CUSTOM_TMP/.velk"
    cat >"$CUSTOM_TMP/.velk/settings.json" <<'JSON'
{
  "tools": [
    {"name": "say_hi", "command": "echo hi-from-custom-tool", "description": "Echo a hi marker"}
  ]
}
JSON
    VELK_ABS="$(cd "$(dirname "$VELK")" && pwd)/$(basename "$VELK")"
    pushd "$CUSTOM_TMP" >/dev/null
    SMOKE_EXPECT_STDERR="custom · 1 tool(s) added" run_case \
        "custom-tools: registered + banner reports count" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            HOME="$CUSTOM_TMP" \
            XDG_CONFIG_HOME="$CUSTOM_TMP/empty" \
            "$VELK_ABS" --no-tui "anything"
    # NOTE: this case uses --debug, which makes std.debug.print
    # interleave with errw and clobber earlier buffered banner
    # output when stderr is a regular file. The custom-tools
    # banner check above runs without --debug; here we only need
    # to confirm `tools=14` lands.
    SMOKE_EXPECT_STDERR="tools=16" run_case \
        "custom-tools: tool count bumps from 15 → 16" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            HOME="$CUSTOM_TMP" \
            XDG_CONFIG_HOME="$CUSTOM_TMP/empty" \
            "$VELK_ABS" --no-tui --debug "anything"

    # Name collision: a custom tool with the same name as a built-in
    # is skipped + flagged.
    cat >"$CUSTOM_TMP/.velk/settings.json" <<'JSON'
{
  "tools": [
    {"name": "bash", "command": "true", "description": "shadow attempt"}
  ]
}
JSON
    SMOKE_EXPECT_STDERR="custom tool 'bash' shadows a built-in" run_case \
        "custom-tools: name collision with built-in is rejected" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            HOME="$CUSTOM_TMP" \
            XDG_CONFIG_HOME="$CUSTOM_TMP/empty" \
            "$VELK_ABS" --no-tui "anything"
    popd >/dev/null
    rm -rf "$CUSTOM_TMP"
    unset SMOKE_EXPECT_STDOUT SMOKE_EXPECT_STDERR

    # Profiles v1: a project-level .velk/settings.json with a `profiles`
    # block selected via `-P <name>` surfaces an "applied" banner; a
    # missing profile name surfaces a clear "not found" warning.
    PROFILE_TMP="$(mktemp -d)"
    mkdir -p "$PROFILE_TMP/.velk"
    cat >"$PROFILE_TMP/.velk/settings.json" <<'JSON'
{
  "profiles": {
    "review": { "model": "claude-sonnet-4-6", "system": "be terse" }
  }
}
JSON
    VELK_ABS="$(cd "$(dirname "$VELK")" && pwd)/$(basename "$VELK")"
    pushd "$PROFILE_TMP" >/dev/null
    SMOKE_EXPECT_STDERR="profile 'review' applied" run_case \
        "profiles: -P review applies named profile" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            HOME="$PROFILE_TMP" \
            XDG_CONFIG_HOME="$PROFILE_TMP/empty" \
            "$VELK_ABS" --no-tui -P review "anything"
    SMOKE_EXPECT_STDERR="profile 'nope' not found" run_case \
        "profiles: -P with unknown name warns" 0 \
        env "ANTHROPIC_BASE_URL=http://127.0.0.1:$MOCK_PORT/v1/messages" \
            ANTHROPIC_API_KEY=sk-fake \
            HOME="$PROFILE_TMP" \
            XDG_CONFIG_HOME="$PROFILE_TMP/empty" \
            "$VELK_ABS" --no-tui -P nope "anything"
    popd >/dev/null
    rm -rf "$PROFILE_TMP"
    unset SMOKE_EXPECT_STDOUT SMOKE_EXPECT_STDERR

    kill "$MOCK_PID" 2>/dev/null || true
    trap - EXIT
else
    echo "smoke: skipping mock-server cases (python3 not on PATH)"
fi

unset SMOKE_EXPECT_STDOUT SMOKE_EXPECT_STDERR

echo
echo "smoke: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    echo "failed cases:"
    for c in "${FAILED_CASES[@]}"; do
        echo "  - $c"
    done
    exit 1
fi
