#!/usr/bin/env bash
set -u

mkdir -p evidence/bfd results/bfd

TS=$(date +%Y%m%d_%H%M%S)
OUT="evidence/bfd/bfd_edge_failure_${TS}.txt"
PING_LOG="evidence/bfd/bfd_edge_ping_${TS}.log"
CSV="results/bfd/bfd_edge_failure_${TS}.csv"
LATEST_CSV="results/bfd/bfd_edge_failure.csv"

FAIL_ROUTER="hpe-r2"
PEER_ROUTER="hpe-r9"
LOCAL_IP="10.0.29.2"
PEER_IP="10.0.29.3"
PING_SRC="hpe-h1"
PING_DST="10.0.93.2"

restore_link() {
  IFACE=$(docker exec "$FAIL_ROUTER" sh -lc "ip -o -4 addr show | awk -v ip='$LOCAL_IP' '\$4 ~ ip\"/\" {print \$2; exit}'" 2>/dev/null || true)
  if [ -n "$IFACE" ]; then
    docker exec "$FAIL_ROUTER" ip link set "$IFACE" up >/dev/null 2>&1 || true
  fi
}

trap restore_link EXIT

{
  echo "BFD WAN Edge Failure Test"
  echo "Date: $(date)"
  echo
  echo "Failed router: $FAIL_ROUTER"
  echo "Peer router: $PEER_ROUTER"
  echo "Local IP: $LOCAL_IP"
  echo "Peer IP: $PEER_IP"
  echo "Traffic test: $PING_SRC -> $PING_DST"
  echo

  echo "============================================================"
  echo "1. Detecting failure interface"
  echo "============================================================"

  FAIL_IFACE=$(docker exec "$FAIL_ROUTER" sh -lc "ip -o -4 addr show | awk -v ip='$LOCAL_IP' '\$4 ~ ip\"/\" {print \$2; exit}'" 2>/dev/null || true)

  echo "Failure interface on $FAIL_ROUTER: $FAIL_IFACE"

  if [ -z "$FAIL_IFACE" ]; then
    echo "ERROR: Could not find interface for $LOCAL_IP on $FAIL_ROUTER"
    exit 1
  fi

  echo
  echo "============================================================"
  echo "2. Baseline state before failure"
  echo "============================================================"

  echo
  echo "---- BFD on $FAIL_ROUTER ----"
  docker exec "$FAIL_ROUTER" birdc show bfd sessions || true

  echo
  echo "---- BGP on $FAIL_ROUTER ----"
  docker exec "$FAIL_ROUTER" birdc show protocols || true

  echo
  echo "---- Route from hpe-r2 to hpe-h3 ----"
  docker exec "$FAIL_ROUTER" ip route get "$PING_DST" || true

  echo
  echo "---- Baseline ping ----"
  docker exec "$PING_SRC" ping -c 5 -W 1 "$PING_DST" || true

  echo
  echo "============================================================"
  echo "3. Start traffic monitor"
  echo "============================================================"

  timeout -s INT 15 docker exec "$PING_SRC" ping -D -i 0.05 -W 1 "$PING_DST" > "$PING_LOG" 2>&1 &
  PING_PID=$!

  sleep 2

  echo
  echo "============================================================"
  echo "4. Trigger link failure"
  echo "============================================================"

  FAIL_MS=$(date +%s%3N)
  echo "Failure timestamp ms: $FAIL_MS"

  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" down

  BFD_DETECT_MS="not_detected"
  BGP_DETECT_MS="not_detected"

  END=$((SECONDS + 5))

  while [ "$SECONDS" -lt "$END" ]; do
    NOW=$(date +%s%3N)

    BFD_LINE=$(docker exec "$FAIL_ROUTER" birdc show bfd sessions 2>/dev/null | grep "$PEER_IP" || true)
    BGP_LINE=$(docker exec "$FAIL_ROUTER" birdc show protocols 2>/dev/null | grep -E "^r9[[:space:]]+BGP" || true)

    if [ "$BFD_DETECT_MS" = "not_detected" ]; then
      echo "$BFD_LINE" | grep -q "Up"
      if [ $? -ne 0 ]; then
        BFD_DETECT_MS=$((NOW - FAIL_MS))
      fi
    fi

    if [ "$BGP_DETECT_MS" = "not_detected" ]; then
      echo "$BGP_LINE" | grep -q "Established"
      if [ $? -ne 0 ]; then
        BGP_DETECT_MS=$((NOW - FAIL_MS))
      fi
    fi

    if [ "$BFD_DETECT_MS" != "not_detected" ] && [ "$BGP_DETECT_MS" != "not_detected" ]; then
      break
    fi

    sleep 0.02
  done

  echo "BFD detection time ms: $BFD_DETECT_MS"
  echo "BGP session reaction time ms: $BGP_DETECT_MS"

  echo
  echo "---- BFD after failure ----"
  docker exec "$FAIL_ROUTER" birdc show bfd sessions || true

  echo
  echo "---- BGP after failure ----"
  docker exec "$FAIL_ROUTER" birdc show protocols || true

  echo
  echo "---- Route from hpe-r2 to hpe-h3 during failure ----"
  docker exec "$FAIL_ROUTER" ip route get "$PING_DST" || true

  sleep 4

  echo
  echo "============================================================"
  echo "5. Restore failed link"
  echo "============================================================"

  RESTORE_MS=$(date +%s%3N)
  echo "Restore timestamp ms: $RESTORE_MS"

  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" up

  echo "Waiting for BFD/BGP to come back..."
  sleep 25

  wait "$PING_PID" || true

  echo
  echo "---- BFD after restore ----"
  docker exec "$FAIL_ROUTER" birdc show bfd sessions || true

  echo
  echo "---- BGP after restore ----"
  docker exec "$FAIL_ROUTER" birdc show protocols || true

  echo
  echo "---- Final ping ----"
  docker exec "$PING_SRC" ping -c 5 -W 1 "$PING_DST" || true

  echo
  echo "============================================================"
  echo "6. Parse ping loss"
  echo "============================================================"

  PING_LOG="$PING_LOG" \
  CSV="$CSV" \
  LATEST_CSV="$LATEST_CSV" \
  TS="$TS" \
  BFD_DETECT_MS="$BFD_DETECT_MS" \
  BGP_DETECT_MS="$BGP_DETECT_MS" \
  FAIL_MS="$FAIL_MS" \
  RESTORE_MS="$RESTORE_MS" \
  FAIL_ROUTER="$FAIL_ROUTER" \
  FAIL_IFACE="$FAIL_IFACE" \
  PEER_IP="$PEER_IP" \
  python3 <<'PY2'
from pathlib import Path
import os
import re

text = Path(os.environ["PING_LOG"]).read_text(errors="ignore")

success = set()
error = set()

for line in text.splitlines():
    m = re.search(r"icmp_seq=(\d+)", line)
    if not m:
        continue

    seq = int(m.group(1))

    if "bytes from" in line:
        success.add(seq)
    elif "Destination" in line or "Unreachable" in line or "unreachable" in line:
        error.add(seq)

seen = success | error

if seen:
    tx = max(seen)
    rx = len(success)
    lost = tx - rx
    loss = (lost / tx) * 100 if tx else 0
else:
    tx = rx = lost = "unknown"
    loss = "unknown"

print(f"Estimated transmitted packets: {tx}")
print(f"Received packets: {rx}")
print(f"Failed/lost packets: {lost}")
print(f"Estimated packet loss percent: {loss if isinstance(loss, str) else f'{loss:.2f}'}")
print(f"Explicit unreachable packets: {len(error)}")

csv = Path(os.environ["CSV"])
latest = Path(os.environ["LATEST_CSV"])

loss_str = loss if isinstance(loss, str) else f"{loss:.2f}"

content = (
    "timestamp,test_name,failed_router,failed_interface,peer_ip,bfd_detection_ms,bgp_reaction_ms,"
    "estimated_tx,received,lost,loss_percent,explicit_unreachable_packets,fail_ms,restore_ms\n"
    f"{os.environ['TS']},bfd_wan_edge_failure,{os.environ['FAIL_ROUTER']},{os.environ['FAIL_IFACE']},"
    f"{os.environ['PEER_IP']},{os.environ['BFD_DETECT_MS']},{os.environ['BGP_DETECT_MS']},"
    f"{tx},{rx},{lost},{loss_str},{len(error)},{os.environ['FAIL_MS']},{os.environ['RESTORE_MS']}\n"
)

csv.write_text(content)
latest.write_text(content)

print(f"Saved CSV: {csv}")
print(f"Updated latest CSV: {latest}")
PY2

  echo
  echo "============================================================"
  echo "7. Evidence files"
  echo "============================================================"

  echo "Main evidence: $OUT"
  echo "Ping log: $PING_LOG"
  echo "CSV result: $CSV"
  echo "Latest CSV: $LATEST_CSV"

} | tee "$OUT"

trap - EXIT
restore_link
