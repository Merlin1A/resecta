#!/usr/bin/env python3
"""container_facts.py — facts from `devicectl device info files` listings.

`xcrun devicectl device info files … --json-output FILE` lists a domain on
the device (an app's data container, the system crash-log folder) with
per-file sizes, dates and extended attributes. This script reads such
listings:

  summary LISTING        the app's stores under Library/Application Support
                         with their extended attributes (backup exclusion,
                         the data-protection marker), the pipeline outputs
                         under tmp/, the app-switcher snapshot count, and
                         every PDF outside tmp/ (names only)
  diff BEFORE AFTER      the entries added, removed and changed (size or
                         modification date) between two listings of the
                         same domain — the crash-log folder's new reports,
                         the container's new or swept files

Paths are made container-relative: a listing taken with `--subdirectory`
gets that prefix back, read from the listing's own recorded arguments.
Names and attributes only; no file is opened.

Usage:
  container_facts.py summary LISTING.json [--out FILE]
  container_facts.py diff BEFORE.json AFTER.json [--out FILE]
  container_facts.py --self-test [--samples DIR [--expect FILE]]
"""
import argparse
import json
import os
import sys
import tempfile

BACKUP_EXCLUDE = "com.apple.metadata:com_apple_backup_excludeItem"
PROTECTION_MARK = "com.apple.dataprotection.policy.exception-applied-by"
STORES = "Library/Application Support/"
SNAPSHOTS = "Library/SplashBoard/Snapshots/"


def entries(path):
    """{relative path: entry} for one listing, with the subdirectory restored."""
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    args = (doc.get("info") or {}).get("arguments") or []
    prefix = ""
    if "--subdirectory" in args:
        i = args.index("--subdirectory")
        if i + 1 < len(args):
            prefix = args[i + 1].strip("/") + "/"
    out = {}
    for f in (doc.get("result") or {}).get("files", []):
        meta = f.get("metadata") or {}
        res = f.get("resources") or {}
        rel = prefix + (f.get("relativePath") or f.get("name") or "")
        out[rel] = {"path": rel, "dir": bool(res.get("isDirectory")), "size": meta.get("size"),
                    "modified": meta.get("lastModDate"),
                    "xattrs": sorted((meta.get("extendedAttributes") or {}).keys()),
                    "xattr_values": meta.get("extendedAttributes") or {}}
    return out


def summary(path):
    items = entries(path)
    files = [e for e in items.values() if not e["dir"]]
    stores = []
    for e in sorted(files, key=lambda e: e["path"]):
        if e["path"].startswith(STORES) and e["path"].endswith(".json"):
            stores.append({"path": e["path"], "size": e["size"], "xattr_count": len(e["xattrs"]),
                           "backup_excluded": e["xattr_values"].get(BACKUP_EXCLUDE) == "com.apple.MobileBackup",
                           "protection_marker": PROTECTION_MARK in e["xattr_values"],
                           "xattrs": e["xattrs"]})
    pdfs = [e["path"] for e in files if e["path"].lower().endswith(".pdf")]
    return {
        "entries": len(items),
        "stores": stores,
        "tmp_outputs": sorted(p for p in pdfs if p.startswith("tmp/")),
        "pdfs_outside_tmp": sorted(p for p in pdfs if not p.startswith("tmp/")),
        "snapshots": sum(e["path"].startswith(SNAPSHOTS) for e in files),
    }


def diff(before, after):
    a, b = entries(before), entries(after)
    changed = sorted(p for p in a.keys() & b.keys()
                     if not b[p]["dir"] and (a[p]["size"], a[p]["modified"]) != (b[p]["size"], b[p]["modified"]))
    return {"added": sorted(p for p in b.keys() - a.keys() if not b[p]["dir"]),
            "removed": sorted(p for p in a.keys() - b.keys() if not a[p]["dir"]),
            "changed": changed}


# ── self-test ──────────────────────────────────────────────────────────
def _listing(files, subdirectory=None):
    args = ["devicectl", "device", "info", "files"] + (["--subdirectory", subdirectory] if subdirectory else [])
    return json.dumps({"info": {"arguments": args}, "result": {"files": [
        {"relativePath": p, "metadata": {"size": s, "lastModDate": m, "extendedAttributes": x},
         "resources": {"isDirectory": d}} for p, s, m, x, d in files]}})


EXCL = {BACKUP_EXCLUDE: "com.apple.MobileBackup", PROTECTION_MARK: "com.apple.containermanagerd"}
SYNTHETIC = {
    "before.json": _listing([
        ("Library/Application Support/UserTerms", 96, "t0", {}, True),
        ("Library/Application Support/UserTerms/user-terms.v1.json", 10, "t0", EXCL, False),
        ("Library/SplashBoard/Snapshots/a.ktx", 5, "t0", {}, False),
        ("tmp/redacted_session_1/redacted_1.pdf", 900, "t0", {}, False),
    ]),
    "after.json": _listing([
        ("Library/Application Support/UserTerms/user-terms.v1.json", 12, "t1", EXCL, False),
        ("Library/SplashBoard/Snapshots/a.ktx", 5, "t0", {}, False),
        ("Library/SplashBoard/Snapshots/b.ktx", 5, "t1", {}, False),
        ("Documents/copy.pdf", 900, "t1", {}, False),
    ]),
    "sub.json": _listing([("SavedRegexes/saved-regexes.v1.json", 3, "t0", {BACKUP_EXCLUDE: "com.apple.MobileBackup"}, False)],
                         subdirectory="Library/Application Support"),
}


def dotted(obj, key):
    for part in key.split("."):
        obj = obj[int(part)] if isinstance(obj, list) else obj.get(part) if isinstance(obj, dict) else None
    return obj


def self_test(samples=None, expect=None):
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        p = {}
        for name, body in SYNTHETIC.items():
            p[name] = os.path.join(tmp, name)
            with open(p[name], "w", encoding="utf-8") as fh:
                fh.write(body)
        s0, s1, s2 = summary(p["before.json"]), summary(p["after.json"]), summary(p["sub.json"])
        d = diff(p["before.json"], p["after.json"])
    checks = [
        (s0["stores"][0]["backup_excluded"], True),
        (s0["stores"][0]["protection_marker"], True),
        (s0["tmp_outputs"], ["tmp/redacted_session_1/redacted_1.pdf"]),
        (s1["pdfs_outside_tmp"], ["Documents/copy.pdf"]),
        (s1["snapshots"], 2),
        (s2["stores"][0]["path"], "Library/Application Support/SavedRegexes/saved-regexes.v1.json"),
        (d["added"], ["Documents/copy.pdf", "Library/SplashBoard/Snapshots/b.ktx"]),
        (d["removed"], ["tmp/redacted_session_1/redacted_1.pdf"]),
        (d["changed"], ["Library/Application Support/UserTerms/user-terms.v1.json"]),
    ]
    for i, (got, want) in enumerate(checks):
        if got != want:
            failures.append(f"synthetic check {i}: got {got!r}, want {want!r}")
    if samples:
        wanted = json.load(open(expect, encoding="utf-8")) if expect else {}
        for name in sorted(os.listdir(samples)):
            if not (name.endswith(".json") and "listing" in name):
                continue
            s = summary(os.path.join(samples, name))
            print(f"{name}: entries={s['entries']} stores={[(x['path'], x['backup_excluded']) for x in s['stores']]}")
            for key, want in wanted.get(name, {}).items():
                if dotted(s, key) != want:
                    failures.append(f"{name} {key}: got {dotted(s, key)!r}, want {want!r}")
    for line in failures:
        print("FAIL", line)
    print("container_facts self-test:", "FAIL" if failures else "PASS")
    return 1 if failures else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("verb", nargs="?", choices=["summary", "diff"])
    ap.add_argument("listings", nargs="*")
    ap.add_argument("--out")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--samples")
    ap.add_argument("--expect")
    a = ap.parse_args()
    if a.self_test:
        return self_test(a.samples, a.expect)
    if a.verb == "summary" and len(a.listings) == 1:
        result = summary(a.listings[0])
    elif a.verb == "diff" and len(a.listings) == 2:
        result = diff(*a.listings)
    else:
        ap.error("summary takes one listing; diff takes two")
    text = json.dumps(result, indent=1)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
