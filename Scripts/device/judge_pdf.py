#!/usr/bin/env python3
"""judge_pdf.py — Mac-side checks on exported PDFs, as JSON.

For every PDF in an inbox folder (newest first; optionally only those
modified at or after `--since`) this script runs command-line checks and
writes one verdict per file:

  text layer   `pdftotext -layout`: the character count, and for each
               operator term (case-insensitive) its hit count — terms are
               reported by position (term1, term2, …), never echoed
  structure    `qpdf --check` exit status; `qpdf --show-encryption`
               (expects an unencrypted file); `qpdf --show-npages`
  metadata     `exiftool -j -G`: how many EXIF, GPS, XMP and MakerNotes
               tags and whether Make/Model are present; `strings -a`
               lines naming GPS, Exif, xmpmeta or MakerNote (a count)

A file passes when no term is found, `qpdf --check` is clean, the file is
not encrypted, and no EXIF/GPS/MakerNotes tag or `strings` hit is present.
Counts and verdicts only: no page text, no metadata value and no byte of
the file is written anywhere; no file is opened in an app or copied.

Usage:
  judge_pdf.py --inbox DIR [--since STAMP] [--terms "a,b" | --terms-file F] [--out FILE]
      (STAMP: epoch seconds or YYYY-MM-DDTHH:MM:SS, local time)
  judge_pdf.py --self-test [--samples DIR [--expect FILE]]
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime

STRINGS_RE = re.compile(r"GPS|Exif|xmpmeta|MakerNote", re.IGNORECASE)
TOOLS = ("pdftotext", "qpdf", "exiftool", "strings")


def run(cmd):
    p = subprocess.run(cmd, capture_output=True)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def judge(path, terms):
    out = {"file": os.path.basename(path), "bytes": os.path.getsize(path),
           "modified": datetime.fromtimestamp(os.path.getmtime(path)).isoformat(timespec="seconds")}
    text_rc, text = run(["pdftotext", "-layout", path, "-"])
    out["text_readable"] = text_rc == 0
    folded = text.lower()
    out["text_chars"] = len(text.strip())
    out["term_hits"] = {f"term{i + 1}": folded.count(t.lower()) for i, t in enumerate(terms)}
    out["qpdf_check_rc"], _ = run(["qpdf", "--check", path])
    _, enc = run(["qpdf", "--show-encryption", path])
    out["encrypted"] = "not encrypted" not in enc
    rc, pages = run(["qpdf", "--show-npages", path])
    out["pages"] = int(pages.strip()) if rc == 0 and pages.strip().isdigit() else None
    _, exif = run(["exiftool", "-j", "-G", path])
    try:
        tags = json.loads(exif)[0]
    except (ValueError, IndexError):
        tags = {}
    groups = {}
    for key in tags:
        group = key.split(":", 1)[0] if ":" in key else ""
        if group == "EXIF" and key.split(":", 1)[1].startswith("GPS"):
            group = "GPS"  # with -G, GPS tags arrive in the EXIF family
        if group in ("EXIF", "GPS", "XMP", "MakerNotes"):
            groups[group] = groups.get(group, 0) + 1
    out["metadata_tags"] = groups
    out["make_or_model"] = any(k.endswith((":Make", ":Model")) for k in tags)
    _, strings = run(["strings", "-a", path])
    out["strings_hits"] = sum(1 for line in strings.splitlines() if STRINGS_RE.search(line))
    reasons = []
    if not out["text_readable"]:
        reasons.append("text layer unreadable (pdftotext failed)")
    if any(out["term_hits"].values()):
        reasons.append("term in text layer")
    if out["qpdf_check_rc"] != 0:
        reasons.append(f"qpdf --check rc {out['qpdf_check_rc']}")
    if out["encrypted"]:
        reasons.append("encrypted")
    if any(groups.get(g) for g in ("EXIF", "GPS", "MakerNotes")) or out["make_or_model"]:
        reasons.append("EXIF/GPS metadata")
    if out["strings_hits"]:
        reasons.append(f"{out['strings_hits']} metadata strings")
    out["verdict"] = "FAIL" if reasons else "PASS"
    out["reasons"] = reasons
    return out


def parse_since(stamp):
    if not stamp:
        return None
    if re.fullmatch(r"\d+(\.\d+)?", stamp):
        return float(stamp)
    return datetime.fromisoformat(stamp).timestamp()


def judge_inbox(inbox, terms, since=None):
    pdfs = [os.path.join(inbox, n) for n in os.listdir(inbox) if n.lower().endswith(".pdf")]
    if since is not None:
        pdfs = [p for p in pdfs if os.path.getmtime(p) >= since]
    pdfs.sort(key=os.path.getmtime, reverse=True)
    results = [judge(p, terms) for p in pdfs]
    return {"inbox": inbox, "terms": len(terms), "files": results,
            "verdict": "FAIL" if any(r["verdict"] == "FAIL" for r in results) else ("PASS" if results else "NONE")}


# ── self-test ──────────────────────────────────────────────────────────
def minimal_pdf(text=None, xmp=False):
    """A one-page PDF written by hand (offsets computed), optionally with text and an XMP stream."""
    content = f"BT /F1 24 Tf 72 700 Td ({text}) Tj ET".encode() if text else b""
    objs = [b"<< /Type /Catalog /Pages 2 0 R" + (b" /Metadata 6 0 R" if xmp else b"") + b" >>",
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R"
            b" /Resources << /Font << /F1 5 0 R >> >> >>",
            b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    if xmp:
        meta = b'<x:xmpmeta xmlns:x="adobe:ns:meta/"></x:xmpmeta>'
        objs.append(b"<< /Type /Metadata /Subtype /XML /Length %d >>\nstream\n" % len(meta) + meta + b"\nendstream")
    data, offsets = b"%PDF-1.4\n", []
    for i, body in enumerate(objs, 1):
        offsets.append(len(data))
        data += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    xref = len(data)
    data += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    data += b"".join(b"%010d 00000 n \n" % o for o in offsets)
    data += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    return data


def dotted(obj, key):
    for part in key.split("."):
        obj = obj[int(part)] if isinstance(obj, list) else obj.get(part) if isinstance(obj, dict) else None
    return obj


def self_test(samples=None, expect=None):
    missing = [t for t in TOOLS if not shutil.which(t)]
    if missing:
        print("judge_pdf self-test: FAIL — missing tools:", ", ".join(missing))
        return 1
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        for name, body in (("leaky.pdf", minimal_pdf("Sample Holder 123")),
                           ("clean.pdf", minimal_pdf()),
                           ("xmp.pdf", minimal_pdf(xmp=True))):
            with open(os.path.join(tmp, name), "wb") as fh:
                fh.write(body)
        with open(os.path.join(tmp, "broken.pdf"), "wb") as fh:
            fh.write(b"%PDF-1.4 not a document")
        r = {f["file"]: f for f in judge_inbox(tmp, ["sample holder", "absent"])["files"]}
    checks = [
        (r["leaky.pdf"]["term_hits"], {"term1": 1, "term2": 0}),
        (r["leaky.pdf"]["verdict"], "FAIL"),
        (r["clean.pdf"]["verdict"], "PASS"),
        (r["clean.pdf"]["qpdf_check_rc"], 0),
        (r["clean.pdf"]["pages"], 1),
        (r["xmp.pdf"]["strings_hits"] > 0, True),
        (r["broken.pdf"]["verdict"], "FAIL"),
        (r["broken.pdf"]["text_readable"], False),
    ]
    for i, (got, want) in enumerate(checks):
        if got != want:
            failures.append(f"synthetic check {i}: got {got!r}, want {want!r}")
    if "Holder" in json.dumps(r):
        failures.append("synthetic: a term or page text reached the report")
    if samples:
        wanted = json.load(open(expect, encoding="utf-8")) if expect else {}
        for f in judge_inbox(samples, [])["files"]:
            print(f"{f['file']}: {f['verdict']} pages={f['pages']} text_chars={f['text_chars']} strings_hits={f['strings_hits']}")
            for key, want in wanted.get(f["file"], {}).items():
                if dotted(f, key) != want:
                    failures.append(f"{f['file']} {key}: got {dotted(f, key)!r}, want {want!r}")
    for line in failures:
        print("FAIL", line)
    print("judge_pdf self-test:", "FAIL" if failures else "PASS")
    return 1 if failures else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--inbox", default=os.path.expanduser("~/Documents/resecta-sitting-inbox"))
    ap.add_argument("--since")
    ap.add_argument("--terms", default="")
    ap.add_argument("--terms-file")
    ap.add_argument("--out")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--samples")
    ap.add_argument("--expect")
    a = ap.parse_args()
    if a.self_test:
        return self_test(a.samples, a.expect)
    terms = [t.strip() for t in a.terms.split(",") if t.strip()]
    if a.terms_file:
        with open(a.terms_file, encoding="utf-8") as fh:
            terms += [line.strip() for line in fh if line.strip()]
    report = judge_inbox(a.inbox, terms, parse_since(a.since))
    for f in report["files"]:
        print(f"{f['verdict']}  {f['file']}  pages={f['pages']} text_chars={f['text_chars']} "
              f"terms={sum(f['term_hits'].values())} encrypted={f['encrypted']} "
              f"metadata={f['metadata_tags'] or 'none'} strings={f['strings_hits']}")
    print(f"judge: {report['verdict']} ({len(report['files'])} file(s))")
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            json.dump(report, fh, indent=1)
            fh.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
