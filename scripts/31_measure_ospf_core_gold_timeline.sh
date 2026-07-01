#!/usr/bin/env bash
set -u

# ============================================================
# GOLD-STANDARD OSPF CORE LINK FAILURE MEASUREMENT
# Measures:
# - T0 failure trigger
# - BFD state change
# - BIRD route-table change
# - Linux kernel route events
# - ip route get next-hop change
# - OSPF/BFD packet evidence using tcpdump
# - data-plane packet loss using timestamped ping
# ============================================================

TS=$(date +%Y%m%d_%H%M%S)

TEST_NAME="ospf_core_failure_gold_timeline"
RUN_DIR="measurement/runs/${TS}_${TEST_NAME}"
SUMMARY_DIR="measurement/summaries"

mkdir -p "$RUN_DIR" "$SUMMARY_DIR"

META="$RUN_DIR/metadata.env"
BFD_LOG="$RUN_DIR/bfd_state_samples.log"
BIRD_LOG="$RUN_DIR/bird_route_samples.log"
ROUTEGET_LOG="$RUN_DIR/route_get_samples.log"
KERNEL_LOG="$RUN_DIR/kernel_route_events.log"
PROTO_LOG="$RUN_DIR/protocol_state_samples.log"
PING_LOG="$RUN_DIR/traffic_ping.log"
TCPDUMP_LOG="$RUN_DIR/tcpdump_ospf_bfd.log"
BIRD_EVENT_LOG="$RUN_DIR/bird_event_debug.log"
SUMMARY="$RUN_DIR/summary.txt"
CSV="$RUN_DIR/parsed_timeline.csv"
GLOBAL_CSV="$SUMMARY_DIR/convergence_gold_summary.csv"

# ------------------------------------------------------------
# Experiment-specific values
# ------------------------------------------------------------
FAIL_ROUTER="hpe-r3"
FAIL_IFACE="eth1"

OBS_ROUTER="hpe-r3"

TARGET_IP="10.0.82.2"
TARGET_PREFIX="10.0.82.0/24"

OLD_NH="10.0.34.3"
NEW_NH="10.0.23.2"

BFD_PEER="10.0.34.3"

TRAFFIC_SRC="hpe-h1"
TRAFFIC_DST="10.0.82.2"

SAMPLE_INTERVAL="0.05"
PING_INTERVAL="0.02"

MONITOR_PIDS=()

now_ms() {
    date +%s%3N
}

cleanup() {
    echo
    echo "[cleanup] Restoring failed interface and stopping monitors..."

    docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" up >/dev/null 2>&1 || true

    docker exec "$TRAFFIC_SRC" pkill -INT ping >/dev/null 2>&1 || true
    docker exec "$OBS_ROUTER" birdc debug ospf1 off >/dev/null 2>&1 || true
    docker exec "$OBS_ROUTER" pkill -INT tcpdump >/dev/null 2>&1 || true

    for pid in "${MONITOR_PIDS[@]:-}"; do
        kill "$pid" >/dev/null 2>&1 || true
    done

    sleep 3
}

trap cleanup EXIT

echo "============================================================"
echo "GOLD OSPF CORE LINK FAILURE MEASUREMENT"
echo "Timestamp: $TS"
echo "Run directory: $RUN_DIR"
echo "============================================================"

cat > "$META" <<METAEOF
timestamp=$TS
test_name=$TEST_NAME
fail_router=$FAIL_ROUTER
fail_iface=$FAIL_IFACE
observer_router=$OBS_ROUTER
target_ip=$TARGET_IP
target_prefix=$TARGET_PREFIX
old_next_hop=$OLD_NH
new_next_hop=$NEW_NH
bfd_peer=$BFD_PEER
traffic_src=$TRAFFIC_SRC
traffic_dst=$TRAFFIC_DST
sample_interval_s=$SAMPLE_INTERVAL
ping_interval_s=$PING_INTERVAL
METAEOF

echo
echo "1. Precheck: restore interface and wait for stable routing"
echo "------------------------------------------------------------"

docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" up >/dev/null 2>&1 || true
sleep 8

echo
echo "Current route-get on $OBS_ROUTER:"
docker exec "$OBS_ROUTER" ip route get "$TARGET_IP" || true

echo
echo "Current BIRD route on $OBS_ROUTER:"
docker exec "$OBS_ROUTER" birdc show route "$TARGET_PREFIX" all || true

echo
echo "Checking that expected OLD next-hop is currently active..."
PRE_ROUTEGET="$(docker exec "$OBS_ROUTER" ip route get "$TARGET_IP" 2>/dev/null || true)"
if echo "$PRE_ROUTEGET" | grep -q "$OLD_NH"; then
    echo "[OK] Precheck route uses expected old next-hop: $OLD_NH"
else
    echo "[WARN] Precheck route does not show old next-hop $OLD_NH"
    echo "Output was:"
    echo "$PRE_ROUTEGET"
    echo
    echo "This does not always mean failure, but the test may not measure the expected path switch."
fi

echo
echo "Baseline ping check:"
docker exec "$TRAFFIC_SRC" ping -c 3 "$TRAFFIC_DST" || true

echo
echo "2. Starting monitors"
echo "------------------------------------------------------------"

# BIRD event/debug log monitor.
# This gives protocol-level BIRD evidence in addition to route polling.
docker exec "$OBS_ROUTER" sh -lc ": > /tmp/bird-gold.log 2>/dev/null || true; birdc debug ospf1 all >/dev/null 2>&1 || true" >/dev/null 2>&1 || true

(
    docker exec "$OBS_ROUTER" sh -lc "tail -n 0 -F /tmp/bird-gold.log" 2>/dev/null | while read -r line; do
        echo "$(date +%s%3N)|${line}"
    done
) > "$BIRD_EVENT_LOG" 2>&1 &
MONITOR_PIDS+=("$!")

# BFD state sampler
(
    while true; do
        TS_MS=$(now_ms)
        OUT="$(docker exec "$OBS_ROUTER" birdc show bfd sessions 2>/dev/null | grep "$BFD_PEER" || true)"

        if echo "$OUT" | grep -q " Up "; then
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

# BIRD route sampler
(
    while true; do
        TS_MS=$(now_ms)
        OUT="$(docker exec "$OBS_ROUTER" birdc show route "$TARGET_PREFIX" all 2>&1 || true)"
        ONE_LINE="$(echo "$OUT" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"

        if echo "$OUT" | grep -q "$NEW_NH"; then
            STATE="new"
        elif echo "$OUT" | grep -q "$OLD_NH"; then
            STATE="old"
        elif echo "$OUT" | grep -qi "Network not found"; then
            STATE="missing"
        else
            STATE="other"
        fi

        echo "${TS_MS}|state=${STATE}|${ONE_LINE}"
        sleep "$SAMPLE_INTERVAL"
    done
) > "$BIRD_LOG" 2>&1 &
MONITOR_PIDS+=("$!")

# ip route get sampler
(
    while true; do
        TS_MS=$(now_ms)
        OUT="$(docker exec "$OBS_ROUTER" ip route get "$TARGET_IP" 2>&1 || true)"
        ONE_LINE="$(echo "$OUT" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"

        if echo "$OUT" | grep -q "$NEW_NH"; then
            STATE="new"
        elif echo "$OUT" | grep -q "$OLD_NH"; then
            STATE="old"
        elif echo "$OUT" | grep -qi "unreachable\\|Network is unreachable\\|No route"; then
            STATE="missing"
        else
            STATE="other"
        fi

        echo "${TS_MS}|state=${STATE}|${ONE_LINE}"
        sleep "$SAMPLE_INTERVAL"
    done
) > "$ROUTEGET_LOG" 2>&1 &
MONITOR_PIDS+=("$!")

# OSPF protocol state sampler
(
    while true; do
        TS_MS=$(now_ms)
        OUT="$(docker exec "$OBS_ROUTER" birdc show protocols ospf1 2>&1 || true)"
        ONE_LINE="$(echo "$OUT" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"

        if echo "$OUT" | grep -q "Running"; then
            STATE="Running"
        else
            STATE="NotRunningOrOther"
        fi

        echo "${TS_MS}|state=${STATE}|${ONE_LINE}"
        sleep "$SAMPLE_INTERVAL"
    done
) > "$PROTO_LOG" 2>&1 &
MONITOR_PIDS+=("$!")

# Event-based Linux kernel route monitor.
# We timestamp every event as it arrives on the host side.
(
    docker exec "$OBS_ROUTER" sh -lc "ip monitor route" 2>/dev/null | while read -r line; do
        echo "$(date +%s%3N)|${line}"
    done
) > "$KERNEL_LOG" 2>&1 &
MONITOR_PIDS+=("$!")

# Packet-level protocol evidence.
# This captures OSPF packets and BFD packets as text.
(
    docker exec "$OBS_ROUTER" sh -lc "tcpdump -i any -ttttt -n -l 'proto 89 or udp port 3784'" 2>&1
) > "$TCPDUMP_LOG" &
MONITOR_PIDS+=("$!")

# Data-plane traffic probe.
# Prefer fping -D if available inside the traffic container.
# Fallback to ping -D, which is also timestamped.
if docker exec "$TRAFFIC_SRC" sh -lc "command -v fping" >/dev/null 2>&1; then
    echo "traffic_tool=fping" >> "$META"
    (
        docker exec "$TRAFFIC_SRC" sh -lc "fping -D -p 20 -l '$TRAFFIC_DST'" 2>&1
    ) > "$PING_LOG" &
else
    echo "traffic_tool=ping_D" >> "$META"
    (
        docker exec "$TRAFFIC_SRC" ping -D -i "$PING_INTERVAL" "$TRAFFIC_DST" 2>&1
    ) > "$PING_LOG" &
fi

PING_PID="$!"
MONITOR_PIDS+=("$PING_PID")

echo "Monitors started."
sleep 2

echo
echo "3. Triggering failure"
echo "------------------------------------------------------------"

T0_MS="$(docker exec "$FAIL_ROUTER" sh -lc "date +%s%3N; ip link set '$FAIL_IFACE' down" | head -1 | tr -d '\r')"

echo "T0 failure trigger ms: $T0_MS"

cat >> "$META" <<METAEOF
t0_ms=$T0_MS
METAEOF

echo
echo "Failure command executed:"
echo "docker exec $FAIL_ROUTER ip link set $FAIL_IFACE down"

echo
echo "4. Letting the network reconverge"
echo "------------------------------------------------------------"
sleep 8

echo
echo "5. Restoring failed interface"
echo "------------------------------------------------------------"

RESTORE_MS="$(docker exec "$FAIL_ROUTER" sh -lc "date +%s%3N; ip link set '$FAIL_IFACE' up" | head -1 | tr -d '\r')"
echo "Restore time ms: $RESTORE_MS"

cat >> "$META" <<METAEOF
restore_ms=$RESTORE_MS
METAEOF

sleep 5

echo
echo "6. Stopping monitors"
echo "------------------------------------------------------------"

docker exec "$TRAFFIC_SRC" pkill -INT ping >/dev/null 2>&1 || true
docker exec "$OBS_ROUTER" birdc debug ospf1 off >/dev/null 2>&1 || true
docker exec "$OBS_ROUTER" pkill -INT tcpdump >/dev/null 2>&1 || true

sleep 1

for pid in "${MONITOR_PIDS[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
done

trap - EXIT

echo
echo "7. Parsing measurement logs"
echo "------------------------------------------------------------"

python3 - "$RUN_DIR" "$META" "$BFD_LOG" "$BIRD_LOG" "$ROUTEGET_LOG" "$KERNEL_LOG" "$PROTO_LOG" "$PING_LOG" "$TCPDUMP_LOG" "$CSV" "$SUMMARY" "$GLOBAL_CSV" <<'PY'
import sys
import re
from pathlib import Path

(
    run_dir,
    meta_path,
    bfd_log,
    bird_log,
    routeget_log,
    kernel_log,
    proto_log,
    ping_log,
    tcpdump_log,
    csv_path,
    summary_path,
    global_csv_path,
) = map(Path, sys.argv[1:])

meta = {}
for line in meta_path.read_text(errors="ignore").splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        meta[k.strip()] = v.strip()

def as_int(v, default=None):
    try:
        return int(v)
    except Exception:
        return default

t0 = as_int(meta.get("t0_ms"))
restore = as_int(meta.get("restore_ms"))

old_nh = meta.get("old_next_hop", "")
new_nh = meta.get("new_next_hop", "")
target_prefix = meta.get("target_prefix", "")
target_ip = meta.get("target_ip", "")
test_name = meta.get("test_name", "unknown")
ts = meta.get("timestamp", "unknown")

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
        state_part = parts[1]
        m = re.search(r"state=([^|]+)", state_part)
        state = m.group(1) if m else "unknown"
        body = parts[2] if len(parts) > 2 else ""
        rows.append((ts_ms, state, body, line))
    return rows

bfd_rows = parse_state_log(bfd_log)
bird_rows = parse_state_log(bird_log)
routeget_rows = parse_state_log(routeget_log)
proto_rows = parse_state_log(proto_log)

def first_after(rows, predicate):
    for ts_ms, state, body, line in rows:
        if t0 is not None and ts_ms < t0:
            continue
        if predicate(ts_ms, state, body, line):
            return ts_ms, line
    return None, ""

bfd_down_ms, bfd_down_line = first_after(
    bfd_rows,
    lambda ts_ms, state, body, line: state != "Up"
)

bird_new_ms, bird_new_line = first_after(
    bird_rows,
    lambda ts_ms, state, body, line: state == "new"
)

bird_missing_ms, bird_missing_line = first_after(
    bird_rows,
    lambda ts_ms, state, body, line: state == "missing"
)

routeget_new_ms, routeget_new_line = first_after(
    routeget_rows,
    lambda ts_ms, state, body, line: state == "new"
)

routeget_missing_ms, routeget_missing_line = first_after(
    routeget_rows,
    lambda ts_ms, state, body, line: state == "missing"
)

proto_not_running_ms, proto_not_running_line = first_after(
    proto_rows,
    lambda ts_ms, state, body, line: state != "Running"
)

# Kernel event monitor parsing
kernel_event_ms = None
kernel_event_line = ""
if kernel_log.exists():
    for line in kernel_log.read_text(errors="ignore").splitlines():
        if "|" not in line:
            continue
        p = line.split("|", 1)
        try:
            ts_ms = int(p[0])
        except Exception:
            continue
        body = p[1]
        if t0 is not None and ts_ms < t0:
            continue
        if target_prefix in body or new_nh in body or target_ip in body:
            kernel_event_ms = ts_ms
            kernel_event_line = line
            break

# Ping parsing
ping_text = ping_log.read_text(errors="ignore") if ping_log.exists() else ""
ping_reply_re = re.compile(r"^\[(\d+(?:\.\d+)?)\].*icmp_seq=(\d+)", re.M)

replies = []
for m in ping_reply_re.finditer(ping_text):
    sec = float(m.group(1))
    seq = int(m.group(2))
    replies.append((seq, int(sec * 1000)))

replies.sort()

tx = rx = loss_percent = "NA"
m = re.search(r"(\d+)\s+packets transmitted,\s+(\d+)\s+(?:packets )?received.*?(\d+(?:\.\d+)?)%\s+packet loss", ping_text, re.S)
if m:
    tx, rx, loss_percent = m.group(1), m.group(2), m.group(3)

first_loss_ms = None
traffic_recovery_ms = None
missing_sequences = []

if replies:
    for (prev_seq, prev_ts), (cur_seq, cur_ts) in zip(replies, replies[1:]):
        if cur_seq > prev_seq + 1:
            missing = list(range(prev_seq + 1, cur_seq))
            missing_sequences.extend(missing)
            # Approximate first loss time using expected ping interval.
            # This is an estimate because lost packets have no receive timestamp.
            interval_ms = int(float(meta.get("ping_interval_s", "0.05")) * 1000)
            first_loss_ms = prev_ts + interval_ms
            traffic_recovery_ms = cur_ts
            break

traffic_outage_ms = None
if first_loss_ms is not None and traffic_recovery_ms is not None:
    traffic_outage_ms = traffic_recovery_ms - first_loss_ms

bird_event_log = run_dir / "bird_event_debug.log"
bird_event_count = 0
first_bird_event_after_t0 = "NA"
if bird_event_log.exists():
    for line in bird_event_log.read_text(errors="ignore").splitlines():
        if "|" not in line:
            continue
        try:
            ts_part = int(line.split("|", 1)[0])
        except Exception:
            continue
        if t0 is not None and ts_part >= t0:
            bird_event_count += 1
            if first_bird_event_after_t0 == "NA":
                first_bird_event_after_t0 = line[:250]

tcpdump_packet_count = 0
if tcpdump_log.exists():
    tcpdump_packet_count = sum(
        1 for line in tcpdump_log.read_text(errors="ignore").splitlines()
        if "IP " in line or "OSPF" in line or "3784" in line
    )

header = [
    "timestamp",
    "test_name",
    "t0_ms",
    "bfd_detect_ms",
    "bird_new_route_ms",
    "bird_missing_ms",
    "kernel_event_ms",
    "route_get_new_ms",
    "route_get_missing_ms",
    "protocol_not_running_ms",
    "first_loss_ms",
    "traffic_recovery_ms",
    "traffic_outage_ms",
    "ping_tx",
    "ping_rx",
    "ping_loss_percent",
    "tcpdump_packet_lines",
    "old_next_hop",
    "new_next_hop",
]

row = [
    ts,
    test_name,
    str(t0) if t0 is not None else "NA",
    rel(bfd_down_ms),
    rel(bird_new_ms),
    rel(bird_missing_ms),
    rel(kernel_event_ms),
    rel(routeget_new_ms),
    rel(routeget_missing_ms),
    rel(proto_not_running_ms),
    rel(first_loss_ms),
    rel(traffic_recovery_ms),
    str(traffic_outage_ms) if traffic_outage_ms is not None else "NA",
    tx,
    rx,
    loss_percent,
    str(tcpdump_packet_count),
    old_nh,
    new_nh,
]

csv_path.write_text(",".join(header) + "\n" + ",".join(row) + "\n")

if not global_csv_path.exists():
    global_csv_path.write_text(",".join(header) + "\n")
with global_csv_path.open("a") as f:
    f.write(",".join(row) + "\n")

summary = []
summary.append("============================================================")
summary.append("GOLD OSPF CORE LINK FAILURE MEASUREMENT SUMMARY")
summary.append("============================================================")
summary.append(f"Run directory: {run_dir}")
summary.append(f"Timestamp: {ts}")
summary.append("")
summary.append(f"T0 failure trigger: {t0}")
summary.append("")
summary.append("Timeline relative to T0:")
summary.append(f"- BFD detection time: {rel(bfd_down_ms)} ms")
summary.append(f"- BIRD route changed to new next-hop: {rel(bird_new_ms)} ms")
summary.append(f"- BIRD route missing observed: {rel(bird_missing_ms)} ms")
summary.append(f"- Kernel route event observed: {rel(kernel_event_ms)} ms")
summary.append(f"- ip route get changed to new next-hop: {rel(routeget_new_ms)} ms")
summary.append(f"- ip route get missing/unreachable observed: {rel(routeget_missing_ms)} ms")
summary.append(f"- OSPF protocol non-running observed: {rel(proto_not_running_ms)} ms")
summary.append(f"- First estimated packet loss: {rel(first_loss_ms)} ms")
summary.append(f"- Traffic recovery after loss: {rel(traffic_recovery_ms)} ms")
summary.append(f"- Estimated traffic outage duration: {traffic_outage_ms if traffic_outage_ms is not None else 'NA'} ms")
summary.append("")
summary.append("Traffic:")
summary.append(f"- Ping transmitted: {tx}")
summary.append(f"- Ping received: {rx}")
summary.append(f"- Packet loss percent: {loss_percent}%")
summary.append(f"- Missing ping sequences sample: {missing_sequences[:20] if missing_sequences else 'none detected'}")
summary.append("")
summary.append("Packet capture:")
summary.append(f"- tcpdump evidence lines counted: {tcpdump_packet_count}")
summary.append("")
summary.append("BIRD event/debug log:")
summary.append(f"- BIRD event lines after T0: {bird_event_count}")
summary.append(f"- First BIRD event after T0: {first_bird_event_after_t0}")
summary.append("")
summary.append("Important evidence lines:")
summary.append(f"- BFD line: {bfd_down_line[:250] if bfd_down_line else 'NA'}")
summary.append(f"- BIRD new route line: {bird_new_line[:250] if bird_new_line else 'NA'}")
summary.append(f"- Kernel event line: {kernel_event_line[:250] if kernel_event_line else 'NA'}")
summary.append(f"- route-get new line: {routeget_new_line[:250] if routeget_new_line else 'NA'}")
summary.append("")
summary.append(f"CSV saved to: {csv_path}")
summary.append(f"Global CSV updated at: {global_csv_path}")
summary.append("============================================================")

summary_path.write_text("\n".join(summary) + "\n")
print("\n".join(summary))
PY

echo
echo "8. Saved files"
echo "------------------------------------------------------------"
echo "Run directory: $RUN_DIR"
echo "Summary: $SUMMARY"
echo "CSV: $CSV"
echo "Global CSV: $GLOBAL_CSV"
echo
echo "Done."
