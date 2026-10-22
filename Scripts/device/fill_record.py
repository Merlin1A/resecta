#!/usr/bin/env python3
"""fill_record.py — fill a run record from a template and a run directory.

Inputs, all written by `sitting.sh` into one run directory:
  device.json             the device, the installed app, the checkout
  rows.jsonl              one line per step: verdict, note, times, checks
  rows/ID/facts.json      the pulled facts for that step
  judge.json              the exported-PDF verdicts (optional)

The template is Markdown with placeholders:
  {{date}}                the run's date
  {{header}}              build, app, device, recorder and time facts
  {{row:ID}}              one step's result as a single table cell
  {{rows}}                a table of every step without its own slot
  {{judge}}               a table of the judged PDFs

A step's result carries the verdict, the operator's note, each machine
check named in its rows-file line with its value, and the evidence file
names. A check on a step without a recording of its own reads the whole
run and says so. The checks:
  preflight:versions  trace:present  process:continuity  memory:peak
  thermal:worst  phase:walls  signpost:NAME:max|total|all  jetsam:none-for-app
  diagnostics:hardened-runtime  xattr:backup-excluded
  container:no-pdf-outside-tmp  container:tmp-outputs
  pdf:no-terms  pdf:unencrypted  pdf:no-exif

SCRUB: before anything is written, every message text in the facts is
checked again against `xctrace_facts.allowed_text`; a text that fails is
dropped and counted in the header. No other message text is ever read.

Usage:
  fill_record.py --template FILE.md --run DIR --out FILE.md
  fill_record.py --self-test
"""
import argparse
import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from xctrace_facts import allowed_text  # noqa: E402

MIB = 1024 * 1024


def load_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def scrub(facts):
    """Drop every message text the allow-list refuses; return how many."""
    dropped = 0
    trace = facts.get("trace") or {}
    for entry in (trace.get("log") or {}).get("phases", []):
        if "text" in entry and not allowed_text("phase", entry.get("format"), entry["text"]):
            del entry["text"]
            dropped += 1
    signposts = trace.get("signposts") or {}
    for entry in signposts.get("intervals", []):
        if "text" in entry and not allowed_text("signpost", entry.get("name"), entry["text"]):
            del entry["text"]
            dropped += 1
    for name, group in (signposts.get("by_name") or {}).items():
        if group.get("max_text") and not allowed_text("signpost", name, group["max_text"]):
            group["max_text"] = ""
            dropped += 1
    for wall in (trace.get("log") or {}).get("phase_walls", []):
        if wall.get("from") not in (None, "?") and not re.fullmatch(r"Phase: [A-Za-z]+ → [A-Za-z]+", wall["from"]):
            wall["from"] = "?"
            dropped += 1
    return dropped


def seconds(ns):
    return f"{(ns or 0) / 1e9:.2f} s"


class Run:
    def __init__(self, run_dir):
        self.dir = run_dir
        self.device = load_json(os.path.join(run_dir, "device.json"), {})
        self.judge = load_json(os.path.join(run_dir, "judge.json"))
        self.rows, self.order = {}, []
        path = os.path.join(run_dir, "rows.jsonl")
        if os.path.exists(path):
            for line in open(path, encoding="utf-8"):
                if line.strip():
                    r = json.loads(line)
                    if r["row"] not in self.rows:
                        self.order.append(r["row"])
                    self.rows[r["row"]] = r
        self.facts, self.scrubbed = {}, 0
        for rid in self.order:
            f = load_json(os.path.join(run_dir, "rows", rid, "facts.json"), {})
            self.scrubbed += scrub(f)
            self.facts[rid] = f

    def traced(self):
        return [f for f in self.facts.values() if f.get("trace")]

    # ── the checks ──
    def check(self, name, rid):
        f = self.facts.get(rid, {})
        own = bool(f.get("trace"))
        pool = [f] if own else self.traced()
        wide = "" if own or name.split(":")[0] in ("preflight", "pdf", "xattr", "container") else " (run-wide)"
        kind = name.split(":")[0]
        if kind == "preflight":
            d = self.device
            app = d.get("app") or {}
            return f"checkout {d.get('repo_version')} ({d.get('repo_build')}) @ {str(d.get('repo_head'))[:8]}; installed {app.get('version')} ({app.get('bundleVersion')})"
        if kind == "trace":
            return f"trace {f['trace_bytes'] / 1e6:.1f} MB" if f.get("trace_bytes") else "no trace"
        if kind == "pdf":
            return self.pdf_check(name)
        if kind in ("xattr", "container"):
            return self.container_check(name, f.get("container") or self.last_container())
        if kind == "jetsam":
            crashes = [x.get("crashes") or {} for x in ([f] if f.get("crashes") else self.facts.values())]
            hits = [r["file"] for c in crashes for r in c.get("reports", []) if r.get("app_implicated")]
            events = sum(c.get("jetsam_events", 0) for c in crashes)
            return (f"APP IMPLICATED: {', '.join(hits)}" if hits else f"none for the app ({events} JetsamEvent(s) in the window)") + wide
        if not pool:
            return "no recording"
        traces = [x["trace"] for x in pool]
        if kind == "memory":
            peaks = [t["memory"]["peak_footprint_bytes"] for t in traces if t["memory"]["peak_footprint_bytes"]]
            return (f"peak footprint {max(peaks) / MIB:.1f} MiB" if peaks else "no app memory samples") + wide
        if kind == "thermal":
            order = ["Nominal", "Fair", "Serious", "Critical"]
            worst = [t["thermal"]["worst"] for t in traces if t["thermal"]["worst"]]
            return (f"worst {max(worst, key=order.index)}" if worst else "no thermal data") + wide
        if kind == "process":
            pids = sorted({p for t in traces for p in t["pids"]})
            died = any(t["memory"]["recently_died"] for t in traces)
            return f"{len(pids)} pid(s) {', '.join(pids) or '—'}; {'DIED' if died else 'no death flagged'}" + wide
        if kind == "phase":
            walls = [w for t in traces for w in t["log"]["phase_walls"]]
            if not walls:
                return "no Phase: lines in the trace" + wide
            return "; ".join(f"{w['from'].replace('Phase: ', '')} {seconds(w['wall_ns'])}" for w in walls) + wide
        if kind == "diagnostics":
            app = sum(t["log"]["diagnostics"]["app"] for t in traces)
            system = sum(t["log"]["diagnostics"]["system"] for t in traces)
            formats = sorted({s for t in traces for s in t["log"]["diagnostics"]["formats"]})
            return f"app {app} · system {system}" + (f" · formats: {' ¦ '.join(formats)}" if formats else "") + wide
        if kind == "signpost":
            parts = name.split(":")
            sp_name, mode = parts[1], parts[2] if len(parts) > 2 else "max"
            items = [i for t in traces for i in t["signposts"]["intervals"] if i["name"] == sp_name]
            if not items:
                return f"no {sp_name} intervals" + wide
            if mode == "all":
                return "; ".join(f"{i.get('text', '?')} {seconds(i['duration_ns'])}" for i in items) + wide
            if mode == "total":
                return f"{len(items)} × total {seconds(sum(i['duration_ns'] or 0 for i in items))}" + wide
            top = max(items, key=lambda i: i["duration_ns"] or 0)
            label = f" ({top['text']})" if top.get("text") else ""
            return f"max {seconds(top['duration_ns'])}{label} over {len(items)}" + wide
        return f"unknown check {name}"

    def last_container(self):
        for rid in reversed(self.order):
            c = self.facts.get(rid, {}).get("container")
            if c:
                return c
        return None

    def container_check(self, name, c):
        if not c:
            return "no container listing"
        if "error" in c:
            return f"listing failed: {c['error']}"
        if name == "xattr:backup-excluded":
            stores = c["stores"]
            ok = sum(s["backup_excluded"] for s in stores)
            marked = sum(s["protection_marker"] for s in stores)
            return f"{ok}/{len(stores)} stores backup-excluded; protection marker on {marked}"
        if name == "container:no-pdf-outside-tmp":
            return "none" if not c["pdfs_outside_tmp"] else f"PDF OUTSIDE tmp/: {', '.join(c['pdfs_outside_tmp'])}"
        if name == "container:tmp-outputs":
            return f"{len(c['tmp_outputs'])} pipeline output(s) under tmp/"
        return f"unknown check {name}"

    def pdf_check(self, name):
        if not self.judge or not self.judge.get("files"):
            return "no judged PDF"
        files = self.judge["files"]
        if name == "pdf:no-terms":
            bad = [f["file"] for f in files if any(f["term_hits"].values())]
        elif name == "pdf:unencrypted":
            bad = [f["file"] for f in files if f["encrypted"]]
        elif name == "pdf:no-exif":
            bad = [f["file"] for f in files if f["strings_hits"] or f["make_or_model"]
                   or any(f["metadata_tags"].get(g) for g in ("EXIF", "GPS", "MakerNotes"))]
        else:
            return f"unknown check {name}"
        return f"FAIL: {', '.join(bad)}" if bad else f"PASS over {len(files)} file(s)"

    # ── the rendering ──
    def cell(self, rid):
        r = self.rows.get(rid)
        if not r:
            return "not run"
        verdict = {"p": "**PASS**", "f": "**FAIL**", "n": "noted"}.get(r.get("verdict"), r.get("verdict") or "—")
        parts = [verdict]
        if r.get("note"):
            parts.append(r["note"])
        for name in filter(None, (r.get("checks") or "").split(",")):
            parts.append(f"`{name}` {self.check(name.strip(), rid)}")
        files = ["row.trace"] if self.facts.get(rid, {}).get("trace_bytes") else []
        files += [x["file"] for x in (self.facts.get(rid, {}).get("crashes") or {}).get("reports", [])]
        if files:
            parts.append("files: " + ", ".join(files))
        return " · ".join(parts).replace("|", "¦").replace("\n", " ")

    def header(self):
        d = self.device
        app = d.get("app") or {}
        times = [self.rows[r][k] for r in self.order for k in ("t0", "t1") if self.rows[r].get(k)]
        rungs = sorted({self.rows[r].get("rung") for r in self.order} - {None, "none", ""})
        lines = [
            f"- **Build:** checkout `{d.get('repo_head')}` · {d.get('repo_version')} ({d.get('repo_build')}) · team {d.get('team') or 'not set'}",
            f"- **Installed:** {app.get('bundleIdentifier', '?')} {app.get('version')} ({app.get('bundleVersion')})",
            f"- **Device:** {d.get('name')} · {d.get('model')} ({d.get('product')}) · iOS {d.get('os')} ({d.get('os_build')})",
            f"- **Recorder:** `{d.get('recorder')}` · recordings: {', '.join(rungs) or 'none'}",
            f"- **Time:** {min(times) if times else '—'} → {max(times) if times else '—'} · {len(self.order)} step(s)",
            f"- **Scrub:** {self.scrubbed} message text(s) dropped by the allow-list",
        ]
        refused = os.path.join(self.dir, "refused-rungs")
        if os.path.exists(refused):
            lines.append(f"- **Refused recordings:** {', '.join(open(refused).read().split())}")
        return "\n".join(lines)

    def rows_table(self, exclude):
        rest = [r for r in self.order if r not in exclude]
        if not rest:
            return "(none)"
        return "\n".join(["| step | result |", "|---|---|"] + [f"| {r} | {self.cell(r)} |" for r in rest])

    def judge_table(self):
        if not self.judge or not self.judge.get("files"):
            return "(no PDF judged)"
        out = ["| file | verdict | pages | text chars | term hits | encrypted | metadata | strings |", "|---|---|---|---|---|---|---|---|"]
        for f in self.judge["files"]:
            out.append(f"| {f['file']} | {f['verdict']} | {f['pages']} | {f['text_chars']} | {sum(f['term_hits'].values())} "
                       f"| {f['encrypted']} | {json.dumps(f['metadata_tags']) if f['metadata_tags'] else 'none'} | {f['strings_hits']} |")
        return "\n".join(out)


def fill(template, run_dir):
    run = Run(run_dir)
    slotted = set(re.findall(r"\{\{row:([^}]+)\}\}", template))
    first = run.rows[run.order[0]].get("t0", "") if run.order else ""
    text = template.replace("{{date}}", first[:10] or "undated")
    text = text.replace("{{header}}", run.header())
    text = re.sub(r"\{\{row:([^}]+)\}\}", lambda m: run.cell(m.group(1)), text)
    text = text.replace("{{rows}}", run.rows_table(slotted))
    return text.replace("{{judge}}", run.judge_table())


# ── self-test ──────────────────────────────────────────────────────────
def self_test():
    failures = []
    with tempfile.TemporaryDirectory() as run:
        for rid in ("r1", "r2"):
            os.makedirs(os.path.join(run, "rows", rid))
        json.dump({"repo_head": "abcdef1234", "repo_version": "1.0", "repo_build": "1", "name": "Phone",
                   "model": "iPhone", "os": "26.0", "recorder": "1234abcd",
                   "app": {"bundleIdentifier": "com.example", "version": "1.0", "bundleVersion": "1"}},
                  open(os.path.join(run, "device.json"), "w"))
        with open(os.path.join(run, "rows.jsonl"), "w") as fh:
            fh.write(json.dumps({"row": "r1", "verdict": "p", "note": "ok | fine", "t0": "2026-01-01T10:00:00+0000",
                                 "t1": "2026-01-01T10:01:00+0000", "rung": "combined",
                                 "checks": "memory:peak,phase:walls,signpost:drawPDFPage:max,jetsam:none-for-app"}) + "\n")
            fh.write(json.dumps({"row": "r2", "verdict": "n", "note": "", "t0": "2026-01-01T10:02:00+0000",
                                 "t1": "2026-01-01T10:02:00+0000", "checks": "memory:peak,xattr:backup-excluded"}) + "\n")
        trace = {"pids": {"42": {}}, "memory": {"peak_footprint_bytes": 300 * MIB, "recently_died": False},
                 "thermal": {"worst": "Nominal"},
                 "log": {"phases": [{"format": "query %{public}s", "text": "LEAKED-TERM"}],
                         "phase_walls": [{"from": "Phase: editing → redacting", "wall_ns": 2500000000},
                                         {"from": "LEAKED-TERM", "wall_ns": 1}],
                         "diagnostics": {"app": 0, "system": 0, "formats": []}},
                 "signposts": {"intervals": [{"name": "drawPDFPage", "duration_ns": 1200000000, "text": "page=3 dpi=200"},
                                             {"name": "other", "duration_ns": 1, "text": "LEAKED-TERM"}],
                               "by_name": {}}}
        json.dump({"trace": trace, "trace_bytes": 2000000, "crashes": {"reports": [], "jetsam_events": 1}},
                  open(os.path.join(run, "rows", "r1", "facts.json"), "w"))
        json.dump({"container": {"stores": [{"backup_excluded": True, "protection_marker": True}],
                                 "pdfs_outside_tmp": [], "tmp_outputs": []}},
                  open(os.path.join(run, "rows", "r2", "facts.json"), "w"))
        out = fill("# {{date}}\n{{header}}\n| r1 | {{row:r1}} |\n{{rows}}\n{{judge}}\n", run)
    for want in ("# 2026-01-01", "**PASS** · ok ¦ fine", "peak footprint 300.0 MiB", "editing → redacting 2.50 s",
                 "max 1.20 s (page=3 dpi=200)", "none for the app (1 JetsamEvent(s)", "| r2 | noted",
                 "peak footprint 300.0 MiB (run-wide)", "1/1 stores backup-excluded", "3 message text(s) dropped",
                 "(no PDF judged)"):
        if want not in out:
            failures.append(f"missing: {want!r}")
    if "LEAKED-TERM" in out:
        failures.append("a non-allow-listed text reached the record")
    for line in failures:
        print("FAIL", line)
    print("fill_record self-test:", "FAIL" if failures else "PASS")
    return 1 if failures else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--template")
    ap.add_argument("--run")
    ap.add_argument("--out")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--samples", help=argparse.SUPPRESS)
    ap.add_argument("--expect", help=argparse.SUPPRESS)
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if not (a.template and a.run and a.out):
        ap.error("--template, --run and --out are required")
    with open(a.template, encoding="utf-8") as fh:
        text = fill(fh.read(), a.run)
    with open(a.out, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"record: {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
