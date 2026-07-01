#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-unknown}"
TS=$(date +%Y%m%d_%H%M%S)

mkdir -p evidence/area_healing_blackhole results/area_healing_blackhole

OUT="evidence/area_healing_blackhole/area_healing_blackhole_${MODE}_${TS}.txt"
PING_LOG="evidence/area_healing_blackhole/ping_${MODE}_${TS}.log"
ROUTEGET_LOG="evidence/area_healing_blackhole/route_get_${MODE}_${TS}.log"
KERNEL_LOG="evidence/area_healing_blackhole/kernel_route_${MODE}_${TS}.log"
BIRD_LOG="evidence/area_healing_blackhole/bird_route_${MODE}_${TS}.log"
BFD_LOG="evidence/area_healing_blackhole/bfd_state_${MODE}_${TS}.log"

CSV="results/area_healing_blackhole/area_healing_blackhole_${MODE}_${TS}.csv"
LATEST="results/area_healing_blackhole/area_healing_blackhole_${MODE}.csv"

R3_IF="eth3"
R4_IF="eth2"

TARGET_NET="10.0.82.0/24"
TARGET_IP="10.0.82.2"
PING_SRC="hpe-h1"

OLD_NH="10.0.34.3"
BFD_PEER="10.0.34.3"

MONITOR_MS=60000

cleanup() {
  docker exec hpe-r3 tc qdisc del dev "$R3_IF" root >/dev/null 2>&1 || true
  docker exec hpe-r4 tc qdisc del dev "$R4_IF" root >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup

{
echo "============================================================"
echo "OSPF AREA HEALING BLACKHOLE TEST"
echo "Mode: $MODE"
echo "Timestamp: $TS"
echo "============================================================"
echo
echo "Traffic: hpe-h1 Area 10 -> hpe-h2 Area 20"
echo "Target IP: $TARGET_IP"
echo "Target network: $TARGET_NET"
echo
echo "Silent blackhole link:"
echo "hpe-r3 $R3_IF <-> hpe-r4 $R4_IF"
echo
echo "Old next-hop: $OLD_NH"
echo

echo "============================================================"
echo "1. Precheck"
echo "============================================================"

echo
echo "---- hpe-r3 route to $TARGET_IP ----"
docker exec hpe-r3 ip route get "$TARGET_IP" || true

echo
echo "---- hpe-r3 BFD sessions ----"
docker exec hpe-r3 birdc show bfd sessions || true

echo
echo "---- hpe-r4 BFD sessions ----"
docker exec hpe-r4 birdc show bfd sessions || true

echo
echo "---- hpe-r3 OSPF neighbours ----"
docker exec hpe-r3 birdc show ospf neighbors || true

echo
echo "---- Baseline ping ----"
docker exec "$PING_SRC" ping -c 5 -W 1 "$TARGET_IP" || true

echo
echo "============================================================"
echo "2. Start monitoring"
echo "============================================================"

START_MS=$(date +%s%3N)

(
  END_MS=$((START_MS + MONITOR_MS))
  while [ "$(date +%s%3N)" -lt "$END_MS" ]; do
    NOW=$(date +%s%3N)
    REL=$((NOW - START_MS))
    LINE=$(docker exec hpe-r3 ip route get "$TARGET_IP" 2>&1 | head -1 || true)
    echo "$REL ms | $LINE"
    sleep 0.05
  done
) > "$ROUTEGET_LOG" &
ROUTEGET_PID=$!

(
  END_MS=$((START_MS + MONITOR_MS))
  while [ "$(date +%s%3N)" -lt "$END_MS" ]; do
    NOW=$(date +%s%3N)
    REL=$((NOW - START_MS))
    LINE=$(docker exec hpe-r3 ip route show "$TARGET_NET" 2>&1 | tr '\n' ' ' || true)
    echo "$REL ms | $LINE"
    sleep 0.05
  done
) > "$KERNEL_LOG" &
KERNEL_PID=$!

(
  END_MS=$((START_MS + MONITOR_MS))
  while [ "$(date +%s%3N)" -lt "$END_MS" ]; do
    NOW=$(date +%s%3N)
    REL=$((NOW - START_MS))
    LINE=$(docker exec hpe-r3 birdc show route "$TARGET_NET" all 2>&1 | grep -E "unicast|via|Network not found" | tr '\n' ' ' || true)
    echo "$REL ms | $LINE"
    sleep 0.1
  done
) > "$BIRD_LOG" &
BIRD_PID=$!

(
  END_MS=$((START_MS + MONITOR_MS))
  while [ "$(date +%s%3N)" -lt "$END_MS" ]; do
    NOW=$(date +%s%3N)
    REL=$((NOW - START_MS))
    LINE=$(docker exec hpe-r3 birdc show bfd sessions 2>/dev/null | awk -v p="$BFD_PEER" '$1 == p {print $0}' || true)
    if [ -z "$LINE" ]; then
      LINE="MISSING"
    fi
    echo "$REL ms | $LINE"
    sleep 0.03
  done
) > "$BFD_LOG" &
BFD_PID=$!

docker exec "$PING_SRC" ping -i 0.1 -c 600 -W 1 "$TARGET_IP" > "$PING_LOG" 2>&1 &
PING_PID=$!

sleep 1

echo
echo "============================================================"
echo "3. Inject silent blackhole"
echo "============================================================"

FAIL_MS=$(date +%s%3N)
FAIL_REL=$((FAIL_MS - START_MS))

echo "Failure time relative to monitor start: ${FAIL_REL} ms"
echo "Applying 100% packet loss using tc/netem"
echo "Command: tc qdisc add dev $R3_IF root netem loss 100%"
echo "Command: tc qdisc add dev $R4_IF root netem loss 100%"

docker exec hpe-r3 tc qdisc add dev "$R3_IF" root netem loss 100%
docker exec hpe-r4 tc qdisc add dev "$R4_IF" root netem loss 100%

echo "Waiting for monitoring to complete..."
wait "$ROUTEGET_PID" || true
wait "$KERNEL_PID" || true
wait "$BIRD_PID" || true
wait "$BFD_PID" || true
wait "$PING_PID" || true

echo
echo "============================================================"
echo "4. Remove blackhole"
echo "============================================================"
cleanup
sleep 15

echo
echo "============================================================"
echo "5. Final health check"
echo "============================================================"

docker exec hpe-r3 ip route get "$TARGET_IP" || true
docker exec hpe-r3 birdc show bfd sessions || true
docker exec hpe-r3 birdc show ospf neighbors || true
docker exec "$PING_SRC" ping -c 5 -W 1 "$TARGET_IP" || true

echo
echo "============================================================"
echo "6. Parse measurements"
echo "============================================================"

python3 - "$MODE" "$FAIL_REL" "$OLD_NH" "$ROUTEGET_LOG" "$KERNEL_LOG" "$BIRD_LOG" "$BFD_LOG" "$PING_LOG" "$CSV" "$LATEST" "$TS" <<'PY'
import re
import sys
from pathlib import Path

mode = sys.argv[1]
fail_rel = int(sys.argv[2])
old_nh = sys.argv[3]
routeget_log = Path(sys.argv[4])
kernel_log = Path(sys.argv[5])
bird_log = Path(sys.argv[6])
bfd_log = Path(sys.argv[7])
ping_log = Path(sys.argv[8])
csv = Path(sys.argv[9])
latest = Path(sys.argv[10])
ts = sys.argv[11]

def first_route_switch(log_path, require_route=True):
    for line in log_path.read_text(errors="ignore").splitlines():
        m = re.match(r"(\d+) ms \| (.*)", line)
        if not m:
            continue
        rel = int(m.group(1))
        body = m.group(2)

        if rel < fail_rel:
            continue
        if old_nh in body:
            continue
        if "Network is unreachable" in body:
            continue
        if require_route and "via" not in body:
            continue

        return str(rel - fail_rel), body.strip()
    return "NA", "NA"

def first_bfd_down(log_path):
    if mode == "no_bfd":
        return "ignored", "BFD disabled for no-BFD mode"

    for line in log_path.read_text(errors="ignore").splitlines():
        m = re.match(r"(\d+) ms \| (.*)", line)
        if not m:
            continue

        rel = int(m.group(1))
        body = m.group(2).strip()

        if rel < fail_rel:
            continue

        parts = body.split()
        state = parts[2] if len(parts) >= 3 else body

        if body == "MISSING" or state != "Up":
            return str(rel - fail_rel), body

    return "NA", "NA"

routeget_ms, routeget_line = first_route_switch(routeget_log)
kernel_ms, kernel_line = first_route_switch(kernel_log)
bird_ms, bird_line = first_route_switch(bird_log)
bfd_ms, bfd_line = first_bfd_down(bfd_log)

ping_text = ping_log.read_text(errors="ignore")
tx = rx = lost = loss = "NA"

m = re.search(r"(\d+) packets transmitted, (\d+) received,.*?(\d+(?:\.\d+)?)% packet loss", ping_text)
if m:
    tx = m.group(1)
    rx = m.group(2)
    loss = m.group(3)
    lost = str(int(tx) - int(rx))

rows = [
    "timestamp,mode,test_name,failed_link,old_next_hop,bfd_detect_ms,route_get_ms,kernel_route_ms,bird_route_ms,ping_tx,ping_rx,ping_lost,ping_loss_percent,bfd_first_line,route_get_first_line,kernel_first_line,bird_first_line",
    f'{ts},{mode},ospf_area_healing_blackhole,hpe-r3_eth3_to_hpe-r4_eth2,{old_nh},{bfd_ms},{routeget_ms},{kernel_ms},{bird_ms},{tx},{rx},{lost},{loss},"{bfd_line}","{routeget_line}","{kernel_line}","{bird_line}"'
]

csv.write_text("\n".join(rows) + "\n")
latest.write_text(csv.read_text())

print("Mode:", mode)
print("BFD detection time ms:", bfd_ms)
print("Route-get switch time ms:", routeget_ms)
print("Kernel route switch time ms:", kernel_ms)
print("BIRD route switch time ms:", bird_ms)
print("Ping transmitted:", tx)
print("Ping received:", rx)
print("Ping lost:", lost)
print("Ping loss percent:", loss)
print("CSV saved to:", csv)
PY

} | tee "$OUT"

echo
echo "Saved evidence to: $OUT"
echo "Saved CSV to: $CSV"
echo "Updated latest CSV at: $LATEST"
