#!/usr/bin/env python3
"""xctrace_facts.py — facts from exported Instruments tables, as JSON.

Reads the XML that `xcrun xctrace export --xpath '…/table[@schema="…"]'`
writes for one recording and reduces it to the facts an attended run
records for one app process:

  os-log                          the app's `Phase:` transitions with their
                                  timestamps; row counts per subsystem,
                                  category and level; the hardened-runtime
                                  and allocator diagnostics as counts plus
                                  their format strings
  os-signpost-interval            every interval the app emitted: name,
                                  subsystem, category, start, duration
  sysmon-process                  the app's physical-footprint and resident
                                  series and their peaks; a death flag
  device-thermal-state-intervals  the thermal states and their durations
  process-info                    the app's process ids

Every value comes from the `fmt` attribute or the text of a cell; a cell
carrying `ref="N"` repeats the element with `id="N"` met earlier in the
same table. The parser streams, so an hour of all-process logging fits.

No message text leaves this script unless it passes the allow-list below
(`allowed_text`): the app's phase names and the numeric or key-only
signpost messages. Everything else is kept as counts. `fill_record.py`
re-applies the same allow-list before it writes a record.

Usage:
  xctrace_facts.py [--process NAME] [--out FILE] TABLE.xml...
  xctrace_facts.py --self-test [--samples DIR [--expect FILE]]

`--self-test` alone runs on built-in synthetic tables. With `--samples`
it also reduces every recognised capture in DIR and prints the facts;
with `--expect` (JSON: {"file name": {"dotted.key": value}}) it compares.
"""
import argparse
import json
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET

DEFAULT_PROCESS = "ResectaApp"

# ── the allow-list ─────────────────────────────────────────────────────
PHASE_FORMAT = re.compile(r"^Phase: %\{public\}[@s] → %\{public\}[@s]$")
PHASE_TEXT = re.compile(r"^Phase: [A-Za-z]+ → [A-Za-z]+$")
SIGNPOST_TEXT = {
    "drawPDFPage": re.compile(r"^page=\d+ dpi=\d+$"),
    "Zeroize": re.compile(r"^bytes=\d+$"),
    "layer": re.compile(r"^key=[A-Za-z0-9_.-]+$"),
    "postBatch": re.compile(r"^$"),
}
# Diagnostics the hardened runtime and the allocator write.
DIAGNOSTIC = re.compile(r"hardened|checked.?alloc|malloc", re.IGNORECASE)


def squash(text):
    """Instruments renders arguments with padding spaces; fold them."""
    text = re.sub(r"\s+", " ", text or "").strip()
    return re.sub(r"\s*=\s*", "=", text)


def allowed_text(kind, key, text):
    """True when `text` may appear in a record. kind: phase | signpost."""
    text = squash(text)
    if kind == "phase":
        return bool(PHASE_FORMAT.match(key or "")) and bool(PHASE_TEXT.match(text))
    if kind == "signpost":
        pattern = SIGNPOST_TEXT.get(key or "")
        return bool(pattern and pattern.match(text))
    return False


# ── the table reader ───────────────────────────────────────────────────
def _value(el):
    return (el.get("fmt") or "", (el.text or "").strip())


def iter_rows(path):
    """Yield (schema, {mnemonic: (fmt, text)}) for every row in the file."""
    ids, schema, cols = {}, None, []
    for _, el in ET.iterparse(path, events=("end",)):
        if el.tag == "schema":
            schema = el.get("name")
            cols = [c.findtext("mnemonic") for c in el.findall("col")]
            ids = {}
        elif el.tag == "row":
            cells = {}
            for name, child in zip(cols, list(el)):
                ref = child.get("ref")
                cells[name] = ids.get(ref, ("", "")) if ref else _value(child)
            yield schema, cells
            el.clear()
        elif el.get("id") is not None:
            ids[el.get("id")] = _value(el)


def process_of(cell):
    """'ResectaApp (6492)' → ('ResectaApp', 6492)."""
    m = re.match(r"^(.*) \((\d+)\)$", cell[0])
    return (m.group(1), int(m.group(2))) if m else (cell[0], None)


def number(cell):
    try:
        return int(float(cell[1]))
    except (TypeError, ValueError):
        return None


# ── the reducer ────────────────────────────────────────────────────────
class Facts:
    def __init__(self, process):
        self.process = process
        self.tables = {}
        self.pids = {}
        self.log = {"rows": 0, "app_rows": 0, "app_by_source": {},
                    "phases": [], "diagnostics": {"app": 0, "system": 0, "formats": []}}
        self.signposts = []
        self.memory = {"samples": 0, "series": [], "recently_died": False}
        self.thermal = []

    def _seen(self, pid, t):
        if pid is None or t is None:
            return
        span = self.pids.setdefault(str(pid), {"first_ns": t, "last_ns": t})
        span["first_ns"] = min(span["first_ns"], t)
        span["last_ns"] = max(span["last_ns"], t)

    def _mine(self, cell):
        name, pid = process_of(cell)
        return name == self.process, pid

    def add(self, schema, row):
        self.tables[schema] = self.tables.get(schema, 0) + 1
        handler = {
            "os-log": self._log,
            "os-signpost-interval": self._signpost,
            "sysmon-process": self._sysmon,
            "device-thermal-state-intervals": self._thermal,
            "process-info": self._process_info,
        }.get(schema)
        if handler:
            handler(row)

    def _log(self, row):
        self.log["rows"] += 1
        mine, pid = self._mine(row.get("process", ("", "")))
        fmt_string = row.get("format-string", ("", ""))[0]
        subsystem = row.get("subsystem", ("", ""))[0]
        category = row.get("category", ("", ""))[0]
        diagnostic = DIAGNOSTIC.search(" ".join((fmt_string, subsystem, category))) \
            or subsystem.startswith("com.apple.security")
        if not mine:
            message = row.get("message", ("", ""))[0]
            if diagnostic and self.process in message:
                self._diagnostic("system", fmt_string)
            return
        t = number(row.get("time", ("", "")))
        self._seen(pid, t)
        self.log["app_rows"] += 1
        level = row.get("message-type", ("", ""))[0]
        key = f"{subsystem}/{category}/{level}"
        self.log["app_by_source"][key] = self.log["app_by_source"].get(key, 0) + 1
        if diagnostic:
            self._diagnostic("app", fmt_string)
        message = row.get("message", ("", ""))[0]
        if fmt_string.startswith("Phase:"):
            entry = {"t_ns": t, "level": level, "format": fmt_string}
            if allowed_text("phase", fmt_string, message):
                entry["text"] = squash(message)
            self.log["phases"].append(entry)

    def _diagnostic(self, side, fmt_string):
        self.log["diagnostics"][side] += 1
        if fmt_string and fmt_string not in self.log["diagnostics"]["formats"]:
            self.log["diagnostics"]["formats"].append(fmt_string)

    def _signpost(self, row):
        mine, pid = self._mine(row.get("process", ("", "")))
        if not mine:
            return
        start = number(row.get("start", ("", "")))
        self._seen(pid, start)
        name = row.get("name", ("", ""))[0]
        entry = {"name": name,
                 "subsystem": row.get("subsystem", ("", ""))[0],
                 "category": row.get("category", ("", ""))[0],
                 "start_ns": start,
                 "duration_ns": number(row.get("duration", ("", "")))}
        message = row.get("start-message", ("", ""))[0]
        if allowed_text("signpost", name, message):
            entry["text"] = squash(message)
        self.signposts.append(entry)

    def _sysmon(self, row):
        mine, pid = self._mine(row.get("process", ("", "")))
        if not mine:
            return
        t = number(row.get("time", ("", "")))
        self._seen(pid, t)
        self.memory["samples"] += 1
        self.memory["series"].append([t, number(row.get("memory-physical-footprint", ("", ""))),
                                      number(row.get("memory-resident-size", ("", "")))])
        if row.get("recently-died", ("", ""))[1] == "1":
            self.memory["recently_died"] = True

    def _thermal(self, row):
        self.thermal.append({"state": row.get("thermal-state", ("", ""))[0],
                             "start_ns": number(row.get("start", ("", ""))),
                             "duration_ns": number(row.get("duration", ("", "")))})

    def _process_info(self, row):
        name = row.get("process-name", ("", ""))[0]
        if name == self.process:
            self._seen(number(row.get("pid", ("", ""))), number(row.get("time", ("", ""))))

    def result(self):
        series = self.memory["series"]
        footprints = [s[1] for s in series if s[1] is not None]
        residents = [s[2] for s in series if s[2] is not None]
        intervals = {}
        for s in self.signposts:
            group = intervals.setdefault(s["name"], {"count": 0, "total_ns": 0, "max_ns": 0})
            group["count"] += 1
            group["total_ns"] += s["duration_ns"] or 0
            if (s["duration_ns"] or 0) >= group["max_ns"]:
                group["max_ns"] = s["duration_ns"] or 0
                group["max_text"] = s.get("text", "")
        phases = self.log["phases"]
        walls = [{"from": a.get("text", "?"), "wall_ns": b["t_ns"] - a["t_ns"]}
                 for a, b in zip(phases, phases[1:]) if a["t_ns"] is not None and b["t_ns"] is not None]
        order = ["Nominal", "Fair", "Serious", "Critical"]
        states = [t["state"] for t in self.thermal if t["state"] in order]
        return {
            "process": self.process,
            "tables": self.tables,
            "pids": self.pids,
            "log": dict(self.log, phase_walls=walls),
            "signposts": {"intervals": self.signposts, "by_name": intervals},
            "memory": {
                "samples": self.memory["samples"],
                "peak_footprint_bytes": max(footprints) if footprints else None,
                "peak_resident_bytes": max(residents) if residents else None,
                "recently_died": self.memory["recently_died"],
                "series": series,
            },
            "thermal": {"intervals": self.thermal,
                        "worst": max(states, key=order.index) if states else None},
        }


def reduce_files(paths, process):
    facts, unreadable = Facts(process), []
    for path in paths:
        try:
            for schema, row in iter_rows(path):
                facts.add(schema, row)
        except ET.ParseError as e:
            unreadable.append(f"{os.path.basename(path)}: {e}")
    return dict(facts.result(), unreadable=unreadable)


# ── self-test ──────────────────────────────────────────────────────────
def _table(schema, cols, rows):
    head = "".join(f"<col><mnemonic>{c}</mnemonic></col>" for c in cols)
    return (f'<?xml version="1.0"?><trace-query-result><node><schema name="{schema}">'
            f"{head}</schema>{''.join(rows)}</node></trace-query-result>")


SYNTHETIC = {
    "log.xml": _table("os-log", ["time", "process", "message-type", "format-string", "subsystem", "category", "message"], [
        '<row><event-time fmt="00:01.000">1000000000</event-time><process id="1" fmt="ResectaApp (42)"/>'
        '<event-type id="2" fmt="Info"/><format-string id="3" fmt="Phase: %{public}s → %{public}s"/>'
        '<subsystem id="4" fmt="com.resecta.app"/><category id="5" fmt="state"/>'
        '<os-log-metadata fmt="Phase:  editing  →  redacting"/></row>',
        '<row><event-time fmt="00:03.500">3500000000</event-time><process ref="1"/><event-type ref="2"/>'
        '<format-string ref="3"/><subsystem ref="4"/><category ref="5"/>'
        '<os-log-metadata fmt="Phase:  redacting  →  verifying"/></row>',
        '<row><event-time fmt="00:04.000">4000000000</event-time><process ref="1"/><event-type fmt="Default"/>'
        '<format-string fmt="query %{public}s"/><subsystem ref="4"/><category fmt="search"/>'
        '<os-log-metadata fmt="query SECRET-NAME"/></row>',
        '<row><event-time fmt="00:04.100">4100000000</event-time><process fmt="kernel (0)"/><event-type fmt="Default"/>'
        '<format-string fmt="hardened process %{public}s report"/><subsystem fmt="com.apple.kernel"/><category fmt="x"/>'
        '<os-log-metadata fmt="hardened process ResectaApp report"/></row>',
    ]),
    "signpost.xml": _table("os-signpost-interval", ["start", "duration", "name", "category", "subsystem", "process", "start-message"], [
        '<row><start-time fmt="00:01.1">1100000000</start-time><duration fmt="2 s">2000000000</duration>'
        '<string id="1" fmt="drawPDFPage"/><category fmt="PageRasterizer"/><subsystem fmt="com.resecta.engine"/>'
        '<process id="2" fmt="ResectaApp (42)"/><os-log-metadata fmt=" page= 3  dpi= 200"/></row>',
        '<row><start-time fmt="00:01.2">1200000000</start-time><duration fmt="1 s">1000000000</duration>'
        '<string fmt="otherSignpost"/><category fmt="c"/><subsystem fmt="com.resecta.app"/>'
        '<process ref="2"/><os-log-metadata fmt="term SECRET-NAME"/></row>',
    ]),
    "sysmon.xml": _table("sysmon-process", ["time", "process", "recently-died", "memory-physical-footprint", "memory-resident-size"], [
        '<row><start-time fmt="0">500000000</start-time><process id="1" fmt="ResectaApp (42)"/><boolean fmt="No">0</boolean>'
        '<size-in-bytes fmt="10 MiB">10485760</size-in-bytes><size-in-bytes fmt="40 MiB">41943040</size-in-bytes></row>',
        '<row><start-time fmt="1">1500000000</start-time><process ref="1"/><boolean fmt="No">0</boolean>'
        '<size-in-bytes fmt="300 MiB">314572800</size-in-bytes><size-in-bytes fmt="350 MiB">367001600</size-in-bytes></row>',
    ]),
    "thermal.xml": _table("device-thermal-state-intervals", ["start", "duration", "thermal-state"], [
        '<row><start-time>0</start-time><duration>1000</duration><thermal-state fmt="Nominal"/></row>',
        '<row><start-time>1000</start-time><duration>500</duration><thermal-state fmt="Fair"/></row>',
    ]),
}


def dotted(obj, key):
    for part in key.split("."):
        obj = obj[int(part)] if isinstance(obj, list) else obj.get(part) if isinstance(obj, dict) else None
    return obj


def self_test(samples=None, expect=None):
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        paths = []
        for name, body in SYNTHETIC.items():
            paths.append(os.path.join(tmp, name))
            with open(paths[-1], "w", encoding="utf-8") as fh:
                fh.write(body)
        f = reduce_files(paths, DEFAULT_PROCESS)
    checks = {
        "log.app_rows": 3,
        "log.phases.0.text": "Phase: editing → redacting",
        "log.phase_walls.0.wall_ns": 2500000000,
        "log.diagnostics.system": 1,
        "signposts.by_name.drawPDFPage.max_text": "page=3 dpi=200",
        "memory.peak_footprint_bytes": 314572800,
        "thermal.worst": "Fair",
        "pids.42.first_ns": 500000000,
    }
    for key, want in checks.items():
        if dotted(f, key) != want:
            failures.append(f"synthetic {key}: got {dotted(f, key)!r}, want {want!r}")
    if "SECRET-NAME" in json.dumps(f):
        failures.append("synthetic: a non-allow-listed message reached the facts")
    with tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False) as fh:
        empty = fh.name
    if not reduce_files([empty], DEFAULT_PROCESS)["unreadable"]:
        failures.append("synthetic: an empty export was not reported as unreadable")
    os.unlink(empty)
    if samples:
        wanted = json.load(open(expect, encoding="utf-8")) if expect else {}
        for name in sorted(os.listdir(samples)):
            if not name.endswith(".xml"):
                continue
            facts = reduce_files([os.path.join(samples, name)], DEFAULT_PROCESS)
            print(f"{name}: tables={facts['tables']} app_log_rows={facts['log']['app_rows']} "
                  f"peak_footprint={facts['memory']['peak_footprint_bytes']} thermal={facts['thermal']['worst']}")
            for key, want in wanted.get(name, {}).items():
                if dotted(facts, key) != want:
                    failures.append(f"{name} {key}: got {dotted(facts, key)!r}, want {want!r}")
    for line in failures:
        print("FAIL", line)
    print("xctrace_facts self-test:", "FAIL" if failures else "PASS")
    return 1 if failures else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("tables", nargs="*", help="exported table XML files")
    ap.add_argument("--process", default=DEFAULT_PROCESS)
    ap.add_argument("--out", help="write the facts here (default: stdout)")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--samples")
    ap.add_argument("--expect")
    a = ap.parse_args()
    if a.self_test:
        return self_test(a.samples, a.expect)
    if not a.tables:
        ap.error("no table files given")
    if any(os.path.isdir(t) for t in a.tables):
        ap.error("pass the XML that `xctrace export --xpath` writes, not the .trace bundle")
    facts = reduce_files(a.tables, a.process)
    text = json.dumps(facts, indent=1, ensure_ascii=False)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
