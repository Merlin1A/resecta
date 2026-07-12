#!/usr/bin/env bash
# pre-push.sh — local push-time test gate.
#
# Runs both test schemes on the iPhone 17 simulator before any push.
# Installed as .git/hooks/pre-push by Scripts/install-hooks.sh.
# Expected wall-clock on Apple-silicon
# dev machines: ≤ 12 minutes.
#
# The RedactionEngine invocation skips the multi-minute stress
# suite via `-skip-testing`. NOTE: an xctestplan was the
# planned vehicle, but as of Xcode 26.5 neither `skippedTests` (any
# identifier shape) nor `skippedTags` in a test plan applies to Swift
# Testing suites — the CLI flag is the mechanism that demonstrably
# works (probed 2026-06-12). The stress suite still runs via
# `make stress-baseline`, which uses an explicit `-only-testing`.
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
DEST='platform=iOS Simulator,name=iPhone 17'

echo "→ pre-push: running RedactionEngine tests (stress suite skipped)…" >&2
xcodebuild test -scheme RedactionEngine \
    -skip-testing:RedactionEngineTests/StressCorpusTests \
    -destination "$DEST" -quiet

echo "→ pre-push: running ResectaApp tests…" >&2
xcodebuild test -scheme ResectaApp \
    -destination "$DEST" -quiet

echo "→ pre-push: both schemes green — push allowed." >&2
