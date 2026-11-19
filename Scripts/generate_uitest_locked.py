#!/usr/bin/env python3
"""Deterministic generator for UITestFixtures/uitest_locked.pdf.

Produces the one-page synthetic document opened by the `--lockedDoc`
DEBUG launch hook (see ResectaApp.swift): a Letter page with the line
"Synthetic locked fixture for UI tests." in Helvetica 12, encrypted by
the PDF standard security handler, revision 3 (128-bit RC4; ISO 32000-1
section 7.6.3, algorithms 2, 3 and 5). The user password is
`uitest-open` and the owner password `uitest-owner`. Both are fixture
data: the app never shows them, and a UI test types the user password
only where it means to open the document.

The hook opens the file through the import entry a Files pick uses, so
the password sheet comes up as it does for a person's locked PDF.

Every value is fictional. Nothing here derives from a real document.

Output is byte-reproducible: the file is assembled from literal bytes
with a fixed file identifier (no library, no dates, no random bytes),
so the tracked fixture matches this script exactly on any machine.

Usage:  python3 Scripts/generate_uitest_locked.py
Needs:  python3 only (hashlib for MD5; RC4 is written out below)
"""

import hashlib
import os

OUT = os.path.join(os.path.dirname(__file__), os.pardir,
                   "UITestFixtures", "uitest_locked.pdf")

PAGE_W, PAGE_H = 612, 792
LINE = "Synthetic locked fixture for UI tests."
USER_PASSWORD = b"uitest-open"
OWNER_PASSWORD = b"uitest-owner"
# Every permission bit granted; bits 1-2 must be 0 (ISO 32000-1 table 22).
PERMISSIONS = -4
KEY_LENGTH = 16  # bytes: 128-bit
# A fixed first file identifier, so the key and every byte are reproducible.
FILE_ID = hashlib.md5(b"resecta uitest_locked fixture").digest()

# ISO 32000-1 algorithm 2, step a: the padding string.
PAD = bytes([
    0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41,
    0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
    0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80,
    0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
])


def rc4(key: bytes, data: bytes) -> bytes:
    s = list(range(256))
    j = 0
    for i in range(256):
        j = (j + s[i] + key[i % len(key)]) % 256
        s[i], s[j] = s[j], s[i]
    out = bytearray()
    i = j = 0
    for byte in data:
        i = (i + 1) % 256
        j = (j + s[i]) % 256
        s[i], s[j] = s[j], s[i]
        out.append(byte ^ s[(s[i] + s[j]) % 256])
    return bytes(out)


def padded(password: bytes) -> bytes:
    return (password + PAD)[:32]


def owner_value() -> bytes:
    """Algorithm 3: the /O entry."""
    digest = hashlib.md5(padded(OWNER_PASSWORD)).digest()
    for _ in range(50):
        digest = hashlib.md5(digest[:KEY_LENGTH]).digest()
    key = digest[:KEY_LENGTH]
    value = rc4(key, padded(USER_PASSWORD))
    for i in range(1, 20):
        value = rc4(bytes(b ^ i for b in key), value)
    return value


def file_key(owner: bytes) -> bytes:
    """Algorithm 2: the document's encryption key from the user password."""
    h = hashlib.md5()
    h.update(padded(USER_PASSWORD))
    h.update(owner)
    h.update((PERMISSIONS & 0xFFFFFFFF).to_bytes(4, "little"))
    h.update(FILE_ID)
    digest = h.digest()
    for _ in range(50):
        digest = hashlib.md5(digest[:KEY_LENGTH]).digest()
    return digest[:KEY_LENGTH]


def user_value(key: bytes) -> bytes:
    """Algorithm 5: the /U entry (revision 3), padded to 32 bytes."""
    value = rc4(key, hashlib.md5(PAD + FILE_ID).digest())
    for i in range(1, 20):
        value = rc4(bytes(b ^ i for b in key), value)
    return value + bytes(16)


def object_key(key: bytes, number: int, generation: int = 0) -> bytes:
    """Algorithm 1: the RC4 key for one object's strings and streams."""
    material = key + number.to_bytes(3, "little") + generation.to_bytes(2, "little")
    return hashlib.md5(material).digest()[:min(len(key) + 5, 16)]


def hexstring(data: bytes) -> bytes:
    return b"<" + data.hex().upper().encode("ascii") + b">"


def build() -> bytes:
    owner = owner_value()
    key = file_key(owner)
    user = user_value(key)

    stream = (f"BT\n/F1 12 Tf\n72 720 Td\n({LINE}) Tj\nET\n").encode("ascii")
    sealed = rc4(object_key(key, 5), stream)

    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {PAGE_W} {PAGE_H}] "
         f"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>").encode("ascii"),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        (f"<< /Length {len(sealed)} >>\nstream\n".encode("ascii")
         + sealed + b"\nendstream"),
        # The encryption dictionary itself is never encrypted.
        (b"<< /Filter /Standard /V 2 /R 3 /Length 128 "
         + b"/O " + hexstring(owner) + b" /U " + hexstring(user)
         + f" /P {PERMISSIONS} >>".encode("ascii")),
    ]

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{number} 0 obj\n".encode("ascii") + body + b"\nendobj\n"

    xref_at = len(out)
    out += f"xref\n0 {len(objects) + 1}\n".encode("ascii")
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode("ascii")
    out += (f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R /Encrypt 6 0 R "
            f"/ID [").encode("ascii") + hexstring(FILE_ID) + b" " + hexstring(FILE_ID)
    out += (f"] >>\nstartxref\n{xref_at}\n%%EOF\n").encode("ascii")
    return bytes(out)


def main():
    data = build()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(data)
    print(f"wrote {os.path.normpath(OUT)} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
