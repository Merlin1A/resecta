#!/usr/bin/env bash
# install-hooks.sh — symlink the repo's git hooks into .git/hooks.
#   pre-commit → ../../Scripts/audit-lint.sh
#   pre-push   → ../../Scripts/pre-push.sh
# Idempotent; re-running is safe.
#
# .git/hooks lives per-clone (not tracked in the repo), so each contributor
# (and each fresh clone of this branch) runs this script once after pulling.
# CONTRIBUTING.md flags this as part of dev setup.
#
# Manual verification (pre-push): `git push --dry-run` fires the hook —
# expect the "→ pre-push: running …" lines (or the SKIP_TESTS=1 skip
# notice) on stderr.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK_DIR="$REPO_ROOT/.git/hooks"
mkdir -p "$HOOK_DIR"

install_hook() { # hook-name script-basename
    local hook_path="$HOOK_DIR/$1"
    local target="../../Scripts/$2"

    if [ ! -x "$REPO_ROOT/Scripts/$2" ]; then
        echo "install-hooks: Scripts/$2 missing or not executable." >&2
        echo "  Expected: $REPO_ROOT/Scripts/$2" >&2
        exit 1
    fi

    if [ -L "$hook_path" ]; then
        local current
        current="$(readlink "$hook_path")"
        if [ "$current" = "$target" ]; then
            echo "install-hooks: $1 already linked → $target (no change)."
            return 0
        fi
        echo "install-hooks: replacing $1 symlink ($current → $target)"
        rm "$hook_path"
    elif [ -e "$hook_path" ]; then
        echo "install-hooks: refusing to overwrite non-symlink hook at $hook_path." >&2
        echo "  Move or delete it manually, then re-run." >&2
        exit 1
    fi

    ln -s "$target" "$hook_path"
    echo "install-hooks: $1 → $target (relative to .git/hooks/)"
}

install_hook pre-commit audit-lint.sh
install_hook pre-push pre-push.sh
echo "install-hooks: verify pre-commit with: git commit --allow-empty -m 'hook smoke test'"
echo "install-hooks: verify pre-push with: git push --dry-run (SKIP_TESTS=1 bypasses the test gate, logged)"
