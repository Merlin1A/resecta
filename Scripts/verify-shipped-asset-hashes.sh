#!/bin/bash
# Pre-archive integrity fence. Asserts the two reviewed, drift-prone
# search-config blobs match their canonical values. This is NOT a
# cryptographic gate (the signed gazetteer manifest is); it pins the exact
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

# gazetteer-manifest.json — the signed manifest's assets[] must describe the
# tree it ships with: every listed file present with the recorded size and
# SHA-256, and every installed asset listed (the manifest triple excepted).
# The engine re-verifies this at first load; failing here fails the archive
# instead of the user.
python3 - "$RES" <<'PY' || exit 1
import hashlib, json, os, sys
res = sys.argv[1]
manifest = json.load(open(os.path.join(res, "Gazetteers", "gazetteer-manifest.json")))
entries = manifest.get("assets")
if entries is None:
    print("FAIL gazetteer-manifest.json carries no assets[] section", file=sys.stderr); sys.exit(1)
triple = {"Gazetteers/gazetteer-manifest.json", "Gazetteers/gazetteer_manifest.sig", "Gazetteers/manifest_public_key.pem"}
installed = set()
for sub in ("Gazetteers", "Classifier", "Audit"):
    for name in os.listdir(os.path.join(res, sub)):
        if name != ".gitkeep":
            installed.add(f"{sub}/{name}")
listed = {e["path"] for e in entries}
if listed != installed - triple:
    print(f"FAIL manifest assets[] != installed tree: unlisted {sorted(installed - triple - listed)} · phantom {sorted(listed - installed)}", file=sys.stderr); sys.exit(1)
for e in entries:
    path = os.path.join(res, e["path"])
    data = open(path, "rb").read()
    if len(data) != e["bytes"] or hashlib.sha256(data).hexdigest() != e["sha256"]:
        print(f"FAIL {e['path']} differs from its signed manifest entry", file=sys.stderr); sys.exit(1)
print(f"OK: gazetteer-manifest.json assets[] describes the shipped tree ({len(entries)} assets)")
PY

echo "OK: shipped-asset hash fence passed"
