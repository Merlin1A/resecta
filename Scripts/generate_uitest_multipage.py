#!/usr/bin/env python3
"""Deterministic generator for UITestFixtures/uitest_multipage.pdf.

Produces the 23-page synthetic workpaper used by the `--multipageDoc`
DEBUG launch hook (see ResectaApp.swift): a text-dense, born-digital PDF
with a searchable text layer, so multipage UI drives exercise the
paginated editor and the searchable-text (OCR-not-needed) path.

Every value below is fictional. PII-shaped strings reuse the established
fake vocabulary from `RedactionState.seedDebugTriage()` (Jordan Avery,
123-45-6789, j.doe@example.com, (555) 010-2934, 4111 1111 1111 1111) so
detector-driven drives on a device still have something to find. Do not
add values derived from any real document.

Output is byte-reproducible: reportlab's `invariant=1` pins the creation
date and document ID.

Usage:  python3 Scripts/generate_uitest_multipage.py
Needs:  reportlab (any recent version)
"""

import os

from reportlab.lib.pagesizes import letter
from reportlab.pdfgen.canvas import Canvas

OUT = os.path.join(os.path.dirname(__file__), os.pardir,
                   "UITestFixtures", "uitest_multipage.pdf")
PAGES = 23
W, H = letter

FAKE_FIELDS = [
    ("Taxpayer name", "Jordan Avery"),
    ("Taxpayer SSN", "123-45-6789"),
    ("Contact email", "j.doe@example.com"),
    ("Contact phone", "(555) 010-2934"),
    ("Card on file", "4111 1111 1111 1111"),
    ("Spouse name", "Jordan Avery"),
]

# Deterministic filler prose, minted here and disclosed as fictional.
SENTENCES = [
    "This synthetic workpaper page exists only to exercise multipage",
    "rendering, page navigation, and the searchable text layer in UI",
    "tests; every figure and label on it is fictional.",
    "Ledger row values repeat a fixed cycle so output bytes stay",
    "stable across regenerations on any machine.",
    "No entry on this page refers to a real person, employer, account,",
    "or filing; see Scripts/generate_uitest_multipage.py.",
]


def line_rows(page: int):
    """Fixed pseudo-ledger rows for one page (pure function of inputs)."""
    rows = []
    for i in range(28):
        k = (page * 31 + i * 7) % 97
        rows.append(f"Line {i + 1:02d}   Item {k:02d}   "
                    f"Amount ${(k * 13) % 900 + 100}.{k % 10}0   "
                    f"Schedule ref {chr(65 + k % 6)}-{k % 12 + 1:02d}")
    return rows


def draw_page(c: Canvas, page: int):
    c.setFont("Helvetica-Bold", 14)
    c.drawString(72, H - 60, "SYNTHETIC TEST WORKPAPER - FICTIONAL DATA")
    c.setFont("Helvetica", 9)
    c.drawString(72, H - 76, f"Tax year 2099 exercise document, "
                             f"page {page + 1} of {PAGES}. Not a real filing.")
    y = H - 110
    if page == 0:
        c.setFont("Helvetica-Bold", 11)
        c.drawString(72, y, "Identification (fake vocabulary, "
                            "seedDebugTriage set)")
        y -= 18
        c.setFont("Helvetica", 10)
        for label, value in FAKE_FIELDS:
            c.drawString(84, y, f"{label}:")
            c.drawString(220, y, value)
            y -= 15
        y -= 10
    c.setFont("Helvetica", 9)
    for s in SENTENCES:
        c.drawString(72, y, s)
        y -= 12
    y -= 8
    c.setFont("Courier", 9)
    for row in line_rows(page):
        c.drawString(72, y, row)
        y -= 13
    c.setFont("Helvetica", 8)
    c.drawString(72, 40, f"synthetic-multipage-fixture page {page + 1}")
    c.showPage()


def main():
    c = Canvas(OUT, pagesize=letter, invariant=1)
    c.setTitle("Synthetic multipage UI-test workpaper")
    c.setAuthor("resecta test fixture generator")
    for page in range(PAGES):
        draw_page(c, page)
    c.save()
    print(f"wrote {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
