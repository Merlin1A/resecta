#!/usr/bin/env bash
# update-context-scorer-hash.sh — B03 (C1 augment context scorer).
#
# Rewrites the compiled-in SHA-256 self-check constant
# (ContextScorerWeights.expectedSHA256) to the SHA-256 of the bundled
# Resources/Classifier/context-scorer.json. Pure local; no network.
#
# This value equals the DataPipeline asset_hashes.lock entry for
# classifier/context_scorer.json — one number, two homes — because the bundled
# file IS the emitted build artifact byte-for-byte (the coordinated PR pair).
# Re-run whenever the bundled weights change (B04 candidates / B05 promotion).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JSON="$REPO_ROOT/Packages/RedactionEngine/Sources/RedactionEngine/Resources/Classifier/context-scorer.json"
LOADER="$REPO_ROOT/Packages/RedactionEngine/Sources/RedactionEngine/Detection/Scoring/ContextScorerWeights.swift"

[ -f "$JSON" ]   || { echo "missing bundled artifact: $JSON" >&2; exit 1; }
[ -f "$LOADER" ] || { echo "missing loader: $LOADER" >&2; exit 1; }

HASH="$(shasum -a 256 "$JSON" | cut -d' ' -f1)"
if [[ ! "$HASH" =~ ^[0-9a-f]{64}$ ]]; then
    echo "unexpected sha256 for $JSON: $HASH" >&2
    exit 1
fi

# The constant's hex literal sits alone on its own line in the loader; rewrite
# exactly that line (the only 64-hex string literal on its own line in the file).
/usr/bin/sed -i '' -E "s/^([[:space:]]*)\"[0-9a-f]{64}\"\$/\1\"${HASH}\"/" "$LOADER"

# Confirm the loader now carries the computed hash.
if ! /usr/bin/grep -q "$HASH" "$LOADER"; then
    echo "rewrite did not take: $LOADER still lacks $HASH" >&2
    exit 1
fi

echo "context-scorer.json sha256 = $HASH"
echo "ContextScorerWeights.expectedSHA256 updated."
