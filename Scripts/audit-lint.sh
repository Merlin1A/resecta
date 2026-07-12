#!/usr/bin/env bash
# audit-lint.sh — pre-commit gate (mechanical checks M-1..M-6; see
# CONTRIBUTING "Audit checklist"), plus script-local M-7 (XcodeGen sync),
# M-8 (resources: no-op warn), and M-9 (sample-statement dual-copy byte
# identity) — numbering note at the M-7 section below.
# Symlinked into .git/hooks/pre-commit by install-hooks.sh.
#
# Scope: staged Added/Modified files (`git diff --cached --diff-filter=AM`).
# Line-based checks (M-1, M-3, M-5) scan only the diff hunks added by this
# commit; pre-existing in-file content is not re-checked. M-4 walks each
# staged Swift file as a state machine. M-6 is a whole-file LOC count on
# staged files.
#
# Override markers (substring on the same line):
#   LegalPhrases:safe          → exempts a forbidden-phrase hit (M-1)
#   Networking:exempt SafariView → exempts a banned-symbol hit (M-3)
#
# Exit 0 on clean; exit 1 on any offence (per-line report on stderr).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

STAGED=()
while IFS= read -r path; do
    [ -n "$path" ] && STAGED+=("$path")
done < <(git diff --cached --name-only --diff-filter=AM)

[ "${#STAGED[@]}" -eq 0 ] && exit 0

FAIL=0
violate() { printf '%s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# Walk added (+) lines from $1's staged diff. Match perl regex $2,
# skip lines containing override marker $3 (empty disables override).
scan_added() {
    local path="$1" pattern="$2" override="$3"
    git diff --cached -U0 --no-color -- "$path" \
        | PATTERN="$pattern" OVERRIDE="$override" perl -e '
        my $line = 0;
        my $re   = qr/$ENV{PATTERN}/i;
        my $ovr  = $ENV{OVERRIDE} // "";
        while (<>) {
            next if /^\+\+\+/ || /^---/;
            if (/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/) { $line = $1; next; }
            if (/^\+(.*)$/) {
                my $body = $1;
                if ((!$ovr || index($body, $ovr) < 0) && $body =~ $re) {
                    print "$line: $body\n";
                }
                $line++;
            }
        }
    '
}

# ── M-1 forbidden phrases (.swift / .xcstrings / .md) ───────────────────
M1_RE='\b(guarantee[ds]?|ensure[ds]?|impossible|find(?:s|ing)?|catch(?:es|ing)?|perfectly|flawlessly)\b|100%'
for path in "${STAGED[@]}"; do
    case "$path" in *.swift|*.xcstrings|*.md) ;; *) continue ;; esac
    while IFS= read -r off; do
        [ -n "$off" ] && violate "M-1 forbidden phrase: $path:$off"
    done < <(scan_added "$path" "$M1_RE" "LegalPhrases:safe")
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
# are banned per CLAUDE.md "Hard Rules".
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
done < <(git diff --cached --name-only --diff-filter=A)

for path in "${STAGED[@]}"; do
    [ "$path" = "$HUB" ] || continue
    [ -f "$path" ] || continue
    loc=$(wc -l < "$path" | tr -d ' ')
    [ "$loc" -gt "$HUB_CAP" ] && violate "M-6 hub LOC cap exceeded: $path is $loc LOC (cap $HUB_CAP)"
done

for path in "${ADDED[@]}"; do
    case "$path" in *.swift) ;; *) continue ;; esac
    [ -f "$path" ] || continue
    loc=$(wc -l < "$path" | tr -d ' ')
    [ "$loc" -gt "$NEW_CAP" ] && violate "M-6 new-file LOC cap exceeded: $path is $loc LOC (cap $NEW_CAP)"
done

# ── M-7 XcodeGen sync (CAT-033) ────────────────────────
# project.pbxproj is GENERATED from project.yml; landing a project.yml
# change without a regenerate means every local build/test ran against a
# stale project (CAT-034 landmine). Script ids M-7/M-8 below are
# audit-lint check ids continuing M-1..M-6 above; M-9+ are reserved for
# the merge-gate cluster. The manual session-discipline checks in
# CONTRIBUTING "Audit checklist" are a separate pre-existing namespace.
PBXPROJ="ResectaApp.xcodeproj/project.pbxproj"
for path in "${STAGED[@]}"; do
    [ "$path" = "project.yml" ] || continue
    if git ls-files --error-unmatch "$PBXPROJ" >/dev/null 2>&1; then
        # Tracked pbxproj: the regenerated file must land in the same commit.
        pbx_staged=0
        for staged_path in "${STAGED[@]}"; do
            [ "$staged_path" = "$PBXPROJ" ] && pbx_staged=1
        done
        [ "$pbx_staged" -eq 1 ] \
            || violate "M-7 project.yml staged but $PBXPROJ not staged — run ./regenerate.sh and stage it"
    else
        # Gitignored-generated pbxproj (current policy, CAT-034): demand a
        # regenerate after the last project.yml edit. mtime tripwire —
        # xcodegen always writes the pbxproj after reading project.yml.
        if [ ! -f "$PBXPROJ" ] || [ "$PBXPROJ" -ot "project.yml" ]; then
            violate "M-7 project.yml staged but $PBXPROJ is missing or older than project.yml — run ./regenerate.sh"
        fi
    fi
done

# ── M-8 app-target resources: block is a silent no-op (warn-only) ──────
# CAT-221. The ResectaApp target's resources: block
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
    head_resources=$(git show HEAD:project.yml 2>/dev/null | list_app_target_resources || true)
    staged_resources=$(git show :project.yml | list_app_target_resources || true)
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        resource_entry_known "$entry" "$head_resources" \
            || warn "M-8 warning: '$entry' added to the ResectaApp resources: block — that block silently fails to enumerate; route it through sources: (see project.yml comment / BundleContentsTests)"
    done <<< "$staged_resources"
done

# ── M-9 sample-statement dual-copy byte identity ─
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
        violate "M-9 sample-statement dual-copy: a copy is missing ($SAMPLE_APP / $SAMPLE_ENGINE) — both must exist and match"
    elif ! cmp -s "$SAMPLE_APP" "$SAMPLE_ENGINE"; then
        violate "M-9 sample-statement dual-copy DIFFERS: $SAMPLE_APP vs $SAMPLE_ENGINE — the statement is FROZEN (three names, one SHA); re-sync the copies"
    fi
fi

# ── M-10 loan-packet dual-copy byte identity (S06, sample-packet series) ─
# The Hartwell loan packet (the SECOND in-app sample, D2) lives in TWO repo
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
        violate "M-10 loan-packet dual-copy: a copy is missing ($PACKET_APP / $PACKET_ENGINE) — both must exist and match"
    elif ! cmp -s "$PACKET_APP" "$PACKET_ENGINE"; then
        violate "M-10 loan-packet dual-copy DIFFERS: $PACKET_APP vs $PACKET_ENGINE — the packet is byte-deterministic (one SHA); re-sync the copies (the generator is the source of truth)"
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────────
if [ "$FAIL" -gt 0 ]; then
    printf '\naudit-lint: %d offence(s); commit blocked.\n' "$FAIL" >&2
    printf 'Reference: CONTRIBUTING.md "Audit checklist" (M-1..M-13)\n' >&2
    exit 1
fi
exit 0
