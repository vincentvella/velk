#!/usr/bin/env bash
# Installs git hooks from scripts/hooks/ into .git/hooks/.
# Run once per fresh clone: `scripts/install-hooks.sh`

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SRC="$ROOT/scripts/hooks"
DST="$ROOT/.git/hooks"

if [[ ! -d "$DST" ]]; then
    echo "install-hooks: $DST does not exist (not a git repo?)" >&2
    exit 1
fi

for hook in "$SRC"/*; do
    name="$(basename "$hook")"
    target="$DST/$name"
    if [[ -e "$target" && ! -L "$target" ]]; then
        echo "install-hooks: $target exists and is not a symlink — skipping"
        continue
    fi
    ln -sf "$hook" "$target"
    chmod +x "$hook"
    echo "install-hooks: $name → $hook"
done
