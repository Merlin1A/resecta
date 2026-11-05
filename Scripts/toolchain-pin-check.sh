#!/bin/sh
# toolchain-pin-check.sh — checks that a release archive was built with the
# pinned Xcode and SDK.
#
# The app's Info.plist records the toolchain that built it: DTXcodeBuild (the
# Xcode build, e.g. 27B52) and DTSDKName (the SDK, e.g. iphoneos27.2). The
# release is archived with DEVELOPER_DIR naming one Xcode, and a different
# Xcode can be picked up without notice (an App Store update of
# /Applications/Xcode.app, a changed xcode-select). This script compares the
# two keys with TOOLCHAIN_PIN below and fails on any difference, so an
# archive built with the wrong toolchain is caught before it is uploaded.
# Scripts/release-identity.sh records the same keys in the release's
# identity record; this script is the check, that script is the record.
#
# Usage:
#   Scripts/toolchain-pin-check.sh --archive PATH.xcarchive
#       Reads Products/Applications/<the one .app>/Info.plist in the archive.
#   Scripts/toolchain-pin-check.sh --info-plist PATH
#       Reads the given Info.plist (an app bundle's).
#   Scripts/toolchain-pin-check.sh --xcode
#       Compares the build of the xcodebuild on PATH (or DEVELOPER_DIR) with
#       the pinned DTXcodeBuild; for a CI log or a shell before an archive.
#   Scripts/toolchain-pin-check.sh --print-pin
#       Prints the pinned values, one KEY=VALUE per line.
#   Scripts/toolchain-pin-check.sh --self-test
#       Plants Info.plist files that match and that differ from the pin, and
#       a stub xcodebuild, and checks each verdict. Prints PASS or FAIL.
#
# Output: one line per key (`ok` or `MISMATCH`, the expected and the found
# value), then `MATCH` or `MISMATCH`.
# Exit: 0 every key matches; 1 a key differs or is missing; 2 an unreadable
# archive or plist; 64 usage.
#
# The pin moves only with a toolchain change: a pull request that moves the
# app to another Xcode changes this constant, and nothing else does.
set -eu

# The toolchain the release is built with (Xcode 27.2 final, iOS 27.2 SDK).
TOOLCHAIN_PIN="DTXcodeBuild=27B52 DTSDKName=iphoneos27.2"

usage() { sed -n '15,27p' "$0" >&2; exit 64; }

pin_value() { # key → pinned value
    for kv in $TOOLCHAIN_PIN; do
        case "$kv" in "$1="*) echo "${kv#*=}"; return 0 ;; esac
    done
    return 1
}

# Reads one string key from a plist; prints nothing when the key is absent.
plist_key() { # plist key
    python3 -I -c '
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    d = plistlib.load(f)
v = d.get(sys.argv[2])
if isinstance(v, str):
    print(v)
' "$1" "$2"
}

check_plist() { # Info.plist path → exit 0 / 1 / 2
    [ -f "$1" ] || { echo "toolchain-pin-check: no Info.plist at $1" >&2; return 2; }
    python3 -I -c 'import plistlib, sys; plistlib.load(open(sys.argv[1], "rb"))' "$1" 2>/dev/null \
        || { echo "toolchain-pin-check: unreadable plist $1" >&2; return 2; }
    bad=0
    for kv in $TOOLCHAIN_PIN; do
        key="${kv%%=*}"; want="${kv#*=}"
        got="$(plist_key "$1" "$key")"
        if [ "$got" = "$want" ]; then
            echo "ok        $key = $got"
        else
            echo "MISMATCH  $key: pinned $want, found ${got:-<absent>}"
            bad=1
        fi
    done
    if [ "$bad" -eq 0 ]; then echo "MATCH"; return 0; fi
    echo "MISMATCH"; return 1
}

archive_plist() { # archive → the one app's Info.plist path (or exit 2)
    [ -d "$1/Products/Applications" ] || { echo "toolchain-pin-check: not an app archive: $1" >&2; exit 2; }
    n=0; app=""
    for a in "$1"/Products/Applications/*.app; do
        [ -d "$a" ] || continue
        n=$((n + 1)); app="$a"
    done
    [ "$n" -eq 1 ] || { echo "toolchain-pin-check: expected one .app in $1/Products/Applications, found $n" >&2; exit 2; }
    echo "$app/Info.plist"
}

check_xcode() { # → exit 0 / 1 / 2
    want="$(pin_value DTXcodeBuild)"
    out="$(xcodebuild -version 2>/dev/null)" || { echo "toolchain-pin-check: xcodebuild -version failed" >&2; return 2; }
    got="$(printf '%s\n' "$out" | sed -n 's/^Build version //p' | head -1)"
    if [ "$got" = "$want" ]; then
        echo "ok        xcodebuild build = $got"; echo "MATCH"; return 0
    fi
    echo "MISMATCH  xcodebuild build: pinned $want, found ${got:-<unreadable>}"; echo "MISMATCH"; return 1
}

self_test() {
    t="$(mktemp -d "${TMPDIR:-/tmp}/toolchain-pin-check.XXXXXX")"
    fails=0
    me="$0"
    xb="$(pin_value DTXcodeBuild)"; sdk="$(pin_value DTSDKName)"
    write_plist() { # path build sdk  (an empty value leaves the key out)
        python3 -I -c '
import plistlib, sys
d = {"CFBundleIdentifier": "self.test"}
if sys.argv[2]: d["DTXcodeBuild"] = sys.argv[2]
if sys.argv[3]: d["DTSDKName"] = sys.argv[3]
with open(sys.argv[1], "wb") as f:
    plistlib.dump(d, f)
' "$1" "$2" "$3"
    }
    expect() { # label wanted-exit command...
        label="$1"; want="$2"; shift 2
        rc=0; out="$("$@" 2>&1)" || rc=$?
        if [ "$rc" -eq "$want" ]; then echo "self-test: $label → exit $rc OK"
        else echo "self-test: $label → exit $rc, wanted $want" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fails=1; fi
    }
    mkapp() { # archive-dir build sdk
        mkdir -p "$1/Products/Applications/Self.app"
        write_plist "$1/Products/Applications/Self.app/Info.plist" "$2" "$3"
    }
    # 1. The pinned values themselves are the green case.
    mkapp "$t/match.xcarchive" "$xb" "$sdk"
    expect "an archive built with the pinned Xcode and SDK" 0 sh "$me" --archive "$t/match.xcarchive"
    # 2. A planted DTXcodeBuild mismatch (the 27.2 release candidate) goes red.
    mkapp "$t/rc.xcarchive" 27B48 "$sdk"
    expect "a planted DTXcodeBuild mismatch (27B48)" 1 sh "$me" --archive "$t/rc.xcarchive"
    # 3. The 1.3.2 archive's toolchain (Xcode 26.6, iOS 26.5 SDK) goes red on both keys.
    mkapp "$t/old.xcarchive" 17F113 iphoneos26.5
    expect "an Xcode 26.6 archive (17F113, iphoneos26.5)" 1 sh "$me" --archive "$t/old.xcarchive"
    rc=0; out="$(sh "$me" --archive "$t/old.xcarchive" 2>&1)" || rc=$?
    n="$(printf '%s\n' "$out" | /usr/bin/grep -c '^MISMATCH  ' || true)"
    if [ "$n" -eq 2 ]; then echo "self-test: both keys are reported on a two-key mismatch OK"
    else echo "self-test: expected 2 MISMATCH key lines, got $n" >&2; fails=1; fi
    # 4. A planted DTSDKName mismatch alone goes red.
    mkapp "$t/sdk.xcarchive" "$xb" iphoneos27.1
    expect "a planted DTSDKName mismatch (iphoneos27.1)" 1 sh "$me" --archive "$t/sdk.xcarchive"
    # 5. A missing key is a mismatch, never a pass.
    mkapp "$t/absent.xcarchive" "" "$sdk"
    expect "an Info.plist without DTXcodeBuild" 1 sh "$me" --archive "$t/absent.xcarchive"
    # 6. An archive with no app, or with two, is unreadable (exit 2).
    mkdir -p "$t/empty.xcarchive/Products/Applications"
    expect "an archive with no .app" 2 sh "$me" --archive "$t/empty.xcarchive"
    mkapp "$t/two.xcarchive" "$xb" "$sdk"
    mkdir -p "$t/two.xcarchive/Products/Applications/Other.app"
    expect "an archive with two .app bundles" 2 sh "$me" --archive "$t/two.xcarchive"
    # 7. --info-plist reads a bundle's plist directly; garbage is unreadable.
    write_plist "$t/Info.plist" "$xb" "$sdk"
    expect "--info-plist on a matching plist" 0 sh "$me" --info-plist "$t/Info.plist"
    printf 'not a plist' > "$t/bad.plist"
    expect "--info-plist on a file that is not a plist" 2 sh "$me" --info-plist "$t/bad.plist"
    # 8. --xcode against a stub xcodebuild: the pinned build passes, another fails.
    mkdir -p "$t/bin-ok" "$t/bin-rc"
    printf '#!/bin/sh\necho "Xcode 27.2"\necho "Build version %s"\n' "$xb" > "$t/bin-ok/xcodebuild"
    printf '#!/bin/sh\necho "Xcode 27.2"\necho "Build version 27B48"\n' > "$t/bin-rc/xcodebuild"
    chmod +x "$t/bin-ok/xcodebuild" "$t/bin-rc/xcodebuild"
    expect "--xcode with the pinned build on PATH" 0 env PATH="$t/bin-ok:$PATH" sh "$me" --xcode
    expect "--xcode with the release candidate (27B48) on PATH" 1 env PATH="$t/bin-rc:$PATH" sh "$me" --xcode
    # 9. The pin is one constant naming exactly the two keys.
    n="$(/usr/bin/grep -c '^TOOLCHAIN_PIN=' "$me")"
    case "$TOOLCHAIN_PIN" in
        "DTXcodeBuild="*" DTSDKName="*)
            if [ "$n" -eq 1 ]; then echo "self-test: one TOOLCHAIN_PIN constant with DTXcodeBuild and DTSDKName OK"
            else echo "self-test: expected one TOOLCHAIN_PIN line, found $n" >&2; fails=1; fi ;;
        *) echo "self-test: TOOLCHAIN_PIN does not name DTXcodeBuild then DTSDKName: $TOOLCHAIN_PIN" >&2; fails=1 ;;
    esac
    rm -rf "$t"
    if [ "$fails" -eq 0 ]; then echo "self-test: PASS"; exit 0; fi
    echo "self-test: FAIL" >&2; exit 1
}

[ $# -ge 1 ] || usage
case "$1" in
    --self-test) self_test ;;
    --print-pin) for kv in $TOOLCHAIN_PIN; do echo "$kv"; done ;;
    --xcode) [ $# -eq 1 ] || usage; rc=0; check_xcode || rc=$?; exit "$rc" ;;
    --archive) [ $# -eq 2 ] || usage; p="$(archive_plist "$2")"; rc=0; check_plist "$p" || rc=$?; exit "$rc" ;;
    --info-plist) [ $# -eq 2 ] || usage; rc=0; check_plist "$2" || rc=$?; exit "$rc" ;;
    *) usage ;;
esac
