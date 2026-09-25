#!/usr/bin/env bash
# growth-ratchet.sh — a source file that is over 800 lines at the base of a
# change may not be larger at its head. Every *.swift under Sources/ and
# Packages/RedactionEngine/Sources/ whose line count at BASE exceeds 800 is
# tracked; the check fails when the count at HEAD is larger. A file the change
# splits along a real seam shrinks and passes; a file gone at HEAD passes; a
# file that is new at HEAD is not tracked here (M-6 caps new files).
#
# Usage: Scripts/growth-ratchet.sh BASE HEAD     (two commits; the pull-request gate)
#        Scripts/growth-ratchet.sh --self-test   (a scratch repository: grown → offence,
#                                                 shrunk → clean, new file → ignored)
#
# RATCHET_ENFORCE=0 (the default) reports every tracked file and exits 0 even
# on growth; RATCHET_ENFORCE=1 exits 1 on any growth. On GitHub Actions each
# grown file is a ::warning:: (report-only) or ::error:: (enforcing) annotation
# and the table is appended to the step summary.
#
# Line counts are `awk 'END{print NR}'` over `git show REV:path`, so a last
# line without a trailing newline counts, as it does for the rating script.
# No grep/find: pure bash + awk + git.
set -euo pipefail

THRESHOLD=800
TREES="Sources Packages/RedactionEngine/Sources"
ENFORCE="${RATCHET_ENFORCE:-0}"

count_at() { # rev path → line count (0 when the path is absent at rev)
    git cat-file -e "$1:$2" 2>/dev/null || { echo 0; return; }
    git show "$1:$2" | awk 'END{print NR}'
}

ratchet() { # base head → 0 clean / 1 growth (exit code shaped by ENFORCE by the caller)
    local base="$1" head="$2" grown=0 tracked=0 rows=""
    local path b h delta mark
    while IFS= read -r path; do
        case "$path" in *.swift) ;; *) continue ;; esac
        b="$(count_at "$base" "$path")"
        [ "$b" -gt "$THRESHOLD" ] || continue
        tracked=$((tracked + 1))
        h="$(count_at "$head" "$path")"
        delta=$((h - b))
        if [ "$h" -eq 0 ]; then mark="gone"
        elif [ "$delta" -gt 0 ]; then mark="GREW"; grown=$((grown + 1))
        elif [ "$delta" -lt 0 ]; then mark="shrank"
        else mark="same"; fi
        printf '%-8s %5d -> %5d (%+d)  %s\n' "$mark" "$b" "$h" "$delta" "$path"
        rows="${rows}| \`${path}\` | ${b} | ${h} | ${delta} | ${mark} |"$'\n'
        if [ "$mark" = GREW ] && [ -n "${GITHUB_ACTIONS:-}" ]; then
            if [ "$ENFORCE" = 1 ]; then echo "::error file=${path}::growth ratchet: ${b} -> ${h} lines (+${delta}); files over ${THRESHOLD} lines may not grow"
            else echo "::warning file=${path}::growth ratchet (report-only): ${b} -> ${h} lines (+${delta}); files over ${THRESHOLD} lines may not grow"; fi
        fi
    done < <(git ls-tree -r --name-only "$base" -- $TREES)
    echo "growth-ratchet: ${tracked} file(s) over ${THRESHOLD} lines at ${base:0:8}; ${grown} grew at ${head:0:8}; $([ "$ENFORCE" = 1 ] && echo enforcing || echo report-only)"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
            echo "## growth ratchet ($([ "$ENFORCE" = 1 ] && echo enforcing || echo report-only))"
            echo
            echo "| file | base | head | delta | |"
            echo "|---|---|---|---|---|"
            printf '%s' "$rows"
            echo
            echo "${tracked} tracked · ${grown} grew"
        } >> "$GITHUB_STEP_SUMMARY"
    fi
    [ "$grown" -eq 0 ]
}

self_test() {
    local tmp; tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    local self; self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    (
        cd "$tmp" && git init -q && git config user.email t@t && git config user.name t
        mkdir -p Sources
        awk 'BEGIN{for(i=1;i<=801;i++) print "let v" i " = " i}' > Sources/Big.swift
        git add . && git commit -qm base && base="$(git rev-parse HEAD)"
        echo "let extra = 0" >> Sources/Big.swift && git commit -qam grow && grow="$(git rev-parse HEAD)"
        awk 'BEGIN{for(i=1;i<=790;i++) print "let v" i " = " i}' > Sources/Big.swift
        awk 'BEGIN{for(i=1;i<=900;i++) print "let n" i " = " i}' > Sources/New.swift
        git add . && git commit -qam shrink && shrink="$(git rev-parse HEAD)"
        fail=0
        RATCHET_ENFORCE=1 "$self" "$base" "$grow" >/dev/null && { echo "self-test: a grown file was NOT an offence" >&2; fail=1; }
        RATCHET_ENFORCE=0 "$self" "$base" "$grow" >/dev/null || { echo "self-test: report-only exited non-zero on growth" >&2; fail=1; }
        RATCHET_ENFORCE=1 "$self" "$base" "$shrink" >/dev/null || { echo "self-test: a shrunk file was an offence" >&2; fail=1; }
        out="$(RATCHET_ENFORCE=1 "$self" "$grow" "$shrink")"
        case "$out" in *New.swift*) echo "self-test: a new file was tracked" >&2; fail=1 ;; esac
        case "$out" in *"1 file(s) over"*) ;; *) echo "self-test: expected one tracked file, got: $out" >&2; fail=1 ;; esac
        exit "$fail"
    ) && echo "growth-ratchet --self-test: grown → offence, shrunk → clean, new file → ignored: OK" \
      || { echo "growth-ratchet --self-test: DRIFTED" >&2; return 1; }
}

case "${1:-}" in
    --self-test) self_test ;;
    -h|--help|"") sed -n '2,22p' "$0"; [ -n "${1:-}" ] && exit 0 || exit 64 ;;
    *)
        [ $# -eq 2 ] || { echo "growth-ratchet: usage BASE HEAD" >&2; exit 64; }
        cd "$(git rev-parse --show-toplevel)"
        for r in "$1" "$2"; do git rev-parse --verify --quiet "${r}^{commit}" >/dev/null || { echo "growth-ratchet: '$r' is not a commit" >&2; exit 64; }; done
        if ratchet "$1" "$2"; then exit 0; else [ "$ENFORCE" = 1 ] && exit 1 || exit 0; fi ;;
esac
