#!/usr/bin/env bash
# doc-metrics.sh — measure the numbers README.md and ENGINEERING.md claim about
# this tree, and (with --check) fail when the documents drift from the tree.
#
# Usage:
#   Scripts/doc-metrics.sh            print the measured numbers
#   Scripts/doc-metrics.sh --check    also compare them with README.md / ENGINEERING.md
#
# Measured, from the checkout this script runs in:
#   - Swift line counts per tree (engine source, engine tests, app source, app
#     tests, UI tests), the source and test totals and their ratio
#   - `@Test` and `@Suite` attribute counts per test tree
#   - XCUITest methods under Tests/ResectaAppUITests
#   - assertion counts: `#expect(` + `#require(` (Swift Testing) and `XCTAssert*(`
#   - the encoding count in `AhoCorasick.encodeForSearch` (the `encodings` array)
#   - `nonisolated(unsafe)` declarations in app + engine source
#
# --check tolerances: line counts within 3 % of the claim (the documents round
# to the nearest thousand), assertion totals within 3 % (the README says
# "about"), every other count exact. Number words (seven, ...) are read as
# numbers. Exit 0 = the documents match; 1 = drift (each drifted claim is
# printed with the measured value); 64 = usage.
#
# Pure local: python3 from the system, no network, no third-party tools.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-print}"
case "$MODE" in
    print|--check) ;;
    *) sed -n '2,25p' "$0"; exit 64 ;;
esac

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

if mode != "--check":
    sys.exit(0)

WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10}

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
claim(readme, "README engine @Test", r"([\d,]+) Swift Testing `@Test` functions across [\d,]+ suites", counts["engine tests"]["tests"])
claim(readme, "README engine suites", r"[\d,]+ Swift Testing `@Test` functions across ([\d,]+) suites", counts["engine tests"]["suites"])
claim(readme, "README app @Test", r"([\d,]+) `@Test` functions across [\d,]+ suites: the pipeline state machine", counts["app tests"]["tests"])
claim(readme, "README app suites", r"[\d,]+ `@Test` functions across ([\d,]+) suites: the pipeline state machine", counts["app tests"]["suites"])
claim(readme, "README XCUITest methods", r"([\d,]+) XCUITest methods", counts["UI tests"]["xcui"])
claim(readme, "README assertions", r"about ([\d,]+) `#expect`/`#require` assertions", expect_total, 0.03)
claim(readme, "README encodings", r"raw bytes across (\w+) encodings", encodings, words=True)

print("Checking ENGINEERING.md")
claim(eng, "ENGINEERING encodings", r"case variants × (\w+) encodings", encodings, words=True)
claim(eng, "ENGINEERING nonisolated(unsafe)", r"(\d+) `nonisolated\(unsafe\)` declarations", unsafe)
claim(eng, "ENGINEERING source lines (concurrency section)", r"declarations across ~([\d,]+) lines of app \+ engine source", source_lines, 0.03)
claim(eng, "ENGINEERING source lines (reading section)", r"about ([\d,]+) lines of source to about", source_lines, 0.03)
claim(eng, "ENGINEERING test lines (reading section)", r"lines of source to about ([\d,]+) lines of tests", test_lines, 0.03)

if drift:
    print("DOC-METRICS FAIL: " + "; ".join(drift))
    sys.exit(1)
print("DOC-METRICS OK")
PY
