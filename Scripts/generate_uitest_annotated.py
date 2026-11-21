#!/usr/bin/env python3
"""Deterministic generator for UITestFixtures/uitest_annotated.pdf.

Produces the one-page synthetic document used by the `--annotatedDoc`
DEBUG launch hook (see ResectaApp.swift) and `ImportNoticeUITests`: a
Letter page with one text line and ONE `/Text` note annotation, with no
popup, no form field, no attachment and no action. A note is the one
thing on the page the import notice reports, so the notice shows its
annotation sentences alone.

Every value is fictional. Nothing here derives from a real document.

Output is byte-reproducible: the file is assembled from literal bytes
(no library, no dates, no document ID), so the tracked fixture matches
this script exactly on any machine.

Usage:  python3 Scripts/generate_uitest_annotated.py
Needs:  python3 only (no reportlab)
"""

import os

OUT = os.path.join(os.path.dirname(__file__), os.pardir,
                   "UITestFixtures", "uitest_annotated.pdf")

PAGE_W, PAGE_H = 612, 792
# The note's icon box, below the text lines (PDF user space, origin
# bottom-left).
NOTE_RECT = (72, 640, 92, 660)
NOTE_CONTENTS = "Synthetic note"


def fmt(v: float) -> str:
    """Fixed-point number formatting so the bytes never depend on float repr."""
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return s if s else "0"


def content_stream() -> bytes:
    ops = [
        "BT",
        "/F1 14 Tf",
        "72 720 Td",
        "(Annotated fixture page 1) Tj",
        "ET",
        "BT",
        "/F1 9 Tf",
        "72 700 Td",
        "(Synthetic UI-test fixture: one note annotation, no popup.) Tj",
        "ET",
    ]
    return ("\n".join(ops) + "\n").encode("ascii")


def build() -> bytes:
    x0, y0, x1, y1 = NOTE_RECT
    stream = content_stream()
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {PAGE_W} {PAGE_H}] "
         f"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R "
         f"/Annots [6 0 R] >>").encode("ascii"),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        (f"<< /Length {len(stream)} >>\nstream\n".encode("ascii")
         + stream + b"endstream"),
        (f"<< /Type /Annot /Subtype /Text "
         f"/Rect [{fmt(x0)} {fmt(y0)} {fmt(x1)} {fmt(y1)}] "
         f"/Contents ({NOTE_CONTENTS}) >>").encode("ascii"),
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
    out += (f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
            f"startxref\n{xref_at}\n%%EOF\n").encode("ascii")
    return bytes(out)


def main():
    data = build()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(data)
    print(f"wrote {os.path.normpath(OUT)} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
