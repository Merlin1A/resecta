#!/usr/bin/env bash
# pre-push.sh — local push-time test gate.
#
# Reads git's ref lines on stdin (<local ref> <local sha> <remote ref>
# <remote sha>) and, for each pushed commit, runs the test schemes the change
# touches through Scripts/test-batched.sh — build once, then serial
# suite-level batches on the pinned simulator, each under a watchdog — unless
# the runner's passing verdict for the same tree is already on disk.
# Installed as .git/hooks/pre-push by Scripts/install-hooks.sh. Measured
# wall-clock on an Apple-silicon dev machine (2026-08-27): ≈ 16 minutes for
# both schemes (engine ≈ 7, app ≈ 9).
#
# In order:
#   1. The stale-project check. ResectaApp.xcodeproj is generated from
#      project.yml and not tracked, so a project generated before a file was
#      added, moved or removed builds the wrong file set. A scratch
#      `xcodegen generate --project <temp dir>` is compared with the live
#      project.pbxproj by their sorted `path = …;` references: XcodeGen's
#      output is byte-identical run to run, but a project generated into
#      another directory spells its paths relative to that directory, so the
#      two files are never byte-equal and the references are compared after
#      re-rooting them (the signing-team lines a regenerate drops carry no
#      path). A difference refuses the push and prints the regenerate
#      commands; no xcodegen on PATH is a printed warning, not a refusal.
#   2. Scheme by diff. The pushed commit is diffed against its merge base with
#      the LOCAL origin/main (never fetched) and each path is classed:
#        engine       Packages/RedactionEngine/**, xcschemes/RedactionEngine.xcscheme
#                     → both schemes (the app links the engine)
#        app          Sources/**, Tests/**, UITestFixtures/**, Resources/**,
#                     project.yml, regenerate.sh, xcschemes/ResectaApp.xcscheme,
#                     EULA.md, PRIVACY.md (bundled by project.yml) → ResectaApp
#        no-scheme    other *.md, LICENSE, NOTICE, .github/**, .gitignore,
#                     .gitattributes, Makefile, Scripts/** → no scheme; a
#                     Scripts/** path runs the two scripts' --self-test
#        unclassified anything else → both schemes (each path printed)
#      PREPUSH_SCHEME_BY_DIFF=0 needs both schemes for every push.
#   3. Verdict acceptance. A needed scheme is not re-run when a verdict.json
#      under /tmp/test-batched-<scheme>-*/ or $TEST_BATCHED_VERDICT_DIR
#      (depth ≤ 3) was written by test-batched.sh for that scheme with
#      VERDICT PASS on the pushed commit's tree (a rebase that keeps the tree
#      keeps the verdict), started and ended with clean tracked files on one
#      commit, ran on $TEST_BATCHED_SIM_UDID whose runtime build is still the
#      same, under the same Xcode build, and names a run dir whose `nonce` and
#      `summary.txt` still match it (the re-read a hand-written verdict
#      without its run dir fails). Each acceptance and each rejection of a
#      verdict for the same tree is printed.
#   4. The runs. The runner tests the working tree, so a needed scheme with no
#      accepted verdict runs only when the pushed commit is this checkout's
#      HEAD and no tracked file is modified; otherwise the push is refused.
#
# Each pushed commit ends with one summary line:
#   → pre-push: diff <base8>..<sha8>: engine <n> · app <n> · no-scheme <n> ·
#     unclassified <n> → needed <list> · accepted <list> · ran <list>
#
# The runner's exit code decides a run: 0 (no gating red) allows the push;
# 1 (a gating suite is red — the offenders are printed) and 2 (an invocation
# wedged or was cut by the watchdog, so its suites went unverified) both
# block it. A direct `xcodebuild test -scheme …` is deliberately NOT used
# here: one xctest process with in-process Swift Testing concurrency has
# wedged the simulator runtime machine-wide (the runner's header records the
# history). The perf-budget suites, the multi-minute stress suite among
# them, run alone and report-only inside the runner; `make stress-baseline`
# is unchanged.
#
# Bypass: SKIP_TESTS=1 env override for hotfix workflows. The
# skip is LOGGED to stderr — never a silent no-op — so the bypass stays
# visible in the push transcript. This is deliberately distinct from
# `git push --no-verify`, which suppresses the hook without leaving any
# trace; prefer SKIP_TESTS=1 so the skip is auditable.
#
# Self-test: Scripts/pre-push.sh --self-test — scratch repositories, a stub
# runner and stub xcrun/xcodebuild; no simulator.
set -euo pipefail

ZERO_RE='^0+$'
BASE_REF=refs/remotes/origin/main

classify() { # path → engine | app | none | unclassified
    case "$1" in
        Packages/RedactionEngine/*|xcschemes/RedactionEngine.xcscheme) echo engine ;;
        Sources/*|Tests/*|UITestFixtures/*|Resources/*|project.yml|regenerate.sh|\
        xcschemes/ResectaApp.xcscheme|EULA.md|PRIVACY.md) echo app ;;
        *.md|LICENSE|NOTICE|.github/*|.gitignore|.gitattributes|Makefile|Scripts/*) echo none ;;
        *) echo unclassified ;;
    esac
}

join_list() { # words → comma-joined, or "none"
    local out="" w
    for w in "$@"; do out="${out:+$out,}$w"; done
    echo "${out:-none}"
}

# The live project's `path = …;` references against a scratch generation's,
# re-rooted: prints "fresh <n>" or one "only in …" line per difference.
compare_project_refs() { # live-pbxproj scratch-pbxproj repo-root scratch-dir
    python3 - "$@" <<'PYEOF'
import collections, os, re, sys
live, scratch, root, sdir = sys.argv[1:5]
PATH_RE = re.compile(r'\bpath = ("(?:[^"\\]|\\.)*"|[^;]*);')
prefixes = [re.compile(r'^(?:\.\./)+' + re.escape(r.lstrip('/')) + r'(?:/|$)')
            for r in {root, os.path.realpath(root)}]
rels = {os.path.relpath(root, sdir), os.path.relpath(os.path.realpath(root), os.path.realpath(sdir))}

def refs(path, reroot):
    out = collections.Counter()
    for m in PATH_RE.finditer(open(path, encoding='utf-8', errors='replace').read()):
        v = m.group(1)
        if v.startswith('"'):
            v = v[1:-1]
        if reroot:
            for p in prefixes:
                v = p.sub('', v, count=1)
            for r in rels:
                if v == r:
                    v = ''
                elif v.startswith(r + '/'):
                    v = v[len(r) + 1:]
        out[v or '.'] += 1
    return out

a, b = refs(live, False), refs(scratch, True)
if a == b:
    print('fresh %d' % sum(a.values()))
    sys.exit(0)
for k in sorted(set(a) | set(b)):
    if a[k] > b[k]:
        print('only in the live project: ' + k)
    elif b[k] > a[k]:
        print('only in a fresh generation: ' + k)
PYEOF
}

stale_check() { # → 0 fresh or warned, 1 stale (printed)
    if ! command -v xcodegen >/dev/null 2>&1; then
        echo "⚠  pre-push: WARN xcodegen is not on PATH — the stale-project check did not run" >&2
        return 0
    fi
    local scratch proj live out n team
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/pre-push-xcodegen.XXXXXX")"
    if ! out="$(xcodegen generate --spec project.yml --project "$scratch" --quiet 2>&1)"; then
        echo "✗ pre-push: xcodegen could not generate project.yml — push refused:" >&2
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        rm -rf "$scratch"; return 1
    fi
    proj="$(cd "$scratch" && ls -d ./*.xcodeproj 2>/dev/null | sed -n '1s#^\./##p' || true)"
    if [ -z "$proj" ]; then
        echo "✗ pre-push: xcodegen generated no .xcodeproj from project.yml — push refused." >&2
        rm -rf "$scratch"; return 1
    fi
    live="$proj/project.pbxproj"
    if [ ! -f "$live" ]; then
        echo "✗ pre-push: no generated project at $live — push refused. Run:" >&2
        echo "    ./regenerate.sh" >&2
        rm -rf "$scratch"; return 1
    fi
    if ! out="$(compare_project_refs "$live" "$scratch/$live" "$PWD" "$scratch" 2>&1)"; then
        echo "✗ pre-push: the path-reference comparison failed — push refused:" >&2
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        rm -rf "$scratch"; return 1
    fi
    rm -rf "$scratch"
    case "$out" in
        fresh\ *)
            echo "→ pre-push: generated project matches project.yml (${out#fresh } path references)" >&2
            return 0 ;;
    esac
    team="$(awk '/^[[:space:]]*DEVELOPMENT_TEAM = [A-Z0-9]+;$/ { sub(/.*= /, ""); sub(/;$/, ""); print; exit }' "$live")"
    n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
    echo "✗ pre-push: $live is stale against project.yml ($n path reference(s) differ) — push refused:" >&2
    printf '%s\n' "$out" | awk 'NR <= 20 { print "    " $0 } NR == 21 { print "    …" }' >&2
    echo "  Regenerate it, restore the signing team, and push again:" >&2
    echo "    ./regenerate.sh" >&2
    echo "    perl -0pi -e 's/^(\\t*)(MARKETING_VERSION = [^;]+;)/\$1\$2\\n\$1DEVELOPMENT_TEAM = ${team:-<team id>};/mg' $live" >&2
    return 1
}

# Prints "ACCEPT <path> <VERDICT line>" for the newest acceptable verdict,
# "REJECT <path> <reason>" for each verdict on the same tree it passed over,
# and "COUNT <read> <same tree>" (tab-separated).
read_verdicts() { # scheme tree
    python3 - "$1" "$2" "${TEST_BATCHED_SIM_UDID:-}" "${TEST_BATCHED_VERDICT_DIR:-}" <<'PYEOF'
import glob, json, os, re, subprocess, sys
scheme, tree, udid, vdir = sys.argv[1:5]

def run(*argv):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=120).stdout
    except Exception:
        return ""

def runtime_build_now(u):  # the runner's lookup: every available runtime on the identifier
    try:
        devices = json.loads(run("xcrun", "simctl", "list", "devices", "-j"))["devices"]
        runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
    except Exception:
        return None
    rid = next((k for k, ds in devices.items() for d in ds if d.get("udid") == u), None)
    match = [r for r in runtimes if rid and r.get("identifier") == rid and r.get("isAvailable", True)]
    return "+".join(sorted(str(r.get("buildversion")) for r in match)) if match else None

now = {}
def current(key):
    if key not in now:
        if key == "runtime":
            now[key] = runtime_build_now(udid) if udid else None
        else:
            m = re.search(r"Build version (\S+)", run("xcodebuild", "-version"))
            now[key] = m.group(1) if m else None
    return now[key]

paths = glob.glob("/tmp/test-batched-%s-*/verdict.json" % scheme)
if vdir and os.path.isdir(vdir):
    for dp, dns, fns in os.walk(vdir):
        rel = os.path.relpath(dp, vdir)
        depth = 0 if rel == "." else rel.count(os.sep) + 1
        if depth >= 2:
            dns[:] = []
        if "verdict.json" in fns:
            paths.append(os.path.join(dp, "verdict.json"))

def why_not(d):
    if d.get("verdict") != "PASS":
        return "verdict is %s, not PASS" % d.get("verdict")
    if not (d.get("tracked_clean_start") is True and d.get("tracked_clean_end") is True):
        return "tracked files were modified at the run's start or end"
    if not d.get("head") or d.get("head") != d.get("head_end"):
        return "the run started and ended on different commits"
    sim = d.get("sim") or {}
    if not udid:
        return "TEST_BATCHED_SIM_UDID is unset, so no simulator to match"
    if sim.get("udid") != udid:
        return "ran on simulator %s, not %s" % (sim.get("udid"), udid)
    if not sim.get("runtime_build") or sim.get("runtime_build") != current("runtime"):
        return "runtime build %s, now %s" % (sim.get("runtime_build"), current("runtime"))
    if not d.get("xcode_build") or d.get("xcode_build") != current("xcode"):
        return "Xcode build %s, now %s" % (d.get("xcode_build"), current("xcode"))
    rd = d.get("run_dir") or ""
    try:
        nonce = open(os.path.join(rd, "nonce")).read().strip()
    except OSError:
        return "its run dir %s holds no nonce" % (rd or "(none)")
    if not d.get("nonce") or nonce != d.get("nonce"):
        return "the nonce in %s does not match" % rd
    try:
        summary = open(os.path.join(rd, "summary.txt")).read().splitlines()
    except OSError:
        return "its run dir %s holds no summary.txt" % rd
    if not d.get("summary_lines") or summary != d.get("summary_lines"):
        return "summary.txt in %s does not match its summary lines" % rd
    return None

seen = same = 0
accepted = None
for p in sorted(set(paths), key=lambda p: os.path.getmtime(p), reverse=True):
    try:
        d = json.load(open(p))
    except Exception:
        continue
    if not isinstance(d, dict) or d.get("source") != "test-batched.sh" or d.get("scheme") != scheme:
        continue
    seen += 1
    if d.get("tree") != tree:
        continue
    same += 1
    if accepted:
        continue
    reason = why_not(d)
    if reason:
        print("REJECT\t%s\t%s" % (p, reason))
    else:
        accepted = p
        lines = [l for l in d["summary_lines"] if l.startswith("VERDICT:")]
        print("ACCEPT\t%s\t%s" % (p, lines[-1] if lines else "(no VERDICT line)"))
print("COUNT\t%d\t%d" % (seen, same))
PYEOF
}

accept_verdict() { # scheme tree → 0 when a verdict is accepted (every outcome printed)
    local out kind p rest rc=1 tab
    tab="$(printf '\t')"
    if ! out="$(read_verdicts "$1" "$2")"; then
        echo "⚠  pre-push: $1: the verdict reader failed — no verdict accepted" >&2
        return 1
    fi
    while IFS="$tab" read -r kind p rest; do
        case "$kind" in
            ACCEPT) echo "→ pre-push: $1: accepted $p ($rest)" >&2; rc=0 ;;
            REJECT) echo "→ pre-push: $1: not accepted $p — $rest" >&2 ;;
            COUNT)  echo "→ pre-push: $1: $p verdict file(s) read, $rest for tree ${2:0:8}" >&2 ;;
        esac
    done <<EOF
$out
EOF
    return "$rc"
}

run_scheme() { # scheme
    echo "→ pre-push: running $1 tests via the batched runner…" >&2
    local rc=0
    Scripts/test-batched.sh "$1" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "✗ pre-push: $1 batched run exited $rc (1 = gating red, 2 = incomplete) — push blocked." >&2
        exit "$rc"
    fi
}

run_self_tests() { # the two scripts' own checks, for a change under Scripts/
    local s rc
    for s in Scripts/test-batched.sh Scripts/pre-push.sh; do
        echo "→ pre-push: running $s --self-test…" >&2
        rc=0
        "$s" --self-test >&2 || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "✗ pre-push: $s --self-test exited $rc — push blocked." >&2
            exit 1
        fi
    done
}

# ── --self-test ───────────────────────────────────────────────────────────
# Drives this script, unmodified, through scratch repositories: a stub runner
# and stub pre-push.sh under the scratch Scripts/ log what would have run, and
# stub xcrun/xcodebuild report a simulator runtime and an Xcode build. The
# real xcodegen builds the scratch projects (its rules are skipped, printed,
# when it is absent). No simulator is used.
self_test() {
    local me t repo fails=0 out rc base tree h x
    me="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    # A hook's environment can carry GIT_DIR and friends; the scratch
    # repositories must never resolve to the repository under test.
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR \
        GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
    t="$(mktemp -d "${TMPDIR:-/tmp}/pre-push-selftest.XXXXXX")"
    trap 'rm -rf "$t"' EXIT
    repo="$t/repo"
    mkdir -p "$t/bin" "$t/verdicts" "$repo/Sources" "$repo/Packages/RedactionEngine" "$repo/Scripts"

    cat > "$t/bin/xcrun" <<'EOF'
#!/bin/sh
case "$*" in
    "simctl list devices -j") echo '{"devices": {"rt.selftest": [{"udid": "SELF-TEST-UDID"}]}}' ;;
    "simctl list runtimes -j") printf '{"runtimes": [{"identifier": "rt.selftest", "version": "1.0", "buildversion": "%s", "isAvailable": true}]}\n' "${STUB_RUNTIME_BUILD:-R1}" ;;
    *) exit 1 ;;
esac
EOF
    cat > "$t/bin/xcodebuild" <<'EOF'
#!/bin/sh
[ "$1" = "-version" ] || exit 1
printf 'Xcode 0\nBuild version %s\n' "${STUB_XCODE_BUILD:-X1}"
EOF
    cat > "$repo/Scripts/test-batched.sh" <<'EOF'
#!/bin/sh
echo "test-batched.sh $*" >> "$PREPUSH_SELFTEST_LOG"
[ "$1" = "--self-test" ] && exit 0
exit "${STUB_RUN_RC:-0}"
EOF
    sed 's/test-batched\.sh \$\*/pre-push.sh $*/' "$repo/Scripts/test-batched.sh" > "$repo/Scripts/pre-push.sh"
    chmod +x "$t/bin/xcrun" "$t/bin/xcodebuild" "$repo/Scripts/test-batched.sh" "$repo/Scripts/pre-push.sh"
    printf 'name: SelfTest\ntargets:\n  SelfTest:\n    type: application\n    platform: iOS\n    sources: [Sources]\n' > "$repo/project.yml"
    echo 'let a = 1' > "$repo/Sources/A.swift"
    echo 'let e = 1' > "$repo/Packages/RedactionEngine/E.swift"
    echo '# Self-test' > "$repo/README.md"
    printf '*.xcodeproj/\n' > "$repo/.gitignore"

    g() { git -C "$repo" -c user.name=self-test -c user.email=self-test@example.invalid \
        -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
    git -c init.defaultBranch=main init -q "$repo"
    g add -A && g commit -qm base
    base="$(g rev-parse HEAD)"
    g update-ref refs/remotes/origin/main "$base"
    commit() { # path line message → the new HEAD, committed on top of the base
        g reset -q --hard "$base"
        echo "$2" >> "$repo/$1"
        g add -A && g commit -qm "$3"
        g rev-parse HEAD
    }
    local have_xg=0
    if command -v xcodegen >/dev/null 2>&1; then
        have_xg=1
        (cd "$repo" && xcodegen generate --quiet)
    fi

    # hook <stdin line or ""> [VAR=value...] — this script in the scratch repo.
    hook() {
        local input="$1"; shift
        : > "$t/runs"
        rc=0
        out="$(cd "$repo" && printf '%s\n' "$input" | env -u SKIP_TESTS -u PREPUSH_SCHEME_BY_DIFF \
            TEST_BATCHED_SIM_UDID=SELF-TEST-UDID TEST_BATCHED_VERDICT_DIR="$t/verdicts" \
            PREPUSH_SELFTEST_LOG="$t/runs" PATH="$t/bin:$PATH" "$@" bash "$me" origin self-test 2>&1)" || rc=$?
    }
    line() { echo "refs/heads/topic $1 refs/heads/topic 0000000000000000000000000000000000000000"; }
    check() { # label expected-rc expected-runs fixed-string...
        local label="$1" want="$2" runs="$3" s ok=1 got
        shift 3
        got="$(tr '\n' ';' < "$t/runs")"
        [ "$rc" = "$want" ] && [ "$got" = "$runs" ] || ok=0
        for s in "$@"; do printf '%s\n' "$out" | /usr/bin/grep -qF -- "$s" || ok=0; done
        if [ "$ok" = 1 ]; then echo "self-test: $label OK"; return 0; fi
        echo "self-test: $label FAILED (rc $rc, wanted $want; runs '$got', wanted '$runs'; expected text: $*)" >&2
        printf '%s\n' "$out" | sed 's/^/    | /' >&2
        fails=1
    }
    forge() { # dir [key=json ... | -nonce | nonce-file=text | summary-file=text]
        python3 - "$tree" "$h" "$@" <<'PYEOF'
import json, os, sys
tree, head, d, mods = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
os.makedirs(d, exist_ok=True)
lines = ["totals: tests=1 suites=1 failed=0 known-issues=0 wedged=0 excluded=0",
         "VERDICT: PASS scheme=ResectaApp tests=1 suites=1 known-issues=0 gating-failures=0 excluded=0"]
v = {"source": "test-batched.sh", "scheme": "ResectaApp", "verdict": "PASS", "head": head,
     "head_end": head, "tree": tree, "tracked_clean_start": True, "tracked_clean_end": True,
     "sim": {"udid": "SELF-TEST-UDID", "runtime_version": "1.0", "runtime_build": "R1"},
     "xcode_build": "X1", "run_dir": d, "nonce": "N-1", "summary_lines": lines}
files = {"nonce": "N-1\n", "summary.txt": "\n".join(lines) + "\n"}
for m in mods:
    if m == "-nonce":
        del files["nonce"]; continue
    k, _, val = m.partition("=")
    if k in ("nonce-file", "summary-file"):
        files[{"nonce-file": "nonce", "summary-file": "summary.txt"}[k]] = val + "\n"; continue
    try:
        val = json.loads(val)
    except ValueError:
        pass
    target = v
    *outer, last = k.split(".")
    for o in outer:
        target = target[o]
    target[last] = val
for name, text in files.items():
    open(os.path.join(d, name), "w").write(text)
json.dump(v, open(os.path.join(d, "verdict.json"), "w"))
PYEOF
    }

    # The bypass, an empty push, a delete.
    hook "$(line "$base")" SKIP_TESTS=1
    check "SKIP_TESTS=1 skips the gate, printed" 0 "" "SKIP_TESTS=1 — test gate SKIPPED"
    hook ""
    check "no ref lines on stdin: nothing to test, printed" 0 "" "no commit pushed"
    hook "refs/heads/topic 0000000000000000000000000000000000000000 refs/heads/topic $base"
    check "a delete tests nothing, printed" 0 "" "refs/heads/topic is deleted — nothing to test"

    # The classes, each diffed against the merge base with the local origin/main.
    h="$(commit README.md more docs)"
    hook "$(line "$h")"
    check "stdin read; documentation only: no scheme" 0 "" \
        "→ pre-push: diff ${base:0:8}..${h:0:8}: engine 0 · app 0 · no-scheme 1 · unclassified 0 → needed none · accepted none · ran none"
    [ "$have_xg" = 1 ] && check "stale check: a fresh project passes" 0 "" "generated project matches project.yml"
    hook "$(line "$h")" PREPUSH_SCHEME_BY_DIFF=0
    check "PREPUSH_SCHEME_BY_DIFF=0 needs both schemes" 0 "test-batched.sh RedactionEngine;test-batched.sh ResectaApp;" \
        "PREPUSH_SCHEME_BY_DIFF=0" "→ needed RedactionEngine,ResectaApp · accepted none · ran RedactionEngine,ResectaApp"
    h="$(commit Sources/A.swift 'let b = 2' app)"
    hook "$(line "$h")"
    check "an app-only change runs the app scheme only" 0 "test-batched.sh ResectaApp;" \
        "engine 0 · app 1 · no-scheme 0 · unclassified 0 → needed ResectaApp · accepted none · ran ResectaApp"
    hook "$(line "$h")" STUB_RUN_RC=1
    check "a red run blocks the push" 1 "test-batched.sh ResectaApp;" "ResectaApp batched run exited 1"
    h="$(commit Packages/RedactionEngine/E.swift 'let f = 2' engine)"
    hook "$(line "$h")"
    check "an engine change runs both schemes" 0 "test-batched.sh RedactionEngine;test-batched.sh ResectaApp;" \
        "engine 1 · app 0 · no-scheme 0 · unclassified 0 → needed RedactionEngine,ResectaApp"
    h="$(commit notes.txt note unclassified)"
    hook "$(line "$h")"
    check "an unclassified path runs both schemes, printed" 0 "test-batched.sh RedactionEngine;test-batched.sh ResectaApp;" \
        "unclassified path notes.txt" "unclassified 1 → needed RedactionEngine,ResectaApp"
    h="$(commit Scripts/test-batched.sh '# changed' scripts)"
    hook "$(line "$h")"
    check "a Scripts/ change runs the two self-tests" 0 "test-batched.sh --self-test;pre-push.sh --self-test;" \
        "no-scheme 1 · unclassified 0 → needed self-tests · accepted none · ran self-tests"

    # The runner tests the working tree: a dirty tree, or a commit that is not
    # HEAD, is refused unless a verdict covers it.
    h="$(commit Sources/A.swift 'let c = 3' app)"
    tree="$(g rev-parse "$h^{tree}")"
    echo 'let dirty = 1' >> "$repo/Sources/A.swift"
    hook "$(line "$h")"
    check "a dirty tracked tree is refused" 1 "" "tracked files are modified — push refused"
    g checkout -q -- Sources/A.swift
    echo 'more' >> "$repo/README.md"; g commit -qam 'docs on top'
    hook "$(line "$h")"
    check "a commit that is not HEAD is refused" 1 "" "is not this checkout's HEAD"

    # Verdict acceptance, field by field (the pushed commit is not HEAD, so
    # only an accepted verdict lets it through).
    forge "$t/verdicts/ok/run"
    hook "$(line "$h")"
    check "a matching verdict is accepted in place of a run" 0 "" \
        "ResectaApp: accepted $t/verdicts/ok/run/verdict.json (VERDICT: PASS scheme=ResectaApp" \
        "→ needed ResectaApp · accepted ResectaApp · ran none"
    rm -rf "$t/verdicts"/*
    forge "$t/verdicts/a/b/c"
    hook "$(line "$h")"
    check "a verdict deeper than three levels is not read" 1 "" ", 0 for tree ${tree:0:8}"
    for x in "source=other|, 0 for tree" "scheme=RedactionEngine|, 0 for tree" "tree=0000|, 0 for tree" \
             "verdict=FAIL|verdict is FAIL" "tracked_clean_start=false|tracked files were modified" \
             "tracked_clean_end=false|tracked files were modified" "head_end=0000|different commits" \
             "sim.udid=OTHER|ran on simulator OTHER" "-nonce|holds no nonce" \
             "nonce-file=N-2|does not match" "summary-file=VERDICT: PASS forged|summary.txt in"; do
        rm -rf "$t/verdicts"/*
        forge "$t/verdicts/v" "${x%%|*}"
        hook "$(line "$h")"
        check "verdict refused: ${x%%|*}" 1 "" "${x#*|}"
    done
    rm -rf "$t/verdicts"/*
    forge "$t/verdicts/v"
    hook "$(line "$h")" STUB_RUNTIME_BUILD=R2
    check "verdict refused: the runtime build moved" 1 "" "runtime build R1, now R2"
    hook "$(line "$h")" STUB_XCODE_BUILD=X2
    check "verdict refused: the Xcode build moved" 1 "" "Xcode build X1, now X2"
    hook "$(line "$h")" TEST_BATCHED_SIM_UDID=
    check "verdict refused: no simulator pinned" 1 "" "TEST_BATCHED_SIM_UDID is unset"
    rm -rf "$t/verdicts"/*

    # The stale-project check.
    if [ "$have_xg" = 1 ]; then
        mkdir -p "$t/xa" "$t/xb"
        (cd "$repo" && xcodegen generate --spec project.yml --project "$t/xa" --quiet \
            && xcodegen generate --spec project.yml --project "$t/xb" --quiet)
        if cmp -s "$t/xa/SelfTest.xcodeproj/project.pbxproj" "$t/xb/SelfTest.xcodeproj/project.pbxproj" \
                && ! cmp -s "$t/xa/SelfTest.xcodeproj/project.pbxproj" "$repo/SelfTest.xcodeproj/project.pbxproj" \
                && [ "$(cd "$repo" && compare_project_refs SelfTest.xcodeproj/project.pbxproj \
                    "$t/xa/SelfTest.xcodeproj/project.pbxproj" "$repo" "$t/xa")" = "fresh 3" ]; then
            echo "self-test: xcodegen output is byte-identical run to run; a scratch generation differs from the live file in path spelling only, so the check compares path references OK"
        else
            echo "self-test: xcodegen determinism or the path-reference comparison changed" >&2; fails=1
        fi
        perl -0pi -e 's/^(\t*)(PRODUCT_NAME = [^;]+;)/$1$2\n$1DEVELOPMENT_TEAM = ABCDE12345;/mg' \
            "$repo/SelfTest.xcodeproj/project.pbxproj"
        h="$(commit README.md docs docs)"
        hook "$(line "$h")"
        check "stale check: the signing-team lines are ignored" 0 "" "generated project matches project.yml"
        g reset -q --hard "$base"
        echo 'let n = 1' > "$repo/Sources/New.swift"
        g add -A && g commit -qm 'new file'
        h="$(g rev-parse HEAD)"
        hook "$(line "$h")"
        check "stale check: a project missing a file is refused, with the regenerate commands" 1 "" \
            "is stale against project.yml" "only in a fresh generation: New.swift" "./regenerate.sh" \
            "DEVELOPMENT_TEAM = ABCDE12345;/mg' SelfTest.xcodeproj/project.pbxproj"
        (cd "$repo" && xcodegen generate --quiet)
        hook "$(line "$h")"
        check "stale check: the regenerated project passes" 0 "test-batched.sh ResectaApp;" "generated project matches project.yml"
        if PATH="$t/bin:/usr/bin:/bin:/usr/sbin:/sbin" command -v xcodegen >/dev/null 2>&1; then
            echo "self-test: SKIP no-xcodegen rule — xcodegen is in a system directory"
        else
            hook "$(line "$h")" PATH="$t/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            check "stale check: no xcodegen is a printed warning, not a refusal" 0 "test-batched.sh ResectaApp;" \
                "WARN xcodegen is not on PATH"
        fi
    else
        echo "self-test: SKIP stale-project rules — xcodegen is not on PATH"
    fi

    [ "$fails" -eq 0 ] && { echo "self-test: PASS"; exit 0; }
    echo "self-test: FAIL" >&2; exit 1
}

# ── Main ──────────────────────────────────────────────────────────────────

[ "${1:-}" = "--self-test" ] && self_test

if [ "${SKIP_TESTS:-0}" = "1" ]; then
    echo "⚠  pre-push: SKIP_TESTS=1 — test gate SKIPPED (visible bypass)" >&2
    exit 0
fi

cd "$(git rev-parse --show-toplevel)"

if [ -t 0 ]; then
    echo "pre-push: reads git's ref lines on stdin (<local ref> <local sha> <remote ref> <remote sha>);" >&2
    echo "  run it through git push, or pipe the lines in — nothing was tested." >&2
    exit 64
fi

P_REF=(); P_SHA=()
while read -r lref lsha rref rsha; do
    [ -n "${lsha:-}" ] || continue
    if [[ "$lsha" =~ $ZERO_RE ]]; then
        echo "→ pre-push: $rref is deleted — nothing to test for it" >&2
        continue
    fi
    P_REF+=("$rref")
    P_SHA+=("$(git rev-parse -q --verify "$lsha^{commit}" 2>/dev/null || echo "$lsha")")
done
if [ "${#P_SHA[@]}" -eq 0 ]; then
    echo "→ pre-push: no commit pushed (no ref lines, or deletes only) — nothing to test; push allowed." >&2
    exit 0
fi

stale_check || exit 1

HEAD_SHA="$(git rev-parse -q --verify HEAD 2>/dev/null || true)"
CLEAN=1
[ -z "$(git status --porcelain --untracked-files=no)" ] || CLEAN=0
EMPTY_TREE="$(git hash-object -t tree /dev/null)"

TO_RUN=""; REFUSED=0
P_LINE=(); P_NEED=(); P_ACC=()
i=0
while [ "$i" -lt "${#P_SHA[@]}" ]; do
    sha="${P_SHA[$i]}"; ref="${P_REF[$i]}"
    base="$(git merge-base "$BASE_REF" "$sha" 2>/dev/null || true)"
    if [ -n "$base" ]; then
        base8="${base:0:8}"
    else
        echo "⚠  pre-push: $ref ${sha:0:8} has no merge base with the local origin/main — every tracked path is diffed and both schemes are needed" >&2
        base="$EMPTY_TREE"; base8=none
    fi
    ne=0; na=0; nn=0; nu=0; scripts=0
    files="$(git -c core.quotePath=false diff --name-only "$base" "$sha")"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$(classify "$f")" in
            engine) ne=$((ne + 1)) ;;
            app)    na=$((na + 1)) ;;
            none)   nn=$((nn + 1)); case "$f" in Scripts/*) scripts=1 ;; esac ;;
            *)      nu=$((nu + 1)); echo "→ pre-push: unclassified path $f — both schemes" >&2 ;;
        esac
    done <<EOF
$files
EOF
    need=""
    if [ "${PREPUSH_SCHEME_BY_DIFF:-1}" = "0" ]; then
        echo "→ pre-push: PREPUSH_SCHEME_BY_DIFF=0 — both schemes needed" >&2
        need="RedactionEngine ResectaApp"
    elif [ "$base8" = none ] || [ "$ne" -gt 0 ] || [ "$nu" -gt 0 ]; then
        need="RedactionEngine ResectaApp"
    elif [ "$na" -gt 0 ]; then
        need="ResectaApp"
    fi
    [ "$scripts" -eq 1 ] && need="${need:+$need }self-tests"

    tree="$(git rev-parse "$sha^{tree}")"
    acc=""
    for s in $need; do
        if [ "$s" != self-tests ] && accept_verdict "$s" "$tree"; then acc="$acc $s"; continue; fi
        if [ "$sha" = "$HEAD_SHA" ] && [ "$CLEAN" -eq 1 ]; then
            case " $TO_RUN " in *" $s "*) ;; *) TO_RUN="$TO_RUN $s" ;; esac
            continue
        fi
        if [ "$sha" != "$HEAD_SHA" ]; then why="${sha:0:8} is not this checkout's HEAD (${HEAD_SHA:0:8})"
        else why="tracked files are modified"; fi
        echo "✗ pre-push: $ref ${sha:0:8} needs $s and no passing verdict covers tree ${tree:0:8}; the runner tests the working tree and $why — push refused." >&2
        REFUSED=$((REFUSED + 1))
    done
    P_LINE+=("diff $base8..${sha:0:8}: engine $ne · app $na · no-scheme $nn · unclassified $nu → needed $(join_list $need)")
    P_NEED+=("$need"); P_ACC+=("$acc")
    i=$((i + 1))
done

summary() { # ran-or-not (1 = the needed, unaccepted items ran)
    local j=0 s ran
    while [ "$j" -lt "${#P_LINE[@]}" ]; do
        ran=""
        if [ "$1" = 1 ]; then
            for s in ${P_NEED[$j]}; do
                case " ${P_ACC[$j]} " in *" $s "*) ;; *) ran="$ran $s" ;; esac
            done
        fi
        echo "→ pre-push: ${P_LINE[$j]} · accepted $(join_list ${P_ACC[$j]}) · ran $(join_list $ran)" >&2
        j=$((j + 1))
    done
}

if [ "$REFUSED" -gt 0 ]; then
    summary 0
    echo "✗ pre-push: $REFUSED needed run(s) cannot run here — push blocked. Push from a clean checkout of the commit, or run Scripts/test-batched.sh <scheme> there first." >&2
    exit 1
fi

for s in RedactionEngine ResectaApp self-tests; do
    case " $TO_RUN " in *" $s "*) ;; *) continue ;; esac
    if [ "$s" = self-tests ]; then run_self_tests; else run_scheme "$s"; fi
done

summary 1
echo "→ pre-push: push allowed." >&2
