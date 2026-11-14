#!/usr/bin/env bash
# doc-metrics.sh — measure the numbers README.md and ENGINEERING.md claim about
# this tree, and (with --check) fail when the documents drift from the tree.
#
# Usage:
#   Scripts/doc-metrics.sh            print the measured numbers
#   Scripts/doc-metrics.sh --check    also compare them with README.md / ENGINEERING.md
#   Scripts/doc-metrics.sh --self-test   prove the claims move: a scratch copy of
#                                     the Swift trees and the two documents passes
#                                     --check; one planted `.public` interpolation
#                                     reads DRIFT; one planted `print(` reads DRIFT;
#                                     the five test counts written "about N" within
#                                     3 % pass and each one outside reads DRIFT; each
#                                     written as a number one off reads DRIFT; the verdict
#                                     line carries the exact counts; exit 1 otherwise
#
# Measured, from the checkout this script runs in:
#   - Swift line counts per tree (engine source, engine tests, app source, app
#     tests, UI tests), the source and test totals and their ratio
#   - `@Test` and `@Suite` attribute counts per test tree
#   - XCUITest methods under Tests/ResectaAppUITests
#   - assertion counts: `#expect(` + `#require(` (Swift Testing) and `XCTAssert*(`
#   - the encoding count in `AhoCorasick.encodeForSearch` (the `encodings` array)
#   - `nonisolated(unsafe)` declarations in app + engine source
#   - log interpolations marked `privacy: .public` in app + engine source, and
#     `print(` / `NSLog(` / `debugPrint(` calls there (the shipping source
#     logs through os.Logger; the documents claim the count and the zero)
#
# --check tolerances: line counts within 3 % of the claim (the documents round
# to the nearest thousand), assertion totals within 3 % (the README says
# "about"). The five test counts (engine and app `@Test` functions and suites,
# XCUITest methods) are exact when written as a number and within 3 % when
# written "about N". Every other count is exact. Number words (seven, ...) are
# read as numbers. The verdict line carries the five counts as measured, the
# exact counts of record. Exit 0 = the documents match; 1 = drift (each drifted
# claim is printed with the measured value); 64 = usage.
#
# Pure local: python3 from the system, no network, no third-party tools.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-print}"
case "$MODE" in
    print|--check|--self-test|--check-root) ;;
    *) sed -n '2,30p' "$0"; exit 64 ;;
esac

if [ "$MODE" = "--self-test" ]; then
    # A scratch root with the Swift trees (source files only) and the two
    # documents; the measured line counts and claims are then the real ones.
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/doc-metrics-selftest.XXXXXX")"
    for tree in Packages/RedactionEngine/Sources Packages/RedactionEngine/Tests Sources Tests/ResectaAppTests Tests/ResectaAppUITests; do
        (cd "$ROOT" && /usr/bin/find "$tree" -name '*.swift' -print0 | while IFS= read -r -d '' f; do
            mkdir -p "$scratch/$(dirname "$f")"; cp "$f" "$scratch/$f"; done)
    done
    cp "$ROOT/README.md" "$ROOT/ENGINEERING.md" "$scratch/"
    fails=0
    if "$0" --check-root "$scratch" > /dev/null 2>&1; then echo "self-test: the scratch copy passes --check OK"
    else echo "self-test: the scratch copy does not pass --check" >&2; fails=1; fi
    planted="$scratch/Sources/ResectaApp/SelfTestPlanted.swift"
    printf 'import os\nlet l = Logger()\nfunc f(_ k: String) { l.info("key \\(k, privacy: .public)") }\n' > "$planted"
    out="$("$0" --check-root "$scratch" 2>&1 || true)"
    if printf '%s' "$out" | /usr/bin/grep -q 'DRIFT ENGINEERING public log interpolations'; then echo "self-test: one planted public interpolation reads DRIFT OK"
    else echo "self-test: a planted public interpolation did not read DRIFT" >&2; fails=1; fi
    printf 'func g() { print("x") }\n' > "$planted"
    out="$("$0" --check-root "$scratch" 2>&1 || true)"
    if printf '%s' "$out" | /usr/bin/grep -q 'DRIFT ENGINEERING print calls'; then echo "self-test: one planted print( reads DRIFT OK"
    else echo "self-test: a planted print( did not read DRIFT" >&2; fails=1; fi
    unlink "$planted"
    # The five test counts: the README's own claims (equal to the tree when the
    # first case passes) rewritten by a factor, as "about N" or as a number.
    cp "$scratch/README.md" "$scratch/README.exact"
    counts_as() { # factor about|exact [label] — rewrite the claims; one label alone when given
        python3 - "$scratch/README.exact" "$scratch/README.md" "$1" "$2" "${3:-}" <<'REWRITE'
import re, sys
src, dst, factor, form, only = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4], sys.argv[5]
text = open(src, encoding="utf-8").read()
CLAIMS = {
    "README engine @Test": r"([\d,]+)( Swift Testing `@Test` functions across [\d,]+ suites)",
    "README engine suites": r"(?<=Swift Testing `@Test` functions across )([\d,]+)( suites)",
    "README app @Test": r"([\d,]+)( `@Test` functions across [\d,]+ suites: the pipeline state machine)",
    "README app suites": r"(?<=`@Test` functions across )([\d,]+)( suites: the pipeline state machine)",
    "README XCUITest methods": r"([\d,]+)( XCUITest methods)",
}
for label, pattern in CLAIMS.items():
    if only and label != only:
        continue
    def scaled(m):
        v = int(m.group(1).replace(",", ""))
        v = v + 1 if form == "one-more" else round(v * factor)
        return ("about " if form == "about" else "") + f"{v:,}" + m.group(2)
    text, n = re.subn(pattern, scaled, text, count=1)
    assert n == 1, label
open(dst, "w", encoding="utf-8").write(text)
REWRITE
    }
    labels="README engine @Test|README engine suites|README app @Test|README app suites|README XCUITest methods"
    counts_as 1.02 about
    out="$("$0" --check-root "$scratch" 2>&1)" && n=$(printf '%s\n' "$out" | /usr/bin/grep -cE "ok    ($labels): claimed about ") \
        && [ "$n" -eq 5 ] && echo "self-test: the five test counts written about N within 3 % pass OK" \
        || { echo "self-test: the five counts written about N within 3 % did not all pass" >&2; fails=1; }
    for label in "README engine @Test" "README engine suites" "README app @Test" "README app suites" "README XCUITest methods"; do
        counts_as 1.05 about "$label"
        out="$("$0" --check-root "$scratch" 2>&1 || true)"
        if printf '%s' "$out" | /usr/bin/grep -q "DRIFT $label: claimed about "; then echo "self-test: $label written about N outside 3 % reads DRIFT OK"
        else echo "self-test: $label written about N outside 3 % did not read DRIFT" >&2; fails=1; fi
    done
    for label in "README engine @Test" "README engine suites" "README app @Test" "README app suites" "README XCUITest methods"; do
        counts_as 1 one-more "$label"
        out="$("$0" --check-root "$scratch" 2>&1 || true)"
        if printf '%s' "$out" | /usr/bin/grep -qE "DRIFT $label: claimed [0-9,]+ measured"; then echo "self-test: $label written as a number one off reads DRIFT OK"
        else echo "self-test: $label written as a number one off did not read DRIFT" >&2; fails=1; fi
    done
    cp "$scratch/README.exact" "$scratch/README.md"
    out="$("$0" --check-root "$scratch" 2>&1 || true)"
    if printf '%s' "$out" | /usr/bin/grep -qE '^DOC-METRICS OK · counts of record: engine @Test [0-9]+, engine suites [0-9]+, app @Test [0-9]+, app suites [0-9]+, XCUITest methods [0-9]+$'; then echo "self-test: the verdict line carries the exact counts OK"
    else echo "self-test: the verdict line does not carry the exact counts" >&2; fails=1; fi
    rm -rf "$scratch"
    [ "$fails" -eq 0 ] && { echo "self-test: PASS"; exit 0; }
    echo "self-test: FAIL" >&2; exit 1
fi
# --check-root DIR: --check against another root (the self-test's scratch copy).
if [ "$MODE" = "--check-root" ]; then ROOT="$2"; MODE="--check"; fi

python3 - "$ROOT" "$MODE" <<'PY'
import os, re, sys

root, mode = sys.argv[1], sys.argv[2]

TREES = {
    "engine source": "Packages/RedactionEngine/Sources",
    "engine tests": "Packages/RedactionEngine/Tests",
    "app source": "Sources",
    "app tests": "Tests/ResectaAppTests",
    "UI tests": "Tests/ResectaAppUITests",
}

def swift_files(rel):
    base = os.path.join(root, rel)
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if d not in (".build", ".swiftpm"))
        for f in sorted(filenames):
            if f.endswith(".swift"):
                yield os.path.join(dirpath, f)

def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()

lines = {}
files = {}
for name, rel in TREES.items():
    n = c = 0
    for p in swift_files(rel):
        n += 1
        c += read(p).count("\n")
    lines[name] = c
    files[name] = n

source_lines = lines["engine source"] + lines["app source"]
test_lines = lines["engine tests"] + lines["app tests"] + lines["UI tests"]
ratio = test_lines / source_lines if source_lines else 0.0

TEST_RE = re.compile(r"^\s*@Test\b", re.M)
SUITE_RE = re.compile(r"^\s*@Suite\b", re.M)
XCUI_RE = re.compile(r"^\s*func test\w*\(", re.M)
EXPECT_RE = re.compile(r"#expect\(|#require\(")
XCT_RE = re.compile(r"\bXCTAssert\w*\(")

counts = {}
for name in ("engine tests", "app tests", "UI tests"):
    tests = suites = xcui = expects = xcts = 0
    for p in swift_files(TREES[name]):
        t = read(p)
        n_tests = len(TEST_RE.findall(t))
        tests += n_tests
        suites += len(SUITE_RE.findall(t))
        xcui += len(XCUI_RE.findall(t))
        expects += len(EXPECT_RE.findall(t))
        xcts += len(XCT_RE.findall(t))
    counts[name] = dict(tests=tests, suites=suites, xcui=xcui, expects=expects, xcts=xcts)

aho = read(os.path.join(root, "Packages/RedactionEngine/Sources/RedactionEngine/Verification/AhoCorasick.swift"))
m = re.search(r"let encodings: \[String\.Encoding\] = \[(.*?)\]", aho, re.S)
encodings = len([e for e in m.group(1).split(",") if e.strip()]) if m else 0

unsafe = 0
for name in ("engine source", "app source"):
    for p in swift_files(TREES[name]):
        unsafe += len(re.findall(r"nonisolated\(unsafe\)\s+(?:static\s+|private\s+|fileprivate\s+|internal\s+|public\s+)*(?:var|let)\b", read(p)))

public_interp = 0
print_calls = 0
PRINT_RE = re.compile(r"\b(?:print|NSLog|debugPrint)\(")
for name in ("engine source", "app source"):
    for p in swift_files(TREES[name]):
        for line in read(p).splitlines():
            code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
            at = code.find("//")
            if at >= 0:
                code = code[:at]
            public_interp += line.count("privacy: .public")
            print_calls += len(PRINT_RE.findall(code))

expect_total = counts["engine tests"]["expects"] + counts["app tests"]["expects"] + counts["UI tests"]["expects"]
xct_total = counts["engine tests"]["xcts"] + counts["app tests"]["xcts"] + counts["UI tests"]["xcts"]

print("Swift line counts")
for name in TREES:
    print(f"  {name:14s} {files[name]:4d} files  {lines[name]:7,d} lines")
print(f"  source total   {source_lines:7,d}   tests total {test_lines:7,d}   ratio {ratio:.2f}x")
print("Test counts")
for name in ("engine tests", "app tests", "UI tests"):
    c = counts[name]
    tail = f"   XCUITest methods {c['xcui']:3d}" if name == "UI tests" else ""
    print(f"  {name:14s} @Test {c['tests']:5d}   @Suite {c['suites']:4d}   #expect/#require {c['expects']:5d}   XCTAssert {c['xcts']:4d}{tail}")
print(f"  assertions: #expect/#require {expect_total:,d} (+ {xct_total} XCTAssert in the UI tests)")
print(f"Encodings in AhoCorasick.encodeForSearch: {encodings}")
print(f"nonisolated(unsafe) declarations in app + engine source: {unsafe}")
print(f"log interpolations marked privacy: .public in app + engine source: {public_interp}")
print(f"print/NSLog/debugPrint calls in app + engine source: {print_calls}")

if mode != "--check":
    sys.exit(0)

WORDS = {"no": 0, "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10}

def num(s):
    s = s.strip().lower().replace(",", "")
    return WORDS.get(s, None) if s in WORDS else int(s)

def flat(path):
    return re.sub(r"\s+", " ", read(os.path.join(root, path)))

readme = flat("README.md")
eng = flat("ENGINEERING.md")
drift = []

def claim(doc, label, pattern, measured, tolerance=0.0, words=False):
    m = re.search(pattern, doc)
    if not m:
        drift.append(f"{label}: claim not found (pattern {pattern!r})")
        return
    try:
        value = num(m.group(1))
    except ValueError:
        drift.append(f"{label}: unreadable claim {m.group(1)!r}")
        return
    if value is None:
        drift.append(f"{label}: unreadable claim {m.group(1)!r}")
        return
    ok = abs(value - measured) <= tolerance * measured if tolerance else value == measured
    print(f"  {'ok   ' if ok else 'DRIFT'} {label}: claimed {value:,} measured {measured:,}")
    if not ok:
        drift.append(label)

def count_claim(doc, label, pattern, measured):
    # A test count: exact when written as a number, within 3 % when written
    # "about N". The pattern's first group is the optional "about ", its second
    # the number.
    m = re.search(pattern, doc)
    if not m:
        drift.append(f"{label}: claim not found (pattern {pattern!r})")
        return
    about = m.group(1) is not None
    value = int(m.group(2).replace(",", ""))
    ok = abs(value - measured) <= 0.03 * measured if about else value == measured
    shown = f"about {value:,}" if about else f"{value:,}"
    print(f"  {'ok   ' if ok else 'DRIFT'} {label}: claimed {shown} measured {measured:,}")
    if not ok:
        drift.append(label)

record = (f"counts of record: engine @Test {counts['engine tests']['tests']}, engine suites {counts['engine tests']['suites']}, "
          f"app @Test {counts['app tests']['tests']}, app suites {counts['app tests']['suites']}, XCUITest methods {counts['UI tests']['xcui']}")

print("Checking README.md")
claim(readme, "README source lines", r"roughly ([\d,]+) lines of Swift source", source_lines, 0.03)
claim(readme, "README test lines", r"roughly ([\d,]+) lines of test code", test_lines, 0.03)
m = re.search(r"about (\d+\.\d)×", readme)
if m:
    ok = abs(float(m.group(1)) - round(ratio, 1)) < 0.05
    print(f"  {'ok   ' if ok else 'DRIFT'} README ratio: claimed {m.group(1)}× measured {ratio:.2f}×")
    if not ok:
        drift.append("README ratio")
else:
    drift.append("README ratio: claim not found")
count_claim(readme, "README engine @Test", r"(about )?([\d,]+) Swift Testing `@Test` functions across (?:about )?[\d,]+ suites", counts["engine tests"]["tests"])
count_claim(readme, "README engine suites", r"[\d,]+ Swift Testing `@Test` functions across (about )?([\d,]+) suites", counts["engine tests"]["suites"])
count_claim(readme, "README app @Test", r"(about )?([\d,]+) `@Test` functions across (?:about )?[\d,]+ suites: the pipeline state machine", counts["app tests"]["tests"])
count_claim(readme, "README app suites", r"[\d,]+ `@Test` functions across (about )?([\d,]+) suites: the pipeline state machine", counts["app tests"]["suites"])
count_claim(readme, "README XCUITest methods", r"(about )?([\d,]+) XCUITest methods", counts["UI tests"]["xcui"])
claim(readme, "README assertions", r"about ([\d,]+) `#expect`/`#require` assertions", expect_total, 0.03)
claim(readme, "README encodings", r"raw bytes across (\w+) encodings", encodings, words=True)

print("Checking ENGINEERING.md")
claim(eng, "ENGINEERING encodings", r"case variants × (\w+) encodings", encodings, words=True)
claim(eng, "ENGINEERING nonisolated(unsafe)", r"(\d+) `nonisolated\(unsafe\)` declarations", unsafe)
claim(eng, "ENGINEERING public log interpolations", r"(\d+) log interpolations are marked `privacy: \.public`", public_interp)
claim(eng, "ENGINEERING print calls", r"carries (\w+) `print`, `NSLog` or `debugPrint` call", print_calls, words=True)
claim(eng, "ENGINEERING source lines (concurrency section)", r"declarations across ~([\d,]+) lines of app \+ engine source", source_lines, 0.03)
claim(eng, "ENGINEERING source lines (reading section)", r"about ([\d,]+) lines of source to about", source_lines, 0.03)
claim(eng, "ENGINEERING test lines (reading section)", r"lines of source to about ([\d,]+) lines of tests", test_lines, 0.03)

if drift:
    print("DOC-METRICS FAIL: " + "; ".join(drift) + " · " + record)
    sys.exit(1)
print("DOC-METRICS OK · " + record)
PY
