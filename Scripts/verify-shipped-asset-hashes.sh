#!/bin/bash
# Pre-archive integrity fence. Asserts the two reviewed, drift-prone
# search-config blobs match their canonical values, and that the signed
# gazetteer manifest verifies and describes the shipped tree. The blob pins
# are NOT a cryptographic gate; the manifest signature check is the same
# Ed25519 verification the engine performs at first load (raw Ed25519 over
# the manifest's exact bytes, the detached signature PEM-wrapped), run here
# with a verifier outside the engine so an accidental swap/clobber or a
# re-signed manifest fails the archive, not the user.
#
# Verifier: OpenSSL 3 (`pkeyutl -verify -rawin`; the system `openssl` on
# macOS is LibreSSL and is never used), else `swift` with CryptoKit. No
# verifier is a FAIL, never a skip. RESECTA_OPENSSL names an OpenSSL 3
# binary; RESECTA_VERIFIER=none forces the no-verifier path (the self-test).
#
# Run from anywhere in the repo.
#   Scripts/verify-shipped-asset-hashes.sh              the fence
#   Scripts/verify-shipped-asset-hashes.sh --self-test  the real tree verifies;
#       a scratch copy with one manifest byte flipped fails the signature
#       check; no verifier fails. Exit 0 when all three hold.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)" || { echo "not in a git repo" >&2; exit 1; }
cd "$ROOT"
RES="Packages/RedactionEngine/Sources/RedactionEngine/Resources"

find_openssl3() {
    local c
    for c in "${RESECTA_OPENSSL:-}" /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl "$(command -v openssl || true)"; do
        [ -n "$c" ] && [ -x "$c" ] && "$c" version 2>/dev/null | /usr/bin/grep -q '^OpenSSL 3' && { echo "$c"; return 0; }
    done
    return 1
}

# verify_manifest_signature DIR — DIR holds gazetteer-manifest.json,
# gazetteer_manifest.sig and manifest_public_key.pem. Prints the verifier
# used; returns 0 on a valid signature, 1 on an invalid one, 2 without a
# verifier.
verify_manifest_signature() {
    local dir="$1" raw ossl
    raw="$(mktemp)"
    python3 - "$dir/gazetteer_manifest.sig" "$raw" <<'PY'
import base64, sys
pem = open(sys.argv[1], encoding="ascii").read().splitlines()
body = "".join(l.strip() for l in pem if l.strip() and not l.startswith("-----"))
sig = base64.b64decode(body)
if len(sig) != 64:
    sys.exit(f"signature is {len(sig)} bytes, not 64")
open(sys.argv[2], "wb").write(sig)
PY
    if [ "${RESECTA_VERIFIER:-}" = "none" ]; then rm -f "$raw"; return 2; fi
    if ossl="$(find_openssl3)"; then
        if "$ossl" pkeyutl -verify -pubin -inkey "$dir/manifest_public_key.pem" -rawin \
                -in "$dir/gazetteer-manifest.json" -sigfile "$raw" >/dev/null 2>&1; then
            rm -f "$raw"; echo "openssl ($ossl)"; return 0
        fi
        rm -f "$raw"; echo "openssl ($ossl)"; return 1
    fi
    if command -v swift >/dev/null 2>&1; then
        local rc=0
        swift - "$dir/manifest_public_key.pem" "$raw" "$dir/gazetteer-manifest.json" <<'SWIFT' >/dev/null 2>&1 || rc=$?
import CryptoKit
import Foundation
let args = CommandLine.arguments
let pem = try String(contentsOfFile: args[1], encoding: .utf8)
let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
let spki = Data(base64Encoded: body)!
let key = try Curve25519.Signing.PublicKey(rawRepresentation: spki.suffix(32))
let sig = try Data(contentsOf: URL(fileURLWithPath: args[2]))
let msg = try Data(contentsOf: URL(fileURLWithPath: args[3]))
exit(key.isValidSignature(sig, for: msg) ? 0 : 1)
SWIFT
        rm -f "$raw"; echo "swift (CryptoKit)"
        [ "$rc" -eq 0 ] && return 0
        return 1
    fi
    rm -f "$raw"; return 2
}

if [ "${1:-}" = "--self-test" ]; then
    fails=0
    v="$(verify_manifest_signature "$RES/Gazetteers")" && echo "self-test: the shipped manifest verifies via $v OK" \
        || { echo "self-test: the shipped manifest did not verify (rc $?)" >&2; fails=1; }
    scratch="$(mktemp -d)"
    cp "$RES/Gazetteers/gazetteer-manifest.json" "$RES/Gazetteers/gazetteer_manifest.sig" "$RES/Gazetteers/manifest_public_key.pem" "$scratch/"
    python3 - "$scratch/gazetteer-manifest.json" <<'PY'
import sys
p = sys.argv[1]; b = bytearray(open(p, "rb").read()); b[-2] ^= 0x01; open(p, "wb").write(bytes(b))
PY
    rc=0; verify_manifest_signature "$scratch" >/dev/null || rc=$?
    if [ "$rc" -eq 1 ]; then echo "self-test: a flipped manifest byte fails the signature check OK"
    else echo "self-test: a flipped manifest byte did not fail (rc $rc)" >&2; fails=1; fi
    rc=0; RESECTA_VERIFIER=none verify_manifest_signature "$scratch" >/dev/null || rc=$?
    if [ "$rc" -eq 2 ]; then echo "self-test: no verifier is a failure, never a skip OK"
    else echo "self-test: the no-verifier path returned $rc" >&2; fails=1; fi
    rm -rf "$scratch"
    [ "$fails" -eq 0 ] && { echo "self-test: PASS"; exit 0; }
    echo "self-test: FAIL" >&2; exit 1
fi

# preset-thresholds.json — calibrated, 17 categories (NOT the degenerate name=0.98
# sweep). Pinned by git blob hash from the verified release head.
EXPECT_PRESET="28921a52a671cb12ddd3590637a27971aaa90344"
ACTUAL_PRESET="$(git hash-object "$RES/Classifier/preset-thresholds.json")"
[ "$ACTUAL_PRESET" = "$EXPECT_PRESET" ] || {
  echo "FAIL preset-thresholds.json blob $ACTUAL_PRESET != $EXPECT_PRESET" >&2; exit 1; }

# context-scorer.json — SHA-256 must equal the compiled-in self-check constant
# (ContextScorerWeights.swift expectedSHA256; one number, two homes).
EXPECT_SCORER="fecd89b6a790d9895e7081e99b448d9245096aa435e2389252f7c5f5eab2acb8"
ACTUAL_SCORER="$(shasum -a 256 "$RES/Classifier/context-scorer.json" | cut -d' ' -f1)"
[ "$ACTUAL_SCORER" = "$EXPECT_SCORER" ] || {
  echo "FAIL context-scorer.json sha256 $ACTUAL_SCORER != $EXPECT_SCORER" >&2; exit 1; }

# manifest_public_key.pem — the key the signed manifest verifies against.
# Pinned by git blob hash; a rotation moves this constant, the fingerprint in
# ManifestPublicKeyPinTests and the one published in the DataPipeline's
# KEY-MANAGEMENT.md together.
EXPECT_PUBKEY="5e7ae488f00778781c50c8a1a16ec56351c99fab"
ACTUAL_PUBKEY="$(git hash-object "$RES/Gazetteers/manifest_public_key.pem")"
[ "$ACTUAL_PUBKEY" = "$EXPECT_PUBKEY" ] || {
  echo "FAIL manifest_public_key.pem blob $ACTUAL_PUBKEY != $EXPECT_PUBKEY" >&2; exit 1; }

# gazetteer_manifest.sig — the Ed25519 signature over the manifest's exact
# bytes, verified with the pinned key by a verifier outside the engine.
rc=0; verifier="$(verify_manifest_signature "$RES/Gazetteers")" || rc=$?
case "$rc" in
  0) echo "OK: gazetteer_manifest.sig verifies over gazetteer-manifest.json ($verifier)" ;;
  1) echo "FAIL gazetteer_manifest.sig does not verify over gazetteer-manifest.json ($verifier)" >&2; exit 1 ;;
  *) echo "FAIL no Ed25519 verifier found (OpenSSL 3 or swift with CryptoKit); the signature was not checked" >&2; exit 1 ;;
esac

# gazetteer-manifest.json — the signed manifest's assets[] must describe the
# tree it ships with: every listed file present with the recorded size and
# SHA-256, and every installed asset listed (the manifest triple excepted).
# The engine re-verifies this at first load; failing here fails the archive
# instead of the user.
python3 - "$RES" <<'PY' || exit 1
import hashlib, json, os, sys
res = sys.argv[1]
manifest = json.load(open(os.path.join(res, "Gazetteers", "gazetteer-manifest.json")))
entries = manifest.get("assets")
if entries is None:
    print("FAIL gazetteer-manifest.json carries no assets[] section", file=sys.stderr); sys.exit(1)
triple = {"Gazetteers/gazetteer-manifest.json", "Gazetteers/gazetteer_manifest.sig", "Gazetteers/manifest_public_key.pem"}
installed = set()
for sub in ("Gazetteers", "Classifier", "Audit"):
    for name in os.listdir(os.path.join(res, sub)):
        if name != ".gitkeep":
            installed.add(f"{sub}/{name}")
listed = {e["path"] for e in entries}
if listed != installed - triple:
    print(f"FAIL manifest assets[] != installed tree: unlisted {sorted(installed - triple - listed)} · phantom {sorted(listed - installed)}", file=sys.stderr); sys.exit(1)
for e in entries:
    path = os.path.join(res, e["path"])
    data = open(path, "rb").read()
    if len(data) != e["bytes"] or hashlib.sha256(data).hexdigest() != e["sha256"]:
        print(f"FAIL {e['path']} differs from its signed manifest entry", file=sys.stderr); sys.exit(1)
print(f"OK: gazetteer-manifest.json assets[] describes the shipped tree ({len(entries)} assets)")
PY

echo "OK: shipped-asset hash fence passed"
