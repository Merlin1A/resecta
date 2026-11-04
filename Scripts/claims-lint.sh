#!/bin/sh
# claims-lint.sh — mechanism-language sweep over shipping docs +
# non-Legal user-facing strings. Companion to LegalPhraseLintTests (which
# guards only Sources/ResectaApp/Legal/Legal.xcstrings); this sweep covers
# the shipping markdown set, the app's Swift string literals and the
# verification checks' copy literals that the compiled test does not reach.
#
# ─── Claims framing ─────────────────────────────────────────────────────────
# Approved positive phrasings (mechanism, no outcome guarantee):
#   - "Secure rasterization removes the text in marked regions; affected
#      pages are rasterized and metadata is stripped."
#   - "On-device detection" / "no network, no account, no data collection."
#   - "A verification pass checks the output before you share; verification
#      is a check, not a substitute for your review."
# The banned set is READ from LegalPhrases.bannedTerms
# (Sources/ResectaApp/Legal/LegalPhrases.swift), its one home: the string
# literals between `bannedTerms: [String] = [` and the closing `]`. A list
# that reads empty fails the lint (fail closed).
#
# Usage: Scripts/claims-lint.sh              (the sweep; exit 0 PASS, 1 FAIL)
#        Scripts/claims-lint.sh --self-test  (scratch trees; no repository file read)
# ───────────────────────────────────────────────────────────────────────────
set -eu
GREP=/usr/bin/grep

# Legitimate negatives that must NOT trip:
#   - "cannot guarantee [complete removal]" — the honest disclaimer.
#   - "Secure Rasterization" / "Secure-Rasterization" — proper-noun mode name.
#   - "not a substitute" — the verification-is-a-check disclaimer.
# An allowed phrase is removed from its line before the line is matched, so
# a banned word elsewhere on the same line still fails. A line that carries
# the marker `LegalPhrases:safe` is exempt; the marker covers its own line only.
ALLOW='cannot guarantee|Secure Rasterization|Secure-Rasterization|not a substitute'

# One doc-only addition beyond the banned list: subject-scoped device-boundary
# overclaims ("documents/files/data never leave ..."). Subject-scoped on
# purpose: PRIVACY.md's collection wording ("it never leaves the device")
# is accurate in its context and stays out of pattern.
DOC_ONLY='(documents?|files?|data|photos?|images?|content) never leaves?'

# Shipping markdown set (NOT internal /specs or test fixtures).
DOCS="README.md ENGINEERING.md CONTRIBUTING.md CHANGELOG.md KNOWN_ISSUES.md EULA.md PRIVACY.md SECURITY.md THREAT-MODEL.md VERIFICATION-SPEC.md NOTICE Packages/RedactionEngine/README.md"

# Swift trees whose string literals are user-facing copy: the app, and the
# verification checks whose result copy the results screen shows.
SWIFT_TREES="Sources/ResectaApp Packages/RedactionEngine/Sources/RedactionEngine/Verification"
LIST_FILE="Sources/ResectaApp/Legal/LegalPhrases.swift"

# The banned terms as one case-insensitive ERE alternation, from the list file.
banned_patterns() { # $1 = the list file
    terms=$(sed -n '/bannedTerms: \[String\] = \[/,/^[[:space:]]*\]/p' "$1" \
        | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p' \
        | sed 's/[][\\.*^$?+(){}|/]/\\&/g' \
        | paste -sd '|' -)
    [ -n "$terms" ] || return 1
    printf '%s' "$terms"
}

# Reads "path:line:text" hits on stdin; prints those still matching once the
# allowed phrases are removed, minus lines that carry the marker.
keep_offending() {
    CL_PAT="$1" CL_ALLOW="$ALLOW" perl -ne '
        BEGIN { $p = qr/$ENV{CL_PAT}/i; $a = qr/$ENV{CL_ALLOW}/i }
        next if /LegalPhrases:safe/;
        (my $l = $_) =~ s/$a//g;
        print if $l =~ $p;'
}

sweep() { # $1 = the tree root
    ROOT="$1"
    if ! BANNED=$(banned_patterns "$ROOT/$LIST_FILE"); then
        echo "CLAIMS-LINT FAIL: no banned terms read from $LIST_FILE"
        return 1
    fi
    PATTERNS="$BANNED|$DOC_ONLY"
    fail=0

    # 1. Shipping markdown.
    for f in $DOCS; do
        [ -f "$ROOT/$f" ] || continue
        hits=$("$GREP" -nEi "$PATTERNS" "$ROOT/$f" | keep_offending "$PATTERNS" || true)
        if [ -n "$hits" ]; then
            echo "CLAIMS-LINT FAIL: $f"
            echo "$hits"
            fail=1
        fi
    done

    # 2. Swift string literals in the app and the verification checks.
    #    Restricted to lines holding a string literal (") that are not comment
    #    lines, so engineering prose (`// ... ensures ...`, a quoted word in a
    #    doc comment) is not flagged; the list file itself is skipped.
    trees=""
    for t in $SWIFT_TREES; do [ -d "$ROOT/$t" ] && trees="$trees $ROOT/$t"; done
    if [ -n "$trees" ]; then
        # shellcheck disable=SC2086
        SWIFT_HITS=$("$GREP" -rnEi "$PATTERNS" $trees --include='*.swift' \
            | "$GREP" -v "^$ROOT/$LIST_FILE:" \
            | "$GREP" '"' \
            | "$GREP" -vE '^[^:]+:[0-9]+:[[:space:]]*//' \
            | keep_offending "$PATTERNS" || true)
        if [ -n "$SWIFT_HITS" ]; then
            echo "CLAIMS-LINT FAIL (Swift string literals):"
            echo "$SWIFT_HITS"
            fail=1
        fi
    fi

    [ "$fail" -eq 0 ] && echo "CLAIMS-LINT PASS"
    return "$fail"
}

self_test() {
    T=$(mktemp -d)
    trap 'rm -rf "$T"' EXIT
    bad=0
    case_tree() { # $1 = case name; prints its root
        d="$T/$1"
        mkdir -p "$d/Sources/ResectaApp/Legal" "$d/Sources/ResectaApp/Views" "$d/Sources/ResectaApp/State" \
            "$d/Packages/RedactionEngine/Sources/RedactionEngine/Verification"
        printf 'public enum LegalPhrases {\n    public static let bannedTerms: [String] = [\n        "guarantee",\n        "ensures",\n        "100%%",\n    ]\n}\n' \
            > "$d/$LIST_FILE"
        printf '# readme\nclean text.\n' > "$d/README.md"
        printf '%s' "$d"
    }
    check() { # $1 = name, $2 = root, $3 = PASS|FAIL wanted
        if sweep "$2" > "$2.out" 2>&1; then got=PASS; else got=FAIL; fi
        if [ "$got" = "$3" ]; then echo "  ok   $1: $got"; else echo "  FAIL $1: $got, wanted $3"; bad=1; fi
    }
    d=$(case_tree clean);        check "clean tree" "$d" PASS
    d=$(case_tree stem);         printf 'The pass guarantees removal.\n' >> "$d/README.md"; check "an inflection of a listed stem" "$d" FAIL
    d=$(case_tree allowline);    printf 'It cannot guarantee completeness, and it ensures removal.\n' >> "$d/README.md"; check "an allowed phrase beside a banned word on one line" "$d" FAIL
    d=$(case_tree allowonly);    printf 'It cannot guarantee completeness.\n' >> "$d/README.md"; check "an allowed phrase alone" "$d" PASS
    d=$(case_tree marker);       printf 'No tool can guarantee perfection. <!-- LegalPhrases:safe -->\n' >> "$d/README.md"; check "a marked line" "$d" PASS
    d=$(case_tree markerother);  printf 'No tool can guarantee perfection. <!-- LegalPhrases:safe -->\nThis ensures removal.\n' >> "$d/README.md"; check "a marker covers its own line only" "$d" FAIL
    d=$(case_tree percent);      printf 'Removes 100%% of the text.\n' >> "$d/README.md"; check "a listed term with a regex character" "$d" FAIL
    d=$(case_tree state);        printf 'let s = "this guarantees removal"\n' > "$d/Sources/ResectaApp/State/X.swift"; check "a string literal outside the view layer" "$d" FAIL
    d=$(case_tree engine);       printf 'LayerCopy(short: "Ensures every page is clean", detail: "")\n' > "$d/Packages/RedactionEngine/Sources/RedactionEngine/Verification/X.swift"; check "a verification copy literal" "$d" FAIL
    d=$(case_tree comment);      printf '// what the app "guarantees" is not the point\n/// a "guarantee" in a doc comment\n' > "$d/Sources/ResectaApp/Views/X.swift"; check "a quoted word in a comment line" "$d" PASS
    d=$(case_tree device);       printf 'Your documents never leave the phone.\n' >> "$d/README.md"; check "the doc-only device-boundary pattern" "$d" FAIL
    d=$(case_tree emptylist);    printf 'public enum LegalPhrases {\n    public static let bannedTerms: [String] = [\n    ]\n}\n' > "$d/$LIST_FILE"; check "an empty banned list fails closed" "$d" FAIL
    if [ "$bad" -eq 0 ]; then echo "claims-lint --self-test: PASS"; else echo "claims-lint --self-test: FAIL"; return 1; fi
}

case "${1:-}" in
    --self-test) self_test; exit $? ;;
    "") sweep "$(cd "$(dirname "$0")/.." && pwd)" || exit 1 ;;
    *) echo "usage: $0 [--self-test]" >&2; exit 64 ;;
esac
