#!/usr/bin/env bash
# pre-push.sh — local push-time test gate.
#
# Runs both test schemes through Scripts/test-batched.sh — build once, then
# serial suite-level batches on the iPhone 17 simulator, each under a
# watchdog — before any push. Installed as .git/hooks/pre-push by
# Scripts/install-hooks.sh. Measured wall-clock on an Apple-silicon dev
# machine (2026-08-27): ≈ 16 minutes for both schemes (engine ≈ 7, app ≈ 9).
#
# The runner's exit code decides the push: 0 (no gating red) allows it;
# 1 (a gating suite is red — the offenders are printed) and 2 (an invocation
# wedged or was cut by the watchdog, so its suites went unverified) both
# block it. A direct `xcodebuild test -scheme …` is deliberately NOT used
# here: one xctest process with in-process Swift Testing concurrency has
# wedged the simulator runtime machine-wide (the runner's header records the
# history). The perf-budget suites, the multi-minute stress suite among
# them, run alone and report-only inside the runner; `make stress-baseline`
# is unchanged.
#
# Bypass: SKIP_TESTS=1 env override for hotfix workflows. The
# skip is LOGGED to stderr — never a silent no-op — so the bypass stays
# visible in the push transcript. This is deliberately distinct from
# `git push --no-verify`, which suppresses the hook without leaving any
# trace; prefer SKIP_TESTS=1 so the skip is auditable.
set -euo pipefail

if [ "${SKIP_TESTS:-0}" = "1" ]; then
    echo "⚠  pre-push: SKIP_TESTS=1 — test gate SKIPPED (visible bypass)" >&2
    exit 0
fi

cd "$(git rev-parse --show-toplevel)"

run_scheme() { # scheme
    echo "→ pre-push: running $1 tests via the batched runner…" >&2
    local rc=0
    Scripts/test-batched.sh "$1" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "✗ pre-push: $1 batched run exited $rc (1 = gating red, 2 = incomplete) — push blocked." >&2
        exit "$rc"
    fi
}

run_scheme RedactionEngine
run_scheme ResectaApp

echo "→ pre-push: both schemes green — push allowed." >&2
