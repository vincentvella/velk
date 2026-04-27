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
