#!/bin/bash
# sitting.sh — a recorder for attended runs on a physical iPhone.
#
# The operator does the taps; this script does the bookkeeping. For each
# step of a rows file it starts and stops an Instruments recording on the
# connected device, snapshots the app's data container and the crash-log
# folder before and after, and writes the operator's verdict. Afterwards it
# pulls the facts (phase transitions, signpost intervals, memory peaks,
# thermal states, jetsam victims, store attributes), judges exported PDFs
# on the Mac and fills a record from a template.
#
# Apple tools only (xcrun devicectl, xcrun xctrace); no root. It never
# installs or uninstalls an app, never writes the app's container, never
# sends a memory warning, never reboots the device, never touches a
# simulator. The only device-side process control is launching and
# terminating the app under test (`state`, and `--launch` on a row).
#
# Usage:
#   sitting.sh preflight [--device NAME|ID]
#   sitting.sh record start ROW-ID [--cap MIN] [--launch]
#   sitting.sh record stop ROW-ID [--verdict p|f|n] [--note TEXT]
#   sitting.sh run --rows FILE.tsv [--from ROW-ID]
#   sitting.sh pull
#   sitting.sh judge --inbox DIR [--since STAMP] [--terms "a,b" | --terms-file F]
#   sitting.sh record --template FILE.md [--record-out FILE.md]
#   sitting.sh state --mode secure|searchable
#   sitting.sh probe
#   sitting.sh self-test [--samples DIR [--expect FILE]]
# Common options:
#   --out DIR         the run directory (default Scripts/device/device-runs/DATE)
#   --bundle-id ID    the app under test (default com.resecta.app)
#   --process NAME    its executable name (default ResectaApp)
#   --repo DIR        the source checkout preflight reads (default this one)
#
# The rows file is tab-separated: id, class, cap minutes, how, pass line,
# machine checks (comma-separated names). Class A with cap 0 runs without
# a prompt (a machine read); D and E rows take a verdict only; X rows are
# offered and skipped unless the operator runs them. See README.md.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PY="python3 -I"
BUNDLE_ID="com.resecta.app"
PROCESS="ResectaApp"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="$HERE/device-runs/$(date +%Y-%m-%d)"
DEVICE_SEL=""
CAP=15

say() { printf '%s\n' "$*"; }
die() { printf 'sitting.sh: %s\n' "$*" >&2; exit 1; }
now() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# dc OUT.json ARGS… — every devicectl call; JSON to a file is its only
# supported script interface. The human log goes beside the JSON.
dc() {
    local json="$1"; shift
    # The JSON flag goes first: after an app's launch arguments it would reach the app.
    xcrun devicectl --json-output "$json" "$@" > "${json%.json}.log" 2>&1
}
# xt ARGS… — every xctrace call.
xt() { xcrun xctrace "$@"; }

# jq-free JSON reads: pyjson FILE 'EXPR over d'.
pyjson() {
    $PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
try:
    v=eval(sys.argv[2])
except Exception:
    v=None
print(v if isinstance(v,str) else json.dumps(v))' "$1" "$2"
}

device_field() { pyjson "$OUT/device.json" "d['$1']"; }

need_device() {
    [ -f "$OUT/device.json" ] || die "no device.json in $OUT — run preflight first"
    UUID="$(device_field uuid)"; UDID="$(device_field udid)"
}

# ── preflight ──────────────────────────────────────────────────────────
preflight() {
    mkdir -p "$OUT"
    local fails=0 table="$OUT/preflight.txt"
    : > "$table"
    row() { printf '%-5s %-22s %s\n' "$1" "$2" "$3" | tee -a "$table"; [ "$1" = FAIL ] && fails=$((fails + 1)); return 0; }

    local xv; xv="$(xcodebuild -version 2>/dev/null | head -1)"
    if [ -n "$xv" ]; then row PASS xcode "$xv"; else row FAIL xcode "xcodebuild not found"; fi

    dc "$OUT/devices.json" list devices || true
    $PY -c 'import json,sys
d=json.load(open(sys.argv[1])); sel=sys.argv[2]
devs=[x for x in d.get("result",{}).get("devices",[]) if x.get("hardwareProperties",{}).get("reality")=="physical"]
if sel: devs=[x for x in devs if sel in (x.get("identifier"), x.get("deviceProperties",{}).get("name"), x.get("hardwareProperties",{}).get("udid"))]
devs=[x for x in devs if x.get("connectionProperties",{}).get("tunnelState")=="connected"] or devs
if not devs: sys.exit(1)
x=devs[0]; h=x["hardwareProperties"]; p=x["deviceProperties"]; c=x["connectionProperties"]
json.dump({"uuid":x["identifier"],"udid":h.get("udid"),"name":p.get("name"),"model":h.get("marketingName"),
  "product":h.get("productType"),"os":p.get("osVersionNumber"),"os_build":p.get("osBuildUpdate"),
  "developer_mode":p.get("developerModeStatus"),"tunnel":c.get("tunnelState"),"transport":c.get("transportType")},
  open(sys.argv[3],"w"),indent=1)' "$OUT/devices.json" "$DEVICE_SEL" "$OUT/device.json" \
        || { row FAIL device "no physical device listed (cable, trust, developer mode)"; finish_preflight; return 1; }
    need_device
    row PASS device "$(device_field name) · $(device_field model) · iOS $(device_field os) ($(device_field os_build))"
    if [ "$(device_field tunnel)" = connected ]; then row PASS connected "$(device_field transport)"; else row FAIL connected "tunnel $(device_field tunnel)"; fi
    if [ "$(device_field developer_mode)" = enabled ]; then row PASS developer-mode enabled; else row FAIL developer-mode "$(device_field developer_mode)"; fi

    if dc "$OUT/lockstate.json" device info lockState --device "$UUID"; then
        if [ "$(pyjson "$OUT/lockstate.json" "d['result']['passcodeRequired']")" = false ]; then
            row PASS unlocked "passcodeRequired false"
        else row FAIL unlocked "unlock the device"; fi
    else row FAIL unlocked "lockState unreadable"; fi

    if xt list devices 2>/dev/null | /usr/bin/grep -q "$UDID"; then row PASS xctrace "sees $UDID"
    else row FAIL xctrace "does not list $UDID"; fi

    if dc "$OUT/app.json" device info apps --device "$UUID" --bundle-id "$BUNDLE_ID"; then
        local app
        app="$(pyjson "$OUT/app.json" "[(a.get('version'), a.get('bundleVersion')) for a in d['result']['apps'] if a.get('bundleIdentifier')=='$BUNDLE_ID'][0]")"
        if [ "$app" != null ]; then row PASS app "$BUNDLE_ID $app"; else row FAIL app "$BUNDLE_ID not installed"; fi
    else row FAIL app "apps unreadable"; fi

    local head ver build team
    head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"
    ver="$(/usr/bin/grep -m1 'MARKETING_VERSION' "$REPO/project.yml" 2>/dev/null | /usr/bin/grep -oE '[0-9][0-9.]*')"
    build="$(/usr/bin/grep -m1 'CURRENT_PROJECT_VERSION' "$REPO/project.yml" 2>/dev/null | /usr/bin/grep -oE '[0-9]+')"
    team="$(/usr/bin/grep -m1 -oE 'DEVELOPMENT_TEAM = [A-Z0-9]+' "$REPO/ResectaApp.xcodeproj/project.pbxproj" 2>/dev/null | awk '{print $3}')"
    row INFO repo "${head:-?} · ${ver:-?} (${build:-?}) · team ${team:-not set}"
    $PY -c 'import json,sys
d=json.load(open(sys.argv[1])); a=sys.argv
try: app=json.loads(a[7])
except ValueError: app=None
d.update(repo_head=a[2], repo_version=a[3], repo_build=a[4], team=a[5], recorder=a[6], app=app); json.dump(d,open(a[1],"w"),indent=1)' \
        "$OUT/device.json" "$head" "$ver" "$build" "$team" "$(git -C "$HERE" rev-parse --short=8 HEAD 2>/dev/null)" "$(pyjson "$OUT/app.json" "[a for a in d['result']['apps'] if a.get('bundleIdentifier')=='$BUNDLE_ID'][0]" 2>/dev/null)"
    finish_preflight
}
finish_preflight() {
    say "preflight: $fails failure(s); table in $table"
    [ "$fails" -eq 0 ]
}

# ── per-row recording ──────────────────────────────────────────────────
# The template ladder: one combined recording first; a refused rung is
# recorded and skipped for the rest of the run.
rung_args() {
    case "$1" in
        combined) echo "--template|Activity Monitor|--instrument|os_log|--instrument|os_signpost|--instrument|Thermal State" ;;
        no-thermal) echo "--template|Activity Monitor|--instrument|os_log|--instrument|os_signpost" ;;
        logging) echo "--template|Logging" ;;
    esac
}

listings() {  # listings DIR SUFFIX — the container and the crash-log folder
    dc "$1/container-$2.json" device info files --device "$UUID" \
        --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" || say "  (container listing failed: $1/container-$2.log)"
    dc "$1/crashes-$2.json" device info files --device "$UUID" --domain-type systemCrashLogs \
        || say "  (crash-log listing failed: $1/crashes-$2.log)"
}

app_pid() {
    dc "$OUT/processes.json" device info processes --device "$UUID" >/dev/null 2>&1 || return 1
    pyjson "$OUT/processes.json" "[p['processIdentifier'] for p in d['result']['runningProcesses'] if str(p.get('executable','')).endswith('/$PROCESS')][0]"
}

record_start() {
    local id="$1" launch="$2" dir="$OUT/rows/$1" rung started pid
    need_device
    mkdir -p "$dir"
    [ -f "$dir/xctrace.pid" ] && die "row $id is already recording"
    listings "$dir" start
    for rung in combined no-thermal logging; do
        /usr/bin/grep -qx "$rung" "$OUT/refused-rungs" 2>/dev/null && continue
        rm -rf "$dir/row.trace"
        IFS='|' read -r -a args <<< "$(rung_args "$rung")"
        nohup xcrun xctrace record --device "$UDID" "${args[@]}" --all-processes \
            --time-limit "${CAP}m" --output "$dir/row.trace" --no-prompt > "$dir/xctrace.log" 2>&1 < /dev/null &
        pid=$!
        started=""
        for _ in $(seq 1 90); do
            /usr/bin/grep -q 'Ctrl-C to stop' "$dir/xctrace.log" && { started=1; break; }
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        if [ -n "$started" ]; then
            echo "$pid" > "$dir/xctrace.pid"
            printf '{"row":"%s","rung":"%s","t0":"%s","t0_epoch":%s,"cap_min":%s}\n' "$id" "$rung" "$(now)" "$(date +%s)" "$CAP" > "$dir/start.json"
            say "row $id: recording ($rung) — T0 $(now)"
            [ "$launch" = 1 ] && launch_app "$dir"
            return 0
        fi
        kill -INT "$pid" 2>/dev/null
        echo "$rung" >> "$OUT/refused-rungs"
        printf '%s\t%s\t%s\n' "$(now)" "$rung" "$(/usr/bin/grep -v '^ *0x' "$dir/xctrace.log" | tail -3 | tr '\n' ' ')" >> "$OUT/refused-rungs.log"
        say "row $id: the $rung recording was refused; trying the next rung"
    done
    die "row $id: every recording rung was refused (see $OUT/refused-rungs.log)"
}

launch_app() {  # the app under test, with any argument-domain defaults in LAUNCH_ARGS
    # `--` keeps devicectl from reading the app's own `-key value` arguments as its options.
    if dc "$1/launch.json" device process launch --device "$UUID" --terminate-existing "$BUNDLE_ID" ${LAUNCH_ARGS:+-- $LAUNCH_ARGS}; then
        say "  launched $BUNDLE_ID ${LAUNCH_ARGS:-}"
    else say "  launch failed ($1/launch.log)"; fi
}

record_stop() {
    local id="$1" verdict="$2" note="$3" dir="$OUT/rows/$1" pid t1 rung
    need_device
    if [ -f "$dir/xctrace.pid" ]; then
        pid="$(cat "$dir/xctrace.pid")"
        kill -INT "$pid" 2>/dev/null
        for _ in $(seq 1 240); do
            /usr/bin/grep -q 'Output file saved' "$dir/xctrace.log" && break
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        /usr/bin/grep -q 'Output file saved' "$dir/xctrace.log" || say "row $id: the recording did not report a save (see $dir/xctrace.log)"
        rm -f "$dir/xctrace.pid"
    fi
    t1="$(now)"
    listings "$dir" stop
    if [ -z "$verdict" ]; then
        read -r -p "row $id verdict [p]ass/[f]ail/[n]ote-only: " verdict
        read -r -p "row $id note (Enter for none): " note
    fi
    rung="$( [ -f "$dir/start.json" ] && pyjson "$dir/start.json" "d['rung']" || echo none)"
    $PY -c 'import json,sys; a=sys.argv; print(json.dumps({"row":a[1],"verdict":a[2],"note":a[3],"t0":a[4],"t1":a[5],"rung":a[6],"class":a[7],"checks":a[8]}, ensure_ascii=False))' \
        "$id" "$verdict" "$note" "$( [ -f "$dir/start.json" ] && pyjson "$dir/start.json" "d['t0']" || echo "$t1")" "$t1" "$rung" "${ROW_CLASS:-}" "${ROW_CHECKS:-}" >> "$OUT/rows.jsonl"
    say "row $id: stopped — $verdict"
}

# ── the row loop ───────────────────────────────────────────────────────
run_rows() {
    local rows="$1" from="$2" go="" id class cap how pass checks ans
    [ -f "$rows" ] || die "no rows file $rows"
    need_device
    cp "$rows" "$OUT/rows.tsv"
    [ -z "$from" ] && go=1
    while IFS=$'\t' read -r id class cap how pass checks <&3; do
        case "$id" in ''|'#'*|id) continue ;; esac
        if [ -z "$go" ]; then
            [ "$id" = "$from" ] || continue
            go=1
        fi
        ROW_CLASS="$class"; ROW_CHECKS="$checks"; CAP="${cap:-15}"
        say ""; say "── $id ($class) ─ $how"; say "   pass: $pass"
        case "$class" in
            X) read -r -p "   not reachable on every build — run it? [y/N] " ans
               [ "$ans" = y ] || { mkdir -p "$OUT/rows/$id"; record_stop "$id" n "not run (unreachable on this build)"; continue; } ;;
        esac
        if [ "${CAP}" = 0 ]; then
            mkdir -p "$OUT/rows/$id"
            if [ "$class" = A ]; then record_stop "$id" n "machine read"; else record_stop "$id" "" ""; fi
            continue
        fi
        read -r -p "   ⏎ START " ans
        record_start "$id" 0
        read -r -p "   ⏎ STOP " ans
        record_stop "$id" "" ""
    done 3< "$rows"
    say ""; say "run complete: $OUT/rows.jsonl"
}

# ── pull ───────────────────────────────────────────────────────────────
SCHEMAS="os-log os-signpost-interval sysmon-process device-thermal-state-intervals process-info"
pull() {
    need_device
    local dir id schema toc rel name
    for dir in "$OUT"/rows/*/; do
        dir="${dir%/}"; id="$(basename "$dir")"
        if [ -d "$dir/row.trace" ]; then
            mkdir -p "$dir/tables"
            toc="$(xt export --input "$dir/row.trace" --toc 2>/dev/null)"
            for schema in $SCHEMAS; do
                printf '%s' "$toc" | /usr/bin/grep -q "schema=\"$schema\"" || continue
                xt export --input "$dir/row.trace" --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema\"]" \
                    --output "$dir/tables/$schema.xml" > /dev/null 2>&1
            done
            if ls "$dir"/tables/*.xml > /dev/null 2>&1; then
                $PY "$HERE/xctrace_facts.py" --process "$PROCESS" --out "$dir/trace-facts.json" "$dir"/tables/*.xml
            else say "  row $id: the trace exported no known table"; fi
        fi
        if [ -f "$dir/container-stop.json" ]; then
            $PY "$HERE/container_facts.py" summary "$dir/container-stop.json" --out "$dir/container-summary.json"
            [ -f "$dir/container-start.json" ] && $PY "$HERE/container_facts.py" diff "$dir/container-start.json" "$dir/container-stop.json" --out "$dir/container-diff.json"
        fi
        if [ -f "$dir/crashes-start.json" ] && [ -f "$dir/crashes-stop.json" ]; then
            $PY "$HERE/container_facts.py" diff "$dir/crashes-start.json" "$dir/crashes-stop.json" --out "$dir/crash-diff.json"
            mkdir -p "$dir/ips"
            for rel in $(pyjson "$dir/crash-diff.json" "' '.join(p for p in d['added'] if p.endswith('.ips'))" | tr -d '"'); do
                name="$(basename "$rel")"
                [ -f "$dir/ips/$name" ] || dc "$dir/ips/$name.copy.json" device copy from --device "$UUID" \
                    --domain-type systemCrashLogs --source "$rel" --destination "$dir/ips/$name"
            done
            $PY "$HERE/crash_facts.py" --process "$PROCESS" --bundle-id "$BUNDLE_ID" --out "$dir/crash-facts.json" "$dir/ips"
        fi
        $PY -c 'import json,os,sys
d=sys.argv[1]; out={"row":os.path.basename(d)}
for k,f in (("trace","trace-facts.json"),("container","container-summary.json"),("container_diff","container-diff.json"),("crashes","crash-facts.json")):
    p=os.path.join(d,f)
    if os.path.exists(p): out[k]=json.load(open(p))
t=os.path.join(d,"row.trace")
if os.path.isdir(t): out["trace_bytes"]=sum(os.path.getsize(os.path.join(r,n)) for r,_,ns in os.walk(t) for n in ns)
json.dump(out,open(os.path.join(d,"facts.json"),"w"),indent=1)' "$dir"
        say "pulled $id"
    done
}

# ── state: argument-domain defaults for the next launch ────────────────
state() {
    local mode="$1" value
    case "$mode" in
        secure) value=secureRasterization ;;
        searchable) value=searchableRedaction ;;
        *) die "state --mode secure|searchable" ;;
    esac
    need_device
    mkdir -p "$OUT/state"
    LAUNCH_ARGS="-pipelineMode.v2 $value" launch_app "$OUT/state"
    say "Check Settings → Default Mode reads ${mode}. If it does not, set it there by hand (the launch default does not persist)."
}

# ── probe: does the combined recording start; trace size per minute ────
probe() {
    need_device
    local dir="$OUT/probe"
    mkdir -p "$dir"
    rm -rf "$dir/p1.trace"
    xt record --device "$UDID" --template 'Activity Monitor' --instrument os_log --instrument os_signpost \
        --instrument 'Thermal State' --all-processes --time-limit 5s --output "$dir/p1.trace" --no-prompt > "$dir/p1.log" 2>&1
    if /usr/bin/grep -q 'Output file saved' "$dir/p1.log"; then say "P1 combined recording: accepted"
    else say "P1 combined recording: refused — $(/usr/bin/grep -v '^ *0x' "$dir/p1.log" | tail -2 | tr '\n' ' ')"; fi
    $PY -c 'import json,os,sys
out=sys.argv[1]; rows=[json.loads(l) for l in open(os.path.join(out,"rows.jsonl"))] if os.path.exists(os.path.join(out,"rows.jsonl")) else []
from datetime import datetime
for r in rows:
    t=os.path.join(out,"rows",r["row"],"row.trace")
    if not os.path.isdir(t): continue
    b=sum(os.path.getsize(os.path.join(a,n)) for a,_,ns in os.walk(t) for n in ns)
    f="%Y-%m-%dT%H:%M:%S%z"; s=(datetime.strptime(r["t1"],f)-datetime.strptime(r["t0"],f)).total_seconds() or 1
    print("P9 row %s: %.1f MB over %.0f s = %.1f MB/min" % (r["row"], b/1e6, s, b/1e6*60/s))' "$OUT"
}

self_test() {
    local rc=0 f
    for f in xctrace_facts crash_facts container_facts judge_pdf fill_record; do
        $PY "$HERE/$f.py" --self-test "$@" | tail -1
        [ "${PIPESTATUS[0]}" -eq 0 ] || rc=1
    done
    bash -n "$0" && say "sitting.sh syntax: PASS" || rc=1
    return $rc
}

# ── dispatch ───────────────────────────────────────────────────────────
VERB="${1:-}"; [ $# -gt 0 ] && shift
case "$VERB" in -h|--help) VERB=help ;; esac
SUB=""; case "$VERB" in record) case "${1:-}" in start|stop) SUB="$1"; shift ;; esac ;; esac
POS=(); ROWS=""; FROM=""; INBOX=""; SINCE=""; TERMS=""; TERMS_FILE=""; TEMPLATE=""; RECORD_OUT=""
VERDICT=""; NOTE=""; MODE=""; LAUNCH=0; PASS_THROUGH=()
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --device) DEVICE_SEL="$2"; shift 2 ;;
        --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
        --process) PROCESS="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --rows) ROWS="$2"; shift 2 ;;
        --from) FROM="$2"; shift 2 ;;
        --cap) CAP="$2"; shift 2 ;;
        --launch) LAUNCH=1; shift ;;
        --verdict) VERDICT="$2"; shift 2 ;;
        --note) NOTE="$2"; shift 2 ;;
        --inbox) INBOX="$2"; shift 2 ;;
        --since) SINCE="$2"; shift 2 ;;
        --terms) TERMS="$2"; shift 2 ;;
        --terms-file) TERMS_FILE="$2"; shift 2 ;;
        --template) TEMPLATE="$2"; shift 2 ;;
        --record-out) RECORD_OUT="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --samples|--expect) PASS_THROUGH+=("$1" "$2"); shift 2 ;;
        -h|--help) VERB=help; shift ;;
        *) POS+=("$1"); shift ;;
    esac
done

case "$VERB:$SUB" in
    preflight:) preflight ;;
    record:start) [ ${#POS[@]} -eq 1 ] || die "record start ROW-ID"; ROW_CLASS=""; record_start "${POS[0]}" "$LAUNCH" ;;
    record:stop) [ ${#POS[@]} -eq 1 ] || die "record stop ROW-ID"; record_stop "${POS[0]}" "$VERDICT" "$NOTE" ;;
    run:) [ -n "$ROWS" ] || die "run --rows FILE.tsv"; run_rows "$ROWS" "$FROM" ;;
    pull:) pull ;;
    judge:)
        [ -n "$INBOX" ] || die "judge --inbox DIR"
        set -- --inbox "$INBOX" --out "$OUT/judge.json"
        [ -n "$SINCE" ] && set -- "$@" --since "$SINCE"
        [ -n "$TERMS" ] && set -- "$@" --terms "$TERMS"
        [ -n "$TERMS_FILE" ] && set -- "$@" --terms-file "$TERMS_FILE"
        $PY "$HERE/judge_pdf.py" "$@" ;;
    record:)
        [ -n "$TEMPLATE" ] || die "record --template FILE.md (or record start|stop ROW-ID)"
        $PY "$HERE/fill_record.py" --template "$TEMPLATE" --run "$OUT" --out "${RECORD_OUT:-$OUT/record.md}" ;;
    state:) state "$MODE" ;;
    probe:) probe ;;
    self-test:) self_test ${PASS_THROUGH[@]+"${PASS_THROUGH[@]}"} ;;
    help:|:) sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//; /^set -u/d' ;;
    *) die "unknown verb '$VERB' (see --help)" ;;
esac
