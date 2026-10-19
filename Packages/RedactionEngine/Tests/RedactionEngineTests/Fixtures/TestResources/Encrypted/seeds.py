#!/usr/bin/env python3
"""Writes the plain seed documents and the two handler stubs of this directory.

Run by `generate.sh` on a Mac, once; never by a test or by CI. Every file is
deterministic: no dates, no random ids. The seeds carry a known string so
`page.string` has text to read after an unlock.
"""
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))

FONT = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"


def pdf(objects, trailer_extra=""):
    """objects: list of (number, body) in object order. Returns the bytes with a
    correct cross-reference table."""
    out = bytearray(b"%PDF-1.5\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}
    for num, body in objects:
        offsets[num] = len(out)
        out += f"{num} 0 obj\n".encode("latin-1") + body + b"\nendobj\n"
    xref = len(out)
    size = max(offsets) + 1
    out += f"xref\n0 {size}\n".encode()
    out += b"0000000000 65535 f \n"
    for n in range(1, size):
        out += f"{offsets[n]:010d} 00000 n \n".encode()
    out += (f"trailer\n<< /Size {size} /Root 1 0 R {trailer_extra} >>\n"
            f"startxref\n{xref}\n%%EOF\n").encode("latin-1")
    return bytes(out)


def stream(content):
    data = content.encode("latin-1")
    return f"<< /Length {len(data)} >>\nstream\n".encode() + data + b"\nendstream"


def page(resources_extra="", contents_obj=5):
    return (f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
            f"/Resources << /Font << /F1 4 0 R >> {resources_extra} >> "
            f"/Contents {contents_obj} 0 R >>").encode()


TEXT_CONTENT = "BT /F1 24 Tf 72 700 Td (ENCRYPTED SEED 7731) Tj ET\n"


def seed_text(catalog_extra="", trailer_extra=""):
    return pdf([
        (1, f"<< /Type /Catalog /Pages 2 0 R {catalog_extra} >>".encode()),
        (2, b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
        (3, page()),
        (4, FONT.encode()),
        (5, stream(TEXT_CONTENT)),
    ], trailer_extra)


def seed_javascript():
    return seed_text(catalog_extra="/OpenAction << /S /JavaScript /JS (app.alert\\(1\\);) >>")


def seed_hidden_ocg():
    content = ("BT /F1 24 Tf 72 700 Td (VISIBLE WORD 2210) Tj ET\n"
               "/OC /oc1 BDC\nBT /F1 24 Tf 72 600 Td (HIDDENLAYER 4410) Tj ET\nEMC\n")
    return pdf([
        (1, b"<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [6 0 R] /D << /OFF [6 0 R] /Order [6 0 R] >> >> >>"),
        (2, b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
        (3, page(resources_extra="/Properties << /oc1 6 0 R >>")),
        (4, FONT.encode()),
        (5, stream(content)),
        (6, b"<< /Type /OCG /Name (Hidden) >>"),
    ])


ID = "/ID [<00112233445566778899AABBCCDDEEFF> <00112233445566778899AABBCCDDEEFF>]"


def stub(encrypt_dict):
    """seed-text's objects plus an /Encrypt dictionary the standard security
    handler does not own. The strings and streams are NOT encrypted: the stub
    exercises the handler-refusal arm only."""
    objects = [
        (1, b"<< /Type /Catalog /Pages 2 0 R >>"),
        (2, b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
        (3, page()),
        (4, FONT.encode()),
        (5, stream(TEXT_CONTENT)),
        (6, encrypt_dict.encode()),
    ]
    return pdf(objects, trailer_extra=f"/Encrypt 6 0 R {ID}")


CERTIFICATE = ("<< /Filter /Adobe.PubSec /SubFilter /adbe.pkcs7.s5 /V 4 /R 4 /Length 128 "
               "/CF << /DefaultCryptFilter << /CFM /AESV2 /Recipients [] >> >> "
               "/StmF /DefaultCryptFilter /StrF /DefaultCryptFilter >>")
UNKNOWN = ("<< /Filter /Bogus /V 1 /R 2 /Length 40 /P -1 "
           "/O <00000000000000000000000000000000000000000000000000000000000000> "
           "/U <00000000000000000000000000000000000000000000000000000000000000> >>")

FILES = {
    "seed-text.pdf": seed_text(),
    "seed-javascript.pdf": seed_javascript(),
    "seed-hidden-ocg.pdf": seed_hidden_ocg(),
    "certificate-stub.pdf": stub(CERTIFICATE),
    "unknown-handler-stub.pdf": stub(UNKNOWN),
}

for name, data in FILES.items():
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(data)
    print(f"wrote {name} ({len(data)} bytes)")
