#!/usr/bin/env python3
"""Generator for UITestFixtures/uitest_image_dark.jpg.

Produces the dark page opened by `--loadTestImage=uitest_image_dark`
(see ResectaApp.swift): a 1200 x 900 image, ground #1C1C1E (a dark app
screenshot's page), with six light grey bars standing for lines of text
across its top third. The rest of the image is the plain dark ground, so
a box drawn there sits on a ground darker than 40 in every channel.

Every value is fictional. Nothing here derives from a real document.

The pixels are written as an uncompressed BMP from literal values (no
library), then converted to JPEG by macOS `sips`, which is deterministic
for one input on one macOS version; the tracked fixture is the file this
script made.

Usage:  python3 Scripts/generate_uitest_dark_image.py
Needs:  python3 and macOS `sips`
"""

import os
import struct
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, os.pardir, "UITestFixtures", "uitest_image_dark.jpg")

WIDTH, HEIGHT = 1200, 900
GROUND = (0x1C, 0x1C, 0x1E)
BAR = (0xC8, 0xC8, 0xC8)
# Bars as (x, y, width, height), y from the top.
BARS = [(80, 70 + 44 * i, w, 18) for i, w in enumerate([620, 880, 540, 760, 900, 430])]


def pixel(x: int, y: int) -> tuple:
    for bx, by, bw, bh in BARS:
        if bx <= x < bx + bw and by <= y < by + bh:
            return BAR
    return GROUND


def bmp() -> bytes:
    row_bytes = WIDTH * 3
    pad = (4 - row_bytes % 4) % 4
    rows = []
    for y in range(HEIGHT - 1, -1, -1):  # BMP rows run bottom to top
        row = bytearray()
        for x in range(WIDTH):
            r, g, b = pixel(x, y)
            row += bytes((b, g, r))
        rows.append(bytes(row) + b"\0" * pad)
    data = b"".join(rows)
    header = struct.pack("<2sIHHI", b"BM", 54 + len(data), 0, 0, 54)
    info = struct.pack("<IiiHHIIiiII", 40, WIDTH, HEIGHT, 1, 24, 0, len(data), 2835, 2835, 0, 0)
    return header + info + data


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        source = os.path.join(tmp, "uitest_image_dark.bmp")
        with open(source, "wb") as f:
            f.write(bmp())
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "80",
                        source, "--out", os.path.abspath(OUT)], check=True, capture_output=True)
    size = os.path.getsize(OUT)
    assert size < 200_000, f"the fixture is {size} bytes; it must stay under 200 KB"
    print(f"wrote {os.path.abspath(OUT)} ({size} bytes)")


if __name__ == "__main__":
    main()
