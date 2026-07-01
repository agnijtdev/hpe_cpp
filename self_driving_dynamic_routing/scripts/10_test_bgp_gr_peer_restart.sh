#!/usr/bin/env bash
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)

mkdir -p evidence/bgp_gr_llgr results/bgp_gr_llgr

OUT="evidence/bgp_gr_llgr/bgp_gr_peer_restart_${TS}.txt"
PING_LOG="evidence/bgp_gr_llgr/ping_h1_to_h3_${TS}.log"
ROUTEGET_LOG="evidence/bgp_gr_llgr/route_get_samples_${TS}.log"
BIRD_ROUTE_LOG="evidence/bgp_gr_llgr/bird_route_samples_${TS}.log"
BGP_STATE_LOG="evidence/bgp_gr_llgr/bgp_state_samples_${TS}.log"

CSV="results/bgp_gr_llgr/bgp_gr_peer_restart_${TS}.csv"
CSV_LATEST="results/bgp_gr_llgr/bgp_gr_peer_restart.csv"

TARGET_NET="10.0.93.0/24"
TARGET_IP="10.0.93.2"
PING_SRC="hpe-h1"

MONITOR_ROUTER="hpe-r1"
RESTART_ROUTER="hpe-r9"
RESTART_PROTOCOL="r1"

OLD_NH="10.0.19.3"

{
  echo "BGP GR / LLGR Peer Restart Test"
  echo "Date: $(date)"
  echo
  echo "Traffic under test: hpe-h1 -> hpe-h3"
  echo "Target network: $TARGET_NET"
  echo "Target IP: $TARGET_IP"
  echo
  echo "Monitoring router: $MONITOR_ROUTER"
  echo "Restarting BGP protocol: $RESTART_ROUTER protocol $RESTART_PROTOCOL"
  echo "Old direct BGP next-hop on hpe-r1: $OLD_NH"
  echo

  echo "============================================================"
  echo "1. Baseline BGP state and route"
  echo "============================================================"

  echo
  echo "---- hpe-r1 BGP protocol r9 ----"
  docker exec hpe-r1 birdc show protocols all r9 || true

  echo
  echo "---- hpe-r9 BGP protocol r1 ----"
  docker exec hpe-r9 birdc show protocols all r1 || true

  echo
  echo "---- hpe-r1 route to $TARGET_NET ----"
  docker exec hpe-r1 birdc show route "$TARGET_NET" all || true

  echo
  echo "---- hpe-r1 route-get to $TARGET_IP ----"
  docker exec hpe-r1 ip route get "$TARGET_IP" || true

  echo
  echo "---- Baseline ping ----"
  docker exec "$PING_SRC" ping -c 5 -W 1 "$TARGET_IP" || true

  echo
  echo "============================================================"
  echo "2. Start monitoring"
  echo "============================================================"

  START_MS=$(date +%s%3N)

  (
    END_MS=$((START_MS + 20000))
    while [ "$(date +%s%3N)" -lt "$END_MS" ]; do
      NOW=$(date +%s%3N)
      REL=$((NOW - START_MS))
      LINE=$(docker exec hpe-r1 ip route get "$TARGET_IP" 2>&1 | head -1 || true)
      echo "$REL ms | $LINE"
      sleep 0.05
    done
  ) > "$ROUTEGET_LOG" &

  ROUTEGET_PID=$!

  (
    END_MS=$((START_MS + 20000))
    while [ "$(date +%s%3N)" -lt "$END_MS" ]; do
      NOW=$(date +%s%3N)
      REL=$((NOW - START_MS))
      LINE=$(docker exec hpe-r1 birdc show route "$TARGET_NET" all 2>&1 | grep -E "unicast|via|Type:|BGP|stale|LLGR|Network not found" | tr '\n' ' ' || true)
      echo "$REL ms | $LINE"
      sleep 0.08
    done
  ) > "$BIRD_ROUTE_LOG" &

  BIRD_ROUTE_PID=$!

  (
    END_MS=$((START_MS + 20000))
    while [ "$(date +%s%3N)" -lt "$END_MS" ]; do
      NOW=$(date +%s%3N)
      REL=$((NOW - START_MS))
      LINE=$(docker exec hpe-r1 birdc show protocols r9 2>&1 | tail -n +2 | tr '\n' ' ' || true)
      echo "$REL ms | $LINE"
      sleep 0.08
    done
  ) > "$BGP_STATE_LOG" &

  BGP_STATE_PID=$!

  docker exec "$PING_SRC" ping -i 0.1 -c 180 -W 1 "$TARGET_IP" > "$PING_LOG" 2>&1 &
  PING_PID=$!

  sleep 1

  echo
  echo "============================================================"
  echo "3. Restart BGP peer/control-plane session"
  echo "============================================================"

  RESTART_MS=$(date +%s%3N)
  RESTART_REL=$((RESTART_MS - START_MS))

  echo "Restart time relative to monitor start: ${RESTART_REL} ms"
  echo "Running: docker exec $RESTART_ROUTER birdc restart $RESTART_PROTOCOL"

  docker exec "$RESTART_ROUTER" birdc restart "$RESTART_PROTOCOL"

  echo
  echo "Waiting for monitoring to complete..."
  wait "$ROUTEGET_PID" || true
  wait "$BIRD_ROUTE_PID" || true
  wait "$BGP_STATE_PID" || true
  wait "$PING_PID" || true

  echo
  echo "============================================================"
  echo "4. Final BGP and connectivity health"
  echo "============================================================"

  echo
  echo "---- hpe-r1 BGP protocol r9 after restart ----"
  docker exec hpe-r1 birdc show protocols all r9 || true

  echo
  echo "---- hpe-r9 BGP protocol r1 after restart ----"
  docker exec hpe-r9 birdc show protocols all r1 || true

  echo
  echo "---- hpe-r1 route to $TARGET_NET after restart ----"
  docker exec hpe-r1 birdc show route "$TARGET_NET" all || true

  echo
  echo "---- Final ping hpe-h1 to hpe-h3 ----"
  docker exec "$PING_SRC" ping -c 5 -W 1 "$TARGET_IP" || true

  echo
  echo "============================================================"
  echo "5. Parse measurements"
  echo "============================================================"

  python3 - "$RESTART_REL" "$OLD_NH" "$ROUTEGET_LOG" "$BIRD_ROUTE_LOG" "$BGP_STATE_LOG" "$PING_LOG" "$CSV" "$CSV_LATEST" "$TS" <<'PY2'
import re
import sys
from pathlib import Path

restart_rel = int(sys.argv[1])
old_nh = sys.argv[2]
routeget_log = Path(sys.argv[3])
bird_route_log = Path(sys.argv[4])
bgp_state_log = Path(sys.argv[5])
ping_log = Path(sys.argv[6])
csv = Path(sys.argv[7])
csv_latest = Path(sys.argv[8])
ts = sys.argv[9]

def first_route_change():
    for line in routeget_log.read_text(errors="ignore").splitlines():
        m = re.match(r"(\d+) ms \| (.*)", line)
        if not m:
            continue
        rel = int(m.group(1))
        body = m.group(2)

        if rel < restart_rel:
            continue

        if old_nh not in body and "via" in body:
            return str(rel - restart_rel), body.strip()

    return "NA", "route-get stayed on old next-hop or no alternate change detected"

def first_bgp_non_established():
    for line in bgp_state_log.read_text(errors="ignore").splitlines():
        m = re.match(r"(\d+) ms \| (.*)", line)
        if not m:
            continue

        rel = int(m.group(1))
        body = m.group(2)

        if rel < restart_rel:
            continue

        if "Established" not in body:
            return str(rel - restart_rel), body.strip()

    return "NA", "BGP stayed Established in sampled output or transition was too fast"

route_change_ms, route_change_line = first_route_change()
bgp_down_ms, bgp_down_line = first_bgp_non_established()

ping_text = ping_log.read_text(errors="ignore")

tx = rx = lost = loss_percent = "NA"
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

missing_text = " ".join(map(str, missing[:120]))

stale_seen = "yes" if re.search(r"stale|LLGR|grace", bird_route_log.read_text(errors="ignore"), re.I) else "no"

rows = [
    "timestamp,test_name,restart_router,restart_protocol,old_next_hop,route_change_ms,bgp_non_established_seen_ms,stale_or_grace_text_seen,ping_tx,ping_rx,ping_lost,ping_loss_percent,route_change_line,bgp_non_established_line,missing_ping_sequences",
    f"{ts},bgp_gr_peer_restart,hpe-r9,r1,{old_nh},{route_change_ms},{bgp_down_ms},{stale_seen},{tx},{rx},{lost},{loss_percent},\"{route_change_line}\",\"{bgp_down_line}\",\"{missing_text}\""
]

csv.write_text("\n".join(rows) + "\n")
csv_latest.write_text(csv.read_text())

print("Route change time ms:", route_change_ms)
print("Route change line:", route_change_line)
print("BGP non-established seen ms:", bgp_down_ms)
print("BGP non-established line:", bgp_down_line)
print("Stale/grace text seen in route samples:", stale_seen)
print("Ping transmitted:", tx)
print("Ping received:", rx)
print("Ping lost:", lost)
print("Ping loss percent:", loss_percent)
print("Missing ping sequences:", missing_text)
print("CSV result saved to:", csv)
PY2

  echo
  echo "============================================================"
  echo "6. Evidence files"
  echo "============================================================"
  echo "Main output: $OUT"
  echo "Ping log: $PING_LOG"
  echo "Route-get log: $ROUTEGET_LOG"
  echo "BIRD route log: $BIRD_ROUTE_LOG"
  echo "BGP state log: $BGP_STATE_LOG"
  echo "CSV result: $CSV"
  echo "Latest CSV: $CSV_LATEST"

} | tee "$OUT"
