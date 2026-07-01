#!/usr/bin/env bash
set -u

mkdir -p evidence/ospf_kernel_monitor
mkdir -p results/ospf

TS=$(date +%Y%m%d_%H%M%S)

OUT="evidence/ospf_kernel_monitor/kernel_monitor_ospf_failure_${TS}.txt"
KERNEL_MONITOR_LOG="evidence/ospf_kernel_monitor/kernel_route_monitor_${TS}.log"
ROUTE_SAMPLE_LOG="evidence/ospf_kernel_monitor/route_get_samples_${TS}.log"
BIRD_SAMPLE_LOG="evidence/ospf_kernel_monitor/bird_route_samples_${TS}.log"
PING_LOG="evidence/ospf_kernel_monitor/ping_timestamped_${TS}.log"
CSV_OUT="results/ospf/ospf_kernel_monitor_result_${TS}.csv"

FAIL_ROUTER="hpe-r3"
FAIL_IP="10.0.23.3"
OLD_NEXT_HOP="10.0.23.2"
NEW_NEXT_HOP="10.0.13.2"
TARGET_IP="10.0.93.2"

FAIL_IFACE=$(docker exec "$FAIL_ROUTER" ip -o -4 addr show | awk -v ip="${FAIL_IP}/24" '$4==ip {split($2,a,"@"); print a[1]; exit}')

if [ -z "$FAIL_IFACE" ]; then
  echo "Could not find interface on $FAIL_ROUTER with IP $FAIL_IP"
  exit 1
fi

restore_link() {
  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" up 2>/dev/null || true
}

trap restore_link EXIT

{
  echo "OSPF Failure Measurement Using Kernel Route Monitor"
  echo "Date: $(date)"
  echo
  echo "Fail router: $FAIL_ROUTER"
  echo "Fail interface: $FAIL_IFACE"
  echo "Fail interface IP: $FAIL_IP"
  echo "Old next-hop: $OLD_NEXT_HOP"
  echo "New/alternate next-hop: $NEW_NEXT_HOP"
  echo "Traffic target: $TARGET_IP"
  echo

  echo "============================================================"
  echo "1. Baseline before failure"
  echo "============================================================"

  echo
  echo "---- hpe-r3 route to hpe-h3 before failure ----"
  docker exec hpe-r3 ip route get "$TARGET_IP" || true

  echo
  echo "---- hpe-r3 BIRD default route before failure ----"
  docker exec hpe-r3 birdc show route 0.0.0.0/0 || true

  echo
  echo "---- hpe-r3 OSPF neighbours before failure ----"
  docker exec hpe-r3 birdc show ospf neighbors || true

  echo
  echo "---- Baseline ping hpe-h1 -> hpe-h3 ----"
  docker exec hpe-h1 ping -c 5 -W 1 "$TARGET_IP" || true

  echo
  echo "============================================================"
  echo "2. Start monitors"
  echo "============================================================"

  : > "$KERNEL_MONITOR_LOG"
  : > "$ROUTE_SAMPLE_LOG"
  : > "$BIRD_SAMPLE_LOG"
  : > "$PING_LOG"

  echo "Starting kernel route monitor..."
  timeout 20 docker exec "$FAIL_ROUTER" sh -lc '
    ip monitor route | while IFS= read -r line; do
      printf "%s %s\n" "$(date +%s%3N)" "$line"
    done
  ' > "$KERNEL_MONITOR_LOG" 2>&1 &
  KERNEL_MONITOR_PID=$!

  echo "Starting route-get sampler..."
  timeout 20 docker exec "$FAIL_ROUTER" sh -lc "
    for i in \$(seq 1 900); do
      printf '%s ' \"\$(date +%s%3N)\"
      ip route get $TARGET_IP 2>&1 | head -1
      sleep 0.02
    done
  " > "$ROUTE_SAMPLE_LOG" 2>&1 &
  ROUTE_SAMPLE_PID=$!

  echo "Starting BIRD route-table sampler..."
  timeout 20 docker exec "$FAIL_ROUTER" sh -lc '
    for i in $(seq 1 400); do
      printf "%s " "$(date +%s%3N)"
      birdc show route 0.0.0.0/0 2>&1 | awk "/via|Network not found/ {print; exit}"
      sleep 0.05
    done
  ' > "$BIRD_SAMPLE_LOG" 2>&1 &
  BIRD_SAMPLE_PID=$!

  echo "Starting timestamped ping..."
  timeout -s INT 18 docker exec hpe-h1 ping -D -i 0.05 -W 1 "$TARGET_IP" > "$PING_LOG" 2>&1 &
  PING_PID=$!

  sleep 2

  echo
  echo "============================================================"
  echo "3. Trigger failure"
  echo "============================================================"

  FAIL_START_MS=$(docker exec "$FAIL_ROUTER" sh -lc "date +%s%3N; ip link set '$FAIL_IFACE' down" | head -1)
  echo "Failure start timestamp ms: $FAIL_START_MS"

  echo "Keeping link down for 6 seconds..."
  sleep 6

  echo
  echo "============================================================"
  echo "4. Restore link"
  echo "============================================================"

  RESTORE_MS=$(docker exec "$FAIL_ROUTER" sh -lc "date +%s%3N; ip link set '$FAIL_IFACE' up" | head -1)
  echo "Restore timestamp ms: $RESTORE_MS"

  wait "$PING_PID" || true
  wait "$KERNEL_MONITOR_PID" || true
  wait "$ROUTE_SAMPLE_PID" || true
  wait "$BIRD_SAMPLE_PID" || true

  sleep 10

  echo
  echo "============================================================"
  echo "5. Final state after restore"
  echo "============================================================"

  echo
  echo "---- hpe-r3 route to hpe-h3 after restore ----"
  docker exec hpe-r3 ip route get "$TARGET_IP" || true

  echo
  echo "---- hpe-r3 BIRD default route after restore ----"
  docker exec hpe-r3 birdc show route 0.0.0.0/0 || true

  echo
  echo "---- hpe-r3 OSPF neighbours after restore ----"
  docker exec hpe-r3 birdc show ospf neighbors || true

  echo
  echo "============================================================"
  echo "6. Parse measured timings"
  echo "============================================================"

  FAIL_START_MS="$FAIL_START_MS" \
  OLD_NEXT_HOP="$OLD_NEXT_HOP" \
  NEW_NEXT_HOP="$NEW_NEXT_HOP" \
  KERNEL_MONITOR_LOG="$KERNEL_MONITOR_LOG" \
  ROUTE_SAMPLE_LOG="$ROUTE_SAMPLE_LOG" \
  BIRD_SAMPLE_LOG="$BIRD_SAMPLE_LOG" \
  PING_LOG="$PING_LOG" \
  CSV_OUT="$CSV_OUT" \
  TS="$TS" \
  python3 - <<'PY'
import os
import re
from pathlib import Path

fail_start = int(os.environ["FAIL_START_MS"])
old_nh = os.environ["OLD_NEXT_HOP"]
new_nh = os.environ["NEW_NEXT_HOP"]

kernel_log = Path(os.environ["KERNEL_MONITOR_LOG"])
route_log = Path(os.environ["ROUTE_SAMPLE_LOG"])
bird_log = Path(os.environ["BIRD_SAMPLE_LOG"])
ping_log = Path(os.environ["PING_LOG"])
csv_out = Path(os.environ["CSV_OUT"])
ts_label = os.environ["TS"]

def first_event_with_next_hop(path, next_hop):
    if not path.exists():
      return None, None

    for line in path.read_text(errors="ignore").splitlines():
        parts = line.split(maxsplit=1)
        if len(parts) != 2:
            continue
        try:
            ts = int(parts[0])
        except ValueError:
            continue

        body = parts[1]

        if ts >= fail_start and next_hop in body:
            return ts - fail_start, body

    return None, None

kernel_ms, kernel_line = first_event_with_next_hop(kernel_log, new_nh)
route_ms, route_line = first_event_with_next_hop(route_log, new_nh)
bird_ms, bird_line = first_event_with_next_hop(bird_log, new_nh)

ping_text = ping_log.read_text(errors="ignore") if ping_log.exists() else ""

packet_loss = "unknown"
tx = rx = "unknown"

m = re.search(r"(\d+)\s+packets transmitted,\s+(\d+)\s+(?:packets\s+)?received.*?(\d+(?:\.\d+)?)%\s+packet loss", ping_text, re.S)
if m:
    tx, rx, packet_loss = m.group(1), m.group(2), m.group(3)

print(f"Kernel route monitor switch time ms: {kernel_ms if kernel_ms is not None else 'not_detected'}")
print(f"Kernel route monitor first switched line: {kernel_line if kernel_line else 'not_detected'}")
print()
print(f"Route-get sampling switch time ms: {route_ms if route_ms is not None else 'not_detected'}")
print(f"Route-get first switched line: {route_line if route_line else 'not_detected'}")
print()
print(f"BIRD route-table sampling switch time ms: {bird_ms if bird_ms is not None else 'not_detected'}")
print(f"BIRD first switched line: {bird_line if bird_line else 'not_detected'}")
print()
print(f"Ping transmitted: {tx}")
print(f"Ping received: {rx}")
print(f"Ping packet loss percent: {packet_loss}")

csv_out.write_text(
    "timestamp,test_name,old_next_hop,new_next_hop,kernel_monitor_ms,route_get_sample_ms,bird_route_sample_ms,ping_tx,ping_rx,ping_loss_percent\n"
    f"{ts_label},ospf_r3_r2_failure,{old_nh},{new_nh},{kernel_ms if kernel_ms is not None else 'not_detected'},"
    f"{route_ms if route_ms is not None else 'not_detected'},"
    f"{bird_ms if bird_ms is not None else 'not_detected'},"
    f"{tx},{rx},{packet_loss}\n"
)

print()
print(f"CSV result saved to: {csv_out}")
PY

  echo
  echo "============================================================"
  echo "7. Ping summary"
  echo "============================================================"

  grep -E "packets transmitted|packet loss|Destination|unreachable" "$PING_LOG" || true

  echo
  echo "============================================================"
  echo "8. Evidence files"
  echo "============================================================"

  echo "Main output: $OUT"
  echo "Kernel monitor log: $KERNEL_MONITOR_LOG"
  echo "Route-get sample log: $ROUTE_SAMPLE_LOG"
  echo "BIRD route sample log: $BIRD_SAMPLE_LOG"
  echo "Ping log: $PING_LOG"
  echo "CSV result: $CSV_OUT"

} | tee "$OUT"

trap - EXIT

echo
echo "Saved final kernel-monitor OSPF evidence to $OUT"
