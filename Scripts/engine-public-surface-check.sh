#!/usr/bin/env bash
# engine-public-surface-check.sh — the engine package's `public` / `open`
# declaration lines may not exceed a cap. Every *.swift under
# Packages/RedactionEngine/Sources at HEAD is read line by line; a line that
# begins, after optional attributes such as `@MainActor` or `@inlinable`,
# with `public ` or `open ` counts as one declaration line (a commented-out
# declaration does not). The check fails when the count at HEAD exceeds the
# cap this script carries (DECLARATION_CAP below); the count at BASE is
# printed beside it so a change can see what it added or removed. A removal
# lowers the count and leaves the cap where it is, so the headroom it frees
# stays visible to the next change; the cap moves only when a release
# restamps it. A pull request that adds to the count names the declarations
# in its description (CONTRIBUTING, "What every change passes").
#
# The script also prints the release line caps on the largest source files
# (FILE_CAPS below): each file's line count at HEAD and its headroom under
# its cap, `AT CAP` when two lines or fewer remain, `absent` when the file is
# gone. That table is informational; only the declaration count gates.
#
# Usage: Scripts/engine-public-surface-check.sh BASE HEAD [--cap N]
#        Scripts/engine-public-surface-check.sh --self-test
#        Scripts/engine-public-surface-check.sh --help
#
# Exit 0 when the HEAD count is at or under the cap; 1 when it is over;
# 64 on a usage error. On GitHub Actions an over-cap head is an ::error::
# annotation, and the count line and the table go to the step summary.
#
# Line counts split the file on newlines and drop a trailing empty piece.
# Pure bash + git + python3 (standard library only); no other input.
set -euo pipefail

DECLARATION_CAP=851

usage() { sed -n '2,28p' "$0"; }

check() { # base head cap → the report on stdout; exit 0 clean / 1 over the cap
    python3 - "$1" "$2" "$3" <<'PY'
import os
import re
import subprocess
import sys

base, head, cap = sys.argv[1], sys.argv[2], int(sys.argv[3])
ENGINE_SOURCES = "Packages/RedactionEngine/Sources"
DECL_RE = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public|open)\s")

# The release line caps on the largest files: the recorded count each file
# may not exceed, and three lower caps that tighten it.
FILE_CAPS = [
    ("Packages/RedactionEngine/Sources/RedactionEngine/Search/DocumentSearcher.swift", 2826),
    ("Packages/RedactionEngine/Sources/RedactionEngine/Verification/VerificationEngine.swift", 2554),
    ("Packages/RedactionEngine/Sources/RedactionEngine/Detection/PIIDetector.swift", 2028),
    ("Packages/RedactionEngine/Sources/RedactionEngine/Verification/SandwichVerification.swift", 1014),
    ("Packages/RedactionEngine/Sources/RedactionEngine/Detection/DetectionOrchestrator.swift", 997),
    ("Sources/ResectaApp/Views/DocumentEditorView.swift", 2952),
    ("Sources/ResectaApp/Overlay/RedactionOverlayView.swift", 2562),
    ("Sources/ResectaApp/State/PipelineCoordinator.swift", 2370),
    ("Sources/ResectaApp/State/RedactionState.swift", 2103),
    ("Sources/ResectaApp/State/SearchState.swift", 1499),
    ("Sources/ResectaApp/Views/SearchAndRedactSheet.swift", 1484),
    ("Sources/ResectaApp/Views/Search/SearchResultsSection.swift", 1283),
    ("Sources/ResectaApp/Views/VerificationResultsView.swift", 1193),
    ("Sources/ResectaApp/Views/Search/SearchToolbarSection.swift", 974),
    ("Sources/ResectaApp/Views/SearchResultRow.swift", 915),
]
TIGHTENED_CAPS = [
    ("Packages/RedactionEngine/Sources/RedactionEngine/Search/DocumentSearcher.swift", 2000),
    ("Sources/ResectaApp/State/PipelineCoordinator.swift", 1500),
    ("Packages/RedactionEngine/Sources/RedactionEngine/Verification/VerificationEngine.swift", 1600),
]


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True).stdout


def lines_at(rev, path):
    """The file's lines at rev, or None when the path is absent there."""
    probe = subprocess.run(["git", "cat-file", "-e", f"{rev}:{path}"], capture_output=True)
    if probe.returncode != 0:
        return None
    text = git("show", f"{rev}:{path}").decode("utf-8", errors="replace")
    parts = text.split("\n")
    if parts and parts[-1] == "":
        parts = parts[:-1]
    return parts


def declaration_count(rev):
    total = 0
    listing = git("ls-tree", "-r", "--name-only", rev, "--", ENGINE_SOURCES).decode()
    for path in listing.split("\n"):
        if not path.endswith(".swift"):
            continue
        for line in lines_at(rev, path) or []:
            if DECL_RE.search(line):
                total += 1
    return total


base_count = declaration_count(base)
head_count = declaration_count(head)
delta = head_count - base_count
headroom = cap - head_count
summary = (f"engine public surface: {head_count} of cap {cap}, headroom {headroom} "
           f"(base {base_count}, head {head_count}, {delta:+d})")
print(summary)

rows = []
tightened = dict(TIGHTENED_CAPS)
for path, file_cap in FILE_CAPS:
    lines = lines_at(head, path)
    name = path.rsplit("/", 1)[-1]
    if lines is None:
        rows.append((name, "absent", str(file_cap), "", ""))
        continue
    n = len(lines)
    room = file_cap - n
    mark = "AT CAP" if room <= 2 else ""
    rows.append((name, str(n), str(file_cap), str(room), mark))
    if path in tightened:
        t_cap = tightened[path]
        t_room = t_cap - n
        rows.append((name + " (tightened)", str(n), str(t_cap), str(t_room), "AT CAP" if t_room <= 2 else ""))

print("release line caps at head:")
print(f"  {'lines':>6}  {'cap':>5}  {'headroom':>8}  file")
for name, n, file_cap, room, mark in rows:
    print(f"  {n:>6}  {file_cap:>5}  {room:>8}  {name}{'  ' + mark if mark else ''}")

over = head_count > cap
if os.environ.get("GITHUB_ACTIONS"):
    if over:
        print(f"::error::engine public surface: {head_count} declaration lines is over the cap {cap} "
              f"by {head_count - cap}; name each added public or open declaration in the pull request "
              f"(ENGINE-PUBLIC +n) or remove it")
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a", encoding="utf-8") as fh:
            fh.write("## engine public surface\n\n")
            fh.write(summary + "\n\n")
            fh.write("| file | lines | cap | headroom | |\n|---|---|---|---|---|\n")
            for name, n, file_cap, room, mark in rows:
                fh.write(f"| `{name}` | {n} | {file_cap} | {room} | {mark} |\n")
            fh.write("\n")
sys.exit(1 if over else 0)
PY
}

self_test() {
    local tmp; tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    local self; self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    (
        cd "$tmp" && git init -q && git config user.email t@t && git config user.name t
        mkdir -p Packages/RedactionEngine/Sources/RedactionEngine
        f=Packages/RedactionEngine/Sources/RedactionEngine/A.swift
        printf '%s\n' 'public func a() {}' '@MainActor public final class B {}' \
            '// public func commented() {}' '/// a public note in a doc comment' \
            'internal func e() {}' 'func f() {}' > "$f"
        git add . && git commit -qm two && c1="$(git rev-parse HEAD)"
        printf '%s\n' 'open class C {}' >> "$f"
        git commit -qam three && c2="$(git rev-parse HEAD)"
        sed -i.bak 's/^public func a() {}$/public func a2() {}/' "$f" && rm -f "$f.bak"
        git commit -qam swap && c3="$(git rev-parse HEAD)"
        git checkout -q "$c2"
        printf '%s\n' 'public func d() {}' >> "$f"
        git commit -qam four && c4="$(git rev-parse HEAD)"
        fail=0
        count_of() { "$self" "$1" "$2" --cap "$3" | sed -n 's/^engine public surface: \([0-9]*\) of cap \([0-9]*\),.*/\1 \2/p'; }
        # a head one above the cap = offence
        "$self" "$c2" "$c4" --cap 3 >/dev/null && { echo "self-test: a head one above the cap was NOT an offence" >&2; fail=1; }
        # a head at the cap = clean
        "$self" "$c1" "$c2" --cap 3 >/dev/null || { echo "self-test: a head at the cap was an offence" >&2; fail=1; }
        # a head below the cap that is above its base = clean (the rule is the cap, not the base)
        "$self" "$c1" "$c2" --cap 4 >/dev/null || { echo "self-test: a head under the cap but above its base was an offence" >&2; fail=1; }
        # --cap honoured: the same head is an offence under a lower cap
        "$self" "$c1" "$c2" --cap 2 >/dev/null && { echo "self-test: --cap was not honoured" >&2; fail=1; }
        # one public line swapped for another = clean, count unchanged
        "$self" "$c2" "$c3" --cap 3 >/dev/null || { echo "self-test: a swapped public line was an offence" >&2; fail=1; }
        [ "$(count_of "$c2" "$c3" 3)" = "3 3" ] || { echo "self-test: the swap changed the count: $(count_of "$c2" "$c3" 3)" >&2; fail=1; }
        # a commented-out declaration, a doc comment and an internal func do not count; the attributed and open forms do
        [ "$(count_of "$c1" "$c1" 9)" = "2 9" ] || { echo "self-test: the two-declaration base counted $(count_of "$c1" "$c1" 9)" >&2; fail=1; }
        [ "$(count_of "$c1" "$c2" 9)" = "3 9" ] || { echo "self-test: open class was not counted: $(count_of "$c1" "$c2" 9)" >&2; fail=1; }
        # the default cap is the recorded one
        "$self" "$c1" "$c2" | head -1 | grep -q " of cap ${DECLARATION_CAP}," || { echo "self-test: the default cap is not ${DECLARATION_CAP}" >&2; fail=1; }
        exit "$fail"
    ) && echo "engine-public-surface-check --self-test: over the cap → offence, at or under the cap → clean (also above the base), --cap honoured, comments and internal lines not counted: OK" \
      || { echo "engine-public-surface-check --self-test: DRIFTED" >&2; return 1; }
}

cap="$DECLARATION_CAP"
positional=()
while [ $# -gt 0 ]; do
    case "$1" in
        --self-test) self_test; exit $? ;;
        -h|--help) usage; exit 0 ;;
        --cap) [ $# -ge 2 ] || { echo "engine-public-surface-check: --cap needs a number" >&2; exit 64; }; cap="$2"; shift 2 ;;
        --cap=*) cap="${1#--cap=}"; shift ;;
        -*) echo "engine-public-surface-check: unknown option: $1" >&2; exit 64 ;;
        *) positional+=("$1"); shift ;;
    esac
done
case "$cap" in ''|*[!0-9]*) echo "engine-public-surface-check: --cap wants a number, got '$cap'" >&2; exit 64 ;; esac
if [ "${#positional[@]}" -eq 0 ]; then usage; exit 64; fi
[ "${#positional[@]}" -eq 2 ] || { echo "engine-public-surface-check: usage BASE HEAD [--cap N]" >&2; exit 64; }
cd "$(git rev-parse --show-toplevel)"
for r in "${positional[@]}"; do
    git rev-parse --verify --quiet "${r}^{commit}" >/dev/null || { echo "engine-public-surface-check: '$r' is not a commit" >&2; exit 64; }
done
check "${positional[0]}" "${positional[1]}" "$cap"
