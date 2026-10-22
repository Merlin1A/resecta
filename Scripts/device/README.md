# Device recorder

A recorder for attended runs on a physical iPhone. The operator does the
taps on the phone; the Mac records each step with Instruments over the
cable, reads the app's data container and the crash-log folder before and
after, checks the PDFs the operator exports, and fills the run's record.
Apple's command-line tools only (`xcrun devicectl`, `xcrun xctrace`); no
root, no jailbreak tooling, no simulator.

## Prerequisites

- Xcode 26.6 with its command-line tools selected.
- An iPhone paired with this Mac, connected by cable, unlocked, with
  Developer Mode on, and the app under test installed.
- For the PDF checks: `pdftotext` (poppler), `qpdf`, `exiftool`.
- `python3` (standard library only) and `bash`.

## Verbs

All output goes to one run directory (`--out DIR`, default
`Scripts/device/device-runs/DATE/`, ignored by git).

| verb | what it does |
|---|---|
| `preflight` | Resolves the device's two identifiers once (devicectl's CoreDevice id, xctrace's hardware UDID) into `device.json`; checks Xcode, the connection, the lock state, Developer Mode, that xctrace sees the device, the installed app's version, and the checkout's commit, version and team. Prints a PASS/FAIL table. |
| `record start ID` | Lists the container and the crash-log folder, then starts an Instruments recording of all processes (Activity Monitor with os_log, os_signpost and Thermal State; if the device refuses that, fewer instruments, then the Logging template — the refusal is remembered for the run). T0 is stamped when xctrace reports it is recording. `--cap MIN` bounds the recording (default 15); `--launch` relaunches the app under test after T0. |
| `record stop ID` | Ends the recording, lists the two folders again and appends the verdict to `rows.jsonl` (prompted, or `--verdict p\|f\|n --note TEXT`). |
| `run --rows FILE` | The loop over a rows file: prints each step's instructions and pass line, waits for Enter to start and to stop, then asks for the verdict. `--from ID` resumes. |
| `pull` | Exports each recording's tables (an empty export is retried once) and reduces them with the three readers below; copies any crash report that appeared since the previous step's last listing; writes `rows/ID/facts.json`. |
| `judge --inbox DIR` | Runs `judge_pdf.py` over the exported PDFs (`--terms`, `--terms-file`, `--since`). |
| `record --template FILE` | Runs `fill_record.py`: the template plus the run directory gives the record (`--record-out FILE`). |
| `state --mode secure\|searchable` | Relaunches the app with the pipeline mode as a launch-argument default, then asks the operator to confirm it in Settings (the default does not persist). |
| `probe` | Starts one five-second combined recording (does the device accept it?) and reports each step's trace size per minute. |
| `self-test` | Every script's self-test; no device needed. `--samples DIR --expect FILE` also checks real captures against pinned values. |

## The scripts

- `sitting.sh` — the verbs above; every device call goes through one
  devicectl helper (JSON to a file, devicectl's supported script output)
  and one xctrace helper.
- `xctrace_facts.py` — exported Instruments tables to facts: `Phase:`
  transitions, signpost intervals, memory footprint series and peaks,
  thermal states, process ids, hardened-runtime diagnostics as counts.
- `crash_facts.py` — `.ips` reports to facts: jetsam victims and the app's
  own entry, crashes that name the app.
- `container_facts.py` — devicectl listings to facts: store attributes
  (backup exclusion), pipeline outputs under `tmp/`, listing diffs.
- `judge_pdf.py` — exported PDFs to verdicts: terms absent from the text
  layer, a clean `qpdf --check`, no encryption, no EXIF/GPS/XMP traces.
- `fill_record.py` — the record from a template and a run directory.

Each takes `--help` and `--self-test`.

## The rows file

Tab-separated, one header line, then one step per line:

| column | meaning |
|---|---|
| `id` | the step's identifier (a directory name under `rows/`) |
| `class` | `A` a machine read · `C` the operator taps, the recorder observes · `D` human by nature · `E` a manual step outside the phone · `X` not reachable on every build (offered, skipped unless run) |
| `cap_min` | the recording's cap in minutes; `0` = no recording (an `A` step then runs without a prompt) |
| `how` | what the operator does |
| `pass` | the pass line shown before the step |
| `checks` | comma-separated machine checks attached to the record (`fill_record.py --help` lists them) |

`example-rows.tsv` is a three-step example.

## Templates

A record template is Markdown with `{{date}}`, `{{header}}`, `{{row:ID}}`
(one step's result as a table cell), `{{rows}}` (every step without its
own slot) and `{{judge}}` (the judged PDFs).

## The inbox

Exported PDFs reach the Mac by AirDrop and land in `~/Downloads`. A
process without access to `~/Downloads` reads them from
`~/Documents/resecta-sitting-inbox/` (the default inbox) after a move by
hand; run from your own terminal, `judge --inbox ~/Downloads` works too.

## What it never does

- Install, uninstall or reinstall an app; reboot the device; take a
  sysdiagnose; send a memory warning.
- Write to the app's data container or to another app's container.
- Use `sudo`, `log collect` (it needs root), or any non-Apple device tool.
- Boot or touch a simulator.
- Open a PDF in an app or copy one anywhere; put page text, metadata
  values or log message text into `facts.json` or the record beyond the
  allow-listed phase names and numeric or key-only signpost messages.

The run directory itself is raw: each `row.trace`, its exported
`tables/*.xml` (the log text of every process on the device) and any
copied `.ips` report stay there, on this Mac. Share `facts.json`,
`rows.jsonl`, `judge.json` and the record, not the run directory.

## Not yet

- Building and installing a Release build on the device, and reading its
  entitlements back from the installed product.
- Preparing fixtures for the phone (a list and checksums to AirDrop).
- Recording the app's network connections (the Network template).
- Driving the taps (a UI test plan on the device); this recorder observes.
