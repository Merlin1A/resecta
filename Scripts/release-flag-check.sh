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
    # Census every code image in the .app: the main binary plus any top-level
    # dylib. Under Xcode's debug-dylib layout the Debug main binary is a thin
    # launcher stub and ALL app code (and its literals) lives in
    # ResectaApp.debug.dylib — a main-binary-only census reads 0 forever.
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
