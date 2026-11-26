#!/usr/bin/env python3
"""Deterministic generator for UITestFixtures/uitest_clear_page.pdf and
UITestFixtures/uitest_clear_page_turned.pdf.

The two one-page documents opened by the `--clearPageDoc` and
`--clearPageTurnedDoc` DEBUG launch hooks (see ResectaApp.swift). Each page
has a heading near its top and a short paragraph near its bottom, so it has
a real text layer, and between them a clear block holding one word only,
"Wrenlowe" (made up), in Helvetica 12, off the page's centre on both axes.

- uitest_clear_page.pdf: Letter, 612 x 792, unturned, crop box = media box.
  Clear block x 156-456, y 246-546; the word's box centred at (214, 515),
  the share (0.35, 0.65).
- uitest_clear_page_turned.pdf: media box 612 x 792, crop box x 36, y 54,
  540 x 684, /Rotate 90, so it is shown 684 wide and 540 tall. As shown:
  clear block x 192-492, y 170-370; the word reading upright, its box
  centred at (239, 351), the share (0.35, 0.65).

On both pages no text lies within 16 pt of the left or the top edge as
shown. Everything is drawn in the page as shown and mapped to the stored
page through the turn and the crop box's origin.

Every value is fictional. Nothing here derives from a real document.

Output is byte-reproducible: the file is assembled from literal bytes
(no library, no dates, no document ID), so the tracked fixtures match
this script exactly on any machine.

Usage:  python3 Scripts/generate_uitest_clear_page.py
Needs:  python3 only (no reportlab)
"""

import os

HERE = os.path.dirname(__file__)
WORD = "Wrenlowe"
SIZE = 12
# Helvetica's widths (per 1000) for the word's letters.
WIDTHS = {"W": 944, "r": 333, "e": 556, "n": 556, "l": 222, "o": 556, "w": 722}
# The text box's middle above the baseline, per 1000 of the size:
# half of Helvetica's ascender (718) less its descender (207).
MIDDLE = (718 - 207) / 2


def word_width() -> float:
    return sum(WIDTHS[c] for c in WORD) * SIZE / 1000


def stream_object(dictionary: str, data: bytes) -> bytes:
    return (f"<< {dictionary}/Length {len(data)} >>\nstream\n".encode("ascii")
            + data + b"\nendstream")


def fmt(v: float) -> str:
    return f"{v:.3f}".rstrip("0").rstrip(".")


def text(font: str, size: float, shown_at, line: str, to_stored) -> str:
    """One line of text whose baseline starts at `shown_at` in the page as
    shown, upright as shown; `to_stored` maps a shown point to the stored
    page and gives the text matrix's turn."""
    (x, y), (a, b, c, d) = to_stored(shown_at)
    return (f"BT\n/{font} {fmt(size)} Tf\n{fmt(a)} {fmt(b)} {fmt(c)} {fmt(d)} {fmt(x)} {fmt(y)} Tm\n"
            f"({line}) Tj\nET\n")


def page_content(shown_w, shown_h, word_centre, to_stored) -> bytes:
    cx, cy = word_centre
    word_at = (cx - word_width() / 2, cy - MIDDLE * SIZE / 1000)
    parts = [
        text("F1", 14, (72, shown_h - 52), "Clear page fixture", to_stored),
        text("F1", 11, (72, 80), "A short paragraph near the foot of the page, so the page", to_stored),
        text("F1", 11, (72, 66), "carries a real text layer around its clear block.", to_stored),
        text("F1", SIZE, word_at, WORD, to_stored),
    ]
    return "".join(parts).encode("ascii")


def build(media, crop, rotate, shown_w, shown_h, word_centre, to_stored) -> bytes:
    crop_entry = "" if crop is None else f"/CropBox [{' '.join(fmt(v) for v in crop)}] "
    rotate_entry = "" if rotate == 0 else f"/Rotate {rotate} "
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (f"<< /Type /Page /Parent 2 0 R /MediaBox [{' '.join(fmt(v) for v in media)}] {crop_entry}{rotate_entry}"
         f"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>").encode("ascii"),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        stream_object("", page_content(shown_w, shown_h, word_centre, to_stored)),
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


def unturned(p):
    return p, (1, 0, 0, 1)


# Turned 90: the crop box (36, 54, 540 x 684) shown 684 wide, 540 tall. A
# shown point (x, y) is the stored point (36 + 540 - y, 54 + x), and text
# upright as shown runs up the stored page.
def turned(p):
    x, y = p
    return (36 + 540 - y, 54 + x), (0, 1, -1, 0)


def main():
    files = {
        "uitest_clear_page.pdf": build((0, 0, 612, 792), None, 0, 612, 792, (214, 515), unturned),
        "uitest_clear_page_turned.pdf": build((0, 0, 612, 792), (36, 54, 576, 738), 90, 684, 540, (239, 351), turned),
    }
    for name, data in files.items():
        path = os.path.join(HERE, os.pardir, "UITestFixtures", name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        print(f"wrote {os.path.normpath(path)} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
