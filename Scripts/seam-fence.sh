#!/bin/bash
# Seam fences: six rules over where code may reach. Each rule holds the sites
# the tree has today as a list in this script; a site may leave its list,
# none may join it. A site is keyed by its file and its line's text, with
# runs of white space read as one space (for F2, by its file and the type it
# names), so an edit elsewhere in the file does not move it.
#
#   F1  Views do not drive the engine. In every file that declares a SwiftUI
#       view or extends one, wherever it lies: no call that constructs the
#       searcher (`DocumentSearcher(`) or the document-type classifier
#       (`DocumentTypeClassifier(`), and no `.search(` on a searcher.
#   F2  The verifier names no new producer type. In the engine's
#       Verification folder, each file may name only the producer types on
#       its list. A producer type is any top-level type declared under the
#       engine's Search or Detection folder.
#   F3  The core holds no sentence. Under the core's sources, no string
#       literal holds a space or a capital letter, unless its line carries
#       `CoreString:ok <reason>`.
#   F4  No second floor, clamp or whole-page rule. On the paint and admission
#       paths (F4_PATHS below): no width or height compared with a number, no
#       width times height compared with anything, and no rectangle tested for
#       a minimum at most 0 and a maximum at least 1. The one admission
#       function's planned home, the core's Geometry/RegionAdmission.swift, is
#       outside these paths.
#   F5  A name a split widened is written only by its own type. A split that
#       widens a name adds it to F5_NAMES with its type's own files, and a
#       write to it from any other file is refused. This list grows with the
#       split that widens the name and is not compared by --compare-lists.
#   F6  The page mode's fallback triggers are asked in one place. In the app
#       and engine sources and the chain runner's page loop, outside the
#       detector itself and the page mode decision's own file
#       (Detection/PageModeDecision.swift): no call of
#       `checkFallbackTriggers(` beyond its list.
#
# Comments are never read. String literals are read by F3 alone. A listed
# site that is no longer in the tree is reported as gone; it may be taken off
# its list, and it fails nothing.
#
# A fence that reads nothing holds nothing, so the tree must give each rule
# something to read: every folder the rules read must exist (the core's
# folder once the engine's manifest declares the core target, and the folder
# of each listed site's file), F2 must find at least one producer type, and a
# rule with listed sites must read at least one file. Each rule prints how
# many files it read. A tree that fails this is a setup error, not a pass,
# and its run never prints the clean line.
#
# Run from anywhere in the repo.
#   Scripts/seam-fence.sh                      the fences over the tree
#   Scripts/seam-fence.sh --files              the same, and the files each
#       rule read
#   Scripts/seam-fence.sh --self-test          three planted spellings per
#       rule each read as an offence; their clean twins and the stated
#       exceptions read as none; a listed site that has gone is reported and
#       fails nothing; a tree that gives a rule nothing to read is a setup
#       error; then the fences over the tree. Exit 0 when all hold.
#   Scripts/seam-fence.sh --lists              this copy's lists, as JSON
#   Scripts/seam-fence.sh --compare-lists BASE this copy's lists against those
#       of BASE (another copy of this script, the base branch's): an entry of
#       F1 to F4 or F6 that this copy holds and BASE does not is an offence.
# Exit 0 clean; 1 an offence or a failed self-test; 2 a usage or setup error.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)" || { echo "not in a git repo" >&2; exit 2; }
exec python3 -I - "$ROOT" "$@" <<'PY'
import collections
import contextlib
import fnmatch
import io
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT, ARGS = sys.argv[1], sys.argv[2:]

A = "Sources/ResectaApp/"
E = "Packages/RedactionEngine/Sources/RedactionEngine/"
C = "Packages/RedactionEngine/Sources/RedactionCore/"
RUNNER = "Packages/RedactionEngine/Tests/RedactionEngineTests/CorpusTests/"

# The folders the rules read. Each must exist. The core's folder is required
# only once the engine's manifest declares the core target.
MANIFEST = "Packages/RedactionEngine/Package.swift"
REQUIRED = [A, A + "State/", E, E + "Search/", E + "Detection/", E + "Verification/", RUNNER]
CORE_TARGET = re.compile(r'\.target\s*\(\s*name\s*:\s*"RedactionCore"')

# ------------------------------------------------------------- the lists

F1_LIST = {
    A + "Views/SearchAndRedactSheet.swift": [
        "@State var searcher = DocumentSearcher()",
    ],
}

F2_LIST = {
    E + "Verification/DetectionSweep.swift": ["UserTermMatcher"],
    E + "Verification/Layer2OCRCheck+Sweep.swift": ["OCRConfiguration"],
    E + "Verification/OutputRecheck.swift": ["DocumentSearcher", "TextLayerDetector"],
    E + "Verification/RegionCoverage.swift": ["DocumentSearcher", "TextLayerDetector"],
    E + "Verification/VerificationEngine+HiddenWordInk.swift": [
        "DocumentSearcher", "OCRConfiguration", "PageContentFacts",
    ],
    E + "Verification/VerificationOrchestrator.swift": ["TextLayerDetector"],
}

F3_LIST = {}

F4_PATHS = [
    A + "State/RunInputs.swift",
    A + "State/RedactionState*.swift",
    A + "State/PipelineRunSupport*.swift",
    A + "State/RedactionApplyEngine.swift",
    E + "Pipeline/*",
    E + "Models/RedactionRegion.swift",
    E + "Detection/PageContentFacts.swift",
    E + "Verification/Layer2OCRCheck*.swift",
]

F4_LIST = {
    E + "Detection/PageContentFacts.swift": [
        "normalizedRect.minX <= 0 && normalizedRect.minY <= 0 && normalizedRect.maxX >= 1 && normalizedRect.maxY >= 1",
    ],
    E + "Pipeline/InkContrastFloor.swift": [
        "return core.isNull || core.width < 1 || core.height < 1 ? nil : core",
    ],
    E + "Pipeline/PageMemoryPolicy.swift": [
        "guard box.width >= 10, box.height >= 10,",
        "box.width <= 5000, box.height <= 5000 else { return false }",
    ],
    E + "Verification/Layer2OCRCheck.swift": [
        "guard region.normalizedRect.width > 0.001,",
        "region.normalizedRect.height > 0.001 else { return nil }",
    ],
    A + "State/PipelineRunSupport+ManualTerms.swift": [
        "if rect.width * rect.height >= Self.wholePageRegionArea {",
    ],
    A + "State/RedactionState.swift": [
        "$0.normalizedRect.width > 0.001 && $0.normalizedRect.height > 0.001",
    ],
    A + "State/RunInputs.swift": [
        "guard clamped.normalizedRect.width > 0.001,",
        "clamped.normalizedRect.height > 0.001 else { return nil }",
    ],
}

# One entry a widened name: {"name": "…", "owners": ["<path glob>", …]}.
F5_NAMES = []

F6_LIST = {
    A + "State/RunInputs.swift": [
        "if let trigger = TextLayerDetector.checkFallbackTriggers(page) {",
    ],
    RUNNER + "VerificationCorpusMirror.swift": [
        "if let trigger = TextLayerDetector.checkFallbackTriggers(page) {",
    ],
}
# The detector itself, and the one place the page's mode is decided (the
# app and the chain runner both call that decision).
F6_EXEMPT = [E + "Detection/TextLayerDetector.swift", E + "Detection/PageModeDecision.swift"]

LISTS = {"F1": F1_LIST, "F2": F2_LIST, "F3": F3_LIST, "F4": F4_LIST, "F6": F6_LIST}

# ------------------------------------------------------- reading Swift

def blank(text, keep_strings):
    """`text` with every comment, and unless `keep_strings` every string
    literal, replaced by spaces; newlines and offsets are kept. Also returns
    the string literals as (offset, text) with interpolations left out."""
    out = list(text)
    literals = []
    i, n = 0, len(text)

    def wipe(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        ch = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            wipe(i, j)
            i = j
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            wipe(i, j)
            i = j
        elif ch == '"' or (ch == "#" and re.match(r'#+"', text[i:])):
            hashes = len(re.match(r'#*', text[i:]).group(0))
            q = i + hashes
            multi = text.startswith('"""', q)
            opener = '"""' if multi else '"'
            closer = opener + "#" * hashes
            j = q + len(opener)
            body = []
            depth = 0
            while j < n:
                if depth == 0 and text.startswith(closer, j):
                    j += len(closer)
                    break
                c = text[j]
                if depth == 0 and c == "\\" and text[j + 1:j + 1 + hashes] == "#" * hashes:
                    k = j + 1 + hashes
                    if k < n and text[k] == "(":
                        depth, j = 1, k + 1
                        continue
                    # An escape is read as the character it stands for.
                    u = re.match(r'u\{([0-9A-Fa-f]{1,8})\}', text[k:])
                    if u:
                        body.append(chr(int(u.group(1), 16)))
                        j = k + len(u.group(0))
                        continue
                    body.append({"n": "\n", "t": "\t", "r": "\r", "0": "\0"}.get(text[k:k + 1], text[k:k + 1]))
                    j = k + 1
                    continue
                if depth:
                    if c == "(":
                        depth += 1
                    elif c == ")":
                        depth -= 1
                    j += 1
                    continue
                if not multi and c == "\n":
                    break
                body.append(c)
                j += 1
            literals.append((i, "".join(body)))
            if not keep_strings:
                wipe(i, j)
            i = j
        else:
            i += 1
    return "".join(out), literals

def line_of(text, offset):
    return text.count("\n", 0, offset) + 1

def key(line):
    return " ".join(line.split())

def swift_files(root, prefixes):
    found = []
    for prefix in prefixes:
        base = os.path.join(root, prefix)
        for dirpath, _, names in os.walk(base):
            for name in names:
                if name.endswith(".swift"):
                    found.append(os.path.relpath(os.path.join(dirpath, name), root))
    return sorted(set(found))

def read(root, path):
    with open(os.path.join(root, path), encoding="utf-8", errors="replace") as fh:
        return fh.read()

def matches(path, globs):
    return any(fnmatch.fnmatchcase(path, g) for g in globs)

def line_sites(root, path, patterns, keep_strings=False):
    """(line number, key) of each line of `path` where a pattern matches."""
    raw = read(root, path)
    code, _ = blank(raw, keep_strings)
    lines = raw.split("\n")
    seen = []
    for number, text in enumerate(code.split("\n"), start=1):
        if any(re.search(p, text) for p in patterns):
            seen.append((number, key(lines[number - 1])))
    return seen

# --------------------------------------------------------------- rules

VIEW_DECL = re.compile(
    r'\b(?:struct|class|enum|actor|extension)\s+([A-Z]\w*)\s*(?:<[^>{]*>)?\s*:\s*([^{]*)\{')
EXTENSION = re.compile(r'\bextension\s+([A-Z]\w*)\b')

def view_files(root):
    files = swift_files(root, [A, E, C])
    code = {f: blank(read(root, f), False)[0] for f in files}
    views = set()
    for text in code.values():
        for name, conformances in VIEW_DECL.findall(text):
            if re.search(r'(?<![\w.])View\b', conformances):
                views.add(name)
    chosen = []
    for f, text in code.items():
        declared = {m[0] for m in VIEW_DECL.findall(text)} | set(EXTENSION.findall(text))
        if declared & views:
            chosen.append(f)
    return chosen

F1_PATTERNS = [
    r'\bDocumentSearcher\s*\(',
    r'\bDocumentTypeClassifier\s*\(',
    r'\b\w*[Ss]earcher\w*\s*[?!]?\s*\.\s*search\s*\(',
]

def rule_f1(root):
    return {f: line_sites(root, f, F1_PATTERNS) for f in view_files(root)}

TOP_DECL = re.compile(
    r'^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private|final|nonisolated|open)\s+)*'
    r'(?:struct|class|enum|actor|protocol|typealias)\s+([A-Z]\w*)', re.M)

def producer_types(root):
    kinds = set()
    for f in swift_files(root, [E + "Search/", E + "Detection/"]):
        kinds |= set(TOP_DECL.findall(blank(read(root, f), False)[0]))
    own = set()
    for f in swift_files(root, [E + "Verification/"]):
        own |= set(TOP_DECL.findall(blank(read(root, f), False)[0]))
    return kinds - own

def rule_f2(root):
    kinds = producer_types(root)
    sites = {}
    for f in swift_files(root, [E + "Verification/"]):
        raw = read(root, f)
        code = blank(raw, False)[0]
        found = []
        for kind in sorted(kinds):
            m = re.search(r'(?<![\w.])' + re.escape(kind) + r'\b', code)
            if m:
                found.append((line_of(code, m.start()), kind))
        sites[f] = found
    return sites

def rule_f3(root):
    sites = {}
    for f in swift_files(root, [C]):
        raw = read(root, f)
        lines = raw.split("\n")
        _, literals = blank(raw, True)
        found = []
        for offset, body in literals:
            if re.search(r'[ A-Z]', body):
                number = line_of(raw, offset)
                if re.search(r'CoreString:ok\s+\S', lines[number - 1]):
                    continue
                found.append((number, key(lines[number - 1])))
        sites[f] = found
    return sites

NUMBER = r'(-?(?:\d[\d_]*\.?[\d_]*|\.\d[\d_]*)(?:[eE][-+]?\d+)?)'
CMP = r'(?:<=|>=|==|!=|<(?!<)|>(?!>))'
OPERAND = r'[\w.()\[\]?!]*'
# A width or a height compared with a number. The number zero, however it is
# written (0, 0.0, -0), is an emptiness guard and not a floor: such a
# comparison is not a site. Every other number is.
F4_NUMBER_FORMS = [
    r'\.(?:width|height)\b\s*' + CMP + r'\s*' + NUMBER + r'(?![\w.])',
    r'(?<![\w.])' + NUMBER + r'\s*' + CMP + r'\s*' + OPERAND + r'\.(?:width|height)\b',
]
# A width times a height compared with anything; a rectangle tested for a
# minimum at most 0 and a maximum at least 1 (the whole page).
F4_OTHER_FORMS = [
    r'\bwidth\s*\*\s*' + OPERAND + r'\bheight\b\s*' + CMP,
    r'\bheight\s*\*\s*' + OPERAND + r'\bwidth\b\s*' + CMP,
    CMP + r'\s*' + OPERAND + r'\bwidth\s*\*\s*' + OPERAND + r'\bheight\b',
    CMP + r'\s*' + OPERAND + r'\bheight\s*\*\s*' + OPERAND + r'\bwidth\b',
    r'\bmin[XY]\s*<=\s*0(?![\w.]).*\bmax[XY]\s*>=\s*1(?![\w.])',
]

def is_zero(number):
    try:
        return float(number.replace("_", "")) == 0
    except ValueError:
        return False

def f4_line_is_site(text):
    if any(re.search(p, text) for p in F4_OTHER_FORMS):
        return True
    return any(not is_zero(m.group(1))
               for p in F4_NUMBER_FORMS for m in re.finditer(p, text))

def f4_files(root):
    return [f for f in swift_files(root, [A + "State/", E]) if matches(f, F4_PATHS)]

def rule_f4(root):
    sites = {}
    for f in f4_files(root):
        raw = read(root, f)
        lines = raw.split("\n")
        code = blank(raw, False)[0]
        sites[f] = [(n, key(lines[n - 1])) for n, text in enumerate(code.split("\n"), start=1)
                    if f4_line_is_site(text)]
    return sites

def rule_f5(root, names):
    sites = {}
    files = swift_files(root, [A, E, C])
    for entry in names:
        name = re.escape(entry["name"])
        patterns = [
            r'(?<![\w])' + name + r'\s*(?:[-+*/%]|&[-+*]|\|\||&&)?=(?!=)',
            r'(?<![\w])' + name + r'\s*\.\s*(?:append|insert|remove\w*|merge|formUnion|subtract|sort|reverse|swapAt|toggle)\s*\(',
        ]
        for f in files:
            if matches(f, entry["owners"]):
                continue
            for number, text in line_sites(root, f, patterns):
                sites.setdefault(f, []).append((number, text))
    return sites

F6_PATTERNS = [r'\bcheckFallbackTriggers\s*\(']

def rule_f6(root):
    files = [f for f in swift_files(root, [A, E, RUNNER]) if f not in F6_EXEMPT]
    return {f: line_sites(root, f, F6_PATTERNS) for f in files}

RULES = [
    ("F1", "views do not drive the engine", rule_f1),
    ("F2", "the verifier names no new producer type", rule_f2),
    ("F3", "the core holds no sentence", rule_f3),
    ("F4", "no second floor, clamp or whole-page rule", rule_f4),
    ("F5", "a name a split widened is written only by its own type", None),
    ("F6", "the page mode's fallback triggers are asked in one place", rule_f6),
]

# ------------------------------------------------------------ judging

def f5_files(root, names):
    return [f for f in swift_files(root, [A, E, C])
            if any(not matches(f, entry["owners"]) for entry in names)]

def judge(root, lists=None, names=None, quiet=False, files_read=None):
    """Run every rule over `root` against `lists` (default: this copy's).
    Returns (offences, gone) as lists of strings. When `files_read` is a
    dict, it is given each rule's files read, by rule."""
    lists = LISTS if lists is None else lists
    names = F5_NAMES if names is None else names
    read_by = {} if files_read is None else files_read
    offences, gone = [], []
    for rid, title, rule in RULES:
        if rid == "F5":
            sites = rule_f5(root, names)
            read_by[rid] = f5_files(root, names)
            for f, found in sorted(sites.items()):
                for number, text in found:
                    offences.append(f"{rid} {f}:{number}: {text}")
            if not quiet:
                print(f"{rid} {title}: {sum(len(v) for v in sites.values())} offence(s); "
                      f"{len(names)} name(s) listed; {len(read_by[rid])} file(s) read")
            continue
        listed = lists.get(rid, {})
        sites = rule(root)
        read_by[rid] = sorted(sites)
        count_seen = 0
        for f in sorted(set(sites) | set(listed)):
            allowed = collections.Counter(listed.get(f, []))
            seen = collections.Counter()
            for number, text in sites.get(f, []):
                seen[text] += 1
                count_seen += 1
                if seen[text] > allowed[text]:
                    offences.append(f"{rid} {f}:{number}: {text}")
            for text, want in allowed.items():
                if seen[text] < want:
                    gone.append(f"{rid} {f}: {text} (listed {want}, seen {seen[text]})")
        if not quiet:
            n_listed = sum(len(v) for v in listed.values())
            print(f"{rid} {title}: {count_seen} site(s) seen, {n_listed} listed; "
                  f"{len(read_by[rid])} file(s) read")
    return offences, gone

def core_declared(root):
    """Whether the engine's manifest declares the core target; None when the
    manifest is missing."""
    path = os.path.join(root, MANIFEST)
    if not os.path.isfile(path):
        return None
    return bool(CORE_TARGET.search(blank(read(root, MANIFEST), True)[0]))

def setup_errors(root, lists, files_read):
    """Why the tree gives a rule nothing to read, one string a reason; none
    when every rule has something to read. `files_read` is judge's files
    read, by rule."""
    errors = []
    declared = core_declared(root)
    if declared is None:
        errors.append(f"the engine's manifest is missing: {MANIFEST}")
    folders = REQUIRED + ([C] if declared else [])
    # The folder of every listed site's file, so a moved folder cannot
    # turn its listed sites into gone ones and pass.
    for rid, listed in sorted(lists.items()):
        for f, entries in sorted(listed.items()):
            folder = os.path.dirname(f) + "/"
            if entries and folder not in folders:
                folders.append(folder)
    for folder in folders:
        if not os.path.isdir(os.path.join(root, folder)):
            errors.append(f"a folder the rules read is missing: {folder}")
    if lists.get("F2") and not producer_types(root):
        errors.append("F2 found no producer type under the engine's Search or Detection folder")
    for rid, listed in sorted(lists.items()):
        if any(listed.values()) and not files_read.get(rid):
            errors.append(f"{rid} has listed sites and read no file")
    if declared and not files_read.get("F3"):
        errors.append("F3 read no file, and the engine's manifest declares the core target")
    return errors

def run_tree(root, show_files=False, quiet=False):
    """The fences over `root`: 0 clean, 1 an offence, 2 a setup error."""
    files_read = {}
    offences, gone = judge(root, quiet=quiet, files_read=files_read)
    errors = setup_errors(root, LISTS, files_read)
    if quiet:
        return 2 if errors else (1 if offences else 0)
    if show_files:
        for rid, files in sorted(files_read.items()):
            for f in files:
                print(f"READ {rid} {f}")
    return report(offences, gone, errors)

def report(offences, gone, errors=()):
    """Print the run's lines and its last line; 0 clean, 1 an offence, 2 a
    setup error. A setup error never prints the clean line."""
    for g in gone:
        print(f"GONE {g} — may be taken off its list")
    for o in offences:
        print(f"OFFENCE {o}")
    for e in errors:
        print(f"SETUP ERROR {e}")
    if errors:
        print(f"SEAM-FENCE SETUP ERROR: {len(errors)} reason(s); the fences did not read the tree")
        return 2
    if offences:
        print(f"SEAM-FENCE FAIL: {len(offences)} offence(s)")
        return 1
    print("SEAM-FENCE OK: no offence" + (f"; {len(gone)} listed site(s) gone" if gone else ""))
    return 0

# ---------------------------------------------------------- self-test

PLANTED = {
    "F1": (A + "Views/PlantedSheet.swift",
           "import SwiftUI\nstruct PlantedSheet: View {\n    var body: some View { Text(\"x\") }\n}\n",
           ["    func a() { let s = DocumentSearcher() }",
            "    func b() { _ = DocumentTypeClassifier().explain(\"x\") }",
            "    func c(_ searcher: DocumentSearcher?) { _ = searcher?.search(source, mode: .text) }"],
           ["    // let s = DocumentSearcher()",
            "    let note = \"DocumentTypeClassifier() is not called here\""]),
    "F2": (E + "Verification/PlantedCheck.swift",
           "import Foundation\n",
           ["func a() { _ = PlantedProducerOne.self }",
            "func b(_ x: PlantedProducerTwo) {}",
            "let c: [PlantedProducerThree] = []"],
           ["// PlantedProducerOne is named in a comment only",
            "let d = \"PlantedProducerTwo\""]),
    "F3": (C + "Planted/PlantedCore.swift",
           "import Foundation\n",
           ["let a = \"two words\"",
            "let b = \"Capital\"",
            "let c = \"\"\"\n    a multi-line literal\n    \"\"\""],
           ["let d = \"lowercase\"", "let f = \"\\u{FB01}\\n\"",
            "let e = \"A sentence the core may hold\" // CoreString:ok a fixed key read by a person"]),
    "F4": (E + "Pipeline/PlantedPaint.swift",
           "import CoreGraphics\n",
           ["func a(_ r: CGRect) -> Bool { r.width > 0.002 }",
            "func b(_ r: CGRect) -> Bool { r.size.width * r.size.height >= 0.9 }",
            "func c(_ r: CGRect) -> Bool { r.minX <= 0 && r.minY <= 0 && r.maxX >= 1 && r.maxY >= 1 }"],
           ["func d(_ r: CGRect) -> Bool { r.width > limit }",
            "// r.height > 0.5 in a comment"]),
    "F5": (A + "Views/PlantedWriter.swift",
           "import Foundation\n",
           ["func a(_ s: PlantedState) { s.plantedName = 1 }",
            "func b(_ s: PlantedState) { s.plantedName += 1 }",
            "func c(_ s: PlantedState) { s.plantedName.append(1) }"],
           ["func d(_ s: PlantedState) -> Bool { s.plantedName == 1 }",
            "func e(_ s: PlantedState) -> Int { s.plantedName }"]),
    "F6": (A + "State/PlantedInputs.swift",
           "import Foundation\n",
           ["func a() { _ = TextLayerDetector.checkFallbackTriggers(page) }",
            "func b() { if let t = TextLayerDetector.checkFallbackTriggers(p, x) { _ = t } }",
            "func c() { _ = checkFallbackTriggers (page) }"],
           ["// checkFallbackTriggers(page) in a comment",
            "let s = \"checkFallbackTriggers(\""]),
}

def write(root, path, text):
    full = os.path.join(root, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", encoding="utf-8") as fh:
        fh.write(text)

def self_test():
    results = []

    def check(name, ok):
        results.append((name, ok))
        print(("PASS " if ok else "FAIL ") + name)

    with tempfile.TemporaryDirectory() as tmp:
        # The producer types F2 reads, declared where the engine declares them.
        write(tmp, E + "Search/PlantedProducers.swift",
              "struct PlantedProducerOne {}\nfinal class PlantedProducerTwo {}\nenum PlantedProducerThree {}\n")
        names = [{"name": "plantedName", "owners": [A + "State/PlantedState*.swift"]}]
        write(tmp, A + "State/PlantedState.swift",
              "final class PlantedState { var plantedName = 0\n func own() { plantedName = 2 } }\n")
        empty = {rid: {} for rid in LISTS}
        for rid, (path, head, offending, clean) in sorted(PLANTED.items()):
            # Each planted spelling alone is one offence of its rule.
            for index, spelling in enumerate(offending, start=1):
                write(tmp, path, head + spelling + "\n")
                offences, _ = judge(tmp, empty, names, quiet=True)
                mine = [o for o in offences if o.startswith(rid + " ")]
                check(f"{rid} planted spelling {index} reads as an offence", len(mine) == 1)
            # The clean twins read as none.
            write(tmp, path, head + "\n".join(clean) + "\n")
            offences, _ = judge(tmp, empty, names, quiet=True)
            check(f"{rid} its clean twins read as none", not [o for o in offences if o.startswith(rid + " ")])
            os.remove(os.path.join(tmp, path))
        # A listed site is no offence; a second copy of it is one.
        path, head, offending, _ = PLANTED["F6"]
        write(tmp, path, head + offending[0] + "\n")
        listed = dict(empty, F6={path: [key(offending[0])]})
        offences, gone = judge(tmp, listed, names, quiet=True)
        check("F6 a listed site reads as none", not offences and not gone)
        write(tmp, path, head + offending[0] + "\n" + offending[0] + "\n")
        offences, _ = judge(tmp, listed, names, quiet=True)
        check("F6 a second copy of a listed site reads as one offence", len(offences) == 1)
        # A listed site that has gone is reported and fails nothing.
        os.remove(os.path.join(tmp, path))
        offences, gone = judge(tmp, listed, names, quiet=True)
        check("F6 a listed site that has gone is reported and fails nothing",
              not offences and len(gone) == 1)
        # F4: a comparison with zero is an emptiness guard; any other number is a floor.
        path, head = PLANTED["F4"][0], PLANTED["F4"][1]
        write(tmp, path, head + "func z(_ r: CGRect) -> Bool { r.width > 0 && r.height <= 0 && r.width != 0.0 && 0 < r.height }\n")
        offences, _ = judge(tmp, empty, names, quiet=True)
        check("F4 a width or height compared with zero reads as none", not offences)
        write(tmp, path, head + "func f(_ r: CGRect) -> Bool { r.width > 0.0001 }\nfunc g(_ r: CGRect) -> Bool { r.height >= 1 }\n")
        offences, _ = judge(tmp, empty, names, quiet=True)
        check("F4 a width or height compared with any other number reads as a floor", len(offences) == 2)
        os.remove(os.path.join(tmp, path))
        # F6: a call in the page mode decision's own file is no offence.
        write(tmp, E + "Detection/PageModeDecision.swift",
              "func d() { _ = TextLayerDetector.checkFallbackTriggers(page) }\n")
        offences, _ = judge(tmp, empty, names, quiet=True)
        check("F6 a call in the page mode decision's own file reads as none", not offences)
        os.remove(os.path.join(tmp, E + "Detection/PageModeDecision.swift"))
        # A widened name written from its own type's files is no offence.
        offences, _ = judge(tmp, empty, names, quiet=True)
        check("F5 a write from the type's own files reads as none", not offences)
    # A tree that gives a rule nothing to read is a setup error.
    with tempfile.TemporaryDirectory() as tmp:
        def errors_with(lists):
            files_read = {}
            judge(tmp, lists, [], quiet=True, files_read=files_read)
            return setup_errors(tmp, lists, files_read)
        no_target = "// .target(name: \"RedactionCore\")\nlet package = 0\n"
        with_target = "let package = [.target(name: \"RedactionCore\")]\n"
        write(tmp, MANIFEST, no_target)
        for folder in REQUIRED:
            write(tmp, folder + "Placeholder.swift", "import Foundation\n")
        write(tmp, E + "Search/Placeholder.swift", "struct PlantedProducerOne {}\n")
        empty = {rid: {} for rid in LISTS}
        check("a tree with every folder read, and no core target, is no setup error",
              not errors_with(empty))
        write(tmp, MANIFEST, with_target)
        check("the core folder missing once the manifest declares the core target is a setup error",
              len(errors_with(empty)) == 2)
        write(tmp, C + "Placeholder.swift", "import Foundation\n")
        check("the core folder present with the core target declared is no setup error",
              not errors_with(empty))
        os.remove(os.path.join(tmp, MANIFEST))
        check("a missing manifest is a setup error", len(errors_with(empty)) == 1)
        write(tmp, MANIFEST, no_target)
        os.remove(os.path.join(tmp, RUNNER + "Placeholder.swift"))
        os.rmdir(os.path.join(tmp, RUNNER))
        check("a missing folder is a setup error", len(errors_with(empty)) == 1)
        check("the fences over a tree missing a folder exit 2", run_tree(tmp, quiet=True) == 2)
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            status = run_tree(tmp)
        lines = printed.getvalue().splitlines()
        check("printed, a tree missing a folder exits 2 and never reads OK",
              status == 2 and lines and lines[-1].startswith("SEAM-FENCE SETUP ERROR")
              and not any(line.startswith("SEAM-FENCE OK") for line in lines))
        write(tmp, RUNNER + "Placeholder.swift", "import Foundation\n")
        f4_listed = dict(empty, F4={A + "State/RunInputs.swift": ["x"]})
        check("a rule with listed sites that read no file is a setup error",
              len(errors_with(f4_listed)) == 1)
        write(tmp, A + "State/RunInputs.swift", "import Foundation\n")
        check("the same rule with a file to read is no setup error", not errors_with(f4_listed))
        f4_listed["F4"] = {A + "State/RunInputs.swift": ["x"], E + "Pipeline/Paint.swift": ["y"]}
        check("a listed site whose folder is missing is a setup error",
              len(errors_with(f4_listed)) == 1)
        write(tmp, E + "Search/Placeholder.swift", "import Foundation\n")
        f2_listed = dict(empty, F2={E + "Verification/Placeholder.swift": ["PlantedProducerOne"]})
        check("F2 with listed sites and no producer type is a setup error",
              len(errors_with(f2_listed)) == 1)
    # The list comparison: an entry this copy adds is an offence.
    base = {rid: {f: list(v) for f, v in lst.items()} for rid, lst in LISTS.items()}
    grown = json.loads(json.dumps(base))
    grown.setdefault("F1", {}).setdefault(A + "Views/Planted.swift", []).append("let s = DocumentSearcher()")
    check("a list entry the change adds reads as an offence", len(list_growth(base, grown)) == 1)
    check("the same lists read as none", not list_growth(base, base))
    expected = 6 * 4 + 4 + 2 + 2 + 1 + 11
    check(f"the self-test ran its {expected} cases", len(results) == expected)
    failed = [n for n, ok in results if not ok]
    print(f"self-test: {len(results) - len(failed)} of {len(results)} cases passed")
    if failed:
        print("SEAM-FENCE SELF-TEST FAIL")
        return 1
    print("--- the fences over the tree")
    return run_tree(ROOT)

# ------------------------------------------------------------ the lists

def list_growth(base, mine):
    joined = []
    for rid in ("F1", "F2", "F3", "F4", "F6"):
        b, m = base.get(rid, {}), mine.get(rid, {})
        for f, entries in m.items():
            extra = collections.Counter(entries) - collections.Counter(b.get(f, []))
            for text, count in extra.items():
                joined.append(f"{rid} {f}: {text} (joined the list {count} time(s))")
    return joined

def main():
    if not ARGS:
        return run_tree(ROOT)
    if ARGS == ["--files"]:
        return run_tree(ROOT, show_files=True)
    if ARGS == ["--self-test"]:
        return self_test()
    if ARGS == ["--lists"]:
        print(json.dumps(LISTS, indent=1, sort_keys=True))
        return 0
    if len(ARGS) == 2 and ARGS[0] == "--compare-lists":
        out = subprocess.run(["bash", ARGS[1], "--lists"], capture_output=True, text=True)
        if out.returncode != 0:
            print(f"could not read the lists of {ARGS[1]}: {out.stderr.strip()}", file=sys.stderr)
            return 2
        joined = list_growth(json.loads(out.stdout), LISTS)
        for j in joined:
            print(f"OFFENCE {j}")
        if joined:
            print(f"SEAM-FENCE LISTS FAIL: {len(joined)} entry(ies) joined a list")
            return 1
        print("SEAM-FENCE LISTS OK: no entry joined a list")
        return 0
    print("usage: seam-fence.sh [--files | --self-test | --lists | --compare-lists BASE]", file=sys.stderr)
    return 2

sys.exit(main())
PY
