#!/usr/bin/env bash
set -u

mkdir -p evidence/ospf_core_link_failure_precise

TS=$(date +%Y%m%d_%H%M%S)

OUT="evidence/ospf_core_link_failure_precise/precise_ospf_failure_${TS}.txt"
ROUTE_LOG="evidence/ospf_core_link_failure_precise/route_samples_${TS}.log"
PING_LOG="evidence/ospf_core_link_failure_precise/ping_samples_${TS}.log"

FAIL_ROUTER="hpe-r3"
FAIL_IP="10.0.23.3"
FAILED_NEXT_HOP="10.0.23.2"
EXPECTED_NEW_NEXT_HOP="10.0.13.2"
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
  echo "Precise OSPF Core Link Failure Test"
  echo "Date: $(date)"
  echo
  echo "Fail router: $FAIL_ROUTER"
  echo "Fail interface: $FAIL_IFACE"
  echo "Fail interface IP: $FAIL_IP"
  echo "Old next-hop: $FAILED_NEXT_HOP"
  echo "Expected new next-hop: $EXPECTED_NEW_NEXT_HOP"
  echo "Target traffic: hpe-h1 -> hpe-h3 ($TARGET_IP)"
  echo

  echo "============================================================"
  echo "1. Baseline before failure"
  echo "============================================================"

  echo
  echo "---- hpe-r3 route to target before failure ----"
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
  echo "2. Start high-frequency route and ping sampling"
  echo "============================================================"

  : > "$ROUTE_LOG"
  : > "$PING_LOG"

  docker exec "$FAIL_ROUTER" sh -lc "
    for i in \$(seq 1 900); do
      printf '%s ' \"\$(date +%s%3N)\"
      ip route get $TARGET_IP 2>&1 | head -1
      sleep 0.02
    done
  " > "$ROUTE_LOG" 2>&1 &

  ROUTE_PID=$!

  timeout -s INT 16 docker exec hpe-h1 ping -D -i 0.05 -W 1 "$TARGET_IP" > "$PING_LOG" 2>&1 &
  PING_PID=$!

  sleep 2

  echo
  echo "============================================================"
  echo "3. Trigger failure"
  echo "============================================================"

  FAIL_START_MS=$(date +%s%3N)
  echo "Failure start timestamp ms: $FAIL_START_MS"

  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" down

  echo "Link down triggered. Waiting before restore..."
  sleep 6

  echo
  echo "============================================================"
  echo "4. Restore link"
  echo "============================================================"

  RESTORE_MS=$(date +%s%3N)
  echo "Restore timestamp ms: $RESTORE_MS"

  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" up

  wait "$PING_PID" || true
  wait "$ROUTE_PID" || true

  sleep 10

  echo
  echo "============================================================"
  echo "5. Final state after restore"
  echo "============================================================"

  echo
  echo "---- hpe-r3 route to target after restore ----"
  docker exec hpe-r3 ip route get "$TARGET_IP" || true

  echo
  echo "---- hpe-r3 BIRD default route after restore ----"
  docker exec hpe-r3 birdc show route 0.0.0.0/0 || true

  echo
  echo "---- hpe-r3 OSPF neighbours after restore ----"
  docker exec hpe-r3 birdc show ospf neighbors || true

  echo
  echo "============================================================"
  echo "6. Parse accurate route switch time"
  echo "============================================================"

  python3 - <<PY
from pathlib import Path

route_log = Path("$ROUTE_LOG")
fail_start = int("$FAIL_START_MS")
old_nh = "$FAILED_NEXT_HOP"
new_nh = "$EXPECTED_NEW_NEXT_HOP"

switch_time = None
switch_line = None

for line in route_log.read_text(errors="ignore").splitlines():
    parts = line.split(maxsplit=1)
    if len(parts) != 2:
        continue

    try:
        ts = int(parts[0])
    except ValueError:
        continue

    route = parts[1]

    if ts >= fail_start and new_nh in route:
        switch_time = ts - fail_start
        switch_line = route
        break

print(f"Route switch time ms: {switch_time if switch_time is not None else 'not_detected'}")
print(f"First switched route line: {switch_line if switch_line else 'not_detected'}")
PY

  echo
  echo "============================================================"
  echo "7. Ping summary"
  echo "============================================================"

  echo "Ping log: $PING_LOG"
  grep -E "packets transmitted|packet loss|bytes from|Destination|unreachable" "$PING_LOG" | tail -20 || true

  echo
  echo "============================================================"
  echo "8. Evidence files"
  echo "============================================================"

  echo "Main output: $OUT"
  echo "Route samples: $ROUTE_LOG"
  echo "Ping samples: $PING_LOG"

} | tee "$OUT"

trap - EXIT

echo
echo "Saved precise OSPF evidence to $OUT"
