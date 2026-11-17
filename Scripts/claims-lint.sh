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
#        Scripts/claims-lint.sh --self-test  (scratch trees; reads only the list file, for the
#                                             length-claim stems' own cases)
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

# Length-claim patterns, the second list: paraphrases of "a box hides how long
# its text is" that no fixed substring catches (the literal stems are in the
# banned list). LEN is a length word (length, width, size; how long, wide,
# short or big a text is; how many letters, characters or digits); GAP is up to
# 30 characters with no sentence stop. Each is matched case-insensitively over
# every sentence of a document (a sentence can wrap across lines; a blank line
# ends one) and over each Swift string-literal line, after the allowed phrases
# are removed; a line with the marker `LegalPhrases:safe` is left out.
LENGTH_PATTERNS=on
length_claims() { # $1 = doc|lines; doc: $2 = file; lines: "path:line:text" on stdin
    CL_ALLOW="$ALLOW" perl -e '
        my $LEN = q{(?:lengths?|widths?|sizes?|how\s+(?:long|wide|short|big)\s+(?:(?:the|its|their|that|this|a|your)\s+)?(?:\w+\s+)?(?:text|texts|name|names|word|words|value|values|number|numbers|it|they)\b|how\s+many\s+(?:letters|characters|digits)|the\s+number\s+of\s+(?:letters|characters|digits))};
        my $GAP = q{[^.;:!?]{0,30}};
        my @P = (
          [L1  => qq{\\bhid(?:e|es|ing|den)\\b$GAP\\b$LEN\\b}],
          [L2  => q{\bhide\s+text\s+length\b}],
          [L3  => qq{\\b$LEN\\b(?:\\s+of\\s+[^.;:!?]{0,25}?)?\\s+(?:is|are|was|were|stays?|remains?|becomes?|gets?)\\s+(?:\\w+\\s+)?(?:hidden|concealed|masked|obscured|disguised|secret|invisible|unknown|gone|erased)\\b|\\b(?:keeps?|leaves?|makes?)\\s+(?:the\\s+|its\\s+|their\\s+)?(?:\\w+\x27s\\s+)?$LEN\\s+(?:hidden|concealed|secret|unknown|invisible)\\b}],
          [L4  => qq{\\b(?:conceal(?:s|ed|ing)?|mask(?:s|ed|ing)?|obscur(?:e|es|ed|ing)|disguis(?:e|es|ed|ing)|protect(?:s|ed|ing)?)\\s+(?:the\\s+|its\\s+|their\\s+|a\\s+|each\\s+)?(?:\\w+\x27s\\s+|\\w+\\s+)?$LEN\\b}],
          [L5  => qq{\\b(?:$LEN|box(?:es)?)\\b[^.;:!?]{0,40}\\b(?:says|tells|reveals|shows|gives|leaks)\\s+(?:\\w+\\s+)?nothing\\b}],
          [L6  => qq{\\b(?:no\\s+longer|does\\s+not|doesn\x27t|never)\\s+(?:follows?|shows?|reveals?|match(?:es)?|tracks?|depends?\\s+on|reflects?|gives?\\s+away)\\b[^.;:!?]{0,25}\\b(?:text|value|name|word|$LEN)\\b}],
          [L7  => qq{\\b(?:cannot|can\x27t|can\\s*not|never|does\\s+not|doesn\x27t|no\\s+longer)\\s+(?:show|reveal|give\\s+away|leak|betray|tell|say|see|know|guess|learn|work\\s+out)\\b$GAP\\b$LEN}],
          [L8  => qq{\\b(?:no\\s+one|nobody|no\\s+reader|anyone)\\s+(?:can|could)(?:not|\x27t)?\\s+(?:tell|see|guess|work\\s+out|infer|know|measure|recover)\\b$GAP\\b$LEN\\b|\\b$LEN\\b[^.;:!?]{0,15}\\b(?:cannot|can\x27t|can\\s+never)\\s+be\\s+(?:read|seen|recovered|measured|guessed|inferred|known|told|worked\\s+out|determined|estimated)\\b}],
          [L9  => q{\b(?:length|width|size)[- ](?:hiding|hidden|proof|safe|neutral|blind|free|protection|privacy)\b|\b(?:hidden|concealed|masked)[- ](?:length|width)\b}],
          [L10 => qq{\\b(?:makes?|keeps?|turns?)\\b$GAP\\bsame\\s+(?:length|width|size)\\b|\\bsame\\s+(?:length|width|size)\\b$GAP\\b(?:whatever|for\\s+any|for\\s+every|regardless|no\\s+matter)\\b|\\b(?:whatever|regardless\\s+of|no\\s+matter)\\b[^.;:!?]{0,25}\\b(?:text|name|value|word)s?\\s+(?:under|beneath|inside|in)\\s+(?:it|the\\s+box|a\\s+box)\\b}],
          [L11 => qq{\\b(?:stops?|keeps?|prevents?)\\b$GAP\\bfrom\\s+(?:showing|revealing|giving\\s+away|leaking)\\b[^.;:!?]{0,20}\\b$LEN}],
          [L12 => qq{\\bwithout\\s+(?:showing|revealing|giving\\s+away|leaking)\\b[^.;:!?]{0,20}\\b$LEN}],
          [L13 => q{\b(?:equali[sz](?:e|es|ed|ing)|standardi[sz](?:e|es|ed|ing)|evens?\s+out)\b[^.;:!?]{0,20}\b(?:lengths?|widths?|sizes?)\b}],
        );
        my $allow = qr/$ENV{CL_ALLOW}/i;
        my @rx = map { [$_->[0], qr/$_->[1]/i] } @P;
        sub scan { my ($where, $text) = @_;
            for my $r (@rx) { print "$where: $r->[0]: $text\n" if $text =~ $r->[1] } }
        if ($ARGV[0] eq "lines") {
            while (my $l = <STDIN>) { chomp $l; next if $l =~ /LegalPhrases:safe/;
                my ($where, $text) = $l =~ /^([^:]+:\d+):(.*)$/ or next; $text =~ s/$allow//g; scan($where, $text) }
            exit 0 }
        open(my $fh, "<", $ARGV[1]) or die "cannot read $ARGV[1]\n";
        my @lines = <$fh>; my ($buf, $start) = ("", 0);
        my $flush = sub { if ($buf =~ /\S/) {
                for my $s (split /(?<=[.!?])\s+/, $buf) { scan("$ARGV[1]:$start", $s) } }
            $buf = ""; $start = 0 };
        for my $i (0 .. $#lines) { my $l = $lines[$i]; chomp $l;
            if ($l !~ /\S/ || $l =~ /LegalPhrases:safe/) { $flush->(); next }
            $l =~ s/$allow//g; $start ||= $i + 1; $buf .= " $l" }
        $flush->();
    ' "$@"
}

# Shipping markdown set (NOT internal /specs or test fixtures).
DOCS="README.md ENGINEERING.md CONTRIBUTING.md CHANGELOG.md KNOWN_ISSUES.md EULA.md PRIVACY.md SECURITY.md THREAT-MODEL.md VERIFICATION-SPEC.md NOTICE Packages/RedactionEngine/README.md"

# Swift trees whose string literals are user-facing copy: the app, the
# verification checks whose result copy the results screen shows, and the
# engine's Foundation-only core, where judging code is written.
SWIFT_TREES="Sources/ResectaApp Packages/RedactionEngine/Sources/RedactionEngine/Verification Packages/RedactionEngine/Sources/RedactionCore"
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
        if [ "$LENGTH_PATTERNS" = on ]; then
            if ! hits=$(length_claims doc "$ROOT/$f"); then
                echo "CLAIMS-LINT FAIL: the length-claim patterns did not run on $f"
                fail=1
            fi
            hits=$(printf '%s' "$hits" | sed "s|^$ROOT/||")
            if [ -n "$hits" ]; then
                echo "CLAIMS-LINT FAIL (length claim): $f"
                echo "$hits"
                fail=1
            fi
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
        if [ "$LENGTH_PATTERNS" = on ]; then
            # shellcheck disable=SC2086
            LENGTH_HITS=$("$GREP" -rn '"' $trees --include='*.swift' \
                | "$GREP" -v "^$ROOT/$LIST_FILE:" \
                | "$GREP" -vE '^[^:]+:[0-9]+:[[:space:]]*//' \
                | length_claims lines) || {
                echo "CLAIMS-LINT FAIL: the length-claim patterns did not run on the Swift string literals"
                fail=1
            }
            if [ -n "$LENGTH_HITS" ]; then
                echo "CLAIMS-LINT FAIL (length claim, Swift string literals):"
                echo "$LENGTH_HITS"
                fail=1
            fi
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
        if sweep "$2" > "$2.out" 2>&1 < /dev/null; then got=PASS; else got=FAIL; fi
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

    # The length-claim stems. A literal's case reads the list file of record,
    # with the patterns off, so the literal alone must catch its line; a
    # pattern's case uses the scratch list above, so the pattern alone must;
    # an innocent line must pass both lists together.
    REPO="$(cd "$(dirname "$0")/.." && pwd)"
    stem_tree() { d=$(case_tree "$1"); cp "$REPO/$LIST_FILE" "$d/$LIST_FILE"; printf '%s' "$d"; }
    n=0
    while IFS='|' read -r kind id line; do
        [ -n "$kind" ] || continue
        n=$((n + 1))
        case "$kind" in
            lit) d=$(stem_tree "s$n"); LENGTH_PATTERNS=off; printf '%s\n' "$line" >> "$d/README.md"
                 check "literal $id catches its line" "$d" FAIL; LENGTH_PATTERNS=on ;;
            pat) d=$(case_tree "s$n"); printf '%s\n' "$line" >> "$d/README.md"; check "pattern $id catches its line" "$d" FAIL ;;
            ok)  d=$(stem_tree "s$n"); printf '%s\n' "$line" >> "$d/README.md"; check "innocent line $id passes" "$d" PASS ;;
        esac
    done <<'LINES'
lit|hide text length|Turn on Hide Text Length in Settings.
lit|length hidden|Boxes with length hidden are counted apart.
lit|hidden length|A box with hidden length covers the line.
lit|length is hidden|With the switch on, the length is hidden.
lit|hides the length|Widen Boxes hides the length of a name.
lit|hide the length|Boxes that hide the length of a name.
lit|hides its length|A widened box hides its length.
lit|hiding the length|It works by hiding the length of the text.
lit|hides how long|Each box hides how long the name is.
lit|hide how long|Wider boxes hide how long a name is.
lit|conceals the length|The switch conceals the length of each name.
lit|conceal the length|Boxes conceal the length of the text.
lit|masks the length|Widen Boxes masks the length of short names.
lit|cannot show how long|A widened box cannot show how long the text is.
lit|can't show how long|A widened box can't show how long the text is.
lit|no longer shows how long|The box no longer shows how long the name is.
lit|can no longer show|A widened box can no longer show the name's length.
lit|width says nothing|So their width says nothing about the text.
lit|says nothing about the text|The box says nothing about the text beyond that it fits.
lit|no longer follows the text|The box's width then no longer follows the text.
pat|L1|Each box hides how long the name is.
pat|L2|Turn on Hide Text Length in Settings.
pat|L3|With the switch on, the length of the name is hidden.
pat|L4|Widen Boxes masks the length of short names.
pat|L5|Resecta draws those boxes to the edge of the column, so their width says nothing about the text beyond that it fits there.
pat|L6|The box's width then no longer follows the text.
pat|L7|A widened box cannot show how long the text is.
pat|L8|No one can tell how long the name was.
pat|L9|A length-hiding box covers the whole line.
pat|L10|Every widened box is the same width whatever the text under it.
pat|L11|It stops a box from showing how long the text was.
pat|L12|It covers the name without showing how long it is.
pat|L13|Widen Boxes equalizes box widths.
ok|1|A box removes the text under it, but its width can still show how long that text was.
ok|2|That can be enough to tell which name or month it was, or how many digits an amount has.
ok|3|Where it can, Widen Boxes runs a box across every line it touches, from one side of the column to the other, or across the whole cell in a table.
ok|4|A widened box can still show about how long its text was: in a paragraph, by where the lines break, and more closely each time the same text appears.
ok|5|Widened boxes can still show how long their text is.
ok|6|The results do not show how long the check took.
ok|7|A page that already carries hidden text is exported as a picture.
ok|8|Your active filters hide all results.
ok|9|Turn on Widen Boxes in Settings.
ok|10|With the font and size known, its hidden Markov models recovered the text almost without error for many common fonts.
ok|11|…on European court judgments whose masks kept each span's length.
ok|12|Nothing was redacted: this PDF has no boxes.
ok|13|The return to the home screen no longer shows an empty page for a moment.
ok|14|19 boxes can still show how long their text is.
ok|15|Page 9: a box over an image. Its fill was checked; Resecta cannot know what it covered.
ok|16|Fonts on Searchable pages must be Courier, Courier New or Menlo, all fixed-width.
ok|17|…so the gap is kept only in whole cells: 13 here, the same for any words 40.3 to 44.6 pt wide.
ok|18|The ink check keeps a box from leaving ink past its edge.
ok|19|Search finds the text you type without showing other forms of it.
ok|20|Resecta re-sets each kept character in one fixed-width font.
LINES
    [ "$n" -eq 53 ] || { echo "  FAIL the stem cases: $n read, 53 wanted (20 literals, 13 patterns, 20 innocent lines)"; bad=1; }
    d=$(case_tree wrapped);      printf 'The box'"'"'s width then no longer\nfollows the text.\n' >> "$d/README.md"; check "a length claim wrapped across two lines" "$d" FAIL
    d=$(case_tree blankstop);    printf 'Hidden\n\nlength of the name.\n' >> "$d/README.md"; check "a blank line ends a sentence" "$d" PASS
    d=$(case_tree lenmarker);    printf 'Each box hides how long the name is. <!-- LegalPhrases:safe -->\n' >> "$d/README.md"; check "a length claim on a marked line" "$d" PASS
    d=$(case_tree lenswift);     printf 'let s = "Widen Boxes masks the length of short names."\n' > "$d/Sources/ResectaApp/Views/X.swift"; check "a length claim in a Swift string literal" "$d" FAIL
    d=$(case_tree lencomment);   printf '// "Widen Boxes masks the length of short names." is banned\n' > "$d/Sources/ResectaApp/Views/X.swift"; check "a length claim in a Swift comment line" "$d" PASS
    if [ "$bad" -eq 0 ]; then echo "claims-lint --self-test: PASS"; else echo "claims-lint --self-test: FAIL"; return 1; fi
}

case "${1:-}" in
    --self-test) self_test; exit $? ;;
    "") sweep "$(cd "$(dirname "$0")/.." && pwd)" || exit 1 ;;
    *) echo "usage: $0 [--self-test]" >&2; exit 64 ;;
esac
