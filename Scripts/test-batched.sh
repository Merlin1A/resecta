#!/usr/bin/env bash
# test-batched.sh — canonical local test runner for this machine.
#
# Full single-invocation parallel runs (`xcodebuild test -scheme X`) drive one
# xctest process with Swift Testing in-process concurrency and have wedged the
# simulator runtime machine-wide three times on 2026-06-11 alone. This runner
# is the structural avoidance: build once, then serial suite-level batches via
# `test-without-building`, each under a watchdog, with perf-budget suites run
# completely alone and report-only.
#
# Perf-budget suites run alone and report-only; known-flaky timing/race
# suites are excluded from the gating batches by policy.
#
# Usage:
#   TEST_BATCHED_SIM_UDID=<udid> Scripts/test-batched.sh RedactionEngine|ResectaApp [--batch-size N] [--timeout-mins M]
#   Scripts/test-batched.sh --self-test
#
# Environment:
#   TEST_BATCHED_SIM_UDID  required — the simulator every invocation runs on,
#                          and the only one this script ever shuts down or
#                          erases. There is no resolution by device name: two
#                          runs on one machine each own their own simulator.
#   TEST_BATCHED_DD        DerivedData for this run (default <repo>/.dd), so
#                          a build elsewhere never invalidates a run in flight.
#   TEST_BATCHED_STALL_SECS  seconds of no output before an invocation is
#                          killed (default 180). A hosted runner without
#                          Neural Engine access runs OCR-heavy tests many
#                          times slower than a Mac and widens this; the
#                          per-invocation ceiling (--timeout-mins) still
#                          bounds each batch.
#   TEST_BATCHED_EXCLUDE   suite names (space-separated) that are NOT run on
#                          this runtime: a suite that hangs on the hosted
#                          virtual machine (the verification pass of a full
#                          pipeline run never returns there, and the test's
#                          own time limit cannot end a hang inside a system
#                          framework) is named here by the workflow, left
#                          out of the batches, listed in the summary and
#                          counted in the VERDICT line as `excluded=N`, so a
#                          verdict that skipped a body is never read as one
#                          that proved it. Empty locally: the pre-push hook
#                          runs every suite.
#   TEST_BATCHED_RECOVERY  what the recovery after a wedge does to the
#                          simulator: `reboot` (default) shuts it down and
#                          boots it again; `erase` also erases it first. An
#                          erase wipes the simulator's provisioned assets
#                          (the name model, the Vision data files) and
#                          forces a cold boot, which on a hosted runner
#                          outlasts the stall allowance and wedges the next
#                          batch in turn.
#   TEST_BATCHED_VERDICT_DIR  when set, the run's verdict files (below) are
#                          also copied to <dir>/<run dir name>/.
#
# Exit codes:
#   0  all reds (if any) are on the exclusion list, no incomplete batches
#   1  at least one red outside the exclusion list (offenders printed)
#   2  no gating reds, but >=1 invocation wedged or hit a test-host launch
#      refusal twice — those suites are unverified, coverage incomplete;
#      also when TEST_BATCHED_SIM_UDID is unset (nothing ran)
#
# Recovery after a wedge is scoped to this run: the run's own xcodebuild and
# its descendants are killed, then only $TEST_BATCHED_SIM_UDID is shut down
# (and erased, with TEST_BATCHED_RECOVERY=erase), booted again and waited
# for, so the next invocation starts on a booted simulator. Nothing here
# signals another run's processes or simulators.
#
# Logs and .xcresult bundles land under /tmp/test-batched-<scheme>-<stamp>/.
# Logs are spam-filtered (attributedStringScaled framework noise) and size-
# bounded; the per-batch .xcresult is the forensic source of record. Beside
# them, a run that reaches its verdict (or fails its build) writes
# verdict.json, summary.txt (the totals and VERDICT lines as printed) and a
# nonce; the pre-push hook reads them (see write_verdict).
#
# Compatible with the stock macOS bash 3.2. Uses /usr/bin/grep throughout
# (`grep` is shimmed to ugrep on this machine and mangles some flag combos).

set -euo pipefail

GREP=/usr/bin/grep

# ──────────────────────────────────────────────────────────────────────────
# Editable classification block — see the triage doc before changing.
#
# PERF-ALONE: suites asserting wall-clock / ratio / percentile budgets.
# Excluded from batches; each runs completely alone AFTER the batches,
# REPORT-ONLY (their reds never set the exit status — a red here is read by
# hand, never gated). "Completely alone" is load-bearing: StressCorpusTests
# has been red when paired with even one other suite.
PERF_ALONE_RedactionEngine="CancellationLatencyTests PixelBufferZeroizeTimingTests ReverseRationalePerformanceTests StressCorpusTests ApplyPhaseMemoryStressTests ParallelLayerExecutionTests DetectionRasterizeOverlapTests Layer2OCRParallelismTests SearchRecheckParallelismTests"
PERF_ALONE_ResectaApp="PageParallelRasterizationTests"

# Exclusion list (suite granularity): reds here do not gate the exit
# status even inside normal batches.
# The last four assert wall-clock bounds that move with a neighbouring
# build or run on the same machine (two runs share one host): report-only.
NON_GATING="ScreenCaptureShieldTests PageParallelRasterizationTests StressCorpusTests ImportServiceCancelTests ReDoSFuzzTests RegexSearchHardeningTests CoverageHistogramTests SearchDebounceCancelTests"
# ──────────────────────────────────────────────────────────────────────────

BATCH_SIZE=28          # ~25-32 suites per batch
TIMEOUT_MINS=15        # hard per-invocation ceiling
STALL_SECS="${TEST_BATCHED_STALL_SECS:-180}"   # kill if the log stops growing this long
RECOVERY="${TEST_BATCHED_RECOVERY:-reboot}"    # reboot | erase (see the header)
EXCLUDE="${TEST_BATCHED_EXCLUDE:-}"            # suites not run on this runtime (see the header)
BOOT_WAIT_SECS=300     # how long the recovery waits for the simulator to report booted
LOAD_WARN=8            # 1-min load average warning threshold
LOG_CAP_BYTES=20000000 # per-batch filtered-log size bound

usage() { sed -n '3,60p' "$0"; exit 64; }

# ── Suite enumeration (runtime, from Tests sources) ──────────────────────
# Every top-level (column-0) type whose body carries a `@Test` function — with
# or without a `@Suite` attribute (Swift Testing runs a bare type holding
# `@Test` functions as an implicit suite, and `-only-testing:` addresses it by
# type name) — plus XCTestCase subclasses, plus a column-0 `extension` of such
# a type whose body carries a `@Test` function (a test file split across
# several files keeps its functions in extensions of the one suite type; the
# runner addresses the type, so the extension's tests run with it).
# Attribute-only detection used to miss implicit suites and the multi-line
# `@Suite(` form, so their tests never ran under this runner. Validated
# 2026-08-27 against the live trees: engine 207, app 209.
enumerate_suites() { # test-source-dir — one suite name per line, sorted
    python3 - "$1" <<'PYEOF'
import os, re, sys

ATTRS = re.compile(r'^(?:@\w+(?:\([^)]*\))?\s*)+')
MODS = r'(?:(?:private|fileprivate|internal|public|final)\s+)*'
TYPE_DECL = re.compile(r'^' + MODS + r'(?:class|struct|enum|actor|extension)\s+(\w+)')
XCTEST_DECL = re.compile(r'^' + MODS + r'class\s+(\w+)\s*:\s*[^{]*\bXCTestCase\b')
TEST_ATTR = re.compile(r'^\s+@Test\b')

suites = set()
for dirpath, _, files in os.walk(sys.argv[1]):
    for fn in sorted(files):
        if not fn.endswith('.swift'):
            continue
        lines = open(os.path.join(dirpath, fn), encoding='utf-8',
                     errors='replace').read().splitlines()
        current = None   # the column-0 type whose body the scan is inside
        for line in lines:
            decl = ATTRS.sub('', line) if line.startswith('@') else line
            m = XCTEST_DECL.match(decl)
            if m:
                suites.add(m.group(1)); current = None; continue
            m = TYPE_DECL.match(decl)
            if m:
                current = m.group(1); continue
            if line.startswith('}'):
                current = None; continue
            if current and TEST_ATTR.match(line):
                suites.add(current)
for s in sorted(suites):
    print(s)
PYEOF
}

# ── Verdict file ──────────────────────────────────────────────────────────
# write_verdict PASS|FAIL|INCOMPLETE|BUILD-FAILED <summary line>... writes,
# beside the run's logs: `nonce` (uuidgen), `summary.txt` (the summary lines
# exactly as printed) and `verdict.json` — the scheme, the verdict, the counts,
# the commit and tree the run started on (START_HEAD / START_TREE, captured
# before the build) and the commit it ended on, whether tracked files were
# clean at both ends, the engine package's tree, the simulator with its
# runtime version and build, the Xcode build, the DerivedData path, the run
# dir, the nonce, the summary lines and the start and end times. With
# TEST_BATCHED_VERDICT_DIR set the three files are copied there too. The
# pre-push hook accepts a PASS for the same tree in place of a re-run and
# re-reads `nonce` and `summary.txt` from the run dir the verdict names.
# The writer never changes the exit code: a failure is printed and passed over.
write_verdict() { # verdict summary-line...
    TBV_SCHEME="${SCHEME:-}" TBV_RUN_DIR="${RUN_DIR:-}" TBV_DD="${DD:-}" \
    TBV_SIM_UDID="${SIM_UDID:-}" TBV_HEAD="${START_HEAD:-}" TBV_TREE="${START_TREE:-}" \
    TBV_CLEAN="${START_CLEAN:-}" TBV_STARTED="${STARTED:-}" \
    TBV_TESTS="${TOT_TESTS:-}" TBV_SUITES="${TOT_SUITES:-}" TBV_FAILED="${TOT_FAILED:-}" \
    TBV_KNOWN="${TOT_KNOWN:-}" TBV_WEDGED="${WEDGED:-}" TBV_EXCLUDED="${#EXCLUDED[@]}" \
    TBV_COPY_DIR="${TEST_BATCHED_VERDICT_DIR:-}" \
    python3 - "$@" <<'PYEOF' || true
import datetime, json, os, re, shutil, subprocess, sys, uuid

e = os.environ

def run(*argv):  # (exit code, stdout); a missing tool reads as a failure
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=120)
        return p.returncode, p.stdout
    except Exception:
        return 1, ""

def num(key):
    try:
        return int(e.get(key, ""))
    except ValueError:
        return None

def sim_info(udid):
    # Two installed runtimes can share one identifier (26.4 and 26.4.1):
    # every available match is recorded, joined, so a change to either moves it.
    info = {"udid": udid or None, "runtime_version": None, "runtime_build": None}
    try:
        devices = json.loads(run("xcrun", "simctl", "list", "devices", "-j")[1])["devices"]
        runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "-j")[1])["runtimes"]
    except Exception:
        return info
    rid = next((k for k, ds in devices.items() for d in ds if d.get("udid") == udid), None)
    match = [r for r in runtimes if rid and r.get("identifier") == rid and r.get("isAvailable", True)]
    if match:
        info["runtime_version"] = "+".join(sorted(str(r.get("version")) for r in match))
        info["runtime_build"] = "+".join(sorted(str(r.get("buildversion")) for r in match))
    return info

try:
    verdict, lines = sys.argv[1], sys.argv[2:]
    run_dir = e["TBV_RUN_DIR"]
    head = e.get("TBV_HEAD") or None
    rc, out = run("git", "rev-parse", "-q", "--verify", "HEAD")
    head_end = out.strip() if rc == 0 and out.strip() else None
    rc, out = run("git", "status", "--porcelain", "--untracked-files=no")
    clean_end = rc == 0 and out == ""
    rc, out = run("git", "rev-parse", "-q", "--verify", (head or "HEAD") + ":Packages/RedactionEngine")
    engine_tree = out.strip() if rc == 0 and out.strip() else None
    m = re.search(r"Build version (\S+)", run("xcodebuild", "-version")[1])
    rc, out = run("uuidgen")
    nonce = out.strip() if rc == 0 and out.strip() else str(uuid.uuid4()).upper()
    doc = {
        "source": "test-batched.sh",
        "scheme": e.get("TBV_SCHEME") or None,
        "verdict": verdict,
        "head": head,
        "head_end": head_end,
        "tree": e.get("TBV_TREE") or None,
        "tracked_clean_start": e.get("TBV_CLEAN") == "true",
        "tracked_clean_end": clean_end,
        "engine_tree": engine_tree,
        "counts": {"tests": num("TBV_TESTS"), "suites": num("TBV_SUITES"),
                   "failed": num("TBV_FAILED"), "known_issues": num("TBV_KNOWN"),
                   "wedged": num("TBV_WEDGED"), "excluded": num("TBV_EXCLUDED")},
        "sim": sim_info(e.get("TBV_SIM_UDID", "")),
        "xcode_build": m.group(1) if m else None,
        "dd": e.get("TBV_DD") or None,
        "run_dir": run_dir,
        "nonce": nonce,
        "summary_lines": lines,
        "started": e.get("TBV_STARTED") or None,
        "ended": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    with open(os.path.join(run_dir, "nonce"), "w") as f:
        f.write(nonce + "\n")
    with open(os.path.join(run_dir, "summary.txt"), "w") as f:
        f.write("".join(l + "\n" for l in lines))
    tmp = os.path.join(run_dir, "verdict.json.tmp")
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, os.path.join(run_dir, "verdict.json"))
    print("verdict file: " + os.path.join(run_dir, "verdict.json"))
    if e.get("TBV_COPY_DIR"):
        dest = os.path.join(e["TBV_COPY_DIR"], os.path.basename(run_dir.rstrip("/")))
        os.makedirs(dest, exist_ok=True)
        for name in ("verdict.json", "summary.txt", "nonce"):
            shutil.copy2(os.path.join(run_dir, name), dest)
        print("verdict file copied to: " + dest)
except Exception as exc:
    print("verdict file NOT written (the exit code is unchanged): %s" % exc, file=sys.stderr)
PYEOF
}

# --self-test: the lane-safety rules against this file and one dry
# invocation. Exit 0 = every rule holds; 1 = a rule drifted (named).
self_test() {
    local fails=0 me="$0" body pat n
    # 1. The script refuses to run without the simulator pin (exit 2).
    n=0; env -u TEST_BATCHED_SIM_UDID bash "$me" ResectaApp >/dev/null 2>&1 || n=$?
    if [ "$n" -eq 2 ]; then echo "self-test: refuses without TEST_BATCHED_SIM_UDID (exit 2) OK"
    else echo "self-test: expected exit 2 without TEST_BATCHED_SIM_UDID, got $n" >&2; fails=1; fi
    # 2. Recovery never touches other simulators or other runs' processes.
    #    (The patterns are assembled so this function's own text cannot match.)
    body="$(sed -n '/^recover_sim()/,/^}/p' "$me")"
    n=0
    for pat in "shutdown ""all" "pkill -9 ""-x" "killall"; do
        if printf '%s\n' "$body" | $GREP -q -- "$pat"; then
            echo "self-test: recover_sim contains '$pat'" >&2; n=1
        fi
    done
    pat="simctl ""shutdown ""all"
    if $GREP -q -- "$pat" "$me"; then echo "self-test: '$pat' present outside recover_sim" >&2; n=1; fi
    if [ "$n" -eq 0 ]; then echo "self-test: recovery scoped to its own process tree and \$SIM_UDID OK"; else fails=1; fi
    # 3. Both xcodebuild invocations carry the per-run DerivedData path.
    n="$($GREP -cE '^[[:space:]]*(if ! )?xcodebuild .*-derivedDataPath "\$DD"' "$me" || true)"
    if [ "$n" -eq 2 ]; then echo "self-test: -derivedDataPath on both xcodebuild calls OK"
    else echo "self-test: expected 2 xcodebuild calls with -derivedDataPath \"\$DD\", found $n" >&2; fails=1; fi
    # 4. The four wall-clock suites are report-only.
    for pat in ReDoSFuzzTests RegexSearchHardeningTests CoverageHistogramTests SearchDebounceCancelTests; do
        case " $NON_GATING " in *" $pat "*) ;; *) echo "self-test: $pat is not in NON_GATING" >&2; fails=1 ;; esac
    done
    [ "$fails" -eq 0 ] && echo "self-test: the four wall-clock suites are report-only OK"
    # 5. The suite enumerator reads `extension` blocks: a @Test inside a
    #    column-0 extension of a type is enumerated under that type; a type
    #    with a @Test in its body still is; an extension with no @Test is not.
    local tdir got
    tdir="$(mktemp -d "${TMPDIR:-/tmp}/test-batched-selftest.XXXXXX")"
    printf 'import Testing\nstruct ExtensionOnlyHost {}\n\nextension ExtensionOnlyHost {\n    @Test func inExtension() {}\n}\n' > "$tdir/ExtensionOnly.swift"
    printf 'import Testing\nstruct PlainType {\n    @Test func inBody() {}\n}\n\nextension PlainType {\n    func helper() {}\n}\n' > "$tdir/Plain.swift"
    printf 'import Testing\nstruct NoTests {}\n\nextension NoTests {\n    func helper() {}\n}\n' > "$tdir/NoTests.swift"
    got="$(enumerate_suites "$tdir" | tr '\n' ' ')"
    rm -rf "$tdir"
    if [ "$got" = "ExtensionOnlyHost PlainType " ]; then echo "self-test: enumerator reads extension blocks (ExtensionOnlyHost, PlainType; NoTests absent) OK"
    else echo "self-test: enumerator expected 'ExtensionOnlyHost PlainType', got '$got'" >&2; fails=1; fi
    # 6. The stall allowance and the recovery shape are read from the
    #    environment with the local defaults; the recovery boots the
    #    simulator again and waits for it; the erase is behind the knob.
    n=0
    $GREP -qE '^STALL_SECS="\$\{TEST_BATCHED_STALL_SECS:-180\}"' "$me" \
        || { echo "self-test: STALL_SECS is not read from TEST_BATCHED_STALL_SECS with the default 180" >&2; n=1; }
    $GREP -qE '^RECOVERY="\$\{TEST_BATCHED_RECOVERY:-reboot\}"' "$me" \
        || { echo "self-test: RECOVERY is not read from TEST_BATCHED_RECOVERY with the default reboot" >&2; n=1; }
    body="$(sed -n '/^recover_sim()/,/^}/p' "$me")"
    printf '%s\n' "$body" | $GREP -q 'xcrun simctl boot "\$SIM_UDID"' \
        || { echo "self-test: recover_sim does not boot the simulator again" >&2; n=1; }
    printf '%s\n' "$body" | $GREP -q 'simctl bootstatus "\$SIM_UDID" -b' \
        || { echo "self-test: recover_sim does not wait for the simulator to boot" >&2; n=1; }
    printf '%s\n' "$body" | $GREP -B1 'simctl erase "\$SIM_UDID"' | $GREP -q '"\$RECOVERY" = "erase"' \
        || { echo "self-test: the erase in recover_sim is not behind TEST_BATCHED_RECOVERY=erase" >&2; n=1; }
    if [ "$n" -eq 0 ]; then echo "self-test: stall allowance + recovery shape from the environment; recovery boots and waits; erase opt-in OK"; else fails=1; fi
    # 7. The runtime exclusion list is read from the environment, applied
    #    before batching, and every VERDICT line carries `excluded=`.
    n=0
    $GREP -qE '^EXCLUDE="\$\{TEST_BATCHED_EXCLUDE:-\}"' "$me" \
        || { echo "self-test: EXCLUDE is not read from TEST_BATCHED_EXCLUDE" >&2; n=1; }
    $GREP -q 'if in_list "\$s" "\$EXCLUDE"; then EXCLUDED+=("\$s")' "$me" \
        || { echo "self-test: the exclusion is not applied before batching" >&2; n=1; }
    [ "$($GREP -c 'VERDICT: .* excluded=\${#EXCLUDED\[@\]}' "$me")" -eq 2 ] \
        || { echo "self-test: a VERDICT line does not carry excluded=" >&2; n=1; }
    if [ "$n" -eq 0 ]; then echo "self-test: runtime exclusion list from the environment, applied before batching, named in the verdict OK"; else fails=1; fi
    # 8. The verdict file is written right before the build-failure exit and
    #    each verdict exit (in that order: BUILD-FAILED, FAIL, INCOMPLETE,
    #    PASS), and a dry call writes every field, the nonce and the summary.
    n=0
    got="$(awk '
        /^if ! xcodebuild build-for-testing/ || /^if \[ -n "\$OFFENDERS" \]/ { on = 1 }
        on && $1 == "exit" { printf "%s>%s ", prev, $2 }
        on && NF { prev = ($1 == "write_verdict") ? $2 : "-" }
        /^echo "build ok"/ { on = 0 }' "$me")"
    [ "$got" = "BUILD-FAILED>1 FAIL>1 INCOMPLETE>2 PASS>0 " ] \
        || { echo "self-test: write_verdict does not precede each verdict exit (got '$got')" >&2; n=1; }
    tdir="$(mktemp -d "${TMPDIR:-/tmp}/test-batched-selftest.XXXXXX")"
    mkdir -p "$tdir/run" "$tdir/copy"
    got="$(cd "$(dirname "$me")/.." && EXCLUDED=() && SCHEME=ResectaApp RUN_DIR="$tdir/run" DD="$tdir/dd" \
        SIM_UDID=SELF-TEST START_HEAD=0 START_TREE=0 START_CLEAN=true STARTED=0 \
        TOT_TESTS=3 TOT_SUITES=1 TOT_FAILED=0 TOT_KNOWN=0 WEDGED=0 \
        TEST_BATCHED_VERDICT_DIR="$tdir/copy" write_verdict PASS "totals: dry" "VERDICT: dry" 2>&1)"
    python3 - "$tdir" <<'PYEOF' || { echo "self-test: the dry verdict file is incomplete (writer said: $got)" >&2; n=1; }
import json, os, sys
t = sys.argv[1]
d = json.load(open(os.path.join(t, "run", "verdict.json")))
need = ("source scheme verdict head head_end tree tracked_clean_start tracked_clean_end engine_tree "
        "counts sim xcode_build dd run_dir nonce summary_lines started ended").split()
missing = [k for k in need if k not in d]
missing += ["sim." + k for k in ("udid", "runtime_version", "runtime_build") if k not in d.get("sim", {})]
missing += ["counts." + k for k in ("tests", "suites", "failed", "known_issues", "wedged", "excluded")
            if k not in d.get("counts", {})]
assert not missing, missing
assert d["source"] == "test-batched.sh" and d["verdict"] == "PASS" and d["counts"]["tests"] == 3
assert open(os.path.join(t, "run", "nonce")).read().strip() == d["nonce"] != ""
assert open(os.path.join(t, "run", "summary.txt")).read().splitlines() == d["summary_lines"] == ["totals: dry", "VERDICT: dry"]
assert open(os.path.join(t, "copy", "run", "verdict.json")).read() == open(os.path.join(t, "run", "verdict.json")).read()
PYEOF
    rm -rf "$tdir"
    if [ "$n" -eq 0 ]; then echo "self-test: write_verdict precedes the build-failure and verdict exits; a dry call writes every field OK"; else fails=1; fi
    [ "$fails" -eq 0 ] && { echo "self-test: PASS"; exit 0; }
    echo "self-test: FAIL" >&2; exit 1
}

[ $# -ge 1 ] || usage
[ "$1" = "--self-test" ] && self_test
case "$RECOVERY" in reboot|erase) ;; *) echo "TEST_BATCHED_RECOVERY must be reboot or erase (got $RECOVERY)" >&2; exit 64 ;; esac
case "$STALL_SECS" in ''|*[!0-9]*) echo "TEST_BATCHED_STALL_SECS must be a whole number of seconds (got $STALL_SECS)" >&2; exit 64 ;; esac
SCHEME="$1"; shift
case "$SCHEME" in
    RedactionEngine)
        TEST_TARGET="RedactionEngineTests"
        TEST_SRC="Packages/RedactionEngine/Tests/RedactionEngineTests"
        PERF_ALONE="$PERF_ALONE_RedactionEngine"
        SETTLE_SECS=0
        ;;
    ResectaApp)
        TEST_TARGET="ResectaAppTests"
        TEST_SRC="Tests/ResectaAppTests"
        PERF_ALONE="$PERF_ALONE_ResectaApp"
        SETTLE_SECS=10   # app-host relaunch churn trips SBMainWorkspace without a settle
        ;;
    *) echo "unknown scheme: $SCHEME (expected RedactionEngine or ResectaApp)" >&2; usage ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --batch-size)   BATCH_SIZE="$2"; shift 2 ;;
        --timeout-mins) TIMEOUT_MINS="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
[ -d "$TEST_SRC" ] || { echo "missing test source dir: $TEST_SRC" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required (xcresult parsing + suite enumeration)" >&2; exit 1; }

# What the verdict file records as the run's starting point: the commit, its
# tree and whether tracked files are clean, read before the build does.
START_HEAD="$(git rev-parse -q --verify HEAD 2>/dev/null || true)"
START_TREE="$(git rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null || true)"
START_CLEAN=false
[ -z "$(git status --porcelain --untracked-files=no 2>/dev/null || echo unreadable)" ] && START_CLEAN=true
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The destination simulator is pinned by id, never resolved by name: with two
# runs on one machine a name match can land on — and the recovery below can
# erase — a simulator another run owns.
[ -n "${TEST_BATCHED_SIM_UDID:-}" ] || { echo "TEST_BATCHED_SIM_UDID required (no name resolution)" >&2; exit 2; }
SIM_UDID="$TEST_BATCHED_SIM_UDID"
xcrun simctl list devices -j | $GREP -q "\"$SIM_UDID\"" \
    || { echo "PRE-FLIGHT: no simulator with udid $SIM_UDID" >&2; exit 1; }
DEST="id=$SIM_UDID"
DD="${TEST_BATCHED_DD:-$REPO_ROOT/.dd}"

STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="/tmp/test-batched-${SCHEME}-${STAMP}"
mkdir -p "$RUN_DIR"
echo "run dir: $RUN_DIR"

# ── Pre-flight ────────────────────────────────────────────────────────────

# A stale xcodebuild still aimed at this simulator (its arguments carry the
# destination id) stalls every later run on it: refuse. Test processes aimed
# elsewhere belong to another run on this machine and are left alone.
stale="$(pgrep -f "xcodebuild .*id=$SIM_UDID" 2>/dev/null || true)"
if [ -n "$stale" ]; then
    echo "PRE-FLIGHT: xcodebuild process(es) already targeting simulator $SIM_UDID: $stale" >&2
    echo "  (a stale run against this simulator stalls every later run on it — stop it first)" >&2
    exit 1
fi

LOAD1="$(sysctl -n vm.loadavg | awk '{print $2}')"
if [ "$(printf '%.0f' "$LOAD1")" -gt "$LOAD_WARN" ]; then
    echo "PRE-FLIGHT WARNING: 1-min load average is $LOAD1 (> $LOAD_WARN)." >&2
    echo "  Perf-budget suites are report-only, but batch wall time will inflate. Proceeding." >&2
fi

echo "simulator: $SIM_UDID (pinned via TEST_BATCHED_SIM_UDID)"

SUITES_FILE="$RUN_DIR/suites.txt"
enumerate_suites "$TEST_SRC" > "$SUITES_FILE"

TOTAL_SUITES="$(wc -l < "$SUITES_FILE" | tr -d ' ')"
[ "$TOTAL_SUITES" -gt 0 ] || { echo "suite enumeration produced nothing — check $TEST_SRC" >&2; exit 1; }
echo "enumerated $TOTAL_SUITES suites in $TEST_TARGET"

in_list() { # word, space-separated list
    local w="$1" l="$2" x
    for x in $l; do [ "$x" = "$w" ] && return 0; done
    return 1
}

BATCHABLE=()
ALONE=()
EXCLUDED=()
while IFS= read -r s; do
    if in_list "$s" "$EXCLUDE"; then EXCLUDED+=("$s")
    elif in_list "$s" "$PERF_ALONE"; then ALONE+=("$s"); else BATCHABLE+=("$s"); fi
done < "$SUITES_FILE"
echo "batchable: ${#BATCHABLE[@]}   perf-alone: ${#ALONE[@]}   excluded on this runtime: ${#EXCLUDED[@]}"
[ "${#EXCLUDED[@]}" -gt 0 ] && echo "excluded (TEST_BATCHED_EXCLUDE; not run here, not verified here): ${EXCLUDED[*]}"

# ── Build once ────────────────────────────────────────────────────────────

echo "build-for-testing ($SCHEME) ..."
BUILD_LOG="$RUN_DIR/build.log"
if ! xcodebuild build-for-testing -scheme "$SCHEME" -destination "$DEST" -derivedDataPath "$DD" \
        > "$BUILD_LOG" 2>&1; then
    echo "BUILD FAILED — tail of $BUILD_LOG:" >&2
    tail -40 "$BUILD_LOG" >&2
    write_verdict BUILD-FAILED "BUILD FAILED — tail of $BUILD_LOG:"
    exit 1
fi
echo "build ok"

# ── Batch execution with watchdog ─────────────────────────────────────────

descendants() { # pid — every process below it, deepest first
    local c
    for c in $(pgrep -P "$1" 2>/dev/null || true); do descendants "$c"; echo "$c"; done
}

recover_sim() { # xcodebuild-pid — this run's process tree and this run's simulator, nothing else
    local xcb="$1" tree t0 bp
    tree="$(descendants "$xcb")"
    echo "  recovery: killing this run's xcodebuild ($xcb) and its process tree, resetting simulator $SIM_UDID ($RECOVERY)" >&2
    kill -TERM "$xcb" 2>/dev/null || true
    sleep 5
    kill -KILL "$xcb" $tree 2>/dev/null || true   # the tree is a pid list, unquoted on purpose
    sleep 2
    xcrun simctl shutdown "$SIM_UDID" 2>/dev/null || true
    if [ "$RECOVERY" = "erase" ]; then
        xcrun simctl erase "$SIM_UDID" 2>/dev/null || true
    fi
    # Boot it again here and wait, so the next invocation starts on a booted
    # simulator instead of booting one silently under the watchdog.
    xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
    t0=$SECONDS
    xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1 &
    bp=$!
    while kill -0 "$bp" 2>/dev/null; do
        if [ $((SECONDS - t0)) -ge "$BOOT_WAIT_SECS" ]; then
            echo "  recovery: simulator $SIM_UDID did not report booted within ${BOOT_WAIT_SECS}s; continuing" >&2
            kill "$bp" 2>/dev/null || true
            break
        fi
        sleep 5
    done
    wait "$bp" 2>/dev/null || true
    echo "  recovery: simulator $SIM_UDID booted again ($((SECONDS - t0))s)" >&2
}

# Results accumulated as parallel indexed arrays (bash 3.2 — no assoc arrays).
R_LABEL=(); R_NSUITES=(); R_TESTS=(); R_PASSED=(); R_FAILED=(); R_SKIPPED=()
R_KNOWN=(); R_STATE=(); R_SECS=(); R_XCRESULT=(); R_MODE=()
FAILURES_FILE="$RUN_DIR/failures.txt"; : > "$FAILURES_FILE"
WEDGED=0

parse_xcresult() { # xcresult-path label mode(gating|report-only)
    local xc="$1" label="$2" mode="$3"
    xcrun xcresulttool get test-results summary --path "$xc" --compact 2>/dev/null \
        | LABEL="$label" MODE="$mode" python3 -c '
import json, os, sys
try:
    s = json.load(sys.stdin)
except Exception:
    print("COUNTS -1 -1 -1 -1 -1"); sys.exit(0)
print("COUNTS", s.get("totalTestCount", -1), s.get("passedTests", -1),
      s.get("failedTests", -1), s.get("skippedTests", -1),
      s.get("expectedFailures", -1))
for f in (s.get("testFailures") or []):
    ident = f.get("testIdentifierString") or f.get("testName") or "?"
    suite = ident.split("/")[0]
    print("FAIL", os.environ["LABEL"], os.environ["MODE"], suite, "::", ident)
'
}

run_invocation() { # label mode suite...
    local label="$1" mode="$2"; shift 2
    local nsuites=$#
    local args=() s
    for s in "$@"; do args+=("-only-testing:$TEST_TARGET/$s"); done

    local attempt=1 state log xc start now
    while :; do
        local tag="$label"
        [ "$attempt" -gt 1 ] && tag="$label-r$attempt"
        local raw="$RUN_DIR/$tag.raw.log"
        log="$RUN_DIR/$tag.log"
        xc="$RUN_DIR/$tag.xcresult"
        state="completed"
        local lastsize size lastprogress
        start="$(date +%s)"
        xcodebuild test-without-building -scheme "$SCHEME" -destination "$DEST" -derivedDataPath "$DD" \
            -resultBundlePath "$xc" "${args[@]}" > "$raw" 2>&1 &
        local pid=$!
        lastsize=0; lastprogress="$start"
        while kill -0 "$pid" 2>/dev/null; do
            sleep 10
            now="$(date +%s)"
            size="$(stat -f%z "$raw" 2>/dev/null || echo 0)"
            if [ "$size" != "$lastsize" ]; then lastsize="$size"; lastprogress="$now"; fi
            if [ $((now - start)) -gt $((TIMEOUT_MINS * 60)) ]; then
                echo "  WATCHDOG: $tag exceeded ${TIMEOUT_MINS}m — killing" >&2
                state="wedged"; break
            fi
            if [ $((now - lastprogress)) -gt "$STALL_SECS" ]; then
                echo "  WATCHDOG: $tag produced no output for ${STALL_SECS}s — killing" >&2
                state="wedged"; break
            fi
        done
        if [ "$state" = "wedged" ]; then
            recover_sim "$pid"
            wait "$pid" 2>/dev/null || true
            WEDGED=$((WEDGED + 1))
        else
            wait "$pid" || true   # nonzero on test failure — counted via xcresult
        fi
        now="$(date +%s)"

        # Log hygiene: strip framework spam, bound size, drop the raw capture.
        { $GREP -v 'attributedStringScaled' "$raw" 2>/dev/null || true; } \
            | tail -c "$LOG_CAP_BYTES" > "$log" || true
        rm -f "$raw"

        # A test-host install/launch refusal (SBMainWorkspace "Busy" /
        # "Application failed preflight checks") is simulator infrastructure,
        # not a test red — zero suites actually ran. Observed on back-to-back
        # ResectaApp host relaunches 2026-06-11. Retry once after a settle;
        # a second refusal marks the invocation incomplete (exit-2 class).
        if [ "$state" = "completed" ] \
                && $GREP -q 'Failed to install or launch the test runner' "$log"; then
            if [ "$attempt" -eq 1 ]; then
                echo "  LAUNCH FAILURE (test-host install/launch — sim infra, no suite ran): retrying once" >&2
                xcrun simctl shutdown "$SIM_UDID" 2>/dev/null || true
                sleep 10
                attempt=2
                continue
            fi
            state="launch-failed"
            WEDGED=$((WEDGED + 1))
        fi
        break
    done

    # Counts and failure detail only come from completed invocations — a
    # wedged/launch-failed batch verified nothing, and its xcresult carries
    # a synthetic failure entry that must not gate.
    local counts="-1 -1 -1 -1 -1"
    if [ "$state" = "completed" ] && { [ -d "$xc" ] || [ -f "$xc" ]; }; then
        local parsed
        parsed="$(parse_xcresult "$xc" "$label" "$mode" || true)"
        counts="$(printf '%s\n' "$parsed" | $GREP '^COUNTS' | head -1 | cut -d' ' -f2- || true)"
        [ -n "$counts" ] || counts="-1 -1 -1 -1 -1"
        printf '%s\n' "$parsed" | $GREP '^FAIL' >> "$FAILURES_FILE" || true
    fi
    set -- $counts
    R_LABEL+=("$label"); R_NSUITES+=("$nsuites"); R_TESTS+=("$1")
    R_PASSED+=("$2"); R_FAILED+=("$3"); R_SKIPPED+=("$4"); R_KNOWN+=("$5")
    R_STATE+=("$state"); R_SECS+=("$((now - start))")
    R_XCRESULT+=("$xc"); R_MODE+=("$mode")

    echo "  $label: state=$state tests=$1 passed=$2 failed=$3 skipped=$4 known-issues=$5 (${R_SECS[${#R_SECS[@]}-1]}s)"
    echo "  xcresult: $xc"
    if [ "$mode" = "report-only" ] && [ "$3" != "0" ] && [ "$3" != "-1" ]; then
        echo "  REPORT-ONLY red — never gates locally; read it by hand"
    fi
}

NBATCH=$(( (${#BATCHABLE[@]} + BATCH_SIZE - 1) / BATCH_SIZE ))
echo "running $NBATCH batches of <=$BATCH_SIZE suites, then ${#ALONE[@]} perf-alone suite(s)"

i=0
b=1
while [ "$i" -lt "${#BATCHABLE[@]}" ]; do
    chunk=("${BATCHABLE[@]:$i:$BATCH_SIZE}")
    echo "batch b$b/${NBATCH} (${#chunk[@]} suites):"
    run_invocation "b$b" "gating" "${chunk[@]}"
    i=$((i + BATCH_SIZE))
    b=$((b + 1))
    # Back-to-back test-host relaunches intermittently trip SBMainWorkspace
    # ("Application failed preflight checks") on the app scheme — give the
    # previous host instance a beat to tear down.
    [ "$SETTLE_SECS" -gt 0 ] && [ "$i" -lt "${#BATCHABLE[@]}" ] && sleep "$SETTLE_SECS"
done

if [ "${#ALONE[@]}" -gt 0 ]; then
    for s in "${ALONE[@]}"; do
        [ "$SETTLE_SECS" -gt 0 ] && sleep "$SETTLE_SECS"
        echo "perf-alone $s (completely alone, report-only):"
        run_invocation "alone-$s" "report-only" "$s"
    done
fi

# ── Summary ───────────────────────────────────────────────────────────────

echo ""
echo "── summary ($SCHEME) ──────────────────────────────────────────────"
TOT_TESTS=0; TOT_FAILED=0; TOT_KNOWN=0; TOT_SUITES=0; WEDGED_LABELS=""
j=0
while [ "$j" -lt "${#R_LABEL[@]}" ]; do
    printf '%-32s %-12s suites=%-3s tests=%-5s failed=%-3s known=%-3s %ss\n' \
        "${R_LABEL[$j]}" "${R_STATE[$j]}[${R_MODE[$j]}]" "${R_NSUITES[$j]}" \
        "${R_TESTS[$j]}" "${R_FAILED[$j]}" "${R_KNOWN[$j]}" "${R_SECS[$j]}"
    if [ "${R_TESTS[$j]}" != "-1" ]; then
        TOT_TESTS=$((TOT_TESTS + R_TESTS[j]))
        TOT_KNOWN=$((TOT_KNOWN + R_KNOWN[j]))
        TOT_SUITES=$((TOT_SUITES + R_NSUITES[j]))
        [ "${R_FAILED[$j]}" != "-1" ] && TOT_FAILED=$((TOT_FAILED + R_FAILED[j]))
    fi
    [ "${R_STATE[$j]}" != "completed" ] && WEDGED_LABELS="$WEDGED_LABELS ${R_LABEL[$j]}(${R_STATE[$j]})"
    j=$((j + 1))
done

# Gating offenders: failed suites from gating invocations, off the exclusion list.
OFFENDERS=""
EXCUSED=""
if [ -s "$FAILURES_FILE" ]; then
    while IFS= read -r line; do
        set -- $line               # FAIL label mode suite :: ident
        mode="$3"; suite="$4"
        if [ "$mode" = "gating" ] && ! in_list "$suite" "$NON_GATING"; then
            case " $OFFENDERS " in *" $suite "*) ;; *) OFFENDERS="$OFFENDERS $suite" ;; esac
        else
            case " $EXCUSED " in *" $suite "*) ;; *) EXCUSED="$EXCUSED $suite" ;; esac
        fi
    done < "$FAILURES_FILE"
fi

echo ""
TOTALS_LINE="totals: tests=$TOT_TESTS suites=$TOT_SUITES failed=$TOT_FAILED known-issues=$TOT_KNOWN wedged=$WEDGED excluded=${#EXCLUDED[@]}"
echo "$TOTALS_LINE"
[ "${#EXCLUDED[@]}" -gt 0 ] && echo "excluded on this runtime (not verified here; the pre-push hook runs them): ${EXCLUDED[*]}"
[ -n "$EXCUSED" ] && echo "non-gating reds (perf-alone or on the exclusion list — never gate locally):$EXCUSED"
[ -s "$FAILURES_FILE" ] && { echo "failure detail:"; sed 's/^/  /' "$FAILURES_FILE"; }
[ -n "$WEDGED_LABELS" ] && echo "incomplete invocations (suites NOT verified — re-run or salvage):$WEDGED_LABELS"

if [ -n "$OFFENDERS" ]; then
    echo "OFFENDERS:$OFFENDERS"
    VERDICT_LINE="VERDICT: FAIL scheme=$SCHEME tests=$TOT_TESTS suites=$TOT_SUITES gating-failures-in:$OFFENDERS"
    echo "$VERDICT_LINE"
    write_verdict FAIL "$TOTALS_LINE" "$VERDICT_LINE"
    exit 1
elif [ "$WEDGED" -gt 0 ]; then
    VERDICT_LINE="VERDICT: INCOMPLETE scheme=$SCHEME tests=$TOT_TESTS suites=$TOT_SUITES wedged=$WEDGED excluded=${#EXCLUDED[@]} (no gating reds in completed batches)"
    echo "$VERDICT_LINE"
    write_verdict INCOMPLETE "$TOTALS_LINE" "$VERDICT_LINE"
    exit 2
else
    VERDICT_LINE="VERDICT: PASS scheme=$SCHEME tests=$TOT_TESTS suites=$TOT_SUITES known-issues=$TOT_KNOWN gating-failures=0 excluded=${#EXCLUDED[@]}"
    echo "$VERDICT_LINE"
    write_verdict PASS "$TOTALS_LINE" "$VERDICT_LINE"
    exit 0
fi
