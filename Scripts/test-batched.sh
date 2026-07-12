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
#   Scripts/test-batched.sh RedactionEngine|ResectaApp [--batch-size N] [--timeout-mins M]
#
# Exit codes:
#   0  all reds (if any) are on the §3 exclusion list, no incomplete batches
#   1  at least one red outside the §3 exclusion list (offenders printed)
#   2  no gating reds, but >=1 invocation wedged or hit a test-host launch
#      refusal twice — those suites are unverified, coverage incomplete
#
# Logs and .xcresult bundles land under /tmp/test-batched-<scheme>-<stamp>/.
# Logs are spam-filtered (attributedStringScaled framework noise) and size-
# bounded; the per-batch .xcresult is the forensic source of record.
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
# REPORT-ONLY (their reds never set the exit status — adjudicate per
# verification.md §3). "Completely alone" is load-bearing: StressCorpusTests
# has been red when paired with even one other suite.
PERF_ALONE_RedactionEngine="CancellationLatencyTests PixelBufferZeroizeTests ReverseRationalePerformanceTests StressCorpusTests ApplyPhaseMemoryStressTests"
PERF_ALONE_ResectaApp="PageParallelRasterizationTests"

# §3 exclusion list (suite granularity): reds here do not gate the exit
# status even inside normal batches. Mirrors verification.md §3 bullet 1.
NON_GATING="ScreenCaptureShieldTests PageParallelRasterizationTests StressCorpusTests ImportServiceCancelTests"
# ──────────────────────────────────────────────────────────────────────────

BATCH_SIZE=28          # ~25-32 suites per batch
TIMEOUT_MINS=15        # hard per-invocation ceiling
STALL_SECS=180         # kill if the log stops growing this long
LOAD_WARN=8            # 1-min load average warning threshold
LOG_CAP_BYTES=20000000 # per-batch filtered-log size bound

usage() { sed -n '3,30p' "$0"; exit 64; }

[ $# -ge 1 ] || usage
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

STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="/tmp/test-batched-${SCHEME}-${STAMP}"
mkdir -p "$RUN_DIR"
echo "run dir: $RUN_DIR"

# ── Pre-flight ────────────────────────────────────────────────────────────

orphans_found=0
for pname in xctest xcodebuild; do
    pids="$(pgrep -x "$pname" 2>/dev/null || true)"
    if [ -n "$pids" ]; then
        orphans_found=1
        echo "PRE-FLIGHT: orphan $pname process(es): $pids" >&2
        echo "  kill with:  pkill -9 -x $pname" >&2
    fi
done
if [ "$orphans_found" -eq 1 ]; then
    echo "PRE-FLIGHT: refusing to start while orphan test processes exist" >&2
    echo "  (a stale xctest/xcodebuild from a dead run stalls every later run)" >&2
    exit 1
fi

LOAD1="$(sysctl -n vm.loadavg | awk '{print $2}')"
if [ "$(printf '%.0f' "$LOAD1")" -gt "$LOAD_WARN" ]; then
    echo "PRE-FLIGHT WARNING: 1-min load average is $LOAD1 (> $LOAD_WARN)." >&2
    echo "  Perf-budget suites are report-only, but batch wall time will inflate. Proceeding." >&2
fi

# Resolve an available iPhone 17 simulator (name may drift across runtimes;
# prefer a booted device, then exact name on the newest runtime, then prefix).
SIM_LINE="$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
data = json.load(sys.stdin)
best = None
for runtime, devs in data.get("devices", {}).items():
    m = re.search(r"iOS-(\d+)-(\d+)$", runtime)
    ver = (int(m.group(1)), int(m.group(2))) if m else (0, 0)
    for d in devs:
        name = d.get("name", "")
        if not name.startswith("iPhone 17"):
            continue
        exact = 1 if name == "iPhone 17" else 0
        booted = 1 if d.get("state") == "Booted" else 0
        key = (booted, exact, ver)
        if best is None or key > best[0]:
            best = (key, d["udid"], name, runtime)
if best is None:
    sys.exit(3)
print(best[1] + "|" + best[2] + " (" + best[3].rsplit(".", 1)[-1] + ")")
')" || { echo "PRE-FLIGHT: no available iPhone 17 simulator" >&2; exit 1; }
SIM_UDID="${SIM_LINE%%|*}"
echo "simulator: ${SIM_LINE#*|} [$SIM_UDID]"
DEST="id=$SIM_UDID"

# ── Suite enumeration (runtime, from Tests sources) ──────────────────────
# Top-level (column-0) @Suite-annotated types + XCTestCase subclasses.
# Validated 2026-06-11 against the live trees: engine 157, app 121.

SUITES_FILE="$RUN_DIR/suites.txt"
python3 - "$TEST_SRC" > "$SUITES_FILE" <<'PYEOF'
import os, re, sys

SUITE_ATTR = re.compile(r'^@Suite\b')
TYPE_DECL = re.compile(r'^(?:final\s+)?(?:class|struct|enum|actor)\s+(\w+)')
XCTEST_DECL = re.compile(r'^(?:final\s+)?class\s+(\w+)\s*:\s*[^{]*\bXCTestCase\b')

suites = set()
for dirpath, _, files in os.walk(sys.argv[1]):
    for fn in sorted(files):
        if not fn.endswith('.swift'):
            continue
        lines = open(os.path.join(dirpath, fn), encoding='utf-8',
                     errors='replace').read().splitlines()
        pending = False
        for line in lines:
            m = XCTEST_DECL.match(line)
            if m:
                suites.add(m.group(1)); pending = False; continue
            if SUITE_ATTR.match(line):
                pending = True
                m = TYPE_DECL.match(re.sub(r'^@Suite(\([^)]*\))?\s*', '', line))
                if m:
                    suites.add(m.group(1)); pending = False
                continue
            if pending:
                m = TYPE_DECL.match(line)
                if m:
                    suites.add(m.group(1)); pending = False
                elif line.strip() and not line.strip().startswith('//') \
                        and not line.strip().startswith('@'):
                    pending = False
for s in sorted(suites):
    print(s)
PYEOF

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
while IFS= read -r s; do
    if in_list "$s" "$PERF_ALONE"; then ALONE+=("$s"); else BATCHABLE+=("$s"); fi
done < "$SUITES_FILE"
echo "batchable: ${#BATCHABLE[@]}   perf-alone: ${#ALONE[@]}"

# ── Build once ────────────────────────────────────────────────────────────

echo "build-for-testing ($SCHEME) ..."
BUILD_LOG="$RUN_DIR/build.log"
if ! xcodebuild build-for-testing -scheme "$SCHEME" -destination "$DEST" \
        > "$BUILD_LOG" 2>&1; then
    echo "BUILD FAILED — tail of $BUILD_LOG:" >&2
    tail -40 "$BUILD_LOG" >&2
    exit 1
fi
echo "build ok"

# ── Batch execution with watchdog ─────────────────────────────────────────

recover_sim() {
    echo "  recovery: killing orphans, resetting simulator $SIM_UDID" >&2
    pkill -9 -x xctest 2>/dev/null || true
    pkill -9 -x xcodebuild 2>/dev/null || true
    sleep 2
    xcrun simctl shutdown all 2>/dev/null || true
    xcrun simctl erase "$SIM_UDID" 2>/dev/null || true
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
        xcodebuild test-without-building -scheme "$SCHEME" -destination "$DEST" \
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
            kill -TERM "$pid" 2>/dev/null || true
            sleep 5
            kill -KILL "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            recover_sim
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
                xcrun simctl shutdown all 2>/dev/null || true
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
        echo "  REPORT-ONLY red — adjudicate per verification.md §3 (never gates locally)"
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

# Gating offenders: failed suites from gating invocations, off the §3 list.
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
echo "totals: tests=$TOT_TESTS suites=$TOT_SUITES failed=$TOT_FAILED known-issues=$TOT_KNOWN wedged=$WEDGED"
[ -n "$EXCUSED" ] && echo "non-gating reds (perf-alone / §3-listed — adjudicate per verification.md §3):$EXCUSED"
[ -s "$FAILURES_FILE" ] && { echo "failure detail:"; sed 's/^/  /' "$FAILURES_FILE"; }
[ -n "$WEDGED_LABELS" ] && echo "incomplete invocations (suites NOT verified — re-run or salvage):$WEDGED_LABELS"

if [ -n "$OFFENDERS" ]; then
    echo "OFFENDERS:$OFFENDERS"
    echo "VERDICT: FAIL scheme=$SCHEME tests=$TOT_TESTS suites=$TOT_SUITES gating-failures-in:$OFFENDERS"
    exit 1
elif [ "$WEDGED" -gt 0 ]; then
    echo "VERDICT: INCOMPLETE scheme=$SCHEME tests=$TOT_TESTS suites=$TOT_SUITES wedged=$WEDGED (no gating reds in completed batches)"
    exit 2
else
    echo "VERDICT: PASS scheme=$SCHEME tests=$TOT_TESTS suites=$TOT_SUITES known-issues=$TOT_KNOWN gating-failures=0"
    exit 0
fi
