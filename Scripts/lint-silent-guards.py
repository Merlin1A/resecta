#!/usr/bin/env python3
"""
lint-silent-guards.py — the "silent test guard" scanner (AL-5) and its census.

A test that reaches a `return` before its first assertion can report PASS
with zero assertions: the fixture it wanted was not bundled, the runtime
asset was absent, the emitter's output path was not set, and the run reads
green all the same. The two honest shapes are `try #require(...)` for a
resource the repository tracks (its absence fails the test) and a visible
`TestGate.skip(...)` before the `return` for an environmental gate (a
warning-severity issue in the xcresult, never a failure).

Modes
  --lint <file.swift>...   one line per offence, `path:line: message`;
                           exit 1 when any offence was found. This is what
                           `Scripts/audit-lint.sh` (AL-5) runs over staged
                           test files, keeping the offences whose guard line
                           the commit added.
  --census [repo-root]     the whole-tree report: per-target counts, the
                           per-file table and the inventory of every silent
                           test with the guard condition it exits on.
  --tags [repo-root]       the `.tags(...)` census: occurrences per tag and
                           the number of tests in files whose suite carries
                           the tag.

The classifier is body-aware, not pattern-based: comments and string
literals are blanked first; every `@Test` function (and every XCTest
`func test…`) is walked with a brace stack; a `return` inside a closure, a
trailing closure, a nested func or a computed property does not exit the
test and is ignored; a `return` at test scope before the first
assertion-like token (`#expect`, `#require`, `XCTAssert…`, `XCTFail`,
`Issue.record`, `withKnownIssue`, `confirmation`, `TestGate.skip`, a
`throw`, `fatalError`) is the offence. A file-local helper whose own body records
the outcome (a `skipNER`-style printer that calls `TestGate.skip`) counts as
assertion-like for that file — one hop, no deeper. The same-line marker
`SilentGuard:ok <reason>` on the guard's line exempts it (a migration aid,
not a style).

Stdlib only; python3 on the host and on the CI runner.
"""
import os
import re
import sys
from collections import defaultdict, Counter

MARKER = 'SilentGuard:ok'

TARGET_DIRS = [
    ("RedactionEngineTests (SPM)", "Packages/RedactionEngine/Tests/RedactionEngineTests"),
    ("ResectaAppTests (unit)",     "Tests/ResectaAppTests"),
    ("ResectaAppUITests (XCUI)",   "Tests/ResectaAppUITests"),
]


# ---------------------------------------------------------------- lexing ----
def blank_noncode(src: str) -> str:
    """Replace comments and string-literal interiors with spaces, preserving
    offsets and newlines so line numbers and positions stay exact."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                out[i] = ' '; i += 1
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            depth = 1; out[i] = out[i + 1] = ' '; i += 2
            while i < n and depth:
                if src[i] == '/' and i + 1 < n and src[i + 1] == '*':
                    depth += 1; out[i] = out[i + 1] = ' '; i += 2; continue
                if src[i] == '*' and i + 1 < n and src[i + 1] == '/':
                    depth -= 1; out[i] = out[i + 1] = ' '; i += 2; continue
                if src[i] != '\n':
                    out[i] = ' '
                i += 1
        elif c == '"':
            # raw strings  #"..."#  / ##"..."##
            hashes = 0
            j = i - 1
            while j >= 0 and src[j] == '#':
                hashes += 1; j -= 1
            if src.startswith('"""', i):
                i += 3
                while i < n and not src.startswith('"""', i):
                    if src[i] != '\n':
                        out[i] = ' '
                    i += 1
                i = min(i + 3, n)
            else:
                out[i] = ' '; i += 1
                closing = '"' + ('#' * hashes)
                while i < n:
                    if src[i] == '\\' and hashes == 0:
                        out[i] = ' '
                        if i + 1 < n and src[i + 1] != '\n':
                            out[i + 1] = ' '
                        i += 2; continue
                    if src.startswith(closing, i):
                        for k in range(len(closing)):
                            out[i + k] = ' '
                        i += len(closing); break
                    if src[i] != '\n':
                        out[i] = ' '
                    i += 1
        else:
            i += 1
    return ''.join(out)


# ------------------------------------------------------------- patterns ----
# Assertion-like tokens. XCTSkip, Issue.record and TestGate.skip are VISIBLE
# outcomes, so a path reaching them is not silent — they count as assertions.
ASSERT_RE = re.compile(
    r'(?<![A-Za-z0-9_])('
    r'#expect|#require|'
    r'XCTAssert[A-Za-z]*|XCTFail|XCTUnwrap|XCTSkip[A-Za-z]*|'
    r'Issue\.record|'
    r'TestGate\.skip|'
    r'withKnownIssue|'
    r'confirmation'
    r')(?![A-Za-z0-9_])'
)
THROW_RE  = re.compile(r'(?<![A-Za-z0-9_])throw(?![A-Za-z0-9_])')
FATAL_RE  = re.compile(r'(?<![A-Za-z0-9_])(fatalError|preconditionFailure)(?![A-Za-z0-9_])')
RETURN_RE = re.compile(r'(?<![A-Za-z0-9_.])return(?![A-Za-z0-9_])')
GUARD_RE  = re.compile(r'(?<![A-Za-z0-9_])guard(?![A-Za-z0-9_])')

CONTROL_KEYWORDS = {'if', 'else', 'guard', 'for', 'while', 'switch',
                    'do', 'repeat', 'catch', 'defer'}
CONT_LEADERS = {'where', 'in', 'else', 'catch', '&&', '||', '?', ':', '.', ','}
# A line ending in one of these continues onto the next. `{` is NOT a
# continuation: a line after `if x {` is the block's first statement, and
# treating it as part of the condition read `if x {` + `Task { in` as one
# control opener (the closure's `return` was then charged to the test).
CONT_TAILS = (',', '(', '[', '=', '&&', '||', '+', '-', '->', '?', ':', '.',
              '&', '|', '<', '>', '*', '/')


def _joined_head(text, end):
    """The logical line that ends at `end`: the physical line plus the
    preceding lines it continues (up to six)."""
    lo = max(0, end - 900)
    lines = text[lo:end].split('\n')
    acc = [lines[-1]]
    k = len(lines) - 2
    while k >= 0 and len(acc) < 6:
        head = acc[0].strip()
        first = head.split()[0] if head.split() else ''
        prev = lines[k].rstrip()
        cont = (first in CONT_LEADERS or head == ''
                or prev.endswith(CONT_TAILS))
        if not cont:
            break
        acc.insert(0, lines[k])
        k -= 1
    return ' '.join(x.strip() for x in acc).strip()


def brace_opener_kind(body, i):
    """Classify the `{` at body[i] as 'control' / 'guard-else' / 'other'.

    'other' covers closures, trailing closures, nested func/type bodies and
    computed properties — anything whose `return` does NOT exit the test.
    """
    block = _joined_head(body, i)
    # strip leading closers / labels
    block = re.sub(r'^[})\]]+\s*', '', block)
    block = re.sub(r'^\w+\s*:\s*(?=(while|for|repeat|switch)\b)', '', block)
    m = re.match(r'([A-Za-z_][A-Za-z0-9_]*)', block)
    first = m.group(1) if m else ''
    if first not in CONTROL_KEYWORDS:
        return 'other'
    if first == 'guard':
        return 'guard-else' if re.search(r'\belse\b\s*$', block) else 'other'
    return 'control'


def match_brace(code, open_idx):
    depth, i, n = 0, open_idx, len(code)
    while i < n:
        if code[i] == '{':
            depth += 1
        elif code[i] == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


# --------------------------------------------------- test-function finder ----
FUNC_RE = re.compile(r'(?<![A-Za-z0-9_])func\s+([A-Za-z_][A-Za-z0-9_]*)\s*[(<]')


def find_tests(code, raw):
    """Every test function in the file: the decl after each `@Test`
    attribute, and every XCTest `func test…`. Funcs nested inside another
    test's body are dropped."""
    cands = []
    for am in re.finditer(r'(?<![A-Za-z0-9_])@Test(?![A-Za-z0-9_])', code):
        fm = FUNC_RE.search(code, am.end())
        if not fm:
            continue
        gap = code[am.end():fm.start()]
        if re.search(r'(?<![A-Za-z0-9_])func(?![A-Za-z0-9_])', gap):
            continue
        cands.append((fm, 'swift-testing'))
    for fm in FUNC_RE.finditer(code):
        if fm.group(1).startswith('test'):
            cands.append((fm, 'xctest'))
    seen, tests = set(), []
    for fm, kind in cands:
        if fm.start() in seen:
            continue
        seen.add(fm.start())
        ob = code.find('{', fm.end() - 1)
        if ob < 0:
            continue
        cb = match_brace(code, ob)
        if cb < 0:
            continue
        tests.append({
            'name': fm.group(1),
            'kind': kind,
            'decl_line': raw.count('\n', 0, fm.start()) + 1,
            'decl_pos': fm.start(),
            'body_start': ob + 1,
            'body_end': cb,
        })
    tests.sort(key=lambda t: t['decl_pos'])
    keep = []
    for t in tests:
        if any(k['body_start'] < t['decl_pos'] < k['body_end'] for k in keep):
            continue
        keep.append(t)
    return keep


def delegating_helpers(code):
    """Names of the file's own funcs whose body contains an assertion-like
    token: a call to one of them is visible, one hop from the test."""
    names = set()
    for fm in FUNC_RE.finditer(code):
        ob = code.find('{', fm.end() - 1)
        if ob < 0:
            continue
        cb = match_brace(code, ob)
        if cb < 0:
            continue
        if ASSERT_RE.search(code, ob, cb):
            names.add(fm.group(1))
    return names


def helper_call_re(names):
    if not names:
        return None
    alt = '|'.join(re.escape(n) for n in sorted(names))
    return re.compile(r'(?<![A-Za-z0-9_.])(?:Self\.|self\.)?(' + alt + r')\s*\(')


def classify(code, t, helpers_re=None):
    body = code[t['body_start']:t['body_end']]
    base = t['body_start']

    assert_hits = [(m.start(), m.group(0)) for m in ASSERT_RE.finditer(body)]
    if helpers_re is not None:
        assert_hits += [(m.start(), m.group(1)) for m in helpers_re.finditer(body)]
    throw_hits  = [(m.start(), 'throw') for m in THROW_RE.finditer(body)]
    fatal_hits  = [(m.start(), m.group(0)) for m in FATAL_RE.finditer(body)]
    all_asserts = sorted(assert_hits + throw_hits + fatal_hits)

    t['n_assert'] = len(all_asserts)
    t['first_assert'] = all_asserts[0][0] if all_asserts else None

    stack = []          # ('closure'|'control'|'guard-else'|'other', open_pos)
    early = []
    ret_positions = {m.start() for m in RETURN_RE.finditer(body)}
    i = 0
    while i < len(body):
        ch = body[i]
        if ch == '{':
            stack.append((brace_opener_kind(body, i), i))
            i += 1; continue
        if ch == '}':
            if stack:
                stack.pop()
            i += 1; continue
        if i in ret_positions:
            in_closure = any(k == 'other' for k, _ in stack)
            enclosing = stack[-1] if stack else None
            early.append({'pos': i, 'in_closure': in_closure,
                          'guard_else': bool(enclosing and enclosing[0] == 'guard-else'),
                          'depth': len(stack),
                          'open': enclosing[1] if enclosing else None})
        i += 1

    fa = t['first_assert']
    silent_exits = []
    for e in early:
        if e['in_closure']:
            continue
        if e['depth'] == 0:
            if fa is not None and e['pos'] < fa:
                silent_exits.append(e)
            continue
        if fa is None:
            continue           # the NO-ASSERT bucket, not this rule
        if e['pos'] < fa:
            silent_exits.append(e)
    t['silent_exits'] = silent_exits
    t['silent'] = bool(silent_exits)
    t['no_assert'] = (t['n_assert'] == 0)
    if silent_exits:
        e = silent_exits[0]
        t['first_exit_abs'] = e['pos'] + base
        ob = e['open']
        if ob is not None:
            t['guard_abs'] = ob + base
            t['cond'] = re.sub(r'\s+', ' ', _joined_head(body, ob)).strip()[:150]
        else:
            t['guard_abs'] = t['first_exit_abs']
            t['cond'] = ''
    return t


def _line(raw, pos):
    return raw.count('\n', 0, pos) + 1


# ------------------------------------------------------------------ lint ----
def lint(paths):
    """Print one line per offence; return the offence count."""
    bad = 0
    for p in paths:
        try:
            raw = open(p, encoding='utf-8', errors='replace').read()
        except OSError as e:
            print(f"{p}:0: cannot read ({e})", file=sys.stderr)
            bad += 1
            continue
        lines = raw.splitlines()
        code = blank_noncode(raw)
        helpers = helper_call_re(delegating_helpers(code))
        for t in find_tests(code, raw):
            classify(code, t, helpers)
            if not t['silent']:
                continue
            guard_ln = _line(raw, t['guard_abs'])
            exit_ln = _line(raw, t['first_exit_abs'])
            if any(MARKER in lines[i - 1]
                   for i in range(guard_ln, min(exit_ln, len(lines)) + 1)):
                continue
            assert_ln = _line(raw, t['body_start'] + t['first_assert'])
            print(f"{p}:{guard_ln}: silent test guard — `{t['name']}` returns at "
                  f":{exit_ln} before its first assertion at :{assert_ln} and can "
                  f"report PASS with zero assertions; use `try #require` for a "
                  f"tracked resource or `TestGate.skip(...)` before the return "
                  f"for an environmental gate")
            bad += 1
    return bad


# ---------------------------------------------------------------- census ----
def walk_targets(root):
    for tname, rel in TARGET_DIRS:
        tdir = os.path.join(root, rel)
        if not os.path.isdir(tdir):
            print(f"!! target dir not found: {tdir}")
            continue
        for dirpath, _dirs, files in os.walk(tdir):
            for f in sorted(files):
                if f.endswith('.swift'):
                    yield tname, os.path.join(dirpath, f)


def census(root):
    results = defaultdict(list)
    per_file = defaultdict(lambda: {'tests': 0, 'silent': 0, 'noassert': 0})
    files_per_target = defaultdict(list)

    for tname, path in walk_targets(root):
        raw = open(path, encoding='utf-8', errors='replace').read()
        code = blank_noncode(raw)
        files_per_target[tname].append(path)
        rel = os.path.relpath(path, root)
        helpers = helper_call_re(delegating_helpers(code))
        for t in find_tests(code, raw):
            classify(code, t, helpers)
            t['file'] = path
            if 'first_exit_abs' in t:
                t['exit_line'] = _line(raw, t['first_exit_abs'])
                t['guard_line'] = _line(raw, t['guard_abs'])
            if t['first_assert'] is not None:
                t['assert_line'] = _line(raw, t['body_start'] + t['first_assert'])
            results[tname].append(t)
            per_file[(tname, rel)]['tests'] += 1
            per_file[(tname, rel)]['silent'] += int(t['silent'])
            per_file[(tname, rel)]['noassert'] += int(t['no_assert'])

    bar = "=" * 78
    print(bar); print("TEST-TARGET MAP"); print(bar)
    total_silent = 0
    for tname, rel in TARGET_DIRS:
        ts = results[tname]
        n_silent = sum(1 for t in ts if t['silent'])
        total_silent += n_silent
        print(f"\n{tname}")
        print(f"  dir                : {rel}")
        print(f"  .swift files       : {len(files_per_target[tname])}")
        print(f"  files w/ tests     : {len({t['file'] for t in ts})}")
        print(f"  test functions     : {len(ts)}"
              f"   (@Test {sum(1 for t in ts if t['kind']=='swift-testing')}"
              f" / XCTest func test… {sum(1 for t in ts if t['kind']=='xctest')})")
        print(f"  SILENT             : {n_silent}")
        print(f"  NO-ASSERT (smoke)  : {sum(1 for t in ts if t['no_assert'])}")
    print(f"\nSILENT total: {total_silent}")

    print("\n" + bar); print("SILENT tests, per file (silent/tests  file)"); print(bar)
    rows = [(k[0], k[1], v) for k, v in per_file.items() if v['silent']]
    rows.sort(key=lambda r: (-r[2]['silent'], r[1]))
    for tn, rel, v in rows:
        print(f"  {v['silent']:3d}/{v['tests']:<3d}  {rel}")
    print(f"  ---- files with >=1 silent: {len(rows)}")

    print("\n" + bar); print("SILENT TEST INVENTORY (file:guard-line  name  [exit -> first assert])"); print(bar)
    for tname, _ in TARGET_DIRS:
        ts = [t for t in results[tname] if t['silent']]
        print(f"\n--- {tname}  ({len(ts)}) ---")
        for t in sorted(ts, key=lambda x: (x['file'], x['decl_line'])):
            rel = os.path.relpath(t['file'], root)
            print(f"  {rel}:{t['guard_line']}  {t['name']}"
                  f"  [exit L{t['exit_line']} -> 1st assert L{t.get('assert_line')}]")
            print(f"        cond: {t.get('cond', '')}")

    print("\n" + bar); print("NO-ASSERT TEST INVENTORY"); print(bar)
    for tname, _ in TARGET_DIRS:
        ts = [t for t in results[tname] if t['no_assert']]
        print(f"\n--- {tname}  ({len(ts)}) ---")
        for t in sorted(ts, key=lambda x: (x['file'], x['decl_line'])):
            print(f"  {os.path.relpath(t['file'], root)}:{t['decl_line']}  {t['name']}")
    return total_silent


def tags(root):
    tagpat = re.compile(r'\.tags\(([^)]*)\)')
    tag_counts = Counter()
    suites = []
    tests_per_file = Counter()
    for tname, path in walk_targets(root):
        raw = open(path, encoding='utf-8', errors='replace').read()
        code = blank_noncode(raw)
        tests_per_file[path] = len(find_tests(code, raw))
        for m in tagpat.finditer(code):
            ln = _line(raw, m.start())
            found = re.findall(r'\.(\w+)', m.group(1))
            line = raw.splitlines()[ln - 1].strip()
            scope = 'suite' if '@Suite' in line else ('test' if '@Test' in line else 'other')
            for tg in found:
                tag_counts[tg] += 1
            suites.append((os.path.relpath(path, root), ln, scope, found, path))
    print("tag occurrences:", dict(sorted(tag_counts.items())))
    cover = Counter()
    for rel, ln, scope, found, path in suites:
        if scope != 'suite':
            continue
        for tg in found:
            cover[tg] += tests_per_file[path]
    print("tests in files whose suite carries the tag:", dict(sorted(cover.items())))
    for rel, ln, scope, found, _ in sorted(suites):
        print(f"  {rel}:{ln} [{scope}] {found}")


# ------------------------------------------------------------------ main ----
def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__.strip())
        return 64
    mode, rest = argv[0], argv[1:]
    default_root = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
    if mode == '--lint':
        if not rest:
            print("--lint needs at least one file", file=sys.stderr)
            return 64
        return 1 if lint(rest) else 0
    if mode == '--census':
        root = rest[0] if rest else default_root
        return 1 if census(root) else 0
    if mode == '--tags':
        tags(rest[0] if rest else default_root)
        return 0
    # bare paths = lint
    return 1 if lint(argv) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
