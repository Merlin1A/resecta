#!/usr/bin/env python3
"""Deterministic generator for UITestFixtures/uitest_annotated_form.pdf.

Produces the one-page synthetic document opened by the
`--annotatedFormDoc` DEBUG launch hook (see ResectaApp.swift): a Letter
page with two lines of Helvetica 12 text, and

- one `/Square` annotation with an opaque black interior over the first
  line (its own appearance stream fills the rectangle), a concealing
  annotation, so the covered-text finding and the concealed-annotations
  confirm can be reached;
- one AcroForm text field (`/FT /Tx`) whose value is "Synthetic value",
  so the import notice shows its form-field sentence.

There is no XFA form data and no embedded file, so the notice carries
its annotation sentences and its form-field sentence only.

Every value is fictional. Nothing here derives from a real document.

Output is byte-reproducible: the file is assembled from literal bytes
(no library, no dates, no document ID), so the tracked fixture matches
this script exactly on any machine.

Usage:  python3 Scripts/generate_uitest_annotated_form.py
Needs:  python3 only (no reportlab)
"""

import os

OUT = os.path.join(os.path.dirname(__file__), os.pardir,
                   "UITestFixtures", "uitest_annotated_form.pdf")

PAGE_W, PAGE_H = 612, 792
LINE_1 = "Synthetic annotated fixture, first line under a box."
LINE_2 = "Synthetic annotated fixture, second line in the open."
# Over the first line (baseline 720, Helvetica 12): x 66-400, y 714-734.
SQUARE_RECT = (66, 714, 400, 734)
# The text field, below both lines.
FIELD_RECT = (72, 640, 300, 664)
FIELD_VALUE = "Synthetic value"


def stream_object(dictionary: str, data: bytes) -> bytes:
    return (f"<< {dictionary}/Length {len(data)} >>\nstream\n".encode("ascii")
            + data + b"\nendstream")


def build() -> bytes:
    sx0, sy0, sx1, sy1 = SQUARE_RECT
    fx0, fy0, fx1, fy1 = FIELD_RECT
    page_text = (f"BT\n/F1 12 Tf\n72 720 Td\n({LINE_1}) Tj\nET\n"
                 f"BT\n/F1 12 Tf\n72 696 Td\n({LINE_2}) Tj\nET\n").encode("ascii")
    square_ap = f"0 0 0 rg\n0 0 {sx1 - sx0} {sy1 - sy0} re f\n".encode("ascii")
    field_ap = (f"/Tx BMC\nBT\n/F1 12 Tf\n2 7 Td\n({FIELD_VALUE}) Tj\nET\nEMC\n").encode("ascii")

    objects = [
        # 1 catalog, with the form
        b"<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [7 0 R] "
        b"/DA (/F1 12 Tf 0 g) /DR << /Font << /F1 4 0 R >> >> >> >>",
        # 2 pages
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        # 3 page
        (f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {PAGE_W} {PAGE_H}] "
         f"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R "
         f"/Annots [6 0 R 7 0 R] >>").encode("ascii"),
        # 4 font
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        # 5 page content
        stream_object("", page_text),
        # 6 the square, opaque black over the first line
        (f"<< /Type /Annot /Subtype /Square /Rect [{sx0} {sy0} {sx1} {sy1}] "
         f"/C [0 0 0] /IC [0 0 0] /CA 1 /BS << /W 0 >> /F 4 "
         f"/AP << /N 8 0 R >> >>").encode("ascii"),
        # 7 the text field, merged with its widget
        (f"<< /Type /Annot /Subtype /Widget /FT /Tx /T (synthetic_field) "
         f"/V ({FIELD_VALUE}) /DA (/F1 12 Tf 0 g) /Rect [{fx0} {fy0} {fx1} {fy1}] "
         f"/F 4 /P 3 0 R /AP << /N 9 0 R >> >>").encode("ascii"),
        # 8 the square's appearance
        stream_object(f"/Type /XObject /Subtype /Form /BBox [0 0 {sx1 - sx0} {sy1 - sy0}] ",
                      square_ap),
        # 9 the field's appearance
        stream_object(f"/Type /XObject /Subtype /Form /BBox [0 0 {fx1 - fx0} {fy1 - fy0}] "
                      f"/Resources << /Font << /F1 4 0 R >> >> ", field_ap),
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
