#!/bin/bash
# Pre-archive integrity fence (D11-config-golive-F6 Phase A). Asserts the two
# reviewed, drift-prone search-config blobs match their Jesse-reviewed canonical
# values. This is NOT a cryptographic gate (see SEC-6 Phase B); it pins the exact
# committed bytes so an accidental swap/clobber fails the archive, not the user.
#
# Run from anywhere in the repo.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)" || { echo "not in a git repo" >&2; exit 1; }
cd "$ROOT"
RES="Packages/RedactionEngine/Sources/RedactionEngine/Resources"

# preset-thresholds.json — calibrated, 17 categories (NOT the degenerate name=0.98
# sweep). Pinned by git blob hash from the verified release head.
EXPECT_PRESET="28921a52a671cb12ddd3590637a27971aaa90344"
ACTUAL_PRESET="$(git hash-object "$RES/Classifier/preset-thresholds.json")"
[ "$ACTUAL_PRESET" = "$EXPECT_PRESET" ] || {
  echo "FAIL preset-thresholds.json blob $ACTUAL_PRESET != $EXPECT_PRESET" >&2; exit 1; }

# context-scorer.json — SHA-256 must equal the compiled-in self-check constant
# (ContextScorerWeights.swift expectedSHA256; one number, two homes).
EXPECT_SCORER="fecd89b6a790d9895e7081e99b448d9245096aa435e2389252f7c5f5eab2acb8"
ACTUAL_SCORER="$(shasum -a 256 "$RES/Classifier/context-scorer.json" | cut -d' ' -f1)"
[ "$ACTUAL_SCORER" = "$EXPECT_SCORER" ] || {
  echo "FAIL context-scorer.json sha256 $ACTUAL_SCORER != $EXPECT_SCORER" >&2; exit 1; }

echo "OK: shipped-asset hash fence passed"
