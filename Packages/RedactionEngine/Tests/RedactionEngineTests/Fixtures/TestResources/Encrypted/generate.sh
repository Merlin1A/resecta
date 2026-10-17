#!/bin/bash
# Regenerates every file in this directory from `seeds.py` and qpdf.
# Run ONCE, by hand, on a Mac with Homebrew qpdf. Encrypted output cannot be
# deterministic (the key is salted), so the committed bytes are pinned by
# their sha256 in README.md rather than re-derived. Never run by a test or by
# CI: the committed bytes are the fixtures; this script is their recipe.
# The passwords are throwaways named in README.md.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
QPDF="${QPDF:-/opt/homebrew/bin/qpdf}"
cd "$HERE"

python3 seeds.py "$HERE"

# The 128-bit revisions (R3 RC4, R4 AES-128) derive their key with MD5, which
# qpdf calls weak and refuses to write without this global flag (it goes
# before --encrypt).
WEAK="--allow-weak-crypto"

"$QPDF" $WEAK --encrypt --user-password=user --owner-password=owner --bits=128 --use-aes=n -- seed-text.pdf r3-rc4-128.pdf
"$QPDF" $WEAK --encrypt --user-password=user --owner-password=owner --bits=128 --use-aes=y -- seed-text.pdf r4-aes-128.pdf
"$QPDF"       --encrypt --user-password=user --owner-password=owner --bits=256 -- seed-text.pdf r6-aes-256.pdf
"$QPDF"       --encrypt --user-password= --owner-password=owner --bits=256 --print=none --modify=none -- seed-text.pdf owner-only-r6.pdf
"$QPDF" $WEAK --encrypt --user-password= --owner-password=owner --bits=128 --use-aes=y --extract=n -- seed-text.pdf owner-only-nocopy-r4.pdf
"$QPDF" $WEAK --encrypt --user-password=pässwörd --owner-password=owner --bits=128 --use-aes=y -- seed-text.pdf r4-nonascii.pdf
"$QPDF"       --encrypt --user-password=pässwörd --owner-password=owner --bits=256 -- seed-text.pdf r6-nonascii.pdf
"$QPDF"       --encrypt --user-password=密码 --owner-password=owner --bits=256 -- seed-text.pdf r6-cjk.pdf
"$QPDF"       --encrypt --user-password=user --owner-password=owner --bits=256 -- seed-javascript.pdf locked-javascript-r6.pdf
"$QPDF" --object-streams=generate --encrypt --user-password=user --owner-password=owner --bits=256 -- seed-hidden-ocg.pdf locked-hidden-ocg-r6.pdf

"$QPDF" --version | head -1
for f in *.pdf; do printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"; done
