#!/usr/bin/env bash
# Codename-safe build check.
#
# Greps the source tree against a deny-list of internal codenames so
# generated content / commits don't leak them. Off by default (the
# deny-list ships empty); a maintainer adds entries to
# scripts/codename-denylist.txt when they need to gate a release.
#
# Deny-list format:
#   - one term per line
#   - blank lines and `#`-prefixed lines are skipped
#   - terms are matched case-insensitively as plain substrings
#
# Searched: source files only (src/, scripts/, README.md, build.zig).
# Skipped: .zig-cache/, zig-pkg/, .git/, .velk/, vscode/, jetbrains/,
# and the deny-list file itself (otherwise listing a codename to ban
# would trigger the check).
#
# Override location: VELK_CODENAME_DENYLIST=/path/to/list.txt
# to point at a different deny-list file.

set -euo pipefail

DENYLIST="${VELK_CODENAME_DENYLIST:-scripts/codename-denylist.txt}"

if [[ ! -f "$DENYLIST" ]]; then
    echo "codename-check: $DENYLIST not found; skipping" >&2
    exit 0
fi

# Collect non-comment, non-blank lines into an alternation. Avoids
# mapfile / readarray (bash 4+) so this works on macOS's stock
# bash 3.2 too.
PATTERN=""
TERM_COUNT=0
while IFS= read -r raw; do
    case "$raw" in
        ''|\#*) continue ;;
    esac
    escaped=$(printf '%s' "$raw" | sed 's/[][\.*^$()+?{}|/]/\\&/g')
    if [[ -z "$PATTERN" ]]; then
        PATTERN="$escaped"
    else
        PATTERN="$PATTERN|$escaped"
    fi
    TERM_COUNT=$((TERM_COUNT + 1))
done < "$DENYLIST"

if [[ "$TERM_COUNT" -eq 0 ]]; then
    echo "codename-check: deny-list empty; skipping (this is the default)"
    exit 0
fi

# Search. `-l` would only print files; we want file:line:match for
# actionable failure output.
HITS=$(
    grep -RInE "$PATTERN" \
        --include="*.zig" --include="*.md" --include="*.json" \
        --include="*.sh" --include="*.py" --include="*.ts" \
        --include="*.kt" --include="*.kts" \
        --exclude-dir=".zig-cache" \
        --exclude-dir="zig-pkg" \
        --exclude-dir=".git" \
        --exclude-dir=".velk" \
        --exclude-dir=".claude" \
        --exclude-dir="node_modules" \
        --exclude-dir="build" \
        --exclude-dir=".gradle" \
        --exclude-dir=".idea" \
        --exclude-dir=".intellijPlatform" \
        --exclude-dir=".kotlin" \
        --exclude="codename-denylist.txt" \
        . 2>/dev/null || true
)

if [[ -n "$HITS" ]]; then
    echo "codename-check: leaked codename(s) found in source tree:" >&2
    echo "$HITS" >&2
    echo "" >&2
    echo "Edit '$DENYLIST' to remove the term or fix the source." >&2
    exit 1
fi

echo "codename-check: $TERM_COUNT term(s) checked, no leaks"
