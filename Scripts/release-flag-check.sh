#!/bin/sh
# release-flag-check.sh — binary-level proof that the DEBUG-only launch-arg
# surfaces are compiled out of Release (1.2 instrumentation plan I-8).
#
# Method: code under `#if DEBUG` is not compiled in Release, so its launch-arg
# string literal cannot appear in the Release binary. A `strings` census over
# the built app binary is therefore a proof independent of the test runner
# (which only ever builds Debug). The existing `--showRetiredSheetControls`
# arg (SearchState.scanCategoryStripEnabled) is the positive control that the
# method detects a literal when one IS compiled in.
#
# Usage:
#   Scripts/release-flag-check.sh                # post-re-light expectations:
#                                                #   Release: 0 of each arg
#                                                #   Debug:  >=1 of each arg
#   Scripts/release-flag-check.sh --pre-relight  # baseline before the
#                                                # --enableAuditSurfaces re-light
#                                                # lands: that arg must be 0 in
#                                                # BOTH configs; the precedent
#                                                # arg still proves the method.
#   Scripts/release-flag-check.sh --archive PATH/ResectaApp.app
#                                                # the archived app itself: both
#                                                # args 0 in its code images and
#                                                # no UITestFixtures file name
#                                                # anywhere in the bundle. Run at
#                                                # the archive SHA; its two
#                                                # result lines go in the
#                                                # release record.
#   Scripts/release-flag-check.sh --self-test    # the census and the fixture
#                                                # check on synthetic bundles;
#                                                # no build.
#
# Also prints the `#if DEBUG` census over Sources/ (drift alarm, not a gate).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GREP=/usr/bin/grep

NEW_ARG='--enableAuditSurfaces'
PRECEDENT_ARG='--showRetiredSheetControls'

PRE_RELIGHT=0
if [ "${1:-}" = "--pre-relight" ]; then PRE_RELIGHT=1; fi

SCRATCH="$(mktemp -d /tmp/release-flag-check.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

FAIL=0

# Census every code image in an .app: the main binary plus any top-level
# dylib. Under Xcode's debug-dylib layout the Debug main binary is a thin
# launcher stub and ALL app code (and its literals) lives in
# ResectaApp.debug.dylib — a main-binary-only census reads 0 forever.
# Sets N_NEW and N_PRECEDENT.
census_app() {
    APP="$1"
    IMAGES="$APP/ResectaApp"
    for d in "$APP"/*.dylib; do
        [ -e "$d" ] && IMAGES="$IMAGES $d"
    done
    N_NEW=0; N_PRECEDENT=0
    for img in $IMAGES; do
        n1="$(strings "$img" | $GREP -c -- "$NEW_ARG" || true)"
        n2="$(strings "$img" | $GREP -c -- "$PRECEDENT_ARG" || true)"
        N_NEW=$((N_NEW + n1)); N_PRECEDENT=$((N_PRECEDENT + n2))
    done
}

# The UI-test fixtures are committed and Release strips them from the
# bundle by file name (project.yml); count the fixture file names found
# anywhere in an .app. $2 = the fixtures directory. Sets N_FIXTURES,
# N_FIXTURE_NAMES and FIXTURE_HITS.
fixtures_in_app() {
    APP="$1"; FIXTURE_DIR="$2"
    N_FIXTURES=0; N_FIXTURE_NAMES=0; FIXTURE_HITS=""
    for f in "$FIXTURE_DIR"/*; do
        [ -f "$f" ] || continue
        name="$(basename "$f")"
        N_FIXTURE_NAMES=$((N_FIXTURE_NAMES + 1))
        hit="$(/usr/bin/find "$APP" -name "$name" | head -1)"
        if [ -n "$hit" ]; then
            N_FIXTURES=$((N_FIXTURES + 1)); FIXTURE_HITS="$FIXTURE_HITS ${hit#"$APP"/}"
        fi
    done
}

# The archived app: the two result lines for the release record.
archive_check() {
    APP="$1"
    if [ ! -d "$APP" ] || [ ! -e "$APP/ResectaApp" ]; then
        echo "RELEASE-FLAG-CHECK FAIL: not an app bundle with a ResectaApp binary: $APP"
        exit 2
    fi
    census_app "$APP"
    fixtures_in_app "$APP" "$ROOT/UITestFixtures"
    echo "archive counts: $NEW_ARG=$N_NEW $PRECEDENT_ARG=$N_PRECEDENT"
    echo "archive fixtures: $N_FIXTURES of $N_FIXTURE_NAMES UITestFixtures file names present${FIXTURE_HITS:+ (}${FIXTURE_HITS# }${FIXTURE_HITS:+)}"
    [ "$N_NEW" -eq 0 ] && [ "$N_PRECEDENT" -eq 0 ] && [ "$N_FIXTURES" -eq 0 ]
}

if [ "${1:-}" = "--archive" ]; then
    [ $# -ge 2 ] || { echo "usage: $0 --archive PATH/ResectaApp.app" >&2; exit 64; }
    if archive_check "$2"; then echo "RELEASE-FLAG-CHECK PASS (archive)"; exit 0; fi
    echo "RELEASE-FLAG-CHECK FAIL (archive)"
    exit 1
fi

if [ "${1:-}" = "--self-test" ]; then
    ok=1
    make_app() { mkdir -p "$SCRATCH/$1.app"; printf '%s\n' "$2" > "$SCRATCH/$1.app/ResectaApp"; }
    make_app clean "plain launcher text"
    make_app fixture "plain launcher text"
    cp "$ROOT/UITestFixtures/test_sample.pdf" "$SCRATCH/fixture.app/"
    make_app literal "release build $PRECEDENT_ARG"
    archive_check "$SCRATCH/clean.app" >/dev/null || ok=0
    archive_check "$SCRATCH/fixture.app" >/dev/null && ok=0
    archive_check "$SCRATCH/literal.app" >/dev/null && ok=0
    fixtures_in_app "$SCRATCH/fixture.app" "$ROOT/UITestFixtures"
    [ "$N_FIXTURES" -eq 1 ] || ok=0
    if [ "$ok" -eq 1 ]; then
        echo "release-flag-check --self-test: OK (a clean bundle passes; a bundled fixture and a compiled-in launch argument each fail)"
        exit 0
    fi
    echo "release-flag-check --self-test: DRIFTED — the census or the fixture check misread a synthetic bundle" >&2
    exit 1
fi

count_in_binary() {
    # $1 = configuration
    CONFIG="$1"
    xcodebuild -project "$ROOT/ResectaApp.xcodeproj" -scheme ResectaApp \
        -configuration "$CONFIG" -sdk iphonesimulator \
        -destination 'generic/platform=iOS Simulator' build \
        SYMROOT="$SCRATCH/$CONFIG" CODE_SIGNING_ALLOWED=NO -quiet \
        > "$SCRATCH/$CONFIG-build.log" 2>&1 || {
            echo "RELEASE-FLAG-CHECK FAIL: $CONFIG build failed (log: $SCRATCH/$CONFIG-build.log)"
            tail -30 "$SCRATCH/$CONFIG-build.log"
            exit 2
        }
    APP="$(/usr/bin/find "$SCRATCH/$CONFIG" -name ResectaApp.app -type d | head -1)"
    if [ -z "$APP" ]; then
        echo "RELEASE-FLAG-CHECK FAIL: $CONFIG ResectaApp.app not found under $SCRATCH/$CONFIG"
        exit 2
    fi
    census_app "$APP"
    echo "$CONFIG images: $IMAGES"
    echo "$CONFIG counts: $NEW_ARG=$N_NEW $PRECEDENT_ARG=$N_PRECEDENT"
}

check() {
    # $1 label, $2 actual, $3 expectation (zero|nonzero)
    if [ "$3" = "zero" ] && [ "$2" -ne 0 ]; then
        echo "RELEASE-FLAG-CHECK FAIL: $1 expected 0, got $2"; FAIL=1
    fi
    if [ "$3" = "nonzero" ] && [ "$2" -eq 0 ]; then
        echo "RELEASE-FLAG-CHECK FAIL: $1 expected >=1, got 0"; FAIL=1
    fi
}

echo "== Release =="
count_in_binary Release
REL_NEW="$N_NEW"; REL_PRECEDENT="$N_PRECEDENT"
check "Release $NEW_ARG" "$REL_NEW" zero
check "Release $PRECEDENT_ARG" "$REL_PRECEDENT" zero

echo "== Debug =="
count_in_binary Debug
DBG_NEW="$N_NEW"; DBG_PRECEDENT="$N_PRECEDENT"
check "Debug $PRECEDENT_ARG (method positive control)" "$DBG_PRECEDENT" nonzero
if [ "$PRE_RELIGHT" -eq 1 ]; then
    check "Debug $NEW_ARG (pre-re-light baseline)" "$DBG_NEW" zero
else
    check "Debug $NEW_ARG" "$DBG_NEW" nonzero
fi

echo "== #if DEBUG census (drift alarm, not a gate) =="
$GREP -rn '#if DEBUG' "$ROOT/Sources" | sed "s|$ROOT/||" || true
N_DEBUG="$($GREP -rn '#if DEBUG' "$ROOT/Sources" | wc -l | tr -d ' ')"
echo "#if DEBUG sites in Sources/: $N_DEBUG"

if [ "$FAIL" -ne 0 ]; then
    echo "RELEASE-FLAG-CHECK FAIL"
    exit 1
fi
echo "RELEASE-FLAG-CHECK PASS"
