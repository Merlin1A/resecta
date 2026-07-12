#!/bin/sh
# claims-lint.sh — ASC-7.4 mechanism-language sweep over shipping docs +
# non-Legal user-facing strings. Companion to LegalPhraseLintTests (which
# guards only Sources/ResectaApp/Legal/Legal.xcstrings); this sweep covers
# the shipping markdown set and the SwiftUI view-layer string literals that
# the compiled test does not reach.
#
# ─── Claims framing (ASC-7.4 / LEGAL-9, ratified by Jesse) ──────────────────
# Approved positive phrasings (mechanism, no outcome guarantee):
#   - "Secure rasterization removes the text in marked regions; affected
#      pages are rasterized and metadata is stripped."
#   - "On-device detection" / "no network, no account, no data collection."
#   - "A verification pass checks the output before you share; verification
#      is a check, not a substitute for your review."
# Banned set mirrors LegalPhrases.bannedTerms
# (Sources/ResectaApp/Legal/LegalPhrases.swift). Keep the two lists in sync.
# ───────────────────────────────────────────────────────────────────────────
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GREP=/usr/bin/grep

# Shipping markdown set (NOT internal /specs or test fixtures).
DOCS="README.md ENGINEERING.md CONTRIBUTING.md CHANGELOG.md KNOWN_ISSUES.md EULA.md PRIVACY.md SECURITY.md NOTICE Packages/RedactionEngine/README.md Scripts/gazetteer/README.md"

# Banned tokens — mirror of LegalPhrases.bannedTerms (case-insensitive),
# plus one doc-only addition beyond that list: subject-scoped device-boundary
# overclaims ("documents/files/data never leave ..."). Subject-scoped on
# purpose: PRIVACY.md's collection wording ("it never leaves the device")
# is accurate in its context and stays out of pattern.
PATTERNS='structurally impossible|the only provably secure approach|destroy-level sanitization per nist|mathematically irreversible|security invariant|provably reliable|guaranteed|ensures|securely removes|100%|impossible to recover|military-grade|bank-level|certified|(documents?|files?|data|photos?|images?|content) never leaves?'

# Legitimate negatives that must NOT trip:
#   - "cannot guarantee [complete removal]" — the honest disclaimer.
#   - "Secure Rasterization" / "Secure-Rasterization" — proper-noun mode name.
#   - "not a substitute" — the verification-is-a-check disclaimer.
ALLOW='cannot guarantee|Secure Rasterization|Secure-Rasterization|not a substitute'

fail=0

# 1. Shipping markdown.
for f in $DOCS; do
  [ -f "$ROOT/$f" ] || continue
  hits=$("$GREP" -nEi "$PATTERNS" "$ROOT/$f" | "$GREP" -vEi "$ALLOW" || true)
  if [ -n "$hits" ]; then
    echo "CLAIMS-LINT FAIL: $f"
    echo "$hits"
    fail=1
  fi
done

# 2. User-facing SwiftUI string literals outside Legal.xcstrings (view layer
#    only). Restricted to lines containing a string literal (") so engineering
#    code comments (e.g. "// ... ensures ...") are not flagged — user-facing
#    claims live inside "..." strings, not comments.
SWIFT_HITS=$("$GREP" -rnEi "$PATTERNS" "$ROOT/Sources/ResectaApp/Views" --include='*.swift' \
  | "$GREP" '"' \
  | "$GREP" -vEi "$ALLOW" || true)
if [ -n "$SWIFT_HITS" ]; then
  echo "CLAIMS-LINT FAIL (SwiftUI literals):"
  echo "$SWIFT_HITS"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "CLAIMS-LINT PASS"
else
  exit 1
fi
