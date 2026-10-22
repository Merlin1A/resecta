#!/usr/bin/env python3
"""crash_facts.py — facts from iOS diagnostic reports (.ips), as JSON.

An `.ips` file is a one-line JSON header followed by a JSON body. For each
report this script records its type, its date and whether the named app
process is implicated:

  JetsamEvent (bug_type 298)  the victims (a process entry carrying a
                              `reason`) with their reason and resident
                              size, and the named process's own entry —
                              states, resident pages, lifetime peak pages,
                              both in bytes from the report's page size,
                              and whether it was a victim
  any other report            whether the named process is the one that
                              crashed (header `app_name`/`name`/`bundleID`,
                              body `procName`)

The summary line `app_implicated` is true when any report names the app as
a jetsam victim or as the crashing process.

Usage:
  crash_facts.py [--process NAME] [--bundle-id ID] [--out FILE] PATH...
      (PATH = .ips files or folders of them)
  crash_facts.py --self-test [--samples DIR [--expect FILE]]
"""
import argparse
import json
import os
import sys
import tempfile

DEFAULT_PROCESS = "ResectaApp"
DEFAULT_BUNDLE = "com.resecta.app"
TYPES = {"298": "JetsamEvent", "309": "Crash", "288": "Stackshot", "385": "CPU resource",
         "142": "Wakeups resource", "145": "Disk writes resource"}


def read_ips(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        head, _, rest = fh.read().partition("\n")
    header = json.loads(head)
    try:
        body = json.loads(rest) if rest.strip() else {}
    except json.JSONDecodeError:
        body = {}
    return header, body


def facts_for(path, process, bundle):
    header, body = read_ips(path)
    bug = str(header.get("bug_type") or body.get("bug_type") or "")
    out = {"file": os.path.basename(path), "bug_type": bug, "type": TYPES.get(bug, "other"),
           "date": header.get("timestamp") or body.get("date"),
           "os_version": header.get("os_version"), "app_implicated": False}
    if bug == "298":
        page = (body.get("memoryStatus") or {}).get("pageSize") or 16384
        out["page_size"] = page
        out["largest_process"] = body.get("largestProcess")
        victims, mine = [], None
        for p in body.get("processes", []):
            if "reason" in p:
                victims.append({"name": p.get("name"), "pid": p.get("pid"), "reason": p.get("reason"),
                                "resident_bytes": (p.get("rpages") or 0) * page})
            if p.get("name") == process:
                mine = {"pid": p.get("pid"), "states": p.get("states", []),
                        "resident_pages": p.get("rpages"),
                        "resident_bytes": (p.get("rpages") or 0) * page,
                        "lifetime_max_pages": p.get("lifetimeMax"),
                        "lifetime_max_bytes": (p.get("lifetimeMax") or 0) * page,
                        "is_victim": "reason" in p, "reason": p.get("reason")}
        out["victims"] = victims
        out["process"] = mine
        out["app_implicated"] = bool(mine and mine["is_victim"])
    else:
        names = {header.get("app_name"), header.get("name"), body.get("procName")}
        out["crashed_process"] = body.get("procName") or header.get("app_name") or header.get("name")
        out["app_implicated"] = process in names or header.get("bundleID") == bundle
    return out


def collect(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            files += [os.path.join(p, n) for n in sorted(os.listdir(p)) if n.endswith(".ips")]
        else:
            files.append(p)
    return files


def summarize(paths, process, bundle):
    reports = [facts_for(f, process, bundle) for f in collect(paths)]
    return {"process": process, "reports": reports,
            "jetsam_events": sum(r["type"] == "JetsamEvent" for r in reports),
            "app_implicated": any(r["app_implicated"] for r in reports)}


# ── self-test ──────────────────────────────────────────────────────────
def _ips(header, body):
    return json.dumps(header) + "\n" + json.dumps(body, indent=1)


SYNTHETIC = {
    "JetsamEvent-a.ips": _ips({"bug_type": "298", "timestamp": "2026-01-01 10:00:00.00 +0000"},
                              {"memoryStatus": {"pageSize": 16384}, "largestProcess": "Big",
                               "processes": [{"name": "ResectaApp", "pid": 7, "rpages": 100, "lifetimeMax": 200,
                                              "states": ["frontmost"], "reason": "per-process-limit"},
                                             {"name": "other", "pid": 8, "rpages": 5}]}),
    "JetsamEvent-b.ips": _ips({"bug_type": "298", "timestamp": "2026-01-01 11:00:00.00 +0000"},
                              {"memoryStatus": {"pageSize": 16384},
                               "processes": [{"name": "ResectaApp", "pid": 9, "rpages": 10, "lifetimeMax": 20,
                                              "states": ["suspended"]},
                                             {"name": "victimd", "pid": 3, "rpages": 4, "reason": "vm-pageshortage"}]}),
    "ResectaApp-c.ips": _ips({"bug_type": "309", "app_name": "ResectaApp", "bundleID": "com.resecta.app"},
                             {"procName": "ResectaApp"}),
    "Other-d.ips": _ips({"bug_type": "309", "app_name": "Other"}, {"procName": "Other"}),
}


def dotted(obj, key):
    for part in key.split("."):
        obj = obj[int(part)] if isinstance(obj, list) else obj.get(part) if isinstance(obj, dict) else None
    return obj


def self_test(samples=None, expect=None):
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        for name, body in SYNTHETIC.items():
            with open(os.path.join(tmp, name), "w", encoding="utf-8") as fh:
                fh.write(body)
        s = summarize([tmp], DEFAULT_PROCESS, DEFAULT_BUNDLE)
    by = {r["file"]: r for r in s["reports"]}
    checks = [
        (by["JetsamEvent-a.ips"]["app_implicated"], True),
        (by["JetsamEvent-a.ips"]["process"]["resident_bytes"], 100 * 16384),
        (by["JetsamEvent-b.ips"]["app_implicated"], False),
        (by["JetsamEvent-b.ips"]["victims"][0]["name"], "victimd"),
        (by["JetsamEvent-b.ips"]["process"]["lifetime_max_bytes"], 20 * 16384),
        (by["ResectaApp-c.ips"]["app_implicated"], True),
        (by["Other-d.ips"]["app_implicated"], False),
        (s["jetsam_events"], 2),
    ]
    for i, (got, want) in enumerate(checks):
        if got != want:
            failures.append(f"synthetic check {i}: got {got!r}, want {want!r}")
    if samples:
        wanted = json.load(open(expect, encoding="utf-8")) if expect else {}
        for name in sorted(os.listdir(samples)):
            if not name.endswith(".ips"):
                continue
            f = facts_for(os.path.join(samples, name), DEFAULT_PROCESS, DEFAULT_BUNDLE)
            mine = f.get("process") or {}
            print(f"{name}: {f['type']} victims={[v['name'] for v in f.get('victims', [])]} "
                  f"app lifetime_max_pages={mine.get('lifetime_max_pages')} victim={mine.get('is_victim')}")
            for key, want in wanted.get(name, {}).items():
                if dotted(f, key) != want:
                    failures.append(f"{name} {key}: got {dotted(f, key)!r}, want {want!r}")
    for line in failures:
        print("FAIL", line)
    print("crash_facts self-test:", "FAIL" if failures else "PASS")
    return 1 if failures else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--process", default=DEFAULT_PROCESS)
    ap.add_argument("--bundle-id", default=DEFAULT_BUNDLE)
    ap.add_argument("--out")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--samples")
    ap.add_argument("--expect")
    a = ap.parse_args()
    if a.self_test:
        return self_test(a.samples, a.expect)
    text = json.dumps(summarize(a.paths, a.process, a.bundle_id), indent=1)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
