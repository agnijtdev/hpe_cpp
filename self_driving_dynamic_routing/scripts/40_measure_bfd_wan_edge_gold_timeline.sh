#!/usr/bin/env bash
set -u

# ============================================================
# GOLD-STANDARD BFD WAN EDGE FAILURE MEASUREMENT
#
# Measures:
# - T0 exact link failure trigger
# - BFD session down time
# - BGP protocol reaction time
# - BIRD route change time
# - Linux forwarding decision change time
# - Kernel route event time
# - Data-plane traffic outage and packet loss
# - tcpdump evidence for BFD and BGP packets
# - BIRD event/debug logs
# ============================================================

TS=$(date +%Y%m%d_%H%M%S)

TEST_NAME="bfd_wan_edge_failure_gold_timeline"
RUN_DIR="measurement/runs/${TS}_${TEST_NAME}"
SUMMARY_DIR="measurement/summaries"

mkdir -p "$RUN_DIR" "$SUMMARY_DIR"

META="$RUN_DIR/metadata.env"
BFD_LOG="$RUN_DIR/bfd_state_samples.log"
BGP_LOG="$RUN_DIR/bgp_state_samples.log"
BIRD_ROUTE_LOG="$RUN_DIR/bird_route_samples.log"
ROUTEGET_LOG="$RUN_DIR/route_get_samples.log"
KERNEL_LOG="$RUN_DIR/kernel_route_events.log"
TRAFFIC_LOG="$RUN_DIR/traffic_probe.log"
TCPDUMP_LOG="$RUN_DIR/tcpdump_bfd_bgp.log"
BIRD_EVENT_LOG="$RUN_DIR/bird_event_debug.log"
SUMMARY="$RUN_DIR/summary.txt"
CSV="$RUN_DIR/parsed_timeline.csv"
GLOBAL_CSV="$SUMMARY_DIR/bfd_wan_gold_summary.csv"

# ------------------------------------------------------------
# Experiment-specific settings
# ------------------------------------------------------------
FAIL_ROUTER="hpe-r2"
OBS_ROUTER="hpe-r2"

# r2 -> r9 WAN/BGP edge link.
FAIL_IFACE="eth2"
EXPECTED_DIRECT_NH="10.0.29.3"

TARGET_IP="10.0.93.2"
TARGET_PREFIX="10.0.93.0/24"

BGP_PROTOCOL="r9"
TRAFFIC_SRC="hpe-r2"
TRAFFIC_DST="$TARGET_IP"

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

    docker exec "$TRAFFIC_SRC" pkill -INT fping >/dev/null 2>&1 || true
    docker exec "$TRAFFIC_SRC" pkill -INT ping >/dev/null 2>&1 || true
    docker exec "$OBS_ROUTER" pkill -INT tcpdump >/dev/null 2>&1 || true

    docker exec "$OBS_ROUTER" birdc debug "$BGP_PROTOCOL" off >/dev/null 2>&1 || true

    BFD_PROTO="$(docker exec "$OBS_ROUTER" birdc show protocols 2>/dev/null | awk '$2=="BFD"{print $1; exit}')"
    if [ -n "${BFD_PROTO:-}" ]; then
        docker exec "$OBS_ROUTER" birdc debug "$BFD_PROTO" off >/dev/null 2>&1 || true
    fi

    for pid in "${MONITOR_PIDS[@]:-}"; do
        kill "$pid" >/dev/null 2>&1 || true
    done

    sleep 3
}

trap cleanup EXIT

echo "============================================================"
echo "GOLD BFD WAN EDGE FAILURE MEASUREMENT"
echo "Timestamp: $TS"
echo "Run directory: $RUN_DIR"
echo "============================================================"

echo
echo "1. Precheck: restore interface and enable expected protocols"
echo "------------------------------------------------------------"

docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" up >/dev/null 2>&1 || true

# Best-effort re-enable common BGP protocols that older tests may have disabled.
docker exec hpe-r2 birdc enable r9 >/dev/null 2>&1 || true
docker exec hpe-r2 birdc enable r1 >/dev/null 2>&1 || true
docker exec hpe-r1 birdc enable r2 >/dev/null 2>&1 || true
docker exec hpe-r1 birdc enable r9 >/dev/null 2>&1 || true
docker exec hpe-r9 birdc enable r2 >/dev/null 2>&1 || true
docker exec hpe-r9 birdc enable r1 >/dev/null 2>&1 || true

sleep 10

echo
echo "Current route-get on $OBS_ROUTER:"
PRE_ROUTEGET="$(docker exec "$OBS_ROUTER" ip route get "$TARGET_IP" 2>&1 || true)"
echo "$PRE_ROUTEGET"

OLD_NH="$(echo "$PRE_ROUTEGET" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' | head -1)"
ACTIVE_DEV="$(echo "$PRE_ROUTEGET" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)"

if [ -z "$OLD_NH" ]; then
    echo "ERROR: Could not detect old next-hop."
    exit 1
fi

echo
echo "Detected active next-hop: $OLD_NH"
echo "Detected active device: $ACTIVE_DEV"

if [ "$OLD_NH" != "$EXPECTED_DIRECT_NH" ] || [ "$ACTIVE_DEV" != "$FAIL_IFACE" ]; then
    echo
    echo "ERROR: The target route is not currently using the expected r2-r9 WAN edge."
    echo "Expected next-hop: $EXPECTED_DIRECT_NH via $FAIL_IFACE"
    echo "Actual route:"
    echo "$PRE_ROUTEGET"
    echo
    echo "This test would be invalid if we continue."
    echo "Run final validation, wait, and try again."
    exit 1
fi

echo "[OK] Target route is using expected BFD/BGP WAN edge."

echo
echo "Current BFD session on $OBS_ROUTER:"
docker exec "$OBS_ROUTER" birdc show bfd sessions || true

BFD_LINE="$(docker exec "$OBS_ROUTER" birdc show bfd sessions 2>/dev/null | grep "$OLD_NH" || true)"

if echo "$BFD_LINE" | grep -q "Up"; then
    echo "[OK] BFD session to $OLD_NH is Up."
else
    echo
    echo "ERROR: BFD session to $OLD_NH is not Up."
    echo "BFD line:"
    echo "$BFD_LINE"
    exit 1
fi

echo
echo "Current BGP protocol state:"
docker exec "$OBS_ROUTER" birdc show protocols "$BGP_PROTOCOL" || true

if docker exec "$OBS_ROUTER" birdc show protocols "$BGP_PROTOCOL" 2>/dev/null | grep -q "Established"; then
    echo "[OK] BGP protocol $BGP_PROTOCOL is Established."
else
    echo
    echo "ERROR: BGP protocol $BGP_PROTOCOL is not Established."
    exit 1
fi

echo
echo "Baseline traffic probe:"
docker exec "$TRAFFIC_SRC" ping -c 3 "$TRAFFIC_DST" || true

cat > "$META" <<METAEOF
timestamp=$TS
test_name=$TEST_NAME
fail_router=$FAIL_ROUTER
fail_iface=$FAIL_IFACE
observer_router=$OBS_ROUTER
target_ip=$TARGET_IP
target_prefix=$TARGET_PREFIX
old_next_hop=$OLD_NH
expected_direct_next_hop=$EXPECTED_DIRECT_NH
bgp_protocol=$BGP_PROTOCOL
traffic_src=$TRAFFIC_SRC
traffic_dst=$TRAFFIC_DST
sample_interval_s=$SAMPLE_INTERVAL
ping_interval_s=$PING_INTERVAL
METAEOF

echo
echo "2. Starting monitors"
echo "------------------------------------------------------------"

# BIRD event/debug log monitor
BFD_PROTO="$(docker exec "$OBS_ROUTER" birdc show protocols 2>/dev/null | awk '$2=="BFD"{print $1; exit}')"

docker exec "$OBS_ROUTER" sh -lc ": > /tmp/bird-gold.log 2>/dev/null || true" >/dev/null 2>&1 || true
docker exec "$OBS_ROUTER" birdc debug "$BGP_PROTOCOL" all >/dev/null 2>&1 || true

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

# BFD state sampler
(
    while true; do
        TS_MS=$(now_ms)
        OUT="$(docker exec "$OBS_ROUTER" birdc show bfd sessions 2>/dev/null | grep "$OLD_NH" || true)"

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

# BGP protocol state sampler
(
    while true; do
        TS_MS=$(now_ms)
        OUT="$(docker exec "$OBS_ROUTER" birdc show protocols "$BGP_PROTOCOL" 2>&1 || true)"
        ONE_LINE="$(echo "$OUT" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"

        if echo "$OUT" | grep -q "Established"; then
            STATE="Established"
        else
            STATE="NotEstablished"
        fi

        echo "${TS_MS}|state=${STATE}|${ONE_LINE}"
        sleep "$SAMPLE_INTERVAL"
    done
) > "$BGP_LOG" 2>&1 &
MONITOR_PIDS+=("$!")

# BIRD route sampler
(
    while true; do
        TS_MS=$(now_ms)
        OUT="$(docker exec "$OBS_ROUTER" birdc show route "$TARGET_PREFIX" all 2>&1 || true)"
        ONE_LINE="$(echo "$OUT" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"

        if echo "$OUT" | grep -q "$OLD_NH"; then
            STATE="old"
        elif echo "$OUT" | grep -qi "Network not found"; then
            STATE="missing"
        else
            STATE="alternate_or_changed"
        fi

        echo "${TS_MS}|state=${STATE}|${ONE_LINE}"
        sleep "$SAMPLE_INTERVAL"
    done
) > "$BIRD_ROUTE_LOG" 2>&1 &
MONITOR_PIDS+=("$!")

# ip route get sampler
(
    while true; do
        TS_MS=$(now_ms)
        OUT="$(docker exec "$OBS_ROUTER" ip route get "$TARGET_IP" 2>&1 || true)"
        ONE_LINE="$(echo "$OUT" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"

        if echo "$OUT" | grep -q "$OLD_NH"; then
            STATE="old"
        elif echo "$OUT" | grep -qi "unreachable\\|Network is unreachable\\|No route"; then
            STATE="missing"
        else
            STATE="alternate_or_changed"
        fi

        echo "${TS_MS}|state=${STATE}|${ONE_LINE}"
        sleep "$SAMPLE_INTERVAL"
    done
) > "$ROUTEGET_LOG" 2>&1 &
MONITOR_PIDS+=("$!")

# Kernel route monitor
(
    docker exec "$OBS_ROUTER" sh -lc "ip monitor route" 2>/dev/null | while read -r line; do
        echo "$(date +%s%3N)|${line}"
    done
) > "$KERNEL_LOG" 2>&1 &
MONITOR_PIDS+=("$!")

# Packet capture for BFD and BGP
(
    docker exec "$OBS_ROUTER" sh -lc "tcpdump -i any -ttttt -n -l 'udp port 3784 or tcp port 179'" 2>&1
) > "$TCPDUMP_LOG" &
MONITOR_PIDS+=("$!")

# Traffic probe: fping if present, else ping -D
if docker exec "$TRAFFIC_SRC" sh -lc "command -v fping" >/dev/null 2>&1; then
    echo "traffic_tool=fping" >> "$META"
    (
        docker exec "$TRAFFIC_SRC" sh -lc "fping -D -p 20 -l '$TRAFFIC_DST'" 2>&1
    ) > "$TRAFFIC_LOG" &
else
    echo "traffic_tool=ping_D" >> "$META"
    (
        docker exec "$TRAFFIC_SRC" ping -D -i "$PING_INTERVAL" "$TRAFFIC_DST" 2>&1
    ) > "$TRAFFIC_LOG" &
fi
MONITOR_PIDS+=("$!")

echo "Monitors started."
sleep 2

echo
echo "3. Triggering WAN edge failure"
echo "------------------------------------------------------------"

T0_MS="$(docker exec "$FAIL_ROUTER" sh -lc "date +%s%3N; ip link set '$FAIL_IFACE' down" | head -1 | tr -d '\r')"

echo "T0 failure trigger ms: $T0_MS"
echo "t0_ms=$T0_MS" >> "$META"

echo
echo "Failure command executed:"
echo "docker exec $FAIL_ROUTER ip link set $FAIL_IFACE down"

echo
echo "4. Waiting during failure"
echo "------------------------------------------------------------"
sleep 8

echo
echo "5. Restoring WAN edge interface"
echo "------------------------------------------------------------"

RESTORE_MS="$(docker exec "$FAIL_ROUTER" sh -lc "date +%s%3N; ip link set '$FAIL_IFACE' up" | head -1 | tr -d '\r')"
echo "Restore time ms: $RESTORE_MS"
echo "restore_ms=$RESTORE_MS" >> "$META"

sleep 20

echo
echo "6. Stopping monitors"
echo "------------------------------------------------------------"

docker exec "$TRAFFIC_SRC" pkill -INT fping >/dev/null 2>&1 || true
docker exec "$TRAFFIC_SRC" pkill -INT ping >/dev/null 2>&1 || true
docker exec "$OBS_ROUTER" pkill -INT tcpdump >/dev/null 2>&1 || true

docker exec "$OBS_ROUTER" birdc debug "$BGP_PROTOCOL" off >/dev/null 2>&1 || true
if [ -n "${BFD_PROTO:-}" ]; then
    docker exec "$OBS_ROUTER" birdc debug "$BFD_PROTO" off >/dev/null 2>&1 || true
fi

sleep 1

for pid in "${MONITOR_PIDS[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
done

trap - EXIT

echo
echo "7. Parsing measurement logs"
echo "------------------------------------------------------------"

python3 - "$RUN_DIR" "$META" "$BFD_LOG" "$BGP_LOG" "$BIRD_ROUTE_LOG" "$ROUTEGET_LOG" "$KERNEL_LOG" "$TRAFFIC_LOG" "$TCPDUMP_LOG" "$BIRD_EVENT_LOG" "$CSV" "$SUMMARY" "$GLOBAL_CSV" <<'PY'
import sys
import re
from pathlib import Path

(
    run_dir,
    meta_path,
    bfd_log,
    bgp_log,
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

def as_int(v, default=None):
    try:
        return int(v)
    except Exception:
        return default

t0 = as_int(meta.get("t0_ms"))
old_nh = meta.get("old_next_hop", "")
target_prefix = meta.get("target_prefix", "")
target_ip = meta.get("target_ip", "")
ts = meta.get("timestamp", "unknown")
test_name = meta.get("test_name", "unknown")
traffic_tool = meta.get("traffic_tool", "unknown")

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

def first_after(rows, predicate):
    for ts_ms, state, body, line in rows:
        if t0 is not None and ts_ms < t0:
            continue
        if predicate(ts_ms, state, body, line):
            return ts_ms, line
    return None, ""

bfd_rows = parse_state_log(bfd_log)
bgp_rows = parse_state_log(bgp_log)
bird_rows = parse_state_log(bird_route_log)
routeget_rows = parse_state_log(routeget_log)

bfd_down_ms, bfd_down_line = first_after(
    bfd_rows,
    lambda ts_ms, state, body, line: state != "Up"
)

bgp_not_est_ms, bgp_not_est_line = first_after(
    bgp_rows,
    lambda ts_ms, state, body, line: state != "Established"
)

bgp_re_est_ms, bgp_re_est_line = first_after(
    bgp_rows,
    lambda ts_ms, state, body, line: state == "Established" and ts_ms > (bgp_not_est_ms or 10**30)
)

bird_changed_ms, bird_changed_line = first_after(
    bird_rows,
    lambda ts_ms, state, body, line: state == "alternate_or_changed"
)

bird_missing_ms, bird_missing_line = first_after(
    bird_rows,
    lambda ts_ms, state, body, line: state == "missing"
)

routeget_changed_ms, routeget_changed_line = first_after(
    routeget_rows,
    lambda ts_ms, state, body, line: state == "alternate_or_changed"
)

routeget_missing_ms, routeget_missing_line = first_after(
    routeget_rows,
    lambda ts_ms, state, body, line: state == "missing"
)

# Kernel event parsing
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
        if old_nh in body or target_prefix in body or "proto bird" in body:
            kernel_event_ms = ts_ms
            kernel_event_line = line
            break

# Traffic parsing: supports ping -D and fping -D
traffic_text = traffic_log.read_text(errors="ignore") if traffic_log.exists() else ""

tx = rx = lost = None
loss_percent = "NA"
first_loss_ms = None
traffic_recovery_ms = None
missing_sequences = []

# fping format with timeout lines
fping_rows = []
fping_re = re.compile(r"^\[(\d+(?:\.\d+)?)\].*?\[(\d+)\].*$", re.M)

for m in fping_re.finditer(traffic_text):
    sec = float(m.group(1))
    seq = int(m.group(2))
    line_start = m.start()
    line_end = traffic_text.find("\n", line_start)
    if line_end == -1:
        line_end = len(traffic_text)
    line = traffic_text[line_start:line_end]
    ts_ms = int(sec * 1000)
    is_loss = "timed out" in line.lower()
    fping_rows.append((seq, ts_ms, is_loss, line))

if fping_rows:
    fping_rows.sort()
    tx = len(fping_rows)
    lost = sum(1 for _, _, is_loss, _ in fping_rows if is_loss)
    rx = tx - lost
    loss_percent = f"{(lost / tx * 100):.5f}" if tx else "NA"

    seen_loss = False
    for seq, ts_ms, is_loss, line in fping_rows:
        if t0 is not None and ts_ms < t0:
            continue
        if is_loss and not seen_loss:
            first_loss_ms = ts_ms
            seen_loss = True
            missing_sequences.append(seq)
        elif is_loss and seen_loss:
            missing_sequences.append(seq)
        elif (not is_loss) and seen_loss:
            traffic_recovery_ms = ts_ms
            break
else:
    # ping -D format
    ping_reply_re = re.compile(r"^\[(\d+(?:\.\d+)?)\].*icmp_seq=(\d+)", re.M)
    replies = []
    for m in ping_reply_re.finditer(traffic_text):
        sec = float(m.group(1))
        seq = int(m.group(2))
        replies.append((seq, int(sec * 1000)))
    replies.sort()

    sm = re.search(r"(\d+)\s+packets transmitted,\s+(\d+)\s+(?:packets )?received.*?(\d+(?:\.\d+)?)%\s+packet loss", traffic_text, re.S)
    if sm:
        tx = int(sm.group(1))
        rx = int(sm.group(2))
        loss_percent = sm.group(3)
        lost = tx - rx

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

# tcpdump counts
tcp_text = tcpdump_log.read_text(errors="ignore") if tcpdump_log.exists() else ""
bfd_packet_lines = sum(1 for line in tcp_text.splitlines() if "3784" in line or "BFD" in line)
bgp_packet_lines = sum(1 for line in tcp_text.splitlines() if ".179" in line or "BGP" in line)

# BIRD event log count after T0 using host-side timestamp.
bird_event_count = 0
first_bird_event_line = "NA"
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
            if first_bird_event_line == "NA":
                first_bird_event_line = line[:250]

header = [
    "timestamp",
    "test_name",
    "t0_ms",
    "bfd_detect_ms",
    "bgp_non_established_ms",
    "bgp_reestablished_ms",
    "bird_route_changed_ms",
    "bird_route_missing_ms",
    "route_get_changed_ms",
    "route_get_missing_ms",
    "kernel_event_ms",
    "first_loss_ms",
    "traffic_recovery_ms",
    "traffic_outage_ms",
    "traffic_tool",
    "traffic_tx",
    "traffic_rx",
    "traffic_lost",
    "traffic_loss_percent",
    "bfd_packet_lines",
    "bgp_packet_lines",
    "bird_event_lines_after_t0",
    "old_next_hop",
]

row = [
    ts,
    test_name,
    str(t0) if t0 is not None else "NA",
    rel(bfd_down_ms),
    rel(bgp_not_est_ms),
    rel(bgp_re_est_ms),
    rel(bird_changed_ms),
    rel(bird_missing_ms),
    rel(routeget_changed_ms),
    rel(routeget_missing_ms),
    rel(kernel_event_ms),
    rel(first_loss_ms),
    rel(traffic_recovery_ms),
    str(traffic_outage_ms) if traffic_outage_ms is not None else "NA",
    traffic_tool,
    str(tx) if tx is not None else "NA",
    str(rx) if rx is not None else "NA",
    str(lost) if lost is not None else "NA",
    loss_percent,
    str(bfd_packet_lines),
    str(bgp_packet_lines),
    str(bird_event_count),
    old_nh,
]

csv_path.write_text(",".join(header) + "\n" + ",".join(row) + "\n")

if not global_csv_path.exists():
    global_csv_path.write_text(",".join(header) + "\n")
with global_csv_path.open("a") as f:
    f.write(",".join(row) + "\n")

summary = []
summary.append("============================================================")
summary.append("GOLD BFD WAN EDGE FAILURE MEASUREMENT SUMMARY")
summary.append("============================================================")
summary.append(f"Run directory: {run_dir}")
summary.append(f"Timestamp: {ts}")
summary.append("")
summary.append(f"T0 failure trigger: {t0}")
summary.append("")
summary.append("Timeline relative to T0:")
summary.append(f"- BFD session down observed: {rel(bfd_down_ms)} ms")
summary.append(f"- BGP non-established observed: {rel(bgp_not_est_ms)} ms")
summary.append(f"- BGP re-established observed: {rel(bgp_re_est_ms)} ms")
summary.append(f"- BIRD route changed to alternate/missing path: {rel(bird_changed_ms)} ms")
summary.append(f"- BIRD route missing observed: {rel(bird_missing_ms)} ms")
summary.append(f"- ip route get changed to alternate path: {rel(routeget_changed_ms)} ms")
summary.append(f"- ip route get missing/unreachable observed: {rel(routeget_missing_ms)} ms")
summary.append(f"- Kernel route event observed: {rel(kernel_event_ms)} ms")
summary.append(f"- First traffic loss observed/estimated: {rel(first_loss_ms)} ms")
summary.append(f"- Traffic recovery after loss: {rel(traffic_recovery_ms)} ms")
summary.append(f"- Estimated traffic outage duration: {traffic_outage_ms if traffic_outage_ms is not None else 'NA'} ms")
summary.append("")
summary.append("Traffic:")
summary.append(f"- Tool: {traffic_tool}")
summary.append(f"- Transmitted: {tx if tx is not None else 'NA'}")
summary.append(f"- Received: {rx if rx is not None else 'NA'}")
summary.append(f"- Lost: {lost if lost is not None else 'NA'}")
summary.append(f"- Loss percent: {loss_percent}%")
summary.append(f"- Missing/lost sequence sample: {missing_sequences[:30] if missing_sequences else 'none detected'}")
summary.append("")
summary.append("Packet capture:")
summary.append(f"- BFD packet evidence lines: {bfd_packet_lines}")
summary.append(f"- BGP packet evidence lines: {bgp_packet_lines}")
summary.append("")
summary.append("BIRD event/debug log:")
summary.append(f"- BIRD event lines after T0: {bird_event_count}")
summary.append(f"- First BIRD event after T0: {first_bird_event_line}")
summary.append("")
summary.append("Important evidence lines:")
summary.append(f"- BFD line: {bfd_down_line[:250] if bfd_down_line else 'NA'}")
summary.append(f"- BGP line: {bgp_not_est_line[:250] if bgp_not_est_line else 'NA'}")
summary.append(f"- BIRD route changed line: {bird_changed_line[:250] if bird_changed_line else 'NA'}")
summary.append(f"- route-get changed line: {routeget_changed_line[:250] if routeget_changed_line else 'NA'}")
summary.append(f"- kernel event line: {kernel_event_line[:250] if kernel_event_line else 'NA'}")
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
