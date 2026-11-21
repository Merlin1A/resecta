#!/usr/bin/env python3
"""Deterministic generator for UITestFixtures/uitest_turned.pdf.

Produces the one-page synthetic document opened by the `--turnedDoc`
DEBUG launch hook (see ResectaApp.swift): a Letter page stored upright
(MediaBox 612 x 792) and shown turned a quarter clockwise (/Rotate 90),
carrying one word, "Marigold", in Helvetica-Bold 40 near its top left.
Shown turned, the page is 792 wide and 612 tall and the word runs down
its right side.

Every value is fictional. Nothing here derives from a real document.

Output is byte-reproducible: the file is assembled from literal bytes
(no library, no dates, no document ID), so the tracked fixture matches
this script exactly on any machine.

Usage:  python3 Scripts/generate_uitest_turned.py
Needs:  python3 only (no reportlab)
"""

import os

OUT = os.path.join(os.path.dirname(__file__), os.pardir,
                   "UITestFixtures", "uitest_turned.pdf")

PAGE_W, PAGE_H = 612, 792
ROTATE = 90
WORD = "Marigold"
# Baseline at x 72, y 680 in the stored page (bottom-left origin).
WORD_AT = (72, 680)


def stream_object(dictionary: str, data: bytes) -> bytes:
    return (f"<< {dictionary}/Length {len(data)} >>\nstream\n".encode("ascii")
            + data + b"\nendstream")


def build() -> bytes:
    x, y = WORD_AT
    page_text = f"BT\n/F1 40 Tf\n{x} {y} Td\n({WORD}) Tj\nET\n".encode("ascii")

    objects = [
        # 1 catalog
        b"<< /Type /Catalog /Pages 2 0 R >>",
        # 2 pages
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        # 3 page, shown turned
        (f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {PAGE_W} {PAGE_H}] /Rotate {ROTATE} "
         f"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>").encode("ascii"),
        # 4 font
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>",
        # 5 page content
        stream_object("", page_text),
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
