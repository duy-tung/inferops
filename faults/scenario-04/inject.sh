#!/usr/bin/env bash
# Scenario 04 — slow client.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

OUT_DIR="${OUT_DIR:-$FAULTS_DIR/scenario-04/evidence/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

flog "== Scenario 04 — slow client — $(date -u --iso-8601=seconds) =="

flog "-- starting mock-faults (baseline ttft/itl) + gateway-faults (-stream-write-timeout=3s, tightened from the 30s release default) --"
start_mock mock-faults -ttft=20ms -itl=8ms -error-rate=0
start_gateway gateway-faults 8091 mock-faults -stream-write-timeout=3s
wait_ready "http://127.0.0.1:8091/readyz" 30

flog ""
flog "== Part A: a genuinely stalled raw-socket client (zero reads for 8s > 2.6x the 3s deadline) =="
flog "   Prompt 'count to a lot' is this repo's known deterministic seed=42 longer output"
flog "   (drain-test.sh's header comment: 242 tokens), so there is plenty of data for TCP"
flog "   backpressure to matter once the receive window (shrunk via SO_RCVBUF) fills."
python3 - "$OUT_DIR/part-a-stall.log" <<'PYEOF'
import socket, time, json, sys
logpath = sys.argv[1]
lines = []
def log(*a):
    s = " ".join(str(x) for x in a)
    print(s)
    lines.append(s)

req_body = json.dumps({
    "model": "mock-8b",
    "messages": [{"role": "user", "content": "count to a lot"}],
    "max_completion_tokens": 3000,
    "stream": True
}).encode()

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
s.connect(("127.0.0.1", 8091))
req = (b"POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:8091\r\n"
       b"Content-Type: application/json\r\nContent-Length: " + str(len(req_body)).encode() +
       b"\r\nConnection: close\r\n\r\n" + req_body)
s.sendall(req)
t0 = time.time()
s.settimeout(2)
first = b""
try:
    while b"\r\n\r\n" not in first:
        first += s.recv(1)
except socket.timeout:
    pass
log("headers received at t=", round(time.time() - t0, 2), "; status line:", first.split(b"\r\n")[0])

STALL_S = 8
WRITE_TIMEOUT_S = 3
log(f"stalling with ZERO reads for {STALL_S}s (gateway -stream-write-timeout={WRITE_TIMEOUT_S}s;"
    f" a working per-write deadline should have failed a blocked write well before this)")
time.sleep(STALL_S)

s.settimeout(1)
closed = False
try:
    chunk = s.recv(65536)
    log(f"first drain after the stall: {len(chunk)} bytes, EOF={chunk == b''}")
    if chunk == b"":
        closed = True
except (ConnectionResetError, BrokenPipeError) as e:
    log("connection was reset while stalled:", e)
    closed = True
except socket.timeout:
    log("recv timed out immediately after the stall (no data, no EOF, socket still nominally open)")

if not closed:
    log("draining further to see whether the stream resumes normal delivery (i.e. it was purely"
        " TCP-window-blocked and NEVER closed by the write-deadline, not that it had already"
        " finished before the stall began)")
    total = 0
    for i in range(6):
        try:
            chunk = s.recv(65536)
            total += len(chunk)
            if chunk == b"":
                log(f"read #{i}: EOF")
                break
            log(f"read #{i}: {len(chunk)} bytes (stream resumed normally)")
        except socket.timeout:
            log(f"read #{i}: timeout, no more buffered data")
            break
    log("additional bytes drained after resuming reads:", total)
    verdict = "DEVIATION: the stream was NOT closed by the write-deadline during the 8s stall -- it just sat blocked on TCP backpressure and resumed normal delivery the moment reads resumed."
else:
    verdict = "MATCHED: the stream was closed during/shortly after the stall, consistent with the write-deadline firing."
log("")
log("VERDICT:", verdict)
s.close()

with open(logpath, "w") as f:
    f.write("\n".join(lines) + "\n")
PYEOF

flog ""
flog "-- gateway-faults /metrics right after Part A (in-flight should be back to 0 once the socket above was closed by this script) --"
sleep 1
gw_metrics gateway-faults | grep -E '^inference_(requests_in_flight|requests_total)' | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "== Part B: inferbench slow-client workload (population-level corroboration) =="
RUN_DIR="$OUT_DIR/inferbench-run"
run_inferbench "$RUN_DIR" "$FAULTS_DIR/workloads/fault-slow-client.json" \
  "http://127.0.0.1:8091" "fs04-run" \
  "30% of clients read at 128 B/s; if the write-deadline worked as the contract describes their streams would close at ~3s; Part A already shows it does not for a genuinely stalled reader, so this population run's slow requests are expected to either finish slowly (bounded by their own total byte count) or run to inferbench's own 60s client-side request-timeout, never to a fast gateway-initiated close." \
  mock -- -model mock-8b -stream >/dev/null
flog "inferbench exit code: $?"

flog ""
flog "-- inferbench summary --"
tail -1 "$RUN_DIR/run.log" | tee -a "$OUT_DIR/transcript.log"

flog ""
flog "-- slow (wall > 2.5s) vs fast population, and how each ended --"
python3 -c "
import json, datetime
def parse(ts): return datetime.datetime.fromisoformat(ts.replace('Z','+00:00'))
slow, fast = [], []
for line in open('$RUN_DIR/events.jsonl'):
    e = json.loads(line)
    d = (parse(e['end_ts']) - parse(e['send_ts'])).total_seconds() if e.get('send_ts') and e.get('end_ts') else None
    row = (e['status'], e.get('error_class'), round(d,2) if d else d)
    (slow if (d is not None and d > 2.5) else fast).append(row)
print('slow (wall>2.5s):', len(slow))
for r in slow: print('  ', r)
print('fast (wall<=2.5s):', len(fast))
" | tee -a "$OUT_DIR/transcript.log"

sleep 1
AFTER_INFLIGHT=$(gw_metrics gateway-faults | grep '^inference_requests_in_flight')
flog ""
flog "-- inference_requests_in_flight after Part B settles: $AFTER_INFLIGHT --"

flog ""
flog "-- tearing down --"
stop_gateway gateway-faults
stop_mock mock-faults

flog ""
flog "Evidence directory: $OUT_DIR"
