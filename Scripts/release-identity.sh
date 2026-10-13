#!/bin/sh
# shellcheck disable=SC2016 # single-quoted backticks are Markdown code spans, not command substitution
# release-identity.sh — an identity record of the archived release build:
# the main executable's UUID and SHA-256, the libraries it links, its
# imported symbols checked against a list of networking interfaces, its
# entitlements, the security-relevant Info.plist keys, the privacy manifest
# and the SHA-256 of every other file in the app bundle.
#
# Method: every field is read from the app inside the Xcode archive with
# the system tools (dwarfdump, otool, nm, codesign, shasum, and python3's
# plistlib for the property lists); nothing is built and the archive is only
# read. The output is deterministic: lists are sorted, no clock is read and
# no absolute local path is written, so the same archive gives the same
# bytes, and --check compares a published record with a fresh derivation.
# The script refuses to write a record that would contain the home
# directory, the archive's location or the signing certificate's name.
#
# Usage:
#   Scripts/release-identity.sh --archive PATH.xcarchive [--tag TAG] [--gate COMMIT] [--mac yes|no]
#       Writes RELEASES/<CFBundleShortVersionString>-identity.md and prints a
#       one-line summary. Run it after the archive has been uploaded: the
#       upload entry Xcode keeps in the archive is part of the record.
#       --tag    the release tag. The record gives the tag's commit and, for
#                each bundled file, the tracked files at that commit with
#                the same bytes.
#       --gate   the commit the release gate ran on (needs --tag). The record
#                lists the paths that differ between it and the tag's commit.
#       --mac    whether the App Store listing offers the release on
#                Apple-silicon Macs; it selects the comparison paragraph.
#   Scripts/release-identity.sh --archive PATH.xcarchive --check RELEASES/<file>
#       Re-derives the record into a temporary file and compares the two byte
#       for byte: prints MATCH and exits 0, or prints the diff and exits 1.
#       --tag, --gate and --mac default to the values the record states.
#
# The networking check reads the imported (undefined) symbols, `nm -u`, and
# counts those that contain a name in NET_SUBSTRINGS or are exactly a name in
# NET_FUNCTIONS (both lists below). An import list shows what the executable
# binds to when it loads; a function looked up by name at run time is not in
# it, so the count is read alongside the source-level check in ENGINEERING.md.
#
# Exit: 0 written or MATCH; 1 the record differs (--check); 2 an unreadable
# archive or a record the privacy guard refused; 64 usage.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GREP=/usr/bin/grep
FIND=/usr/bin/find
SCRIPT_NAME="Scripts/release-identity.sh"
LC_ALL=C
export LC_ALL

# Network client interfaces, counted when an imported symbol contains the
# name (Swift-mangled and Objective-C class symbols carry the type name).
# WKWebView is a view, not a network client, and is not on the list.
NET_SUBSTRINGS='URLSession NSURLSession NSURLConnection URLRequest NWConnection NWListener NWBrowser NWPathMonitor nw_connection nw_listener nw_browser CFNetwork CFSocket CFStream CFHost SCNetworkReachability'
# BSD socket and resolver functions, counted when imported under exactly
# this name.
NET_FUNCTIONS='_socket _connect _getaddrinfo _gethostbyname _bind _listen _accept _send _sendto _sendmsg _recv _recvfrom _recvmsg'

usage() { sed -n '3,42p' "$0" >&2; exit 64; }
die() { echo "release-identity: $1" >&2; exit 2; }

ARCHIVE=""; CHECK=""; TAG=""; GATE=""; MAC=""
while [ $# -gt 0 ]; do
    case "$1" in
        --archive) [ $# -ge 2 ] || usage; ARCHIVE="$2"; shift 2 ;;
        --check) [ $# -ge 2 ] || usage; CHECK="$2"; shift 2 ;;
        --tag) [ $# -ge 2 ] || usage; TAG="$2"; shift 2 ;;
        --gate) [ $# -ge 2 ] || usage; GATE="$2"; shift 2 ;;
        --mac) [ $# -ge 2 ] || usage
               case "$2" in yes|no) MAC="$2" ;; *) usage ;; esac; shift 2 ;;
        -h|--help) sed -n '3,42p' "$0"; exit 0 ;;
        *) echo "release-identity: unknown option: $1" >&2; usage ;;
    esac
done
[ -n "$ARCHIVE" ] || usage
ARCHIVE="${ARCHIVE%/}"
[ -f "$ARCHIVE/Info.plist" ] || die "not an Xcode archive (no Info.plist): $ARCHIVE"
ARCHIVE_ABS="$(cd "$ARCHIVE" && pwd)"
ARCHIVE_NAME="$(basename "$ARCHIVE_ABS")"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/release-identity.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

# The property-list reader. Modes:
#   get FILE KEY.PATH      a scalar value, or nothing when absent
#   entitlements FILE      table rows: key | value
#   info FILE              table rows for the security-relevant Info.plist keys
#   privacy FILE           the privacy manifest as tables
#   archive FILE           table rows from the archive's own Info.plist
PLIST_PY='
import datetime, json, plistlib, re, sys

def load(path):
    with open(path, "rb") as f:
        return plistlib.load(f)

def cell(s):
    return str(s).replace("|", "\\|").replace("\n", " ")

def fmt(v):
    if isinstance(v, bool):
        return "`true`" if v else "`false`"
    if isinstance(v, (int, float)):
        return "`%s`" % v
    if isinstance(v, str):
        return "`%s`" % cell(v)
    if isinstance(v, datetime.datetime):
        return "`%s`" % v.strftime("%Y-%m-%dT%H:%M:%SZ")
    if isinstance(v, (bytes, bytearray)):
        return "%d bytes of data" % len(v)
    if isinstance(v, list):
        return ", ".join(fmt(x) for x in v) if v else "empty list"
    if isinstance(v, dict):
        return "`%s`" % cell(json.dumps(v, sort_keys=True, separators=(",", ":"), default=str))
    return "`%s`" % cell(v)

def names(v, key):
    if not isinstance(v, list):
        return fmt(v)
    out = sorted(str(x.get(key, "(unnamed)")) for x in v if isinstance(x, dict))
    return ", ".join("`%s`" % cell(n) for n in out) if out else "empty list"

mode, path = sys.argv[1], sys.argv[2]
p = load(path)

if mode == "get":
    v = p
    for part in sys.argv[3].split("."):
        v = v.get(part) if isinstance(v, dict) else None
    if v is not None and not isinstance(v, (dict, list)):
        print(v)

elif mode == "entitlements":
    for k in sorted(p):
        print("| `%s` | %s |" % (cell(k), fmt(p[k])))

elif mode == "info":
    rows = [
        ("CFBundleIdentifier", None), ("CFBundleShortVersionString", None),
        ("CFBundleVersion", None), ("MinimumOSVersion", None),
        ("DTSDKName", "built with"), ("DTXcodeBuild", "built with"),
        ("UIDeviceFamily", None), ("UIRequiredDeviceCapabilities", None),
        ("NSAppTransportSecurity", None), ("UIFileSharingEnabled", None),
        ("LSSupportsOpeningDocumentsInPlace", None), ("UIBackgroundModes", None),
        ("ITSAppUsesNonExemptEncryption", None), ("CFBundleURLTypes", "URL schemes"),
        ("LSApplicationQueriesSchemes", None),
        ("CFBundleDocumentTypes", "type names"),
        ("UTExportedTypeDeclarations", "type identifiers"),
        ("UTImportedTypeDeclarations", "type identifiers"),
    ]
    for key, note in rows:
        label = "`%s`" % key + (" (%s)" % note if note else "")
        if key not in p:
            value = "absent"
        elif key == "CFBundleURLTypes":
            schemes = sorted(s for t in p[key] if isinstance(t, dict) for s in t.get("CFBundleURLSchemes", []))
            value = ", ".join("`%s`" % cell(s) for s in schemes) if schemes else "empty list"
        elif key == "CFBundleDocumentTypes":
            value = names(p[key], "CFBundleTypeName")
        elif key.startswith("UT"):
            value = names(p[key], "UTTypeIdentifier")
        else:
            value = fmt(p[key])
        print("| %s | %s |" % (label, value))
    usage = sorted(k for k in p if re.fullmatch(r"NS[A-Za-z]*UsageDescription", k))
    if usage:
        for k in usage:
            print("| `%s` | %s |" % (k, fmt(p[k])))
    else:
        print("| `NS…UsageDescription` (any) | absent: no usage-description key |")

elif mode == "privacy":
    print("| Key | Value |")
    print("|---|---|")
    print("| `NSPrivacyTracking` | %s |" % (fmt(p["NSPrivacyTracking"]) if "NSPrivacyTracking" in p else "absent"))
    domains = p.get("NSPrivacyTrackingDomains")
    print("| `NSPrivacyTrackingDomains` | %s |" % ("absent" if domains is None else (fmt(sorted(domains)) if domains else "empty list")))
    collected = p.get("NSPrivacyCollectedDataTypes")
    print("| `NSPrivacyCollectedDataTypes` | %s |" % ("absent" if collected is None else ("empty list" if not collected else "%d entries, below" % len(collected))))
    if collected:
        print()
        print("| Collected data type | Linked to the user | Used for tracking | Purposes |")
        print("|---|---|---|---|")
        for c in sorted(collected, key=lambda c: str(c.get("NSPrivacyCollectedDataType", ""))):
            print("| %s | %s | %s | %s |" % (
                fmt(c.get("NSPrivacyCollectedDataType", "")),
                fmt(c.get("NSPrivacyCollectedDataTypeLinked", "absent")),
                fmt(c.get("NSPrivacyCollectedDataTypeTracking", "absent")),
                fmt(sorted(c.get("NSPrivacyCollectedDataTypePurposes", [])))))
    apis = p.get("NSPrivacyAccessedAPITypes") or []
    print()
    if apis:
        print("| Accessed API type | Reason codes |")
        print("|---|---|")
        for a in sorted(apis, key=lambda a: str(a.get("NSPrivacyAccessedAPIType", ""))):
            print("| %s | %s |" % (fmt(a.get("NSPrivacyAccessedAPIType", "")),
                                   fmt(sorted(a.get("NSPrivacyAccessedAPITypeReasons", [])))))
    else:
        print("Accessed API types: none declared.")

elif mode == "archive":
    ap = p.get("ApplicationProperties", {})
    ident = str(ap.get("SigningIdentity", ""))
    print("| Archive format (`ArchiveVersion`) | %s |" % (fmt(p["ArchiveVersion"]) if "ArchiveVersion" in p else "absent"))
    print("| Archive created (`CreationDate`) | %s |" % (fmt(p["CreationDate"]) if "CreationDate" in p else "absent"))
    print("| Signing identity type | %s |" % (fmt(ident.split(":")[0].strip()) if ident else "absent"))
    print("| Architectures | %s |" % fmt(ap.get("Architectures", [])))
    uploads = []
    for d in p.get("Distributions", []) or []:
        if not isinstance(d, dict) or d.get("destination") != "upload":
            continue
        ev = d.get("uploadEvent") or {}
        uploads.append("%s (Apple ID %s), build %s, %s, %s" % (
            cell(d.get("uploadDestination", "unknown destination")), fmt(d.get("adamId", "")),
            fmt(d.get("uploadedBuildNumber", "")), fmt(ev.get("date", "")), fmt(ev.get("state", ""))))
    print("| Uploads recorded in the archive | %s |" % ("; ".join(uploads) if uploads else "none"))

else:
    sys.exit("unknown mode " + mode)
'
plist() { python3 -I -c "$PLIST_PY" "$@"; }

# The app inside the archive.
APP_REL="$(plist get "$ARCHIVE/Info.plist" ApplicationProperties.ApplicationPath)"
[ -n "$APP_REL" ] || die "the archive's Info.plist names no ApplicationPath"
APP="$ARCHIVE/Products/$APP_REL"
[ -f "$APP/Info.plist" ] || die "no app bundle at Products/$APP_REL in the archive"
APP_NAME="$(basename "$APP")"
EXE_NAME="$(plist get "$APP/Info.plist" CFBundleExecutable)"
EXE="$APP/$EXE_NAME"
[ -n "$EXE_NAME" ] && [ -f "$EXE" ] || die "the app's main executable is missing"
VERSION="$(plist get "$APP/Info.plist" CFBundleShortVersionString)"
BUILD="$(plist get "$APP/Info.plist" CFBundleVersion)"
BUNDLE_ID="$(plist get "$APP/Info.plist" CFBundleIdentifier)"
[ -n "$VERSION" ] || die "the app's Info.plist has no CFBundleShortVersionString"
SIGNING_IDENTITY="$(plist get "$ARCHIVE/Info.plist" ApplicationProperties.SigningIdentity)"

# --check: the release facts default to the values the record states.
record_value() { sed -n "s/^| $1 | \`\\([^\`]*\\)\` |\$/\\1/p" "$CHECK" | head -1; }
if [ -n "$CHECK" ]; then
    [ -f "$CHECK" ] || die "no record to check at $CHECK"
    [ -n "$TAG" ] || TAG="$(record_value 'Release tag')"
    [ -n "$GATE" ] || GATE="$(record_value 'Gated commit')"
    [ -n "$MAC" ] || MAC="$(record_value 'Offered on Apple-silicon Macs (App Store listing)')"
fi
[ -z "$GATE" ] || [ -n "$TAG" ] || { echo "release-identity: --gate needs --tag" >&2; usage; }

TAG_COMMIT=""; GATE_COMMIT=""
if [ -n "$TAG" ]; then
    TAG_COMMIT="$(git -C "$ROOT" rev-parse --verify --quiet "refs/tags/$TAG^{commit}")" \
        || die "tag $TAG is not in this repository (fetch the tags first)"
    git -C "$ROOT" -c core.quotePath=false ls-tree -r --full-tree "$TAG_COMMIT" > "$SCRATCH/tree.txt"
fi
if [ -n "$GATE" ]; then
    GATE_COMMIT="$(git -C "$ROOT" rev-parse --verify --quiet "$GATE^{commit}")" \
        || die "commit $GATE is not in this repository"
fi

# The main executable.
dwarfdump --uuid "$EXE" | sed -n 's/^UUID: \([0-9A-Fa-f-]*\) (\([^)]*\)).*/\1 \2/p' > "$SCRATCH/uuid.txt"
[ -s "$SCRATCH/uuid.txt" ] || die "dwarfdump read no UUID from the executable"
EXE_SHA="$(shasum -a 256 < "$EXE" | cut -d' ' -f1)"

# Linked libraries, as otool prints them, without the header line (the
# executable's path; one per architecture in a universal binary).
otool -L "$EXE" | $GREP -v ':$' | sed 's/^[[:space:]]*//' > "$SCRATCH/libs.txt"
N_LIBS="$($GREP -c . "$SCRATCH/libs.txt" || true)"

# Imported symbols and the networking check.
nm -u "$EXE" | $GREP -v -e '^$' -e ':$' | sort -u > "$SCRATCH/imports.txt" || true
N_IMPORTS="$($GREP -c . "$SCRATCH/imports.txt" || true)"
: > "$SCRATCH/net-rows.txt"; : > "$SCRATCH/net-hits.txt"
for p in $NET_SUBSTRINGS; do
    $GREP -F -- "$p" "$SCRATCH/imports.txt" >> "$SCRATCH/net-hits.txt" || true
    n="$($GREP -c -F -- "$p" "$SCRATCH/imports.txt" || true)"
    printf '| `%s` | contains | %s |\n' "$p" "$n" >> "$SCRATCH/net-rows.txt"
done
for p in $NET_FUNCTIONS; do
    $GREP -x -F -- "$p" "$SCRATCH/imports.txt" >> "$SCRATCH/net-hits.txt" || true
    n="$($GREP -c -x -F -- "$p" "$SCRATCH/imports.txt" || true)"
    printf '| `%s` | exactly | %s |\n' "$p" "$n" >> "$SCRATCH/net-rows.txt"
done
sort -u "$SCRATCH/net-hits.txt" -o "$SCRATCH/net-hits.txt"
N_NET="$($GREP -c . "$SCRATCH/net-hits.txt" || true)"
HAS_DLSYM=0; $GREP -qx -F '_dlsym' "$SCRATCH/imports.txt" && HAS_DLSYM=1

# Entitlements (the --xml form, or the older ':-' form).
codesign -d --entitlements - --xml "$APP" > "$SCRATCH/ent.plist" 2>/dev/null || : > "$SCRATCH/ent.plist"
if ! $GREP -q '<plist' "$SCRATCH/ent.plist"; then
    codesign -d --entitlements :- "$APP" > "$SCRATCH/ent.plist" 2>/dev/null || : > "$SCRATCH/ent.plist"
fi

# Every file in the bundle, sorted; the digested set leaves out the main
# executable, _CodeSignature/ and embedded.mobileprovision.
(cd "$APP" && $FIND . \( -type f -o -type l \) | sed 's|^\./||' | sort) > "$SCRATCH/all.txt"
# shellcheck disable=SC1003 # the last pattern is one literal backslash
if $GREP -q -e '|' -e '`' -e '\\' "$SCRATCH/all.txt"; then die "a bundled file name holds a character the table cannot carry"; fi
N_ALL="$($GREP -c . "$SCRATCH/all.txt" || true)"
$GREP -v -x -F -e "$EXE_NAME" -e 'embedded.mobileprovision' "$SCRATCH/all.txt" \
    | $GREP -v -e '^_CodeSignature/' -e '/_CodeSignature/' > "$SCRATCH/files.txt" || true
N_FILES="$($GREP -c . "$SCRATCH/files.txt" || true)"
(cd "$APP" && $FIND . -mindepth 1 -type d \( -name '*.bundle' -o -name '*.framework' -o -name '*.appex' -o -name '*.app' -o -name '*.xpc' \) | sed 's|^\./||' | sort) > "$SCRATCH/nested.txt"
(cd "$APP" && $FIND . -name PrivacyInfo.xcprivacy -type f | sed 's|^\./||' | sort) > "$SCRATCH/privacy.txt"

# For one bundled file: the tracked files at the tag's commit with the same
# bytes. Candidates end with the file's path inside its innermost bundle.
same_at_tag() { # bundle-relative path, digest
    inner="$(printf '%s' "$1" | sed 's|^.*\.bundle/||; s|^.*\.framework/||')"
    awk -F '\t' -v s="$inner" '{ n = length($2) - length(s); if ($2 == s || (n > 0 && substr($2, n) == "/" s)) { split($1, a, " "); print a[3] " " $2 } }' \
        "$SCRATCH/tree.txt" > "$SCRATCH/cands.txt"
    hits=""
    while read -r blob path; do
        if [ "$(git -C "$ROOT" cat-file blob "$blob" | shasum -a 256 | cut -d' ' -f1)" = "$2" ]; then
            hits="$hits${hits:+, }\`$path\`"
        fi
    done < "$SCRATCH/cands.txt"
    printf '%s' "${hits:-—}"
}

render() {
    echo "# Resecta $VERSION ($BUILD): identity record of the archived build"
    echo
    echo "This record describes the app bundle in the Xcode archive \`$ARCHIVE_NAME\`, as \`$SCRIPT_NAME\` reads it. Running the script again on the same archive in this repository gives this file byte for byte (the command is at the end)."
    echo
    echo "## Source"
    echo
    echo "| Field | Value |"
    echo "|---|---|"
    echo "| Bundle identifier | \`$BUNDLE_ID\` |"
    echo "| Version (build) | \`$VERSION\` (\`$BUILD\`) |"
    if [ -n "$TAG" ]; then
        echo "| Release tag | \`$TAG\` |"
        echo "| Tag's commit | \`$TAG_COMMIT\` |"
    fi
    if [ -n "$GATE" ]; then
        echo "| Gated commit | \`$GATE_COMMIT\` |"
        if git -C "$ROOT" merge-base --is-ancestor "$GATE_COMMIT" "$TAG_COMMIT"; then anc=yes; else anc=no; fi
        echo "| Gated commit is an ancestor of the tag's commit | $anc |"
    fi
    [ -z "$MAC" ] || echo "| Offered on Apple-silicon Macs (App Store listing) | \`$MAC\` |"
    if [ -n "$TAG" ] || [ -n "$MAC" ]; then
        named=""
        [ -z "$TAG" ] || named="the release tag"
        [ -z "$GATE" ] || named="$named, the gated commit (the commit the release gate ran on)"
        [ -z "$MAC" ] || named="$named${named:+ and }the Mac availability"
        echo
        printf '%s' "The maintainer supplies $named when the record is made"
        [ -z "$TAG" ] || printf '%s' "; the script resolves the tag$( [ -z "$GATE" ] || printf ' and the commit' ) in this repository"
        echo "."
    fi
    if [ -n "$GATE" ]; then
        git -C "$ROOT" -c core.quotePath=false diff --no-renames --name-only "$GATE_COMMIT" "$TAG_COMMIT" | sort > "$SCRATCH/gate-diff.txt"
        n="$($GREP -c . "$SCRATCH/gate-diff.txt" || true)"
        echo
        if [ "$n" -eq 0 ]; then
            echo "The tag's commit and the gated commit have the same tree."
        else
            echo "The paths that differ between the gated commit and the tag's commit ($n):"
            echo
            sed 's/^\(.*\)$/- `\1`/' "$SCRATCH/gate-diff.txt"
        fi
    fi
    echo
    echo "## Main executable"
    echo
    echo "| Field | Value |"
    echo "|---|---|"
    echo "| Path in the bundle | \`$EXE_NAME\` |"
    while read -r uuid arch; do
        echo "| UUID (\`LC_UUID\`, $arch) | \`$uuid\` |"
    done < "$SCRATCH/uuid.txt"
    echo "| SHA-256 | \`$EXE_SHA\` |"
    echo
    echo "The SHA-256 is of the archived, signed executable; the App Store copy differs in it (see How this record was made)."
    echo
    echo "## Linked libraries"
    echo
    echo "$N_LIBS libraries, as \`otool -L\` prints them, in load order:"
    echo
    echo '```'
    cat "$SCRATCH/libs.txt"
    echo '```'
    echo
    echo "## Imported symbols checked for networking"
    echo
    echo "The executable imports $N_IMPORTS symbols (\`nm -u\`, the undefined symbols). Each pattern below is counted against them: \"contains\" counts a symbol that contains the name, \"exactly\" a symbol imported under exactly that name."
    echo
    echo "| Pattern | Match | Imported symbols |"
    echo "|---|---|---|"
    cat "$SCRATCH/net-rows.txt"
    echo
    echo "Imported symbols matching any pattern: $N_NET of $N_IMPORTS."
    if [ "$N_NET" -gt 0 ]; then
        echo
        sed 's/^\(.*\)$/- `\1`/' "$SCRATCH/net-hits.txt"
    fi
    echo
    printf '%s' "An import list shows what the executable binds to when it loads. A function looked up by name at run time is not in it"
    if [ "$HAS_DLSYM" -eq 1 ]; then printf '%s' " (this executable imports \`dlsym\`, through which such a lookup can be made)"; fi
    echo ", so this count is read alongside the source-level check in \`ENGINEERING.md\`. A system view the app presents, such as a browser sheet, loads its content in a separate process and does not appear here."
    echo
    echo "## Entitlements"
    echo
    if $GREP -q '<plist' "$SCRATCH/ent.plist"; then
        echo "From the code signature (\`codesign -d --entitlements\`), sorted by key:"
        echo
        echo "| Key | Value |"
        echo "|---|---|"
        plist entitlements "$SCRATCH/ent.plist"
    else
        echo "The code signature carries no entitlements."
    fi
    echo
    echo "## Info.plist"
    echo
    echo "| Key | Value |"
    echo "|---|---|"
    plist info "$APP/Info.plist"
    echo
    echo "## Privacy manifest"
    echo
    if [ -s "$SCRATCH/privacy.txt" ]; then
        while read -r pm; do
            echo "\`$pm\`:"
            echo
            plist privacy "$APP/$pm"
            echo
        done < "$SCRATCH/privacy.txt"
    else
        echo "The bundle carries no \`PrivacyInfo.xcprivacy\`."
        echo
    fi
    echo "## Bundled files"
    echo
    echo "The bundle holds $N_ALL files. Below is the SHA-256 of each of the $N_FILES that are not the main executable (above), \`_CodeSignature/\` or \`embedded.mobileprovision\`. The last two depend on the signature and differ between signings of the same build."
    echo
    : > "$SCRATCH/macho.txt"
    while read -r f; do
        [ -L "$APP/$f" ] || case "$(od -An -tx1 -N4 "$APP/$f" | tr -d ' \n')" in
            cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|bebafeca) echo "$f" >> "$SCRATCH/macho.txt" ;;
        esac
    done < "$SCRATCH/files.txt"
    if [ -s "$SCRATCH/nested.txt" ]; then
        printf '%s' "Nested bundles: "
        first=1
        while read -r b; do
            bexe="$( [ -f "$APP/$b/Info.plist" ] && plist get "$APP/$b/Info.plist" CFBundleExecutable || true)"
            [ "$first" -eq 1 ] || printf '; '
            first=0
            printf '`%s` (%s)' "$b" "${bexe:+executable \`$bexe\`}${bexe:-no executable}"
        done < "$SCRATCH/nested.txt"
        echo "; their files are listed with the rest."
    else
        echo "Nested bundles: none."
    fi
    echo
    if [ -s "$SCRATCH/macho.txt" ]; then
        echo "Other Mach-O files: $(sed 's/^\(.*\)$/`\1`/' "$SCRATCH/macho.txt" | paste -sd ',' - | sed 's/,/, /g')."
    else
        echo "Other Mach-O files: none."
    fi
    echo
    if [ -n "$TAG" ]; then
        echo "The last column names the tracked files at the tag's commit that have the same bytes. A file without one is produced by the build (an asset catalog, a compiled strings table, an Info.plist) or differs from the tree at the tag."
        echo
        echo "| File | SHA-256 | Same bytes at \`$TAG\` |"
        echo "|---|---|---|"
    else
        echo "| File | SHA-256 |"
        echo "|---|---|"
    fi
    n_same=0
    while read -r f; do
        if [ -L "$APP/$f" ]; then
            d="symbolic link to \`$(readlink "$APP/$f")\`"; same="—"
        else
            d="$(shasum -a 256 < "$APP/$f" | cut -d' ' -f1)"
            [ -z "$TAG" ] || same="$(same_at_tag "$f" "$d")"
            d="\`$d\`"
        fi
        if [ -n "$TAG" ]; then
            [ "$same" = "—" ] || n_same=$((n_same + 1))
            echo "| \`$f\` | $d | $same |"
        else
            echo "| \`$f\` | $d |"
        fi
    done < "$SCRATCH/files.txt"
    if [ -n "$TAG" ]; then
        echo
        echo "Files with the same bytes at the tag's commit: $n_same of $N_FILES."
    fi
    echo
    echo "## How this record was made"
    echo
    echo "| Field | Value |"
    echo "|---|---|"
    echo "| Script | \`$SCRIPT_NAME\` |"
    echo "| Archive | \`$ARCHIVE_NAME\` |"
    echo "| App in the archive | \`Products/$APP_REL\` |"
    plist archive "$ARCHIVE/Info.plist"
    echo
    echo "The signing identity type is the part of the archive's signing identity before its certificate name. Xcode signs the build it exports for App Store Connect with a distribution identity, and the App Store encrypts the executable's code (FairPlay) and adds an \`SC_Info\` directory, so the copy a device installs differs from this record in known fields:"
    echo
    echo "- the executable's SHA-256;"
    echo "- the entitlements \`get-task-allow\` (\`true\` in a development signature; \`false\` in the App Store copy) and \`beta-reports-active\` (added for App Store distribution); \`application-identifier\` and \`com.apple.developer.team-identifier\` carry the team identifier, which the same team's distribution signature keeps;"
    echo "- \`_CodeSignature/\`, \`embedded.mobileprovision\` and \`SC_Info/\`, which depend on the signature or the store;"
    echo "- \`Info.plist\`, to which App Store processing adds keys (\`DTAppStoreToolsBuild\`), so its digest differs while the keys listed above do not; and \`Assets.car\`, which App Store thinning may cut to the installing device's variant."
    echo
    echo "Re-signing and encryption do not change the executable's UUID, its linked libraries, its imported symbols or the other bundled files."
    echo
    echo "## How to compare"
    echo
    case "$MAC" in
        yes)
            echo "The App Store offers this release on Apple-silicon Macs. On such a Mac, install the App Store copy and read the bundle at \`/Applications/<name>.app/Wrapper/$APP_NAME\`, where \`<name>\` is the name the App Store gives the app. Compare its UUID (\`dwarfdump --uuid\`), its linked libraries (\`otool -L\`), the imported-symbol check (\`nm -u\` with the patterns above) and the digests of the bundled files with this record; the executable's digest and the signature-dependent fields differ, as described above. The encryption covers the executable's code, not the load commands and symbol tables these tools read." ;;
        *)
            [ "$MAC" != "no" ] || printf '%s' "The App Store does not offer this release on Apple-silicon Macs, so there is no installed copy on a Mac to read. "
            echo "The maintainer publishes this record from the archive that produced the submitted build; the upload entry above is the archive's own record of that upload. The executable's UUID also appears in crash reports from the shipped build, in the list of binary images. A reader who obtains the App Store IPA by other means can compare the same fields: the UUID (\`dwarfdump --uuid\`), the linked libraries (\`otool -L\`), the imported-symbol check (\`nm -u\` with the patterns above) and the digests of the bundled files, with the signature-dependent fields described above set aside. The encryption covers the executable's code, not the load commands and symbol tables these tools read." ;;
    esac
    echo
    printf '%s' "To re-make this record and compare it with this file: \`$SCRIPT_NAME --archive <path>/$ARCHIVE_NAME"
    [ -z "$TAG" ] || printf ' --tag %s' "$TAG"
    [ -z "$GATE" ] || printf ' --gate %s' "$(printf '%s' "$GATE_COMMIT" | cut -c1-8)"
    [ -z "$MAC" ] || printf ' --mac %s' "$MAC"
    echo " --check RELEASES/$VERSION-identity.md\` prints MATCH."
}

render > "$SCRATCH/record.md"

# The privacy guard: no local path and no certificate name in the record.
for s in "$HOME" "$ARCHIVE_ABS" "/Users/" "$SIGNING_IDENTITY" "${SIGNING_IDENTITY#*: }"; do
    [ -n "$s" ] || continue
    if $GREP -q -F -- "$s" "$SCRATCH/record.md"; then
        die "refusing: the record would contain a local path or the signing certificate's name"
    fi
done

if [ -n "$CHECK" ]; then
    if cmp -s "$CHECK" "$SCRATCH/record.md"; then
        echo "MATCH"
        exit 0
    fi
    diff -u "$CHECK" "$SCRATCH/record.md" | sed "s|$SCRATCH/record.md|(re-derived)|" || true
    echo "release-identity: the record differs from the archive's re-derivation" >&2
    exit 1
fi

mkdir -p "$ROOT/RELEASES"
OUT="RELEASES/$VERSION-identity.md"
cp "$SCRATCH/record.md" "$ROOT/$OUT"
echo "release-identity: wrote $OUT — $VERSION ($BUILD), UUID $(cut -d' ' -f1 "$SCRATCH/uuid.txt" | head -1), $N_IMPORTS imported symbols, $N_NET matching the networking patterns, $N_FILES bundled files digested"
