#!/usr/bin/env bash
set -u

MODE="${1:-unknown}"

TS=$(date +%Y%m%d_%H%M%S)
TEST_NAME="ospf_ecmp_silent_gold_${MODE}"
RUN_DIR="measurement/runs/${TS}_${TEST_NAME}"
SUMMARY_DIR="measurement/summaries"

mkdir -p "$RUN_DIR" "$SUMMARY_DIR"

META="$RUN_DIR/metadata.env"
BFD_LOG="$RUN_DIR/bfd_state_samples.log"
BIRD_ROUTE_LOG="$RUN_DIR/bird_route_samples.log"
ROUTEGET_LOG="$RUN_DIR/route_get_samples.log"
KERNEL_LOG="$RUN_DIR/kernel_route_events.log"
TRAFFIC_LOG="$RUN_DIR/traffic_ping.log"
TCPDUMP_LOG="$RUN_DIR/tcpdump_ospf_bfd.log"
BIRD_EVENT_LOG="$RUN_DIR/bird_event_debug.log"
SUMMARY="$RUN_DIR/summary.txt"
CSV="$RUN_DIR/parsed_timeline.csv"
GLOBAL_CSV="$SUMMARY_DIR/ospf_ecmp_silent_gold_summary.csv"

FAIL_ROUTER="hpe-r3"
OBS_ROUTER="hpe-r3"

TARGET_NET="10.0.24.0/24"
TARGET_IP="10.0.24.2"

# For silent ECMP branch testing, using router-originated probe is cleaner.
# It ensures the probe follows the same route-get decision we are measuring.
TRAFFIC_SRC="hpe-r3"
TRAFFIC_DST="$TARGET_IP"

PING_INTERVAL="0.02"
SAMPLE_INTERVAL="0.05"

NH1="10.0.23.2"
NH2="10.0.34.3"

SILENT_HOLD_SECONDS=20
POST_RESTORE_WAIT_SECONDS=10

MONITOR_PIDS=()

now_ms() {
    date +%s%3N
}

iface_for_ip() {
    local router="$1"
    local ip="$2"
    docker exec "$router" sh -lc "ip -o -4 addr show | awk -v ip='$ip' '\$4 ~ ip\"/\" {print \$2; exit}'" 2>/dev/null || true
}

clear_tc() {
    local router="$1"
    local iface="$2"

    if [ -n "$iface" ]; then
        docker exec "$router" sh -lc "tc qdisc del dev '$iface' root 2>/dev/null || true" >/dev/null 2>&1 || true
    fi
}

apply_drop() {
    local router="$1"
    local iface="$2"

    docker exec "$router" sh -lc "tc qdisc del dev '$iface' root 2>/dev/null || true"
    docker exec "$router" sh -lc "tc qdisc add dev '$iface' root netem loss 100%"
}

cleanup() {
    echo
    echo "[cleanup] Removing silent-drop qdisc and stopping monitors..."

    if [ -n "${FAIL_IFACE:-}" ]; then
        clear_tc "$FAIL_ROUTER" "$FAIL_IFACE"
    fi

    if [ -n "${PEER_ROUTER:-}" ] && [ -n "${PEER_IFACE:-}" ]; then
        clear_tc "$PEER_ROUTER" "$PEER_IFACE"
    fi

    docker exec "$TRAFFIC_SRC" pkill -INT ping >/dev/null 2>&1 || true
    docker exec "$OBS_ROUTER" pkill -INT tcpdump >/dev/null 2>&1 || true
    docker exec "$OBS_ROUTER" birdc debug ospf1 off >/dev/null 2>&1 || true

    BFD_PROTO="$(docker exec "$OBS_ROUTER" birdc show protocols 2>/dev/null | awk '$2=="BFD"{print $1; exit}')"
    if [ -n "${BFD_PROTO:-}" ]; then
        docker exec "$OBS_ROUTER" birdc debug "$BFD_PROTO" off >/dev/null 2>&1 || true
    fi

    for pid in "${MONITOR_PIDS[@]:-}"; do
        kill "$pid" >/dev/null 2>&1 || true
    done

    sleep 5
}

trap cleanup EXIT

echo "============================================================"
echo "GOLD OSPF ECMP SILENT FAILURE MEASUREMENT"
echo "Mode: $MODE"
echo "Timestamp: $TS"
echo "Run directory: $RUN_DIR"
echo "============================================================"

echo
echo "1. Precheck tools"
echo "------------------------------------------------------------"

for r in hpe-r2 hpe-r3 hpe-r4; do
    if docker exec "$r" sh -lc "command -v tc" >/dev/null 2>&1; then
        echo "[OK] tc exists in $r"
    else
        echo "ERROR: tc command missing inside $r"
        echo "Install iproute2 inside the container or rebuild image."
        exit 1
    fi
done

echo
echo "2. Clear any old silent-drop qdisc"
echo "------------------------------------------------------------"

R3_NH1_IFACE="$(iface_for_ip hpe-r3 10.0.23.3)"
R3_NH2_IFACE="$(iface_for_ip hpe-r3 10.0.34.2)"
R2_PEER_IFACE="$(iface_for_ip hpe-r2 10.0.23.2)"
R4_PEER_IFACE="$(iface_for_ip hpe-r4 10.0.34.3)"

clear_tc hpe-r3 "$R3_NH1_IFACE"
clear_tc hpe-r3 "$R3_NH2_IFACE"
clear_tc hpe-r2 "$R2_PEER_IFACE"
clear_tc hpe-r4 "$R4_PEER_IFACE"

sleep 10

echo
echo "3. Baseline ECMP check"
echo "------------------------------------------------------------"

BIRD_ROUTE="$(docker exec "$OBS_ROUTER" birdc show route "$TARGET_NET" all 2>&1 || true)"
KERNEL_ROUTE="$(docker exec "$OBS_ROUTER" ip route show "$TARGET_NET" 2>&1 || true)"
ROUTE_GET="$(docker exec "$OBS_ROUTER" ip route get "$TARGET_IP" 2>&1 || true)"
BFD_SESSIONS="$(docker exec "$OBS_ROUTER" birdc show bfd sessions 2>&1 || true)"

echo "BIRD route:"
echo "$BIRD_ROUTE"
echo
echo "Kernel route:"
echo "$KERNEL_ROUTE"
echo
echo "Route-get:"
echo "$ROUTE_GET"
echo
echo "BFD sessions:"
echo "$BFD_SESSIONS" | grep -E "$NH1|$NH2" || true

if ! echo "$BIRD_ROUTE" | grep -q "$NH1"; then
    echo "ERROR: ECMP next-hop $NH1 missing from BIRD route."
    exit 1
fi

if ! echo "$BIRD_ROUTE" | grep -q "$NH2"; then
    echo "ERROR: ECMP next-hop $NH2 missing from BIRD route."
    exit 1
fi

if ! echo "$KERNEL_ROUTE" | grep -q "$NH1"; then
    echo "ERROR: ECMP next-hop $NH1 missing from kernel route."
    exit 1
fi

if ! echo "$KERNEL_ROUTE" | grep -q "$NH2"; then
    echo "ERROR: ECMP next-hop $NH2 missing from kernel route."
    exit 1
fi

FAILED_NH="$(echo "$ROUTE_GET" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' | head -1)"
FAIL_IFACE="$(echo "$ROUTE_GET" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)"

if [ "$FAILED_NH" = "$NH1" ]; then
    SURVIVOR_NH="$NH2"
    PEER_ROUTER="hpe-r2"
    PEER_IP="$NH1"
elif [ "$FAILED_NH" = "$NH2" ]; then
    SURVIVOR_NH="$NH1"
    PEER_ROUTER="hpe-r4"
    PEER_IP="$NH2"
else
    echo "ERROR: route-get selected unexpected next-hop: $FAILED_NH"
    exit 1
fi

PEER_IFACE="$(iface_for_ip "$PEER_ROUTER" "$PEER_IP")"

if [ -z "$FAIL_IFACE" ]; then
    echo "ERROR: Could not detect fail interface from route-get."
    exit 1
fi

if [ -z "$PEER_IFACE" ]; then
    echo "ERROR: Could not detect peer interface on $PEER_ROUTER for $PEER_IP."
    exit 1
fi

BFD_PRESENT="no"
if echo "$BFD_SESSIONS" | grep "$FAILED_NH" | grep -q "Up"; then
    BFD_PRESENT="yes"
fi

echo
echo "[OK] ECMP baseline is valid."
echo "Selected next-hop for target: $FAILED_NH"
echo "Failed local interface: $FAIL_IFACE on $FAIL_ROUTER"
echo "Peer router/interface: $PEER_ROUTER $PEER_IFACE"
echo "Surviving next-hop: $SURVIVOR_NH"
echo "BFD session present before failure: $BFD_PRESENT"

echo
echo "Baseline traffic probe from $TRAFFIC_SRC:"
docker exec "$TRAFFIC_SRC" ping -c 5 -W 1 "$TRAFFIC_DST" || true

cat > "$META" <<METAEOF
timestamp=$TS
test_name=$TEST_NAME
mode=$MODE
failure_type=silent_tc_netem_loss_100
fail_router=$FAIL_ROUTER
observer_router=$OBS_ROUTER
peer_router=$PEER_ROUTER
peer_iface=$PEER_IFACE
target_net=$TARGET_NET
target_ip=$TARGET_IP
failed_next_hop=$FAILED_NH
survivor_next_hop=$SURVIVOR_NH
fail_iface=$FAIL_IFACE
traffic_src=$TRAFFIC_SRC
traffic_dst=$TRAFFIC_DST
bfd_present=$BFD_PRESENT
sample_interval_s=$SAMPLE_INTERVAL
ping_interval_s=$PING_INTERVAL
silent_hold_seconds=$SILENT_HOLD_SECONDS
post_restore_wait_seconds=$POST_RESTORE_WAIT_SECONDS
METAEOF

echo
echo "4. Starting monitors"
echo "------------------------------------------------------------"

docker exec "$OBS_ROUTER" sh -lc ": > /tmp/bird-gold.log 2>/dev/null || true" >/dev/null 2>&1 || true
docker exec "$OBS_ROUTER" birdc debug ospf1 all >/dev/null 2>&1 || true

BFD_PROTO="$(docker exec "$OBS_ROUTER" birdc show protocols 2>/dev/null | awk '$2=="BFD"{print $1; exit}')"
if [ -n "${BFD_PROTO:-}" ]; then
    docker exec "$OBS_ROUTER" birdc debug "$BFD_PROTO" all >/dev/null 2>&1 || true
    echo "bfd_protocol=$BFD_PROTO" >> "$META"
else
    echo "bfd_protocol=NA" >> "$META"
fi

(
    docker exec "$OBS_ROUTER" sh -lc "tail -n 0 -F /tmp/bird-gold.log" 2>/dev/null | while read -r line; do
        echo "$(date +%s%3N)|${line}"
    done
) > "$BIRD_EVENT_LOG" 2>&1 &
MONITOR_PIDS+=("$!")

(
    while true; do
        TS_MS=$(now_ms)
        OUT="$(docker exec "$OBS_ROUTER" birdc show bfd sessions 2>/dev/null | grep "$FAILED_NH" || true)"

        if echo "$OUT" | grep -q "Up"; then
            STATE="Up"
        elif [ -n "$OUT" ]; then
            STATE="DownOrOther"
        else
            STATE="Missing"
        fi

        echo "${TS_MS}|state=${STATE}|${OUT}"
        sleep "$SAMPLE_INTERVAL"
    done
) > "$BFD_LOG" 2>&1 &
MONITOR_PIDS+=("$!")

(
    while true; do
        TS_MS=$(now_ms)
        OUT="$(docker exec "$OBS_ROUTER" birdc show route "$TARGET_NET" all 2>&1 || true)"
        ONE="$(echo "$OUT" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"

        if echo "$OUT" | grep -q "$FAILED_NH" && echo "$OUT" | grep -q "$SURVIVOR_NH"; then
            STATE="ecmp_both"
        elif echo "$OUT" | grep -q "$SURVIVOR_NH" && ! echo "$OUT" | grep -q "$FAILED_NH"; then
            STATE="survivor_only"
        elif echo "$OUT" | grep -qi "Network not found"; then
            STATE="missing"
        else
            STATE="other"
        fi

        echo "${TS_MS}|state=${STATE}|${ONE}"
        sleep "$SAMPLE_INTERVAL"
    done
) > "$BIRD_ROUTE_LOG" 2>&1 &
MONITOR_PIDS+=("$!")

(
    while true; do
        TS_MS=$(now_ms)
        OUT="$(docker exec "$OBS_ROUTER" ip route get "$TARGET_IP" 2>&1 || true)"
        ONE="$(echo "$OUT" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"

        if echo "$OUT" | grep -q "$FAILED_NH"; then
            STATE="failed_nh"
        elif echo "$OUT" | grep -q "$SURVIVOR_NH"; then
            STATE="survivor_nh"
        elif echo "$OUT" | grep -qi "unreachable\\|Network is unreachable\\|No route"; then
            STATE="missing"
        else
            STATE="other"
        fi

        echo "${TS_MS}|state=${STATE}|${ONE}"
        sleep "$SAMPLE_INTERVAL"
    done
) > "$ROUTEGET_LOG" 2>&1 &
MONITOR_PIDS+=("$!")

(
    docker exec "$OBS_ROUTER" sh -lc "ip monitor route" 2>/dev/null | while read -r line; do
        echo "$(date +%s%3N)|${line}"
    done
) > "$KERNEL_LOG" 2>&1 &
MONITOR_PIDS+=("$!")

(
    docker exec "$OBS_ROUTER" sh -lc "tcpdump -i any -ttttt -n -l 'proto ospf or udp port 3784'" 2>&1
) > "$TCPDUMP_LOG" &
MONITOR_PIDS+=("$!")

(
    docker exec "$TRAFFIC_SRC" ping -D -i "$PING_INTERVAL" "$TRAFFIC_DST" 2>&1
) > "$TRAFFIC_LOG" &
MONITOR_PIDS+=("$!")

sleep 2

echo
echo "5. Triggering SILENT ECMP branch failure"
echo "------------------------------------------------------------"
echo "This keeps interfaces UP but drops packets using tc/netem."

T0_MS="$(now_ms)"
echo "T0 silent failure trigger: $T0_MS"
echo "t0_ms=$T0_MS" >> "$META"

apply_drop "$FAIL_ROUTER" "$FAIL_IFACE"
apply_drop "$PEER_ROUTER" "$PEER_IFACE"

echo "Silent drop applied on:"
echo "- $FAIL_ROUTER $FAIL_IFACE"
echo "- $PEER_ROUTER $PEER_IFACE"

echo
echo "Holding silent failure for $SILENT_HOLD_SECONDS seconds..."
sleep "$SILENT_HOLD_SECONDS"

echo
echo "6. Restoring silent failure"
echo "------------------------------------------------------------"

RESTORE_MS="$(now_ms)"
echo "restore_ms=$RESTORE_MS" >> "$META"
echo "Restore time: $RESTORE_MS"

clear_tc "$FAIL_ROUTER" "$FAIL_IFACE"
clear_tc "$PEER_ROUTER" "$PEER_IFACE"

sleep "$POST_RESTORE_WAIT_SECONDS"

echo
echo "7. Stopping monitors"
echo "------------------------------------------------------------"

docker exec "$TRAFFIC_SRC" pkill -INT ping >/dev/null 2>&1 || true
docker exec "$OBS_ROUTER" pkill -INT tcpdump >/dev/null 2>&1 || true
docker exec "$OBS_ROUTER" birdc debug ospf1 off >/dev/null 2>&1 || true

if [ -n "${BFD_PROTO:-}" ]; then
    docker exec "$OBS_ROUTER" birdc debug "$BFD_PROTO" off >/dev/null 2>&1 || true
fi

sleep 1

for pid in "${MONITOR_PIDS[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
done

trap - EXIT

echo
echo "8. Parsing"
echo "------------------------------------------------------------"

python3 - "$RUN_DIR" "$META" "$BFD_LOG" "$BIRD_ROUTE_LOG" "$ROUTEGET_LOG" "$KERNEL_LOG" "$TRAFFIC_LOG" "$TCPDUMP_LOG" "$BIRD_EVENT_LOG" "$CSV" "$SUMMARY" "$GLOBAL_CSV" <<'PY'
import sys
import re
from pathlib import Path

(
    run_dir,
    meta_path,
    bfd_log,
    bird_route_log,
    routeget_log,
    kernel_log,
    traffic_log,
    tcpdump_log,
    bird_event_log,
    csv_path,
    summary_path,
    global_csv_path,
) = map(Path, sys.argv[1:])

meta = {}
for line in meta_path.read_text(errors="ignore").splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        meta[k.strip()] = v.strip()

def i(v):
    try:
        return int(v)
    except Exception:
        return None

t0 = i(meta.get("t0_ms"))
failed_nh = meta.get("failed_next_hop", "")
survivor_nh = meta.get("survivor_next_hop", "")
target_net = meta.get("target_net", "")
target_ip = meta.get("target_ip", "")
ts = meta.get("timestamp", "unknown")
test_name = meta.get("test_name", "unknown")
mode = meta.get("mode", "unknown")
bfd_present = meta.get("bfd_present", "unknown")

def rel(ms):
    if ms is None or t0 is None:
        return "NA"
    return str(ms - t0)

def parse_state_log(path):
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text(errors="ignore").splitlines():
        parts = line.split("|", 2)
        if len(parts) < 2:
            continue
        try:
            ts_ms = int(parts[0])
        except Exception:
            continue
        m = re.search(r"state=([^|]+)", parts[1])
        state = m.group(1) if m else "unknown"
        body = parts[2] if len(parts) > 2 else ""
        rows.append((ts_ms, state, body, line))
    return rows

def first_after(rows, pred):
    for ts_ms, state, body, line in rows:
        if t0 is not None and ts_ms < t0:
            continue
        if pred(ts_ms, state, body, line):
            return ts_ms, line
    return None, ""

bfd_rows = parse_state_log(bfd_log)
bird_rows = parse_state_log(bird_route_log)
rget_rows = parse_state_log(routeget_log)

bfd_down_ms, bfd_down_line = first_after(
    bfd_rows,
    lambda ts, st, body, line: st != "Up"
)

bird_survivor_ms, bird_survivor_line = first_after(
    bird_rows,
    lambda ts, st, body, line: st == "survivor_only"
)

routeget_switch_ms, routeget_switch_line = first_after(
    rget_rows,
    lambda ts, st, body, line: st == "survivor_nh"
)

routeget_still_failed_end = "unknown"
if rget_rows:
    after = [x for x in rget_rows if t0 is None or x[0] >= t0]
    if after:
        routeget_still_failed_end = after[-1][1]

kernel_event_ms = None
kernel_event_line = ""
if kernel_log.exists():
    for line in kernel_log.read_text(errors="ignore").splitlines():
        if "|" not in line:
            continue
        try:
            ts_ms = int(line.split("|", 1)[0])
        except Exception:
            continue
        body = line.split("|", 1)[1]
        if t0 is not None and ts_ms < t0:
            continue
        if target_net in body or survivor_nh in body or failed_nh in body or "proto bird" in body:
            kernel_event_ms = ts_ms
            kernel_event_line = line
            break

# ping -D parse
txt = traffic_log.read_text(errors="ignore") if traffic_log.exists() else ""

replies = []
for m in re.finditer(r"^\[(\d+(?:\.\d+)?)\].*icmp_seq=(\d+)", txt, re.M):
    sec = float(m.group(1))
    seq = int(m.group(2))
    replies.append((seq, int(sec * 1000)))
replies.sort()

tx = rx = lost = None
loss_percent = "NA"

sm = re.search(r"(\d+)\s+packets transmitted,\s+(\d+)\s+(?:packets )?received.*?(\d+(?:\.\d+)?)%\s+packet loss", txt, re.S)
if sm:
    tx = int(sm.group(1))
    rx = int(sm.group(2))
    loss_percent = sm.group(3)
    lost = tx - rx

first_loss_ms = None
traffic_recovery_ms = None
missing_sequences = []

if replies:
    interval_ms = int(float(meta.get("ping_interval_s", "0.02")) * 1000)
    for (prev_seq, prev_ts), (cur_seq, cur_ts) in zip(replies, replies[1:]):
        if cur_seq > prev_seq + 1:
            missing_sequences = list(range(prev_seq + 1, cur_seq))
            first_loss_ms = prev_ts + interval_ms
            traffic_recovery_ms = cur_ts
            break

traffic_outage_ms = None
if first_loss_ms is not None and traffic_recovery_ms is not None:
    traffic_outage_ms = traffic_recovery_ms - first_loss_ms

tcp = tcpdump_log.read_text(errors="ignore") if tcpdump_log.exists() else ""
ospf_packet_lines = sum(1 for line in tcp.splitlines() if "OSPF" in line or "proto OSPF" in line)
bfd_packet_lines = sum(1 for line in tcp.splitlines() if "3784" in line or "BFD" in line)

bird_event_count = 0
first_bird_event = "NA"
if bird_event_log.exists():
    for line in bird_event_log.read_text(errors="ignore").splitlines():
        if "|" not in line:
            continue
        try:
            ts_ms = int(line.split("|", 1)[0])
        except Exception:
            continue
        if t0 is not None and ts_ms >= t0:
            bird_event_count += 1
            if first_bird_event == "NA":
                first_bird_event = line[:250]

header = [
    "timestamp","test_name","mode","failure_type","t0_ms","bfd_present",
    "bfd_detect_ms","kernel_event_ms","route_get_switch_ms",
    "bird_route_survivor_only_ms","routeget_final_state",
    "first_loss_ms","traffic_recovery_ms","traffic_outage_ms",
    "traffic_tx","traffic_rx","traffic_lost","traffic_loss_percent",
    "ospf_packet_lines","bfd_packet_lines","bird_event_lines_after_t0",
    "failed_next_hop","survivor_next_hop"
]

row = [
    ts,test_name,mode,meta.get("failure_type","unknown"),str(t0),bfd_present,
    rel(bfd_down_ms),rel(kernel_event_ms),rel(routeget_switch_ms),
    rel(bird_survivor_ms),routeget_still_failed_end,
    rel(first_loss_ms),rel(traffic_recovery_ms),
    str(traffic_outage_ms) if traffic_outage_ms is not None else "NA",
    str(tx) if tx is not None else "NA",
    str(rx) if rx is not None else "NA",
    str(lost) if lost is not None else "NA",
    loss_percent,
    str(ospf_packet_lines),str(bfd_packet_lines),str(bird_event_count),
    failed_nh,survivor_nh
]

csv_path.write_text(",".join(header) + "\n" + ",".join(row) + "\n")

if not global_csv_path.exists():
    global_csv_path.write_text(",".join(header) + "\n")
with global_csv_path.open("a") as f:
    f.write(",".join(row) + "\n")

summary = []
summary.append("============================================================")
summary.append("GOLD OSPF ECMP SILENT FAILURE SUMMARY")
summary.append("============================================================")
summary.append(f"Run directory: {run_dir}")
summary.append(f"Timestamp: {ts}")
summary.append(f"Mode: {mode}")
summary.append("")
summary.append(f"T0 silent failure trigger: {t0}")
summary.append(f"Failed next-hop: {failed_nh}")
summary.append(f"Survivor next-hop: {survivor_nh}")
summary.append(f"BFD session present before failure: {bfd_present}")
summary.append("")
summary.append("Timeline relative to T0:")
summary.append(f"- BFD state down/missing observed: {rel(bfd_down_ms)} ms")
summary.append(f"- Kernel route event observed: {rel(kernel_event_ms)} ms")
summary.append(f"- ip route get switched to survivor: {rel(routeget_switch_ms)} ms")
summary.append(f"- BIRD route became survivor-only: {rel(bird_survivor_ms)} ms")
summary.append(f"- route-get final state: {routeget_still_failed_end}")
summary.append(f"- First estimated packet loss: {rel(first_loss_ms)} ms")
summary.append(f"- Traffic recovery after loss: {rel(traffic_recovery_ms)} ms")
summary.append(f"- Estimated traffic outage duration: {traffic_outage_ms if traffic_outage_ms is not None else 'NA'} ms")
summary.append("")
summary.append("Traffic:")
summary.append(f"- Ping transmitted: {tx if tx is not None else 'NA'}")
summary.append(f"- Ping received: {rx if rx is not None else 'NA'}")
summary.append(f"- Packet loss percent: {loss_percent}%")
summary.append(f"- Missing ping sequence sample: {missing_sequences[:30] if missing_sequences else 'none detected'}")
summary.append("")
summary.append("Packet capture:")
summary.append(f"- OSPF packet evidence lines: {ospf_packet_lines}")
summary.append(f"- BFD packet evidence lines: {bfd_packet_lines}")
summary.append("")
summary.append("BIRD event/debug log:")
summary.append(f"- BIRD event lines after T0: {bird_event_count}")
summary.append(f"- First BIRD event after T0: {first_bird_event}")
summary.append("")
summary.append("Important evidence lines:")
summary.append(f"- BFD line: {bfd_down_line[:250] if bfd_down_line else 'NA'}")
summary.append(f"- Kernel event line: {kernel_event_line[:250] if kernel_event_line else 'NA'}")
summary.append(f"- route-get switch line: {routeget_switch_line[:250] if routeget_switch_line else 'NA'}")
summary.append(f"- BIRD survivor-only line: {bird_survivor_line[:250] if bird_survivor_line else 'NA'}")
summary.append("")
summary.append(f"CSV saved to: {csv_path}")
summary.append(f"Global CSV updated at: {global_csv_path}")
summary.append("============================================================")

summary_path.write_text("\n".join(summary) + "\n")
print("\n".join(summary))
PY

echo
echo "Done."
echo "Run directory: $RUN_DIR"
echo "Summary: $SUMMARY"
