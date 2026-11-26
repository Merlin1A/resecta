#!/usr/bin/env python3
"""Deterministic generator for UITestFixtures/uitest_legal.pdf.

Produces the two-page synthetic US Legal document (612 x 1008 pt) used by
the `--legalDoc` DEBUG launch hook (see ResectaApp.swift): a page taller
than Letter, so a test can draw and select a box in the strip at a page's
foot that the editor's bottom controls cover at fit zoom.

Each page carries a title line that names the size and says the page is
synthetic, a first text line whose top is within 30 pt of the page's top
edge, a last text line whose baseline is within 30 pt of the bottom edge,
and ordinary lines between. Every word is fictional.

Output is byte-reproducible: the file is assembled from literal bytes
(no library, no dates, no document ID), so the tracked fixture matches
this script exactly on any machine.

Usage:  python3 Scripts/generate_uitest_legal.py
Needs:  python3 only (no reportlab)
"""

import os

OUT = os.path.join(os.path.dirname(__file__), os.pardir,
                   "UITestFixtures", "uitest_legal.pdf")

PAGE_W, PAGE_H = 612, 1008
PAGES = 2


def text(size: int, x: int, y: int, words: str) -> list:
    return ["BT", f"/F1 {size} Tf", f"{x} {y} Td", f"({words}) Tj", "ET"]


def content_stream(page: int) -> bytes:
    ops = []
    # Title: the top of its letters is about 10 pt under the page's top edge.
    ops += text(14, 72, 984, f"Legal size page {page} of {PAGES}: a synthetic UI-test fixture")
    ops += text(11, 72, 960, "The first ordinary line of the page, made up for the tests of the editor.")
    y = 900
    n = 1
    while y > 80:
        ops += text(11, 72, y, f"Line {n} of the body: the clerk of Varnholt filed the Quillmere note here.")
        y -= 60
        n += 1
    # Last line: its baseline is 24 pt above the page's bottom edge.
    ops += text(11, 72, 24, f"The last line of page {page}, in the strip at the foot of the page.")
    return ("\n".join(ops) + "\n").encode("ascii")


def build() -> bytes:
    kids = " ".join(f"{3 + 2 * i} 0 R" for i in range(PAGES))
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        f"<< /Type /Pages /Kids [{kids}] /Count {PAGES} >>".encode("ascii"),
    ]
    font_id = 3 + 2 * PAGES
    for i in range(PAGES):
        stream = content_stream(i + 1)
        objects.append(
            (f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {PAGE_W} {PAGE_H}] "
             f"/Resources << /Font << /F1 {font_id} 0 R >> >> "
             f"/Contents {4 + 2 * i} 0 R >>").encode("ascii"))
        objects.append(f"<< /Length {len(stream)} >>\nstream\n".encode("ascii") + stream + b"endstream")
    objects.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

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
