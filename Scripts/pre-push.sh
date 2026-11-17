#!/usr/bin/env bash
# pre-push.sh — local push-time test gate.
#
# Reads git's ref lines on stdin (<local ref> <local sha> <remote ref>
# <remote sha>) and, for each pushed commit, checks what the change touches:
# an engine change needs a passing host run of the engine's whole test suite
# on the same tree, already on disk, and a compile of the app scheme; an app
# change needs the compile. No simulator is used by default; the hosted
# `sim-suite` check runs the app's suites on every pull request.
# PREPUSH_SCHEME_BY_DIFF=0 brings back the simulator schemes through
# Scripts/test-batched.sh (build once, then serial suite-level batches on the
# pinned simulator, each under a watchdog), for every push.
# Installed as .git/hooks/pre-push by Scripts/install-hooks.sh.
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
#   2. The documented counts. The local origin/main's copy of
#      Scripts/doc-metrics.sh --check runs against the pushed commit's tree
#      (git archive, --check-root); a drifted count refuses the push and
#      prints what the script measured. The hosted gate runs the same check;
#      this shows a miss before the push. A commit whose tree cannot be
#      checked (no README.md, the tree cannot be written out, the script
#      ends without its verdict line) is refused as "could not run"; a local
#      origin/main without the script is a printed warning, not a refusal.
#   3. Needs by diff. The pushed commit is diffed against its merge base with
#      the LOCAL origin/main (never fetched) and each path is classed:
#        engine       Packages/RedactionEngine/**, xcschemes/RedactionEngine.xcscheme
#                     → engine-host and app-build (the app links the engine)
#        app          Sources/**, Tests/**, UITestFixtures/**, Resources/**,
#                     project.yml, regenerate.sh, xcschemes/ResectaApp.xcscheme,
#                     EULA.md, PRIVACY.md (bundled by project.yml) → app-build
#        no-scheme    other *.md, LICENSE, NOTICE, .github/**, .gitignore,
#                     .gitattributes, Makefile, Scripts/** → nothing; a
#                     Scripts/** path runs the two scripts' --self-test
#        unclassified anything else → engine-host and app-build (each path printed)
#      PREPUSH_SCHEME_BY_DIFF=0 needs both simulator schemes, RedactionEngine
#      and ResectaApp, for every push (steps 4 and 5 below).
#   3a. engine-host: the host run is accepted, never made here. A verdict.json
#      under $ENGINE_HOST_VERDICT_DIR (depth ≤ 3) with source
#      "engine-host-run" must name the pushed commit's tree, have started and
#      ended on one commit with clean tracked files, record the full-suite
#      command `swift test --skip-build --no-parallel --skip
#      FileProtectionTests`, and record an Xcode build that its own
#      DEVELOPER_DIR still reports. The hook then reads the run's log itself
#      (its sha256 must match the verdict's): the last "Test run with N tests
#      in M suites" line must count tests and suites, and the issues it records,
#      by file:line, must be exactly the judged rows of the pushed tree's
#      Scripts/engine-host-known-reds.txt (location, count, judged yes/no). A
#      row judged "no" is printed and never decides. A pushed list that
#      differs from origin/main's is printed row by row. With no accepted
#      verdict the push is refused.
#   3b. app-build: `xcodebuild build-for-testing -scheme ResectaApp` for a
#      generic simulator destination, compile only, on this checkout's HEAD
#      with clean tracked files (otherwise the push is refused).
#   4. Verdict acceptance. A needed scheme is not re-run when a verdict.json
#      under /tmp/test-batched-<scheme>-*/ or $TEST_BATCHED_VERDICT_DIR
#      (depth ≤ 3) was written by test-batched.sh for that scheme with
#      VERDICT PASS on the pushed commit's tree (a rebase that keeps the tree
#      keeps the verdict), counted at least one test, started and ended with clean tracked files on one
#      commit, ran on $TEST_BATCHED_SIM_UDID whose runtime build is still the
#      same, under the same Xcode build, and names a run dir whose `nonce` and
#      `summary.txt` still match it (the re-read a hand-written verdict
#      without its run dir fails). Each acceptance and each rejection of a
#      verdict for the same tree is printed.
#   5. The runs. The runner tests the working tree, so a needed scheme with no
#      accepted verdict runs only when the pushed commit is this checkout's
#      HEAD and no tracked file is modified; otherwise the push is refused.
#   6. The record. An allowed push posts a `local-suites` commit status for
#      each pushed commit ("PASS @ tree <tree8>: <schemes>") once GitHub has
#      the commit; a SKIP_TESTS=1 push posts none, so on a pull request a
#      skipped push shows no such check.
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

# The documented counts, for every pushed commit: the local origin/main's copy
# of Scripts/doc-metrics.sh (so a change cannot edit the check it is gated by,
# as in the hosted step) runs with --check-root on the commit's own files,
# written out with git archive into a temporary folder, so the pushed tree is
# checked whatever the working tree holds. The outcome is read from the
# script's exit code and its last line: 0 with "DOC-METRICS OK" passes; 1 with
# "DOC-METRICS FAIL: …" is a stale or unreadable count, refused with the
# script's DRIFT lines; anything else means the check could not run, refused.
count_check() { # → 0 match or warned, 1 refused (printed)
    local base_id j sha tmp p out last rc a_rc t_rc
    local -a paths st
    base_id="$(git log -1 --format='%h, %cs' "$BASE_REF" 2>/dev/null || echo unknown)"
    if ! git cat-file -e "$BASE_REF:Scripts/doc-metrics.sh" 2>/dev/null; then
        echo "⚠  pre-push: WARN origin/main ($base_id) has no Scripts/doc-metrics.sh — the documented counts are not checked" >&2
        return 0
    fi
    cannot() { # sha words [lines]
        echo "✗ pre-push: the documented-count check could not run on the pushed tree of ${1:0:8} (origin/main $base_id's copy of Scripts/doc-metrics.sh): $2. Push refused. Mend the cause; if the check itself is broken, SKIP_TESTS=1 skips every gate and is logged." >&2
        [ -n "${3:-}" ] && printf '%s\n' "$3" | sed 's/^/    | /' >&2
        return 0
    }
    j=0
    while [ "$j" -lt "${#P_SHA[@]}" ]; do
        sha="${P_SHA[$j]}"; j=$((j + 1))
        if ! tmp="$(mktemp -d "${TMPDIR:-/tmp}/pre-push-counts.XXXXXX" 2>/dev/null)" || [ -z "$tmp" ]; then
            cannot "$sha" "cannot make a temporary folder"; return 1
        fi
        trap 'rm -rf "$tmp"' EXIT
        if ! git cat-file -e "$sha:README.md" 2>/dev/null; then
            cannot "$sha" "the pushed tree has no README.md"; rm -rf "$tmp"; trap - EXIT; return 1
        fi
        paths=()
        for p in Packages/RedactionEngine/Sources Packages/RedactionEngine/Tests Sources Tests README.md ENGINEERING.md; do
            git cat-file -e "$sha:$p" 2>/dev/null && paths+=("$p")
        done
        mkdir -p "$tmp/tree"
        git archive "$sha" -- "${paths[@]}" | tar -x -C "$tmp/tree"
        st=("${PIPESTATUS[@]}"); a_rc="${st[0]}"; t_rc="${st[1]:-}"
        if [ "$a_rc" != 0 ] || [ "$t_rc" != 0 ]; then
            cannot "$sha" "cannot write the pushed tree out: git archive rc $a_rc, tar rc $t_rc"; rm -rf "$tmp"; trap - EXIT; return 1
        fi
        if ! git show "$BASE_REF:Scripts/doc-metrics.sh" > "$tmp/doc-metrics.sh" || ! chmod +x "$tmp/doc-metrics.sh"; then
            cannot "$sha" "cannot write out origin/main's copy of the script"; rm -rf "$tmp"; trap - EXIT; return 1
        fi
        rc=0
        out="$("$tmp/doc-metrics.sh" --check-root "$tmp/tree" 2>&1)" || rc=$?
        rm -rf "$tmp"; trap - EXIT
        last="$(printf '%s\n' "$out" | tail -n 1)"
        if [ "$rc" = 0 ] && { [ "$last" = "DOC-METRICS OK" ] || [ "${last#DOC-METRICS OK · }" != "$last" ]; }; then
            echo "→ pre-push: documented counts match the pushed tree of ${sha:0:8} (origin/main $base_id's copy of Scripts/doc-metrics.sh)." >&2
        elif [ "$rc" = 1 ] && [ "${last#DOC-METRICS FAIL:}" != "$last" ]; then
            echo "✗ pre-push: the documented counts do not match the pushed tree of ${sha:0:8} (Scripts/doc-metrics.sh --check, origin/main $base_id's copy):" >&2
            printf '%s\n' "$out" | /usr/bin/grep -E '^  DRIFT ' >&2 || true
            printf '%s\n' "$last" >&2
            echo "  Run Scripts/doc-metrics.sh in this tree and set README.md / ENGINEERING.md to the numbers it prints; where it says 'claim not found' or 'unreadable claim', the counted sentence was reworded: put its wording back. Change no other word. Push refused." >&2
            return 1
        else
            cannot "$sha" "Scripts/doc-metrics.sh exited $rc and its last line is not its verdict line" \
                "$(printf '%s\n' "$out" | tail -n 3)"
            return 1
        fi
    done
    return 0
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
    tests = (d.get("counts") or {}).get("tests")
    if not isinstance(tests, int) or isinstance(tests, bool) or tests <= 0:
        return "verdict PASS counted no tests (tests=%s)" % tests
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

# The host run of the engine suite (step 3a). Prints "ACCEPT <path> <facts>"
# for the newest acceptable verdict, "REJECT <path> <reason>" for each verdict
# on the same tree it passed over, "LIST <text>" for each way the pushed
# known-red list differs from origin/main's, "NOTE <text>" for a row judged
# "no", and "COUNT <read> <same tree>" (tab-separated).
read_host_verdicts() { # sha tree
    python3 - "$1" "$2" "${ENGINE_HOST_VERDICT_DIR:-}" "$BASE_REF" <<'PYEOF'
import hashlib, json, os, re, subprocess, sys
sha, tree, vdir, base_ref = sys.argv[1:5]
LIST = "Scripts/engine-host-known-reds.txt"
COMMAND = "swift test --skip-build --no-parallel --skip FileProtectionTests"
ISSUE_RE = re.compile(r"^✘ Test .* recorded an issue( with [0-9]+ arguments?.*)? at ([A-Za-z0-9_+]+\.swift:[0-9]+):[0-9]+: ", re.M)
RUN_RE = re.compile(r"Test run with ([0-9]+) tests? in ([0-9]+) suites? (passed|failed)")

def show(rev):
    p = subprocess.run(["git", "show", "%s:%s" % (rev, LIST)], capture_output=True, text=True)
    return p.stdout if p.returncode == 0 else None

def parse(text):  # → ({location: count} judged, {location} not judged) or a reason
    judged, free = {}, set()
    for n, line in enumerate((text or "").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        f = line.split("\t")
        if len(f) != 3 or f[2] not in ("yes", "no") or not re.fullmatch(r"[A-Za-z0-9_+]+\.swift:[0-9]+", f[0]):
            return "%s line %d is not 'location<TAB>count<TAB>yes|no'" % (LIST, n)
        if f[2] == "no":
            free.add(f[0])
        elif not f[1].isdigit() or int(f[1]) < 1:
            return "%s line %d: a judged row needs a count of 1 or more" % (LIST, n)
        else:
            judged[f[0]] = int(f[1])
    return judged, free

pushed = show(sha)
if pushed is None:
    print("NOTE\tthe pushed tree has no %s: no red is known, so any red refuses" % LIST)
mine = parse(pushed)
if isinstance(mine, str):
    print("REJECT\t%s\t%s" % (sha[:8], mine)); print("COUNT\t0\t0"); sys.exit(0)
judged, free = mine
theirs = parse(show(base_ref))
if not isinstance(theirs, str):
    for loc in sorted(set(judged) | set(theirs[0])):
        if judged.get(loc) != theirs[0].get(loc):
            print("LIST\t%s: origin/main %s, pushed %s" % (loc, theirs[0].get(loc, "absent"), judged.get(loc, "absent")))
    for loc in sorted(free ^ theirs[1]):
        print("LIST\t%s (not judged): %s" % (loc, "added" if loc in free else "removed"))

def xcode_build_now(dev):
    env = dict(os.environ, DEVELOPER_DIR=dev)
    try:
        out = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True, timeout=120, env=env).stdout
    except Exception:
        return None
    m = re.search(r"Build version (\S+)", out)
    return m.group(1) if m else None

def why_not(d):
    if d.get("verdict") != "PASS":
        return "verdict is %s, not PASS" % d.get("verdict")
    if not (d.get("tracked_clean_start") is True and d.get("tracked_clean_end") is True):
        return "tracked files were modified at the run's start or end"
    if not d.get("head") or d.get("head") != d.get("head_end"):
        return "the run started and ended on different commits"
    if d.get("command") != COMMAND:
        return "the command was %r, not the whole suite (%s)" % (d.get("command"), COMMAND)
    dev = d.get("developer_dir") or ""
    if not dev or not d.get("xcode_build") or d.get("xcode_build") != xcode_build_now(dev):
        return "Xcode build %s under %s, now %s" % (d.get("xcode_build"), dev or "(no developer_dir)", xcode_build_now(dev) if dev else None)
    try:
        raw = open(d.get("log") or "", "rb").read()
    except OSError:
        return "its log %s cannot be read" % (d.get("log") or "(none)")
    if hashlib.sha256(raw).hexdigest() != d.get("log_sha256"):
        return "its log %s does not match its log_sha256" % d.get("log")
    text = raw.decode("utf-8", "replace")
    runs = RUN_RE.findall(text)
    if not runs:
        return "its log has no 'Test run with N tests in M suites' line: an empty or cut run"
    tests, suites = int(runs[-1][0]), int(runs[-1][1])
    if tests < 1 or suites < 1:
        return "its log counts %d tests in %d suites" % (tests, suites)
    got = {}
    for m in ISSUE_RE.finditer(text):
        got[m.group(2)] = got.get(m.group(2), 0) + 1
    for loc in sorted(free):
        if loc in got:
            print("NOTE\t%s recorded %d issue(s); not judged (%s)" % (loc, got[loc], LIST))
    reds = {k: v for k, v in got.items() if k not in free}
    new = {k: v for k, v in reds.items() if judged.get(k) != v}
    gone = {k: v for k, v in judged.items() if reds.get(k) != v}
    if new or gone:
        return "its reds differ from %s: recorded %s; listed %s" % (
            LIST, ", ".join("%s ×%d" % kv for kv in sorted(new.items())) or "nothing new",
            ", ".join("%s ×%d" % kv for kv in sorted(gone.items())) or "nothing missing")
    return "%d tests in %d suites; reds %d at %d listed location(s)" % (tests, suites, sum(reds.values()), len(reds)), True

paths = []
if vdir and os.path.isdir(vdir):
    for dp, dns, fns in os.walk(vdir):
        rel = os.path.relpath(dp, vdir)
        if (0 if rel == "." else rel.count(os.sep) + 1) >= 2:
            dns[:] = []
        if "verdict.json" in fns:
            paths.append(os.path.join(dp, "verdict.json"))
seen = same = 0
accepted = None
for p in sorted(set(paths), key=lambda p: os.path.getmtime(p), reverse=True):
    try:
        d = json.load(open(p))
    except Exception:
        continue
    if not isinstance(d, dict) or d.get("source") != "engine-host-run":
        continue
    seen += 1
    if d.get("tree") != tree:
        continue
    same += 1
    if accepted:
        continue
    r = why_not(d)
    if isinstance(r, tuple):
        accepted = p
        print("ACCEPT\t%s\t%s" % (p, r[0]))
    else:
        print("REJECT\t%s\t%s" % (p, r))
print("COUNT\t%d\t%d" % (seen, same))
PYEOF
}

accept_host_verdict() { # sha tree → 0 when a host run is accepted (every outcome printed)
    local out kind p rest rc=1 tab
    tab="$(printf '\t')"
    if [ -z "${ENGINE_HOST_VERDICT_DIR:-}" ]; then
        echo "→ pre-push: engine-host: ENGINE_HOST_VERDICT_DIR is unset — no host run to accept" >&2
        return 1
    fi
    if ! out="$(read_host_verdicts "$1" "$2")"; then
        echo "⚠  pre-push: engine-host: the verdict reader failed — no host run accepted" >&2
        return 1
    fi
    while IFS="$tab" read -r kind p rest; do
        case "$kind" in
            ACCEPT) echo "→ pre-push: engine-host: accepted $p ($rest)" >&2; rc=0 ;;
            REJECT) echo "→ pre-push: engine-host: not accepted $p — $rest" >&2 ;;
            LIST)   echo "→ pre-push: engine-host: the known-red list differs from origin/main's: $p" >&2 ;;
            NOTE)   echo "→ pre-push: engine-host: $p" >&2 ;;
            COUNT)  echo "→ pre-push: engine-host: $p verdict file(s) read, $rest for tree ${2:0:8}" >&2 ;;
        esac
    done <<EOF
$out
EOF
    return "$rc"
}

run_app_build() { # a compile of the app scheme and its test bundles; no simulator
    local dd="${PREPUSH_APP_BUILD_DIR:-${TMPDIR:-/tmp}/pre-push-app-build}" rc=0
    echo "→ pre-push: compiling ResectaApp (build-for-testing, generic simulator destination, no simulator)…" >&2
    xcodebuild build-for-testing -scheme ResectaApp -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$dd" -quiet >&2 || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "✗ pre-push: the ResectaApp compile exited $rc — push blocked." >&2
        exit 1
    fi
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
    mkdir -p "$t/bin" "$t/verdicts" "$t/hostv" "$repo/Sources" "$repo/Packages/RedactionEngine" "$repo/Scripts"

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
if [ "$1" = "-version" ]; then
    printf 'Xcode 0\nBuild version %s\n' "${STUB_XCODE_BUILD:-X1}"
    exit 0
fi
echo "xcodebuild $1" >> "$PREPUSH_SELFTEST_LOG"
exit "${STUB_BUILD_RC:-0}"
EOF
    cat > "$repo/Scripts/test-batched.sh" <<'EOF'
#!/bin/sh
echo "test-batched.sh $*" >> "$PREPUSH_SELFTEST_LOG"
[ "$1" = "--self-test" ] && exit 0
exit "${STUB_RUN_RC:-0}"
EOF
    sed 's/test-batched\.sh \$\*/pre-push.sh $*/' "$repo/Scripts/test-batched.sh" > "$repo/Scripts/pre-push.sh"
    # A stub count check: its outcome is the line in DIR/README.md; each line it
    # prints is the real script's, copied from its output.
    cat > "$repo/Scripts/doc-metrics.sh" <<'EOF'
#!/bin/sh
[ "$1" = "--check-root" ] || exit 64
f="$2/README.md"
if grep -qx 'counts: stale' "$f"; then
    echo '  DRIFT README app @Test: claimed 1 measured 2'
    echo 'DOC-METRICS FAIL: README app @Test'
    exit 1
fi
if grep -qx 'counts: notfound' "$f"; then
    cat <<'X'
DOC-METRICS FAIL: README XCUITest methods: claim not found (pattern '([\\d,]+) XCUITest methods')
X
    exit 1
fi
if grep -qx 'counts: crash' "$f"; then
    echo 'Traceback (most recent call last):'
    echo "NameError: name 'x' is not defined"
    exit 1
fi
grep -qx 'counts: usage' "$f" && exit 64
grep -qx 'counts: of record' "$f" && {
    echo 'DOC-METRICS OK · counts of record: engine @Test 2291, engine suites 317, app @Test 2156, app suites 339, XCUITest methods 96'
    exit 0
}
grep -qx 'counts: ok' "$f" && { echo 'DOC-METRICS OK'; exit 0; }
exit 3
EOF
    chmod +x "$t/bin/xcrun" "$t/bin/xcodebuild" "$repo/Scripts/test-batched.sh" "$repo/Scripts/pre-push.sh" \
        "$repo/Scripts/doc-metrics.sh"
    printf 'name: SelfTest\ntargets:\n  SelfTest:\n    type: application\n    platform: iOS\n    sources: [Sources]\n' > "$repo/project.yml"
    echo 'let a = 1' > "$repo/Sources/A.swift"
    echo 'let e = 1' > "$repo/Packages/RedactionEngine/E.swift"
    printf '# Self-test\ncounts: ok\n' > "$repo/README.md"
    printf '*.xcodeproj/\n' > "$repo/.gitignore"
    printf '# known reds\nA.swift:1\t1\tyes\nB.swift:2\t2\tyes\nC.swift:3\t0\tno\n' > "$repo/Scripts/engine-host-known-reds.txt"

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

    # hook <stdin line or ""> [VAR=value...] — this script in the scratch repo
    # (or the copy named by $hook_script, for a planted failure).
    hook_script=""
    hook() {
        local input="$1"; shift
        : > "$t/runs"
        rc=0
        out="$(cd "$repo" && printf '%s\n' "$input" | env -u SKIP_TESTS -u PREPUSH_SCHEME_BY_DIFF -u ENGINE_HOST_VERDICT_DIR -u STUB_BUILD_RC \
            TEST_BATCHED_SIM_UDID=SELF-TEST-UDID TEST_BATCHED_VERDICT_DIR="$t/verdicts" ENGINE_HOST_VERDICT_DIR="$t/hostv" \
            PREPUSH_SELFTEST_LOG="$t/runs" PATH="$t/bin:$PATH" "$@" bash "${hook_script:-$me}" origin self-test 2>&1)" || rc=$?
    }
    line() { echo "refs/heads/topic $1 refs/heads/topic 0000000000000000000000000000000000000000"; }
    check() { # label expected-rc expected-runs fixed-string... ("!text": text must be absent)
        local label="$1" want="$2" runs="$3" s ok=1 got
        shift 3
        got="$(tr '\n' ';' < "$t/runs")"
        [ "$rc" = "$want" ] && [ "$got" = "$runs" ] || ok=0
        for s in "$@"; do
            case "$s" in
                !*) ! printf '%s\n' "$out" | /usr/bin/grep -qF -- "${s#!}" || ok=0 ;;
                *)  printf '%s\n' "$out" | /usr/bin/grep -qF -- "$s" || ok=0 ;;
            esac
        done
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
     "xcode_build": "X1", "run_dir": d, "nonce": "N-1", "summary_lines": lines,
     "counts": {"tests": 1, "suites": 1}}
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
    check "an app-only change compiles the app scheme only, no simulator" 0 "xcodebuild build-for-testing;" \
        "engine 0 · app 1 · no-scheme 0 · unclassified 0 → needed app-build · accepted none · ran app-build" \
        "compiling ResectaApp (build-for-testing, generic simulator destination, no simulator)"
    hook "$(line "$h")" STUB_BUILD_RC=65
    check "a failed app compile blocks the push" 1 "xcodebuild build-for-testing;" "the ResectaApp compile exited 65"
    hook "$(line "$h")" PREPUSH_SCHEME_BY_DIFF=0 STUB_RUN_RC=1
    check "a red simulator run blocks the push" 1 "test-batched.sh RedactionEngine;" "RedactionEngine batched run exited 1"
    h="$(commit Packages/RedactionEngine/E.swift 'let f = 2' engine)"
    hook "$(line "$h")"
    check "an engine change with no host run is refused, and nothing runs" 1 "" \
        "engine 1 · app 0 · no-scheme 0 · unclassified 0 → needed engine-host,app-build · accepted none · ran none" \
        "no passing host run of the engine suite covers tree"
    h="$(commit notes.txt note unclassified)"
    hook "$(line "$h")"
    check "an unclassified path needs the host run and the app compile, printed" 1 "" \
        "unclassified path notes.txt" "unclassified 1 → needed engine-host,app-build"
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
    check "a dirty tracked tree is refused" 1 "" "needs app-build, which compiles the working tree, and tracked files are modified — push refused"
    g checkout -q -- Sources/A.swift
    echo 'more' >> "$repo/README.md"; g commit -qam 'docs on top'
    hook "$(line "$h")"
    check "a commit that is not HEAD is refused" 1 "" "is not this checkout's HEAD"

    # Simulator verdict acceptance, field by field, under
    # PREPUSH_SCHEME_BY_DIFF=0 (the pushed commit is not HEAD, so only accepted
    # verdicts let it through; a good RedactionEngine verdict sits beside each).
    forge "$t/verdicts/ok/run"
    forge "$t/verdicts/e" scheme=RedactionEngine
    hook "$(line "$h")" PREPUSH_SCHEME_BY_DIFF=0
    check "a matching verdict is accepted in place of a run" 0 "" \
        "ResectaApp: accepted $t/verdicts/ok/run/verdict.json (VERDICT: PASS scheme=ResectaApp" \
        "→ needed RedactionEngine,ResectaApp · accepted RedactionEngine,ResectaApp · ran none"
    rm -rf "$t/verdicts"/*
    forge "$t/verdicts/a/b/c"
    forge "$t/verdicts/e" scheme=RedactionEngine
    hook "$(line "$h")" PREPUSH_SCHEME_BY_DIFF=0
    check "a verdict deeper than three levels is not read" 1 "" ", 0 for tree ${tree:0:8}"
    for x in "source=other|, 0 for tree" "scheme=RedactionEngine|, 0 for tree" "tree=0000|, 0 for tree" \
             "verdict=FAIL|verdict is FAIL" "tracked_clean_start=false|tracked files were modified" \
             "tracked_clean_end=false|tracked files were modified" "head_end=0000|different commits" \
             "sim.udid=OTHER|ran on simulator OTHER" "-nonce|holds no nonce" \
             "nonce-file=N-2|does not match" "summary-file=VERDICT: PASS forged|summary.txt in" \
             "counts.tests=0|counted no tests (tests=0)" "counts.tests=-1|counted no tests (tests=-1)" \
             "counts.tests=null|counted no tests (tests=None)"; do
        rm -rf "$t/verdicts"/*
        forge "$t/verdicts/v" "${x%%|*}"
        forge "$t/verdicts/e" scheme=RedactionEngine
        hook "$(line "$h")" PREPUSH_SCHEME_BY_DIFF=0
        check "verdict refused: ${x%%|*}" 1 "" "${x#*|}"
    done
    rm -rf "$t/verdicts"/*
    forge "$t/verdicts/v"
    hook "$(line "$h")" PREPUSH_SCHEME_BY_DIFF=0 STUB_RUNTIME_BUILD=R2
    check "verdict refused: the runtime build moved" 1 "" "runtime build R1, now R2"
    hook "$(line "$h")" PREPUSH_SCHEME_BY_DIFF=0 STUB_XCODE_BUILD=X2
    check "verdict refused: the Xcode build moved" 1 "" "Xcode build X1, now X2"
    hook "$(line "$h")" PREPUSH_SCHEME_BY_DIFF=0 TEST_BATCHED_SIM_UDID=
    check "verdict refused: no simulator pinned" 1 "" "TEST_BATCHED_SIM_UDID is unset"
    rm -rf "$t/verdicts"/*

    # The host run of the engine suite (step 3a), on an engine change that is
    # this checkout's HEAD, so an accepted run is followed by the app compile.
    # forge_host dir log-kind [key=json ... | -loghash]: a verdict.json and its log.
    forge_host() {
        python3 - "$tree" "$h" "$@" <<'PYEOF'
import hashlib, json, os, sys
tree, head, d, kind, mods = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
os.makedirs(d, exist_ok=True)
def red(loc): return "✘ Test planted() recorded an issue at %s:5: Expectation failed" % loc
base = [red("A.swift:1"), red("B.swift:2"), red("B.swift:2")]
lines = {"base": base, "base+timing": base + [red("C.swift:3")], "new": base + [red("D.swift:4")],
         "gone": base[1:], "count": base[:2], "clean": [], "cleanred": [red("D.swift:4")],
         "norun": base, "zero": []}[kind]
run = {"clean": "✔ Test run with 10 tests in 3 suites passed after 1.0 seconds.",
       "norun": "", "zero": "✔ Test run with 0 tests in 0 suites passed after 0.0 seconds."}.get(
    kind, "✘ Test run with 10 tests in 3 suites failed after 1.0 seconds with %d issues." % len(lines))
log = os.path.join(d, "hosttest.log")
open(log, "w").write("\n".join(lines + [run]) + "\n")
v = {"source": "engine-host-run", "verdict": "PASS", "tree": tree, "head": head, "head_end": head,
     "tracked_clean_start": True, "tracked_clean_end": True,
     "command": "swift test --skip-build --no-parallel --skip FileProtectionTests",
     "developer_dir": "/stub/Developer", "xcode_build": "X1", "log": log,
     "log_sha256": hashlib.sha256(open(log, "rb").read()).hexdigest()}
for m in mods:
    if m == "-loghash":
        open(log, "a").write("one line more\n"); continue
    k, _, val = m.partition("=")
    try:
        val = json.loads(val)
    except ValueError:
        pass
    v[k] = val
json.dump(v, open(os.path.join(d, "verdict.json"), "w"))
PYEOF
    }
    local hv="$t/hostv/r/verdict.json" he
    h="$(commit Packages/RedactionEngine/E.swift 'let g = 3' engine)"
    tree="$(g rev-parse "$h^{tree}")"
    forge_host "$t/hostv/r" base
    hook "$(line "$h")"
    check "host run: exactly the listed reds are accepted, then the app compiles" 0 "xcodebuild build-for-testing;" \
        "engine-host: accepted $hv (10 tests in 3 suites; reds 3 at 2 listed location(s))" \
        "→ needed engine-host,app-build · accepted engine-host · ran app-build"
    hook "$(line "$h")" STUB_BUILD_RC=65
    check "host run accepted, but a failed app compile still blocks the push" 1 "xcodebuild build-for-testing;" \
        "engine-host: accepted" "the ResectaApp compile exited 65"
    forge_host "$t/hostv/r" base+timing
    hook "$(line "$h")"
    check "host run: a row judged 'no' is printed and does not decide" 0 "xcodebuild build-for-testing;" \
        "engine-host: C.swift:3 recorded 1 issue(s); not judged" "engine-host: accepted $hv"
    for x in "new|its reds differ from Scripts/engine-host-known-reds.txt: recorded D.swift:4 ×1; listed nothing missing" \
             "gone|recorded nothing new; listed A.swift:1 ×1" \
             "count|recorded B.swift:2 ×1; listed B.swift:2 ×2" \
             "norun|no 'Test run with N tests in M suites' line: an empty or cut run" \
             "zero|its log counts 0 tests in 0 suites"; do
        rm -rf "$t/hostv"/*
        forge_host "$t/hostv/r" "${x%%|*}"
        hook "$(line "$h")"
        check "host run refused: a ${x%%|*} log" 1 "" "${x#*|}" "no passing host run of the engine suite covers tree ${tree:0:8}"
    done
    for x in "source=other|engine-host: 0 verdict file(s) read, 0 for tree" \
             "tree=0000|engine-host: 1 verdict file(s) read, 0 for tree ${tree:0:8}" \
             "verdict=FAIL|verdict is FAIL, not PASS" \
             "tracked_clean_start=false|tracked files were modified" \
             "head_end=0000|the run started and ended on different commits" \
             "command=\"swift test --skip-build --filter E\"|not the whole suite" \
             "developer_dir=\"\"|(no developer_dir)" \
             "-loghash|does not match its log_sha256" \
             "log=\"/nonexistent/no-such.log\"|cannot be read"; do
        rm -rf "$t/hostv"/*
        forge_host "$t/hostv/r" base "${x%%|*}"
        hook "$(line "$h")"
        check "host run refused: ${x%%|*}" 1 "" "${x#*|}" "no passing host run of the engine suite covers tree"
    done
    rm -rf "$t/hostv"/*
    forge_host "$t/hostv/r" base
    hook "$(line "$h")" STUB_XCODE_BUILD=X2
    check "host run refused: the Xcode build under its DEVELOPER_DIR moved" 1 "" "Xcode build X1 under /stub/Developer, now X2"
    rm -rf "$t/hostv"/*
    hook "$(line "$h")"
    check "host run refused: no verdict at all" 1 "" "engine-host: 0 verdict file(s) read, 0 for tree" \
        "no passing host run of the engine suite covers tree ${tree:0:8}"
    forge_host "$t/hostv/a/b/c" base
    hook "$(line "$h")"
    check "host run refused: a verdict deeper than three levels is not read" 1 "" "engine-host: 0 verdict file(s) read"
    rm -rf "$t/hostv"/*
    forge_host "$t/hostv/r" base
    hook "$(line "$h")" ENGINE_HOST_VERDICT_DIR=
    check "host run refused: ENGINE_HOST_VERDICT_DIR unset" 1 "" "ENGINE_HOST_VERDICT_DIR is unset"
    he="$h"

    # The known-red list travels with the pushed tree; a change to it is printed.
    g reset -q --hard "$base"
    echo 'let k = 4' >> "$repo/Packages/RedactionEngine/E.swift"
    printf '# known reds\n' > "$repo/Scripts/engine-host-known-reds.txt"
    g add -A && g commit -qm 'engine change, every known red mended'
    h="$(g rev-parse HEAD)"; tree="$(g rev-parse "$h^{tree}")"
    rm -rf "$t/hostv"/*
    forge_host "$t/hostv/r" clean
    hook "$(line "$h")"
    check "host run: an empty list and a clean run pass" 0 "xcodebuild build-for-testing;test-batched.sh --self-test;pre-push.sh --self-test;" \
        "engine-host: accepted $hv (10 tests in 3 suites; reds 0 at 0 listed location(s))" \
        "engine-host: the known-red list differs from origin/main's: A.swift:1: origin/main 1, pushed absent" \
        "engine-host: the known-red list differs from origin/main's: C.swift:3 (not judged): removed"
    forge_host "$t/hostv/r" cleanred
    hook "$(line "$h")"
    check "host run refused: an empty list and a red that is not listed" 1 "" "recorded D.swift:4 ×1; listed nothing missing"
    forge_host "$t/hostv/r" base
    hook "$(line "$h")"
    check "host run refused: an empty list and the old reds" 1 "" "recorded A.swift:1 ×1, B.swift:2 ×2"
    g reset -q --hard "$base"
    echo 'let k = 5' >> "$repo/Packages/RedactionEngine/E.swift"
    printf 'A.swift:1 1 yes\n' > "$repo/Scripts/engine-host-known-reds.txt"
    g add -A && g commit -qm 'a list row without tabs'
    h="$(g rev-parse HEAD)"; tree="$(g rev-parse "$h^{tree}")"
    rm -rf "$t/hostv"/*
    forge_host "$t/hostv/r" base
    hook "$(line "$h")"
    check "host run refused: a list row that is not location, count, judged" 1 "" \
        "Scripts/engine-host-known-reds.txt line 1 is not 'location<TAB>count<TAB>yes|no'"
    g reset -q --hard "$base"
    echo 'let k = 6' >> "$repo/Packages/RedactionEngine/E.swift"
    g rm -q Scripts/engine-host-known-reds.txt && g add -A && g commit -qm 'no list'
    h="$(g rev-parse HEAD)"; tree="$(g rev-parse "$h^{tree}")"
    rm -rf "$t/hostv"/*
    forge_host "$t/hostv/r" clean
    hook "$(line "$h")"
    check "host run: a pushed tree with no list knows no red, and a clean run passes" 0 \
        "xcodebuild build-for-testing;test-batched.sh --self-test;pre-push.sh --self-test;" \
        "engine-host: the pushed tree has no Scripts/engine-host-known-reds.txt" "engine-host: accepted"
    forge_host "$t/hostv/r" base
    hook "$(line "$h")"
    check "host run refused: no list and a red run" 1 "" "recorded A.swift:1 ×1, B.swift:2 ×2"

    # Planted failures for the host run: each copy must let through a case above.
    h="$he"; tree="$(g rev-parse "$h^{tree}")"
    g reset -q --hard "$h"
    [ "$have_xg" = 1 ] && (cd "$repo" && xcodegen generate --quiet)
    mut="$t/pre-push-mutant.sh"
    sed 's/^    if new or gone:$/    if False:/' "$me" > "$mut"
    rm -rf "$t/hostv"/*; forge_host "$t/hostv/r" new
    hook_script="$mut"; hook "$(line "$h")"; hook_script=""
    if cmp -s "$me" "$mut"; then rc=unchanged; fi
    check "planted failure: without the reds comparison a new red is accepted" 0 "xcodebuild build-for-testing;"
    sed '/^    if d.get("tree") != tree:$/{N;d;}' "$me" > "$mut"
    rm -rf "$t/hostv"/*; forge_host "$t/hostv/r" base tree=0000
    hook_script="$mut"; hook "$(line "$h")"; hook_script=""
    if cmp -s "$me" "$mut"; then rc=unchanged; fi
    check "planted failure: without the tree comparison another tree's run is accepted" 0 "xcodebuild build-for-testing;"
    perl -0pe 's/(accept_host_verdict\(\) \{.*?)return "\$rc"/${1}return 0/s' "$me" > "$mut"
    rm -rf "$t/hostv"/*
    hook_script="$mut"; hook "$(line "$h")"; hook_script=""
    if cmp -s "$me" "$mut"; then rc=unchanged; fi
    check "planted failure: an acceptance that always says yes lets a missing run through" 0 "xcodebuild build-for-testing;"
    rm -rf "$t/hostv"/*
    g reset -q --hard "$base"
    [ "$have_xg" = 1 ] && (cd "$repo" && xcodegen generate --quiet)

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
        check "stale check: the regenerated project passes" 0 "xcodebuild build-for-testing;" "generated project matches project.yml"
        if PATH="$t/bin:/usr/bin:/bin:/usr/sbin:/sbin" command -v xcodegen >/dev/null 2>&1; then
            echo "self-test: SKIP no-xcodegen rule — xcodegen is in a system directory"
        else
            hook "$(line "$h")" PATH="$t/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            check "stale check: no xcodegen is a printed warning, not a refusal" 0 "xcodebuild build-for-testing;" \
                "WARN xcodegen is not on PATH"
        fi
    else
        echo "self-test: SKIP stale-project rules — xcodegen is not on PATH"
    fi

    # The documented counts: the base's copy of the script runs on the pushed
    # commit's tree; the stub's outcome is the line in that tree's README.md.
    local b8 cc6b mut
    b8="$(g log -1 --format='%h' "$base")"
    g reset -q --hard "$base"
    [ "$have_xg" = 1 ] && (cd "$repo" && xcodegen generate --quiet)
    h="$(commit README.md 'more docs' docs)"
    hook "$(line "$h")"
    check "documented counts that match pass, naming the base" 0 "" \
        "documented counts match the pushed tree of ${h:0:8}" "origin/main $b8, "
    local hrec; hrec="$(commit README.md 'counts: of record' record)"
    hook "$(line "$hrec")"
    check "a verdict line that carries the counts of record passes" 0 "" \
        "documented counts match the pushed tree of ${hrec:0:8}" "!could not run"
    h="$(commit README.md 'counts: stale' stale)"
    hook "$(line "$h")"
    check "a stale documented count refuses the push" 1 "" "the documented counts do not match" \
        "  DRIFT README app @Test" "DOC-METRICS FAIL: README app @Test" "!could not run"
    g reset -q --hard "$base"
    hook "$(line "$h")"
    check "the pushed tree is checked, not the working tree" 1 "" "the documented counts do not match"
    g reset -q --hard "$base"
    echo 'let s = 9' >> "$repo/Sources/A.swift"; echo 'counts: stale' >> "$repo/README.md"
    g add -A && g commit -qm 'app change with a stale count'
    local h3; h3="$(g rev-parse HEAD)"
    hook "$(line "$h3")"
    check "a stale count refuses before a scheme runs" 1 "" "the documented counts do not match"
    h="$(commit Sources/A.swift 'let s = 9' app)"
    hook "$(line "$h")"
    check "control: the same app change with matching counts compiles the app scheme" 0 "xcodebuild build-for-testing;" \
        "documented counts match the pushed tree"
    g reset -q --hard "$base"
    g rm -q README.md && g commit -qm 'no readme'
    h="$(g rev-parse HEAD)"
    hook "$(line "$h")"
    check "could not run: the pushed tree has no README.md" 1 "" "could not run" "has no README.md"
    h="$(commit README.md 'counts: crash' crash)"
    hook "$(line "$h")"
    check "could not run: the script ends without its verdict line" 1 "" "could not run" "exited 1" \
        "Traceback (most recent call last):" "!do not match"
    cc6b="$(commit README.md 'counts: notfound' notfound)"
    hook "$(line "$cc6b")"
    check "a reworded counted sentence refuses the push" 1 "" "the documented counts do not match" \
        "claim not found" "!could not run"
    h="$(commit README.md 'counts: usage' usage)"
    hook "$(line "$h")"
    check "could not run: the script exits 64" 1 "" "could not run" "exited 64"
    h="$(commit README.md 'more docs' docs)"
    mkdir -p "$t/bin-mktemp" "$t/bin-tar"
    printf '#!/bin/sh\nfor a in "$@"; do case "$a" in *pre-push-counts.*) exit 1 ;; esac; done\nexec /usr/bin/mktemp "$@"\n' \
        > "$t/bin-mktemp/mktemp"
    printf '#!/bin/sh\nexit 2\n' > "$t/bin-tar/tar"
    chmod +x "$t/bin-mktemp/mktemp" "$t/bin-tar/tar"
    hook "$(line "$h")" PATH="$t/bin-mktemp:$t/bin:$PATH"
    check "could not run: no temporary folder for the count check" 1 "" "could not run" "cannot make a temporary folder"
    hook "$(line "$h")" PATH="$t/bin-tar:$t/bin:$PATH"
    check "could not run: the pushed tree cannot be written out" 1 "" "could not run" "tar rc 2"
    g reset -q --hard "$base"
    g rm -q Scripts/doc-metrics.sh && g commit -qm 'no count script'
    g update-ref refs/remotes/origin/main "$(g rev-parse HEAD)"
    hook "$(line "$h")"
    check "a base without the script is a printed warning, not a refusal" 0 "" \
        "has no Scripts/doc-metrics.sh — the documented counts are not checked"
    g update-ref refs/remotes/origin/main "$base"

    # Planted failures: each copy of this script must fail a case above.
    mut="$t/pre-push-mutant.sh"
    /usr/bin/grep -vx 'count_check || exit 1' "$me" > "$mut"
    g reset -q --hard "$h3"
    hook_script="$mut"; hook "$(line "$h3")"; hook_script=""
    check "planted failure: without the count check the stale app change compiles its scheme" 0 "xcodebuild build-for-testing;"
    sed 's/elif \[ "$rc" = 1 \] && \[ "${last#DOC-METRICS FAIL:}" != "$last" \]; then/elif [ "$rc" = 1 ] \&\& printf "%s\\n" "$out" | \/usr\/bin\/grep -q "^  DRIFT "; then/' "$me" > "$mut"
    hook_script="$mut"; hook "$(line "$cc6b")"; hook_script=""
    if cmp -s "$me" "$mut"; then rc=unchanged; fi
    check "planted failure: reading DRIFT lines, not the last line, calls a reworded sentence could not run" 1 "" "could not run"
    sed 's/ || \[ "${last#DOC-METRICS OK · }" != "$last" \]//' "$me" > "$mut"
    hook_script="$mut"; hook "$(line "$hrec")"; hook_script=""
    if cmp -s "$me" "$mut"; then rc=unchanged; fi
    check "planted failure: reading only the bare verdict line calls the counts of record could not run" 1 "" "could not run"
    sed "s/grep -E '^  DRIFT ' >\&2/grep -E '^  DRIFT  ' >\&2/" "$me" > "$mut"
    h="$(commit README.md 'counts: stale' stale)"
    hook_script="$mut"; hook "$(line "$h")"; hook_script=""
    if cmp -s "$me" "$mut"; then rc=unchanged; fi
    check "planted failure: a pass-through for the old DRIFT shape loses the DRIFT line" 1 "" \
        "the documented counts do not match" "!  DRIFT README app @Test"

    [ "$fails" -eq 0 ] && { echo "self-test: PASS"; exit 0; }
    echo "self-test: FAIL" >&2; exit 1
}

# Posts a `local-suites` commit status (success, "PASS @ tree <tree>: <schemes>")
# for each pushed commit, so a pull request shows which commits passed the
# local suites; a SKIP_TESTS=1 push posts none. GitHub has the commit only
# after the push, so a detached job retries for up to five minutes and the push
# never waits on it. Nothing is posted without `gh` or without a GitHub origin.
publish_local_status() {
    command -v gh >/dev/null 2>&1 || return 0
    local url slug j sha tree desc
    url="$(git remote get-url origin 2>/dev/null || true)"
    case "$url" in *github.com[:/]*) ;; *) return 0 ;; esac
    slug="${url#*github.com[:/]}"; slug="${slug%.git}"
    j=0
    while [ "$j" -lt "${#P_SHA[@]}" ]; do
        sha="${P_SHA[$j]}"; tree="$(git rev-parse "$sha^{tree}")"
        desc="PASS @ tree ${tree:0:8}: $(join_list ${P_NEED[$j]})"
        ( for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
              gh api -X POST "repos/$slug/statuses/$sha" -f state=success -f context=local-suites \
                  -f description="$desc" >/dev/null 2>&1 && exit 0
              sleep 10
          done ) </dev/null >/dev/null 2>&1 &
        echo "→ pre-push: posting local-suites ($desc) for ${sha:0:8} once GitHub has it" >&2
        j=$((j + 1))
    done
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
count_check || exit 1

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
        need="engine-host app-build"
    elif [ "$na" -gt 0 ]; then
        need="app-build"
    fi
    [ "$scripts" -eq 1 ] && need="${need:+$need }self-tests"

    tree="$(git rev-parse "$sha^{tree}")"
    acc=""
    for s in $need; do
        if [ "$s" = engine-host ]; then
            if accept_host_verdict "$sha" "$tree"; then acc="$acc $s"; continue; fi
            echo "✗ pre-push: $ref ${sha:0:8} changes the engine and no passing host run of the engine suite covers tree ${tree:0:8} — push refused. Run \`swift test --skip-build --no-parallel --skip FileProtectionTests\` in Packages/RedactionEngine on this tree, write its verdict.json, and point ENGINE_HOST_VERDICT_DIR at it." >&2
            REFUSED=$((REFUSED + 1))
            continue
        fi
        if [ "$s" != self-tests ] && [ "$s" != app-build ] && accept_verdict "$s" "$tree"; then acc="$acc $s"; continue; fi
        if [ "$sha" = "$HEAD_SHA" ] && [ "$CLEAN" -eq 1 ]; then
            case " $TO_RUN " in *" $s "*) ;; *) TO_RUN="$TO_RUN $s" ;; esac
            continue
        fi
        if [ "$sha" != "$HEAD_SHA" ]; then why="${sha:0:8} is not this checkout's HEAD (${HEAD_SHA:0:8})"
        else why="tracked files are modified"; fi
        if [ "$s" = app-build ]; then
            echo "✗ pre-push: $ref ${sha:0:8} needs app-build, which compiles the working tree, and $why — push refused." >&2
        else
            echo "✗ pre-push: $ref ${sha:0:8} needs $s and no passing verdict covers tree ${tree:0:8}; the runner tests the working tree and $why — push refused." >&2
        fi
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

for s in RedactionEngine ResectaApp app-build self-tests; do
    case " $TO_RUN " in *" $s "*) ;; *) continue ;; esac
    case "$s" in
        self-tests) run_self_tests ;;
        app-build)  run_app_build ;;
        *)          run_scheme "$s" ;;
    esac
done

summary 1
publish_local_status
echo "→ pre-push: push allowed." >&2
