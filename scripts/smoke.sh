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

echo
echo "smoke: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    echo "failed cases:"
    for c in "${FAILED_CASES[@]}"; do
        echo "  - $c"
    done
    exit 1
fi
