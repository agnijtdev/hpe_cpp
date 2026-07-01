#!/usr/bin/env bash
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)

mkdir -p evidence/area_healing results/area_healing

OUT="evidence/area_healing/area_healing_r3_r4_failure_${TS}.txt"
PING_LOG="evidence/area_healing/ping_h1_to_h2_${TS}.log"
ROUTEGET_LOG="evidence/area_healing/route_get_samples_${TS}.log"
KERNEL_LOG="evidence/area_healing/kernel_route_samples_${TS}.log"
BIRD_LOG="evidence/area_healing/bird_route_samples_${TS}.log"

CSV="results/area_healing/area_healing_r3_r4_failure_${TS}.csv"
CSV_LATEST="results/area_healing/area_healing_r3_r4_failure.csv"

FAIL_ROUTER="hpe-r3"
FAIL_IF="eth3"

TARGET_NET="10.0.82.0/24"
TARGET_IP="10.0.82.2"
PING_SRC="hpe-h1"

OLD_NH="10.0.34.3"

restore_link() {
  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IF" up >/dev/null 2>&1 || true
}

trap restore_link EXIT

{
  echo "OSPF Area Healing Across ABRs"
  echo "Date: $(date)"
  echo
  echo "Traffic under test: hpe-h1 -> hpe-h2"
  echo "Source host: hpe-h1"
  echo "Destination IP: $TARGET_IP"
  echo "Destination network: $TARGET_NET"
  echo
  echo "Failed link: hpe-r3 eth3"
  echo "Old direct next-hop: $OLD_NH"
  echo

  echo "============================================================"
  echo "1. Baseline route before failure"
  echo "============================================================"

  echo
  echo "---- hpe-r3 BIRD route to $TARGET_NET ----"
  docker exec hpe-r3 birdc show route "$TARGET_NET" all || true

  echo
  echo "---- hpe-r3 kernel route-get to $TARGET_IP ----"
  docker exec hpe-r3 ip route get "$TARGET_IP" || true

  echo
  echo "---- hpe-r3 OSPF neighbours before failure ----"
  docker exec hpe-r3 birdc show ospf neighbors || true

  echo
  echo "---- Baseline ping hpe-h1 to hpe-h2 ----"
  docker exec "$PING_SRC" ping -c 5 -W 1 "$TARGET_IP" || true

  echo
  echo "============================================================"
  echo "2. Start monitoring"
  echo "============================================================"

  START_MS=$(date +%s%3N)

  (
    END_MS=$((START_MS + 15000))
    while [ "$(date +%s%3N)" -lt "$END_MS" ]; do
      NOW=$(date +%s%3N)
      REL=$((NOW - START_MS))
      LINE=$(docker exec hpe-r3 ip route get "$TARGET_IP" 2>&1 | head -1 || true)
      echo "$REL ms | $LINE"
      sleep 0.03
    done
  ) > "$ROUTEGET_LOG" &

  ROUTEGET_PID=$!

  (
    END_MS=$((START_MS + 15000))
    while [ "$(date +%s%3N)" -lt "$END_MS" ]; do
      NOW=$(date +%s%3N)
      REL=$((NOW - START_MS))
      LINE=$(docker exec hpe-r3 ip route show "$TARGET_NET" 2>&1 | tr '\n' ' ' || true)
      echo "$REL ms | $LINE"
      sleep 0.03
    done
  ) > "$KERNEL_LOG" &

  KERNEL_PID=$!

  (
    END_MS=$((START_MS + 15000))
    while [ "$(date +%s%3N)" -lt "$END_MS" ]; do
      NOW=$(date +%s%3N)
      REL=$((NOW - START_MS))
      LINE=$(docker exec hpe-r3 birdc show route "$TARGET_NET" all 2>&1 | grep -E "unicast|via|Network not found" | tr '\n' ' ' || true)
      echo "$REL ms | $LINE"
      sleep 0.05
    done
  ) > "$BIRD_LOG" &

  BIRD_PID=$!

  docker exec "$PING_SRC" ping -i 0.1 -c 150 -W 1 "$TARGET_IP" > "$PING_LOG" 2>&1 &
  PING_PID=$!

  sleep 1

  echo
  echo "============================================================"
  echo "3. Fail direct ABR link"
  echo "============================================================"

  FAIL_MS=$(date +%s%3N)
  FAIL_REL=$((FAIL_MS - START_MS))

  echo "Failure time relative to monitor start: ${FAIL_REL} ms"
  echo "Failing $FAIL_ROUTER $FAIL_IF now..."
  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IF" down

  echo "Waiting for monitoring to complete..."
  wait "$ROUTEGET_PID" || true
  wait "$KERNEL_PID" || true
  wait "$BIRD_PID" || true
  wait "$PING_PID" || true

  echo
  echo "============================================================"
  echo "4. Restore failed link"
  echo "============================================================"

  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IF" up
  sleep 10

  echo
  echo "============================================================"
  echo "5. Post-restore health check"
  echo "============================================================"

  echo
  echo "---- hpe-r3 BIRD route after restore ----"
  docker exec hpe-r3 birdc show route "$TARGET_NET" all || true

  echo
  echo "---- hpe-r3 OSPF neighbours after restore ----"
  docker exec hpe-r3 birdc show ospf neighbors || true

  echo
  echo "---- Final ping hpe-h1 to hpe-h2 ----"
  docker exec "$PING_SRC" ping -c 5 -W 1 "$TARGET_IP" || true

  echo
  echo "============================================================"
  echo "6. Parse measurements"
  echo "============================================================"

  python3 - "$FAIL_REL" "$OLD_NH" "$ROUTEGET_LOG" "$KERNEL_LOG" "$BIRD_LOG" "$PING_LOG" "$CSV" "$CSV_LATEST" "$TS" <<'PY2'
import re
import sys
from pathlib import Path

fail_rel = int(sys.argv[1])
old_nh = sys.argv[2]
routeget_log = Path(sys.argv[3])
kernel_log = Path(sys.argv[4])
bird_log = Path(sys.argv[5])
ping_log = Path(sys.argv[6])
csv = Path(sys.argv[7])
csv_latest = Path(sys.argv[8])
ts = sys.argv[9]

def first_switch(log_path, require_route=True):
    first_line = ""
    first_ms = "NA"

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

        if require_route and "via" not in body:
            continue

        if "Network is unreachable" in body:
            continue

        first_ms = str(rel - fail_rel)
        first_line = body.strip()
        break

    return first_ms, first_line

routeget_ms, routeget_line = first_switch(routeget_log)
kernel_ms, kernel_line = first_switch(kernel_log)
bird_ms, bird_line = first_switch(bird_log)

ping_text = ping_log.read_text(errors="ignore")

tx = rx = lost = "NA"
loss_percent = "NA"

m = re.search(r"(\d+) packets transmitted, (\d+) received,.*?(\d+(?:\.\d+)?)% packet loss", ping_text)
if m:
    tx = m.group(1)
    rx = m.group(2)
    loss_percent = m.group(3)
    lost = str(int(tx) - int(rx))

missing = []
seen = set()

for m in re.finditer(r"icmp_seq=(\d+)", ping_text):
    seen.add(int(m.group(1)))

if seen:
    for i in range(1, max(seen) + 1):
        if i not in seen:
            missing.append(i)

missing_text = " ".join(map(str, missing[:80]))

rows = [
    "timestamp,test_name,failed_link,old_next_hop,route_get_ms,kernel_route_ms,bird_route_ms,ping_tx,ping_rx,ping_lost,ping_loss_percent,route_get_first_line,kernel_first_line,bird_first_line,missing_ping_sequences",
    f"{ts},ospf_area_healing_r3_r4,hpe-r3_eth3,{old_nh},{routeget_ms},{kernel_ms},{bird_ms},{tx},{rx},{lost},{loss_percent},\"{routeget_line}\",\"{kernel_line}\",\"{bird_line}\",\"{missing_text}\""
]

csv.write_text("\n".join(rows) + "\n")
csv_latest.write_text(csv.read_text())

print("Route-get switch time ms:", routeget_ms)
print("Route-get first switched line:", routeget_line)
print("Kernel route switch time ms:", kernel_ms)
print("Kernel first switched line:", kernel_line)
print("BIRD route switch time ms:", bird_ms)
print("BIRD first switched line:", bird_line)
print("Ping transmitted:", tx)
print("Ping received:", rx)
print("Ping lost:", lost)
print("Ping loss percent:", loss_percent)
print("Missing ping sequences:", missing_text)
print("CSV result saved to:", csv)
PY2

  echo
  echo "============================================================"
  echo "7. Evidence files"
  echo "============================================================"
  echo "Main output: $OUT"
  echo "Ping log: $PING_LOG"
  echo "Route-get log: $ROUTEGET_LOG"
  echo "Kernel route log: $KERNEL_LOG"
  echo "BIRD route log: $BIRD_LOG"
  echo "CSV result: $CSV"
  echo "Latest CSV: $CSV_LATEST"

} | tee "$OUT"
