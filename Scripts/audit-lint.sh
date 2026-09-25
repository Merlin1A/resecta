#!/usr/bin/env bash
# audit-lint.sh — pre-commit gate (mechanical checks M-1..M-6; see
# CONTRIBUTING "Audit checklist"), plus the script-local checks AL-1..AL-6
# (XcodeGen sync · resources: no-op warn · sample-statement and loan-packet
# dual-copy byte identity · silent test guards on added lines · planning
# shorthand on added lines) — numbering note at the AL-1 section below.
# Symlinked into .git/hooks/pre-commit by install-hooks.sh.
#
# Scope: staged Added/Modified files (`git diff --cached --diff-filter=AM`).
# Line-based checks (M-1, M-3, M-5) scan only the diff hunks added by this
# commit; pre-existing in-file content is not re-checked. M-4 walks each
# staged Swift file as a state machine. M-6 is a whole-file LOC count on
# staged files.
#
# Range mode (CI): `--range A..B` (or the env AUDIT_LINT_RANGE=A..B) swaps
# the staged diff for the commit range A..B — the same rules over the lines
# the range adds, with the file list, the added-line scan and the new-file
# list all read from `git diff A..B`. AL-1 (pbxproj freshness) is skipped in
# range mode: the pbxproj is gitignored and CI regenerates it first.
#
# Usage: Scripts/audit-lint.sh                 (staged mode; the pre-commit hook)
#        Scripts/audit-lint.sh --range A..B    (range mode; the pull-request gate)
#        Scripts/audit-lint.sh --self-test     (the M-1 keyword rule and the AL-6
#                                               shorthand rule against synthetic
#                                               lines; exit 1 on drift)
#
# Override markers (substring on the same line):
#   LegalPhrases:safe          → exempts a forbidden-phrase hit (M-1)
#   Networking:exempt SafariView → exempts a banned-symbol hit (M-3)
#   Shorthand:ok <reason>      → exempts a planning-shorthand hit (AL-6)
#
# M-1 in a .swift file skips a match that is Swift syntax rather than prose:
# `catch` / `do` at statement position (or a `catch` clause after code on the
# same line) and a `find(` / `finds(` call. Matches inside a `//` comment or
# anywhere else on the line still need the marker.
#
# Exit 0 on clean; exit 1 on any offence (per-line report on stderr).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

RANGE="${AUDIT_LINT_RANGE:-}"
SELF_TEST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --range)
            [ $# -ge 2 ] || { echo "audit-lint: --range needs A..B" >&2; exit 64; }
            RANGE="$2"; shift 2 ;;
        --range=*) RANGE="${1#--range=}"; shift ;;
        --self-test) SELF_TEST=1; shift ;;
        -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
        *) echo "audit-lint: unknown option: $1" >&2; exit 64 ;;
    esac
done
if [ -n "$RANGE" ]; then
    case "$RANGE" in *..*) ;; *) echo "audit-lint: --range wants A..B, got '$RANGE'" >&2; exit 64 ;; esac
    RANGE_BASE="${RANGE%%..*}"
    git rev-parse --verify --quiet "${RANGE_BASE}^{commit}" >/dev/null \
        || { echo "audit-lint: range base '$RANGE_BASE' is not a commit" >&2; exit 64; }
fi

# The three git sources of truth, staged (hook) or ranged (CI).
diff_names() { # diff-filter
    if [ -n "$RANGE" ]; then git diff --name-only --diff-filter="$1" "$RANGE"
    else git diff --cached --name-only --diff-filter="$1"; fi
}
diff_added_hunks() { # path
    if [ -n "$RANGE" ]; then git diff -U0 --no-color "$RANGE" -- "$1"
    else git diff --cached -U0 --no-color -- "$1"; fi
}
# The pre-change and post-change copies of a file (AL-2).
show_before() { # path
    if [ -n "$RANGE" ]; then git show "${RANGE_BASE}:$1" 2>/dev/null
    else git show "HEAD:$1" 2>/dev/null; fi
}
show_after() { # path
    if [ -n "$RANGE" ]; then git show "${RANGE##*..}:$1" 2>/dev/null
    else git show ":$1"; fi
}

STAGED=()
if [ -z "$SELF_TEST" ]; then
    while IFS= read -r path; do
        [ -n "$path" ] && STAGED+=("$path")
    done < <(diff_names AM)
    [ "${#STAGED[@]}" -eq 0 ] && exit 0
fi

FAIL=0
violate() { printf '%s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# The line scanner (perl; env-configured). Reads a unified diff and walks
# its added (+) lines, or with PLAIN=1 reads plain lines (the self-test).
# PATTERN = the regex, case-insensitive unless CASE_SENSITIVE=1; OVERRIDE = the same-line marker
# that exempts a line (empty disables); KEYWORD_EXEMPT=1 = the M-1 Swift
# rule: a match is skipped when it sits in the code part of the line
# (before any `//`) and is `catch` / `do` at statement position (only
# whitespace and an optional `}` before it; `do` also needs `{` or the
# line end after it), a `catch` clause after code on the same line
# (`… } catch {`, `… } catch let e as E {`, `… } catch is E {`), or a
# `find(` / `finds(` call. Every other match on the line still counts, so a
# `} catch { // ensures …` line is reported for its comment. Prints
# "<line>: <body>" per offending line.
SCAN_PERL='
    my $line  = 0;
    my $re    = $ENV{CASE_SENSITIVE} ? qr/$ENV{PATTERN}/ : qr/$ENV{PATTERN}/i;
    my $ovr   = $ENV{OVERRIDE} // "";
    my $plain = $ENV{PLAIN} // "";
    my $kw    = $ENV{KEYWORD_EXEMPT} // "";
    sub offends {
        my ($body) = @_;
        return 0 if $ovr && index($body, $ovr) >= 0;
        return ($body =~ $re) ? 1 : 0 unless $kw;
        my $code_end = index($body, "//");
        $code_end = length($body) if $code_end < 0;
        while ($body =~ /$re/g) {
            my ($word, $start, $end) = ($&, $-[0], $+[0]);
            my $exempt = 0;
            if ($start < $code_end) {
                my $before = substr($body, 0, $start);
                my $after  = substr($body, $end);
                if ($word eq "catch") {
                    $exempt = 1 if $before =~ /^\s*\}?\s*$/;
                    $exempt = 1 if $after =~ /^\s+(let|var|is)\b/ || $after =~ /^\s*\{/;
                } elsif ($word eq "do") {
                    $exempt = 1 if $before =~ /^\s*\}?\s*$/ && $after =~ /^\s*(\{|$)/;
                } elsif ($word eq "find" || $word eq "finds") {
                    $exempt = 1 if $after =~ /^\(/;
                }
            }
            return 1 unless $exempt;
        }
        return 0;
    }
    while (<>) {
        chomp;
        if ($plain) {
            print "$.: $_\n" if offends($_);
            next;
        }
        next if /^\+\+\+/ || /^---/;
        if (/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/) { $line = $1; next; }
        if (/^\+(.*)$/) {
            print "$line: $1\n" if offends($1);
            $line++;
        }
    }
'

# Walk added (+) lines from $1's staged diff. Match perl regex $2,
# skip lines containing override marker $3 (empty disables override);
# $4 = 1 applies the Swift keyword rule (M-1 on .swift files). The regex
# is case-insensitive unless the caller sets CASE_SENSITIVE=1 (AL-6).
scan_added() {
    local path="$1" pattern="$2" override="$3" keyword="${4:-}"
    diff_added_hunks "$path" \
        | PATTERN="$pattern" OVERRIDE="$override" KEYWORD_EXEMPT="$keyword" CASE_SENSITIVE="${CASE_SENSITIVE:-}" perl -e "$SCAN_PERL"
}

# ── M-1 forbidden phrases (.swift / .xcstrings / .md) ───────────────────
# On .swift files the scanner's Swift keyword rule applies (SCAN_PERL
# above): `} catch {`, `do {` and `.find(` are syntax, not claims, and pass
# without a marker; the same words in a comment, a string or a doc line
# are still reported and still take `LegalPhrases:safe`.
M1_RE='\b(guarantee[ds]?|ensure[ds]?|impossible|find(?:s|ing)?|catch(?:es|ing)?|perfectly|flawlessly)\b|100%'
# AL-6's pattern (used by the self-test below and the AL-6 section at the end):
# the register-identifier shape of the private planning notes — a short
# upper-case prefix, a hyphen, digits. Case-sensitive on purpose: `p3-1` is
# arithmetic, `P3-1` is a citation. The hyphen is required: without it a
# prefix running straight into digits (a licence number such as `S4482911`)
# would read as a citation.
AL6_RE='\b(D12|C12|F12|M12|Q12|RB12|SR12|SR|AL|PB|UXC|DC|R111|S4|P3)-[0-9]+\b'

# --self-test: the keyword rule against five synthetic Swift lines. The
# two comment lines (3 and 5) must be the only hits; anything else means
# the rule drifted. Exit 0/1, no git access.
if [ -n "$SELF_TEST" ]; then
    expected=$'3\n5'
    actual=$(printf '%s\n' \
        '        } catch {' \
        '        do {' \
        '        // we catch every error' \
        '        let x = a.find(1)' \
        '        /// finds every match' \
        | PATTERN="$M1_RE" OVERRIDE="LegalPhrases:safe" KEYWORD_EXEMPT=1 PLAIN=1 perl -e "$SCAN_PERL" \
        | cut -d: -f1)
    if [ "$actual" = "$expected" ]; then
        echo "audit-lint --self-test: M-1 keyword rule OK (hits on lines 3 and 5 of 5; the two comment lines)"
    else
        echo "audit-lint --self-test: M-1 keyword rule DRIFTED — expected hits on lines 3 and 5, got: $(printf '%s' "$actual" | tr '\n' ' ')" >&2
        exit 1
    fi
    # AL-6 against six synthetic lines: a comment citing a register id (1)
    # and a string citing one (4) are the only hits; an arithmetic `p3-1`
    # (2), a marked line (3), a lower-case token (5) and a licence-number
    # literal with no hyphen (6) pass.
    expected=$'1\n4'
    actual=$(printf '%s\n' \
        '        // D12-155 fence: the OCR body stays one' \
        '        let y = p3-1' \
        '        // Shorthand:ok C12-118 cited on purpose' \
        '        let note = "see C12-118 for the split"' \
        '        // the al-6 rule is case-sensitive' \
        '        let id = "DL S4482911"' \
        | PATTERN="$AL6_RE" OVERRIDE="Shorthand:ok" CASE_SENSITIVE=1 PLAIN=1 perl -e "$SCAN_PERL" \
        | cut -d: -f1)
    if [ "$actual" = "$expected" ]; then
        echo "audit-lint --self-test: AL-6 shorthand rule OK (hits on lines 1 and 4 of 6; the comment and the string)"
        exit 0
    fi
    echo "audit-lint --self-test: AL-6 shorthand rule DRIFTED — expected hits on lines 1 and 4, got: $(printf '%s' "$actual" | tr '\n' ' ')" >&2
    exit 1
fi

for path in "${STAGED[@]}"; do
    case "$path" in *.swift|*.xcstrings|*.md) ;; *) continue ;; esac
    keyword=""
    case "$path" in *.swift) keyword=1 ;; esac
    while IFS= read -r off; do
        [ -n "$off" ] && violate "M-1 forbidden phrase: $path:$off"
    done < <(scan_added "$path" "$M1_RE" "LegalPhrases:safe" "$keyword")
done

# ── M-3 banned networking symbols (Sources/ + Packages/RedactionEngine/) ─
M3_RE='\b(URLSession|URLRequest|NWConnection|NWPathMonitor|WKWebView)\b'
for path in "${STAGED[@]}"; do
    case "$path" in *.swift) ;; *) continue ;; esac
    case "$path" in Sources/*|Packages/RedactionEngine/*) ;; *) continue ;; esac
    while IFS= read -r off; do
        [ -n "$off" ] && violate "M-3 banned networking symbol: $path:$off"
    done < <(scan_added "$path" "$M3_RE" "Networking:exempt SafariView")
done

# ── M-4 @AppStorage inside @Observable (whole-file state machine) ──────
# Walks each staged .swift file. Tracks @Observable class bodies via brace
# depth; flags any @AppStorage declaration inside one. Note: synthesized
# attributes on App/View structs are fine — only @Observable class bodies
# are banned (that is the M-4 rule).
for path in "${STAGED[@]}"; do
    case "$path" in *.swift) ;; *) continue ;; esac
    [ -f "$path" ] || continue
    while IFS= read -r off; do
        [ -n "$off" ] && violate "M-4 @AppStorage inside @Observable class: $path:$off"
    done < <(perl -e '
        my $waiting = 0; my $in_obs = 0; my $depth = 0;
        while (<>) {
            chomp;
            my $body = $_;
            if ($body =~ /^\s*\@Observable\b/) { $waiting = 1; next; }
            if ($waiting) {
                if ($body =~ /\bclass\b/) {
                    $waiting = 0; $in_obs = 1;
                    my $o = ($body =~ tr/{//);
                    my $c = ($body =~ tr/}//);
                    $depth = $o - $c;
                    if ($body =~ /\@AppStorage\b/) { print "$.: $body\n"; }
                    $in_obs = 0 if $depth <= 0;
                    next;
                }
                if ($body =~ /\S/ && $body !~ /^\s*\/\//) { $waiting = 0; }
            }
            if ($in_obs) {
                if ($body =~ /\@AppStorage\b/) { print "$.: $body\n"; }
                my $o = ($body =~ tr/{//);
                my $c = ($body =~ tr/}//);
                $depth += $o - $c;
                $in_obs = 0 if $depth <= 0;
            }
        }
    ' "$path")
done

# ── M-5 banned APIs (Sources/ + Packages/) ─────────────────────────────
M5_RE='\b(PKCanvasView)\b|\bPDFPage\.draw\b'
for path in "${STAGED[@]}"; do
    case "$path" in *.swift) ;; *) continue ;; esac
    case "$path" in Sources/*|Packages/*) ;; *) continue ;; esac
    while IFS= read -r off; do
        [ -n "$off" ] && violate "M-5 banned API: $path:$off"
    done < <(scan_added "$path" "$M5_RE" "")
done

# ── M-6 LOC ceilings ────────────────────────────────────────────────────
# 1500 strict cap on the search-sheet hub; 700 cap on newly-added .swift
# files anywhere. Modified non-hub files are warnings-only (per stale-file
# policy) and not enforced.
HUB="Sources/ResectaApp/Views/SearchAndRedactSheet.swift"
HUB_CAP=1500
NEW_CAP=700

ADDED=()
while IFS= read -r path; do
    [ -n "$path" ] && ADDED+=("$path")
done < <(diff_names A)

for path in "${STAGED[@]}"; do
    [ "$path" = "$HUB" ] || continue
    [ -f "$path" ] || continue
    loc=$(wc -l < "$path" | tr -d ' ')
    [ "$loc" -gt "$HUB_CAP" ] && violate "M-6 hub LOC cap exceeded: $path is $loc LOC (cap $HUB_CAP)"
done

# ${ADDED[@]+...}: expanding an empty array under `set -u` is fatal on
# bash 3.2 (the runner's /bin/bash); the parameter-expansion guard makes
# the loop a no-op instead when no files were added.
for path in ${ADDED[@]+"${ADDED[@]}"}; do
    case "$path" in *.swift) ;; *) continue ;; esac
    [ -f "$path" ] || continue
    loc=$(wc -l < "$path" | tr -d ' ')
    [ "$loc" -gt "$NEW_CAP" ] && violate "M-6 new-file LOC cap exceeded: $path is $loc LOC (cap $NEW_CAP)"
done

# ── AL-1 XcodeGen sync ─────────────────────────────────
# project.pbxproj is GENERATED from project.yml; landing a project.yml
# change without a regenerate means every local build/test ran against a
# stale project. AL-* are this script's own checks; M-* belong to
# CONTRIBUTING "Audit checklist" (M-1..M-6 are the mechanical rules this
# script enforces above; its manual session-discipline checks live only
# on that page and are never referenced here).
PBXPROJ="ResectaApp.xcodeproj/project.pbxproj"
for path in "${STAGED[@]}"; do
    [ "$path" = "project.yml" ] || continue
    if [ -n "$RANGE" ]; then
        echo "AL-1 skipped in range mode: the pbxproj is gitignored and regenerated from project.yml before the lint runs"
        break
    fi
    if git ls-files --error-unmatch "$PBXPROJ" >/dev/null 2>&1; then
        # Tracked pbxproj: the regenerated file must land in the same commit.
        pbx_staged=0
        for staged_path in "${STAGED[@]}"; do
            [ "$staged_path" = "$PBXPROJ" ] && pbx_staged=1
        done
        [ "$pbx_staged" -eq 1 ] \
            || violate "AL-1 project.yml staged but $PBXPROJ not staged — run ./regenerate.sh and stage it"
    else
        # Gitignored-generated pbxproj (current policy): demand a
        # regenerate after the last project.yml edit. mtime tripwire —
        # xcodegen always writes the pbxproj after reading project.yml.
        if [ ! -f "$PBXPROJ" ] || [ "$PBXPROJ" -ot "project.yml" ]; then
            violate "AL-1 project.yml staged but $PBXPROJ is missing or older than project.yml — run ./regenerate.sh"
        fi
    fi
done

# ── AL-2 app-target resources: block is a silent no-op (warn-only) ─────
# The ResectaApp target's resources: block
# silently enumerates nothing; a new `- path:` entry there never reaches
# the bundle. Route shipped resources through sources: instead (the
# SampleDocument.pdf precedent; BundleContentsTests guards the critical
# set). Warning only — does not block the commit.
warn() { printf '%s\n' "$1" >&2; }

list_app_target_resources() {
    perl -e '
        my $intargets = 0; my $target = ""; my $inres = 0;
        while (<>) {
            chomp;
            if (/^targets:\s*$/) { $intargets = 1; next; }
            if ($intargets && /^\S/) { $intargets = 0; }
            if ($intargets && /^  ([A-Za-z0-9_-]+):\s*$/) { $target = $1; $inres = 0; next; }
            if ($intargets && $target eq "ResectaApp" && /^    resources:\s*$/) { $inres = 1; next; }
            if ($inres) {
                if (/^      - path:\s*(\S+)/) { print "$1\n"; next; }
                if (/^ {0,4}\S/) { $inres = 0; }
            }
        }
    '
}

resource_entry_known() {
    local entry="$1" known="$2" line
    while IFS= read -r line; do
        [ "$line" = "$entry" ] && return 0
    done <<< "$known"
    return 1
}

for path in "${STAGED[@]}"; do
    [ "$path" = "project.yml" ] || continue
    head_resources=$(show_before project.yml | list_app_target_resources || true)
    staged_resources=$(show_after project.yml | list_app_target_resources || true)
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        resource_entry_known "$entry" "$head_resources" \
            || warn "AL-2 warning: '$entry' added to the ResectaApp resources: block — that block silently fails to enumerate; route it through sources: (see project.yml comment / BundleContentsTests)"
    done <<< "$staged_resources"
done

# ── AL-3 sample-statement dual-copy byte identity ─
# The shipped first-run statement lives in TWO repo locations that must stay
# byte-identical (three names, ONE SHA): the app-bundle copy and the engine
# test fixture. The SHA is pinned on both sides (BundleContentsTests app-side,
# SampleStatementSnapshotTests engine-side, both against
# 992ca054…ce18fa20); this is the commit-time cmp backstop. Triggers whenever
# either copy is staged.
SAMPLE_APP="Resources/SampleDocument.pdf"
SAMPLE_ENGINE="Packages/RedactionEngine/Tests/RedactionEngineTests/Fixtures/TestResources/sample-bank-statement.pdf"
sample_touched=0
for path in "${STAGED[@]}"; do
    case "$path" in "$SAMPLE_APP"|"$SAMPLE_ENGINE") sample_touched=1 ;; esac
done
if [ "$sample_touched" -eq 1 ]; then
    if [ ! -f "$SAMPLE_APP" ] || [ ! -f "$SAMPLE_ENGINE" ]; then
        violate "AL-3 sample-statement dual-copy: a copy is missing ($SAMPLE_APP / $SAMPLE_ENGINE) — both must exist and match"
    elif ! cmp -s "$SAMPLE_APP" "$SAMPLE_ENGINE"; then
        violate "AL-3 sample-statement dual-copy DIFFERS: $SAMPLE_APP vs $SAMPLE_ENGINE — the statement is FROZEN (three names, one SHA); re-sync the copies"
    fi
fi

# ── AL-4 loan-packet dual-copy byte identity (sample-packet series) ──────
# The Hartwell loan packet (the SECOND in-app sample) lives in TWO repo
# locations that must stay byte-identical (one SHA): the app-bundle copy and
# the engine test fixture. The SHA is pinned on both sides (BundleContentsTests
# app-side, TestFixtures.loanPacketSHA256 engine-side, both against
# 362375…f54339a); this is the commit-time cmp backstop. Triggers whenever
# either copy is staged.
PACKET_APP="Resources/packet.pdf"
PACKET_ENGINE="Packages/RedactionEngine/Tests/RedactionEngineTests/Fixtures/TestResources/packet.pdf"
packet_touched=0
for path in "${STAGED[@]}"; do
    case "$path" in "$PACKET_APP"|"$PACKET_ENGINE") packet_touched=1 ;; esac
done
if [ "$packet_touched" -eq 1 ]; then
    if [ ! -f "$PACKET_APP" ] || [ ! -f "$PACKET_ENGINE" ]; then
        violate "AL-4 loan-packet dual-copy: a copy is missing ($PACKET_APP / $PACKET_ENGINE) — both must exist and match"
    elif ! cmp -s "$PACKET_APP" "$PACKET_ENGINE"; then
        violate "AL-4 loan-packet dual-copy DIFFERS: $PACKET_APP vs $PACKET_ENGINE — the packet is byte-deterministic (one SHA); re-sync the copies (the generator is the source of truth)"
    fi
fi

# ── AL-5 silent test guard (added lines of test files) ──────────────────
# A test that returns before its first assertion reports PASS with zero
# assertions. `Scripts/lint-silent-guards.py` walks every test body in a
# file (comments and strings blanked; closures, nested funcs and computed
# properties skipped) and names each guard whose early return precedes the
# first assertion-like token. This check keeps the offences whose guard
# line this change ADDED, so a pre-existing guard elsewhere in the file is
# not re-reported. The two accepted shapes: `try #require(...)` for a
# resource the repository tracks; `TestGate.skip(...)` before the `return`
# for an environmental gate. Same-line marker: `SilentGuard:ok <reason>`.
AL5_SCANNER="$REPO_ROOT/Scripts/lint-silent-guards.py"
if [ -f "$AL5_SCANNER" ] && command -v python3 >/dev/null 2>&1; then
    for path in "${STAGED[@]}"; do
        case "$path" in *Tests/*.swift) ;; *) continue ;; esac
        [ -f "$path" ] || continue
        added="$(diff_added_hunks "$path" | perl -ne 'if (/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/) { my ($s, $n) = ($1, defined $2 ? $2 : 1); print "$_\n" for ($s .. $s + $n - 1); }')"
        [ -n "$added" ] || continue
        while IFS= read -r off; do
            [ -n "$off" ] || continue
            line="${off#"$path":}"; line="${line%%:*}"
            if printf '%s\n' "$added" | /usr/bin/grep -qx "$line"; then
                violate "AL-5 silent test guard: $off"
            fi
        done < <(python3 "$AL5_SCANNER" --lint "$path" 2>/dev/null || true)
    done
else
    warn "AL-5 skipped: $AL5_SCANNER or python3 not found"
fi

# ── AL-6 planning shorthand on added lines ──────────────────────────────
# Shipped source, tests and string tables describe mechanisms; they never
# cite the private planning registers that scheduled the work, and a
# reader of the repository has no way to resolve such a citation. This
# check reports, on each added line of a .swift or .xcstrings file, a token
# in the register-identifier shape (AL6_RE, defined with M-1 above) as an
# offence: the pre-commit hook blocks the commit and the pull-request gate
# fails. Same-line marker: `Shorthand:ok <reason>`. The mechanical twin
# of the datapipeline's hygiene gate (scripts/hygiene_gate.py there scans
# the whole tree; this one scans the lines a change adds).
for path in "${STAGED[@]}"; do
    case "$path" in *.swift|*.xcstrings) ;; *) continue ;; esac
    while IFS= read -r off; do
        [ -n "$off" ] && violate "AL-6 planning shorthand: $path:$off"
    done < <(CASE_SENSITIVE=1 scan_added "$path" "$AL6_RE" "Shorthand:ok")
done

# ── Summary ─────────────────────────────────────────────────────────────
if [ "$FAIL" -gt 0 ]; then
    printf '\naudit-lint: %d offence(s); commit blocked.\n' "$FAIL" >&2
    printf 'Reference: CONTRIBUTING.md "Audit checklist" (M-1..M-6 mechanical) and this script'"'"'s AL-1..AL-6\n' >&2
    exit 1
fi
exit 0
