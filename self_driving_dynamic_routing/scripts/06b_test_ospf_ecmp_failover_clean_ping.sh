#!/usr/bin/env bash
set -u

mkdir -p evidence/ospf_ecmp results/ospf

TS=$(date +%Y%m%d_%H%M%S)

OUT="evidence/ospf_ecmp/ospf_ecmp_failover_${TS}.txt"
KMON_LOG="evidence/ospf_ecmp/kernel_route_monitor_${TS}.log"
KSAMPLE_LOG="evidence/ospf_ecmp/kernel_route_samples_${TS}.log"
RGET_LOG="evidence/ospf_ecmp/route_get_samples_${TS}.log"
BIRD_LOG="evidence/ospf_ecmp/bird_route_samples_${TS}.log"
PING_LOG="evidence/ospf_ecmp/ping_timestamped_${TS}.log"
CSV="results/ospf/ospf_ecmp_failover_${TS}.csv"
CSV_LATEST="results/ospf/ospf_ecmp_failover.csv"

FAIL_ROUTER="hpe-r3"
FAIL_IP="10.0.23.3"
FAILED_NH="10.0.23.2"
SURVIVOR_NH="10.0.34.3"
TARGET_NET="10.0.24.0/24"
TARGET_IP="10.0.24.2"
PING_SRC="hpe-h1"

restore_link() {
  IFACE=$(docker exec "$FAIL_ROUTER" sh -lc "ip -o -4 addr show | awk -v ip='$FAIL_IP' '\$4 ~ ip\"/\" {print \$2; exit}'" 2>/dev/null || true)
  if [ -n "$IFACE" ]; then
    docker exec "$FAIL_ROUTER" ip link set "$IFACE" up >/dev/null 2>&1 || true
  fi
}

trap restore_link EXIT

FAIL_IFACE=$(docker exec "$FAIL_ROUTER" sh -lc "ip -o -4 addr show | awk -v ip='$FAIL_IP' '\$4 ~ ip\"/\" {print \$2; exit}'" 2>/dev/null || true)

{
  echo "OSPF ECMP Failover Measurement"
  echo "Date: $(date)"
  echo
  echo "Fail router: $FAIL_ROUTER"
  echo "Failed ECMP branch IP: $FAIL_IP"
  echo "Failed interface: $FAIL_IFACE"
  echo "Failed next-hop: $FAILED_NH"
  echo "Surviving next-hop: $SURVIVOR_NH"
  echo "Target network: $TARGET_NET"
  echo "Traffic target: $TARGET_IP"
  echo

  echo "============================================================"
  echo "1. Baseline before failure"
  echo "============================================================"

  echo
  echo "---- BIRD ECMP route before failure ----"
  docker exec "$FAIL_ROUTER" birdc show route "$TARGET_NET" all || true

  echo
  echo "---- Kernel ECMP route before failure ----"
  docker exec "$FAIL_ROUTER" ip route show "$TARGET_NET" || true

  echo
  echo "---- Route-get to target before failure ----"
  docker exec "$FAIL_ROUTER" ip route get "$TARGET_IP" || true

  echo
  echo "---- Baseline ping ----"
  docker exec "$PING_SRC" ping -c 5 -W 1 "$TARGET_IP" || true

  echo
  echo "============================================================"
  echo "2. Start monitors"
  echo "============================================================"

  docker exec "$FAIL_ROUTER" sh -lc 'ip monitor route | while read line; do echo "$(date +%s%3N) $line"; done' > "$KMON_LOG" 2>&1 &
  KMON_PID=$!

  (
    END=$(( $(date +%s) + 12 ))
    while [ "$(date +%s)" -lt "$END" ]; do
      NOW=$(date +%s%3N)
      LINE=$(docker exec "$FAIL_ROUTER" ip route show "$TARGET_NET" 2>&1 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')
      echo "$NOW $LINE"
      sleep 0.02
    done
  ) > "$KSAMPLE_LOG" 2>&1 &
  KSAMPLE_PID=$!

  (
    END=$(( $(date +%s) + 12 ))
    while [ "$(date +%s)" -lt "$END" ]; do
      NOW=$(date +%s%3N)
      LINE=$(docker exec "$FAIL_ROUTER" ip route get "$TARGET_IP" 2>&1 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')
      echo "$NOW $LINE"
      sleep 0.02
    done
  ) > "$RGET_LOG" 2>&1 &
  RGET_PID=$!

  (
    END=$(( $(date +%s) + 12 ))
    while [ "$(date +%s)" -lt "$END" ]; do
      NOW=$(date +%s%3N)
      LINE=$(docker exec "$FAIL_ROUTER" birdc show route "$TARGET_NET" all 2>&1 | awk '/via /{print}' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')
      echo "$NOW $LINE"
      sleep 0.02
    done
  ) > "$BIRD_LOG" 2>&1 &
  BIRD_PID=$!

  docker exec "$PING_SRC" ping -i 0.02 -c 500 -W 1 "$TARGET_IP" > "$PING_LOG" 2>&1 &
  PING_PID=$!

  sleep 2

  echo
  echo "============================================================"
  echo "3. Trigger ECMP branch failure"
  echo "============================================================"

  FAIL_MS=$(date +%s%3N)
  echo "Failure start timestamp ms: $FAIL_MS"

  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" down

  echo "Keeping failed ECMP branch down for 6 seconds..."
  sleep 6

  echo
  echo "============================================================"
  echo "4. Restore failed ECMP branch"
  echo "============================================================"

  RESTORE_MS=$(date +%s%3N)
  echo "Restore timestamp ms: $RESTORE_MS"

  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" up

  wait "$PING_PID" 2>/dev/null || true
  wait "$KSAMPLE_PID" 2>/dev/null || true
  wait "$RGET_PID" 2>/dev/null || true
  wait "$BIRD_PID" 2>/dev/null || true

  kill "$KMON_PID" 2>/dev/null || true

  echo "Waiting 25 seconds for OSPF restoration..."
  sleep 25

  echo
  echo "============================================================"
  echo "5. Final state after restore"
  echo "============================================================"

  echo
  echo "---- BIRD ECMP route after restore ----"
  docker exec "$FAIL_ROUTER" birdc show route "$TARGET_NET" all || true

  echo
  echo "---- Kernel ECMP route after restore ----"
  docker exec "$FAIL_ROUTER" ip route show "$TARGET_NET" || true

  echo
  echo "---- Route-get to target after restore ----"
  docker exec "$FAIL_ROUTER" ip route get "$TARGET_IP" || true

  echo
  echo "---- Final ping ----"
  docker exec "$PING_SRC" ping -c 5 -W 1 "$TARGET_IP" || true

  echo
  echo "============================================================"
  echo "6. Parse measured timings"
  echo "============================================================"

  python3 - "$CSV" "$CSV_LATEST" "$KSAMPLE_LOG" "$RGET_LOG" "$BIRD_LOG" "$KMON_LOG" "$PING_LOG" "$FAIL_MS" "$TS" "$FAILED_NH" "$SURVIVOR_NH" "$TARGET_NET" "$TARGET_IP" <<'PY2'
import re
import shutil
import sys
from pathlib import Path

csv_path = Path(sys.argv[1])
csv_latest = Path(sys.argv[2])
ksample = Path(sys.argv[3])
rget = Path(sys.argv[4])
bird = Path(sys.argv[5])
kmon = Path(sys.argv[6])
ping = Path(sys.argv[7])
fail_ms = int(sys.argv[8])
ts = sys.argv[9]
failed_nh = sys.argv[10]
survivor_nh = sys.argv[11]
target_net = sys.argv[12]
target_ip = sys.argv[13]

def first_delta(path, predicate):
    if not path.exists():
        return "unknown", ""
    for line in path.read_text(errors="ignore").splitlines():
        parts = line.split(maxsplit=1)
        if len(parts) < 2:
            continue
        try:
            t = int(parts[0])
        except ValueError:
            continue
        body = parts[1]
        if t >= fail_ms and predicate(body):
            return str(t - fail_ms), body
    return "unknown", ""

kernel_sample_ms, kernel_sample_line = first_delta(
    ksample,
    lambda s: target_net in s and survivor_nh in s and failed_nh not in s
)

route_get_ms, route_get_line = first_delta(
    rget,
    lambda s: target_ip in s and survivor_nh in s
)

bird_ms, bird_line = first_delta(
    bird,
    lambda s: survivor_nh in s and failed_nh not in s
)

kernel_monitor_ms, kernel_monitor_line = first_delta(
    kmon,
    lambda s: target_net in s and survivor_nh in s and failed_nh not in s
)

success = set()
errors = set()

if ping.exists():
    for line in ping.read_text(errors="ignore").splitlines():
        m = re.search(r"icmp_seq=(\d+)", line)
        if not m:
            continue
        seq = int(m.group(1))
        if "bytes from" in line:
            success.add(seq)
        elif "Destination" in line or "Unreachable" in line or "unreachable" in line:
            errors.add(seq)

seen = success | errors
if seen:
    tx = max(seen)
    rx = len(success)
    lost = tx - rx
    loss = (lost / tx) * 100 if tx else 0
    unreachable = len(errors)
else:
    tx = rx = lost = unreachable = "unknown"
    loss = "unknown"

print(f"Kernel monitor ECMP switch time ms: {kernel_monitor_ms}")
print(f"Kernel monitor first switched line: {kernel_monitor_line}")
print()
print(f"Kernel route sample ECMP switch time ms: {kernel_sample_ms}")
print(f"Kernel route sample first switched line: {kernel_sample_line}")
print()
print(f"Route-get sample switch time ms: {route_get_ms}")
print(f"Route-get first switched line: {route_get_line}")
print()
print(f"BIRD route-table sample switch time ms: {bird_ms}")
print(f"BIRD first switched line: {bird_line}")
print()
print(f"Estimated transmitted packets: {tx}")
print(f"Received packets: {rx}")
print(f"Failed/lost packets: {lost}")
print(f"Estimated packet loss percent: {loss if isinstance(loss, str) else f'{loss:.2f}'}")
print(f"Explicit unreachable packets: {unreachable}")

csv_path.write_text(
    "timestamp,test_name,failed_next_hop,surviving_next_hop,kernel_monitor_ms,kernel_route_sample_ms,route_get_sample_ms,bird_route_sample_ms,ping_tx_estimated,ping_rx,failed_or_lost_packets,ping_loss_percent,explicit_unreachable_packets\n"
    + f"{ts},ospf_ecmp_failover,{failed_nh},{survivor_nh},{kernel_monitor_ms},{kernel_sample_ms},{route_get_ms},{bird_ms},{tx},{rx},{lost},{loss if isinstance(loss, str) else f'{loss:.2f}'},{unreachable}\n"
)

shutil.copyfile(csv_path, csv_latest)

print()
print(f"CSV result saved to: {csv_path}")
print(f"Latest CSV updated: {csv_latest}")
PY2

  echo
  echo "============================================================"
  echo "7. Evidence files"
  echo "============================================================"
  echo "Main output: $OUT"
  echo "Kernel monitor log: $KMON_LOG"
  echo "Kernel route sample log: $KSAMPLE_LOG"
  echo "Route-get sample log: $RGET_LOG"
  echo "BIRD route sample log: $BIRD_LOG"
  echo "Ping log: $PING_LOG"
  echo "CSV result: $CSV"

} | tee "$OUT"

trap - EXIT
restore_link
