#!/usr/bin/env bash
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)

mkdir -p evidence/bgp_gr_llgr results/bgp_gr_llgr

OUT="evidence/bgp_gr_llgr/bgp_gr_blackhole_guard_${TS}.txt"
PING_LOG="evidence/bgp_gr_llgr/ping_blackhole_guard_${TS}.log"
ROUTEGET_LOG="evidence/bgp_gr_llgr/route_get_blackhole_guard_${TS}.log"
BGP_STATE_LOG="evidence/bgp_gr_llgr/bgp_state_blackhole_guard_${TS}.log"
BIRD_ROUTE_LOG="evidence/bgp_gr_llgr/bird_route_blackhole_guard_${TS}.log"

CSV="results/bgp_gr_llgr/bgp_gr_blackhole_guard_${TS}.csv"
CSV_LATEST="results/bgp_gr_llgr/bgp_gr_blackhole_guard.csv"

TARGET_NET="10.0.93.0/24"
TARGET_IP="10.0.93.2"
PING_SRC="hpe-h1"
OLD_NH="10.0.19.3"

cleanup() {
  echo
  echo "Cleanup: restoring hpe-r1 eth1, removing blackhole guard, enabling r2..."
  docker exec hpe-r1 ip link set eth1 up >/dev/null 2>&1 || true
  docker exec hpe-r1 ip route del blackhole 10.0.93.0/24 metric 9999 >/dev/null 2>&1 || true
  docker exec hpe-r1 birdc enable r2 >/dev/null 2>&1 || true
  docker exec hpe-r9 birdc enable r1 >/dev/null 2>&1 || true
  sleep 5
}

trap cleanup EXIT

{
  echo "BGP GR Blackhole-Guard Proof"
  echo "Date: $(date)"
  echo
  echo "Goal:"
  echo "Prove that forwarding continuity is caused by BGP route retention, not alternate routing or default-route fallback."
  echo
  echo "Traffic under test: hpe-h1 -> hpe-h3"
  echo "Target network: $TARGET_NET"
  echo "Target IP: $TARGET_IP"
  echo "Expected retained next-hop: $OLD_NH"
  echo

  echo "============================================================"
  echo "1. Add blackhole guard route on hpe-r1"
  echo "============================================================"

  docker exec hpe-r1 ip route add blackhole "$TARGET_NET" metric 9999 2>/dev/null || true

  echo "hpe-r1 routes for $TARGET_NET:"
  docker exec hpe-r1 ip route show "$TARGET_NET" || true

  echo
  echo "Route-get should still prefer real BGP route via $OLD_NH:"
  docker exec hpe-r1 ip route get "$TARGET_IP" || true

  echo
  echo "============================================================"
  echo "2. Disable alternate hpe-r1 <-> hpe-r2 path"
  echo "============================================================"

  echo "Disabling BGP protocol r2 on hpe-r1..."
  docker exec hpe-r1 birdc disable r2 || true

  echo "Bringing down hpe-r1 eth1, the r1-r2 link..."
  docker exec hpe-r1 ip link set eth1 down

  sleep 6

  echo
  echo "hpe-r1 link state:"
  docker exec hpe-r1 ip -br addr | grep -E "eth0|eth1|eth2|eth3"

  echo
  echo "hpe-r1 BGP protocols after isolation:"
  docker exec hpe-r1 birdc show protocols | grep -Ei "r9|r2|BGP|Established|disabled|Active|down|start" || true

  echo
  echo "hpe-r1 route to $TARGET_NET after isolation:"
  docker exec hpe-r1 birdc show route "$TARGET_NET" all || true

  echo
  echo "hpe-r1 route-get after isolation:"
  docker exec hpe-r1 ip route get "$TARGET_IP" || true

  echo
  echo "Baseline ping under blackhole guard + no r2 link:"
  docker exec "$PING_SRC" ping -c 5 -W 1 "$TARGET_IP" || true

  echo
  echo "============================================================"
  echo "3. Start monitoring"
  echo "============================================================"

  START_MS=$(date +%s%3N)

  (
    END_MS=$((START_MS + 22000))
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
    END_MS=$((START_MS + 22000))
    while [ "$(date +%s%3N)" -lt "$END_MS" ]; do
      NOW=$(date +%s%3N)
      REL=$((NOW - START_MS))
      LINE=$(docker exec hpe-r1 birdc show route "$TARGET_NET" all 2>&1 | grep -E "unicast|via|Type:|BGP|stale|LLGR|grace|Network not found" | tr '\n' ' ' || true)
      echo "$REL ms | $LINE"
      sleep 0.08
    done
  ) > "$BIRD_ROUTE_LOG" &

  BIRD_ROUTE_PID=$!

  (
    END_MS=$((START_MS + 22000))
    while [ "$(date +%s%3N)" -lt "$END_MS" ]; do
      NOW=$(date +%s%3N)
      REL=$((NOW - START_MS))
      LINE=$(docker exec hpe-r1 birdc show protocols r9 2>&1 | tail -n +2 | tr '\n' ' ' || true)
      echo "$REL ms | $LINE"
      sleep 0.08
    done
  ) > "$BGP_STATE_LOG" &

  BGP_STATE_PID=$!

  docker exec "$PING_SRC" ping -i 0.1 -c 200 -W 1 "$TARGET_IP" > "$PING_LOG" 2>&1 &
  PING_PID=$!

  sleep 1

  echo
  echo "============================================================"
  echo "4. Restart direct BGP peer session hpe-r9 -> hpe-r1"
  echo "============================================================"

  RESTART_MS=$(date +%s%3N)
  RESTART_REL=$((RESTART_MS - START_MS))

  echo "Restart time relative to monitor start: ${RESTART_REL} ms"
  echo "Running: docker exec hpe-r9 birdc restart r1"

  docker exec hpe-r9 birdc restart r1

  echo
  echo "Waiting for monitoring to complete..."
  wait "$ROUTEGET_PID" || true
  wait "$BIRD_ROUTE_PID" || true
  wait "$BGP_STATE_PID" || true
  wait "$PING_PID" || true

  echo
  echo "============================================================"
  echo "5. Final state before cleanup"
  echo "============================================================"

  echo
  echo "hpe-r1 route-get final:"
  docker exec hpe-r1 ip route get "$TARGET_IP" || true

  echo
  echo "hpe-r1 route to $TARGET_NET final:"
  docker exec hpe-r1 birdc show route "$TARGET_NET" all || true

  echo
  echo "Final ping:"
  docker exec "$PING_SRC" ping -c 5 -W 1 "$TARGET_IP" || true

  echo
  echo "============================================================"
  echo "6. Parse result"
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

route_text = routeget_log.read_text(errors="ignore")
bird_text = bird_route_log.read_text(errors="ignore")
bgp_text = bgp_state_log.read_text(errors="ignore")
ping_text = ping_log.read_text(errors="ignore")

old_nh_seen = "no"
alternate_seen = "no"
blackhole_or_unreachable_seen = "no"
route_missing_seen = "no"

for line in route_text.splitlines():
    m = re.match(r"(\d+) ms \| (.*)", line)
    if not m:
        continue

    rel = int(m.group(1))
    body = m.group(2)

    if rel < restart_rel:
        continue

    if old_nh in body:
        old_nh_seen = "yes"

    if "10.0.12.3" in body or "10.0.12.2" in body:
        alternate_seen = "yes"

    if "blackhole" in body.lower() or "unreachable" in body.lower() or "prohibit" in body.lower():
        blackhole_or_unreachable_seen = "yes"

for line in bird_text.splitlines():
    m = re.match(r"(\d+) ms \| (.*)", line)
    if not m:
        continue

    rel = int(m.group(1))
    body = m.group(2)

    if rel >= restart_rel and "Network not found" in body:
        route_missing_seen = "yes"

bgp_non_established_ms = "NA"
bgp_non_established_line = "not observed"

for line in bgp_text.splitlines():
    m = re.match(r"(\d+) ms \| (.*)", line)
    if not m:
        continue

    rel = int(m.group(1))
    body = m.group(2)

    if rel >= restart_rel and "Established" not in body:
        bgp_non_established_ms = str(rel - restart_rel)
        bgp_non_established_line = body.strip()
        break

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

stale_or_grace_seen = "yes" if re.search(r"stale|LLGR|grace", bird_text, re.I) else "no"

rows = [
    "timestamp,test_name,blackhole_guard_enabled,r1_r2_link_down,old_next_hop,bgp_non_established_seen_ms,old_next_hop_seen_after_restart,alternate_next_hop_seen_after_restart,blackhole_or_unreachable_seen_after_restart,bird_route_missing_seen_after_restart,stale_or_grace_text_seen,ping_tx,ping_rx,ping_lost,ping_loss_percent,bgp_non_established_line,missing_ping_sequences",
    f"{ts},bgp_gr_blackhole_guard,yes,yes,{old_nh},{bgp_non_established_ms},{old_nh_seen},{alternate_seen},{blackhole_or_unreachable_seen},{route_missing_seen},{stale_or_grace_seen},{tx},{rx},{lost},{loss_percent},\"{bgp_non_established_line}\",\"{missing_text}\""
]

csv.write_text("\n".join(rows) + "\n")
csv_latest.write_text(csv.read_text())

print("BGP non-established seen ms:", bgp_non_established_ms)
print("BGP non-established line:", bgp_non_established_line)
print("Old next-hop seen after restart:", old_nh_seen)
print("Alternate next-hop seen after restart:", alternate_seen)
print("Blackhole/unreachable seen after restart:", blackhole_or_unreachable_seen)
print("BIRD route missing seen after restart:", route_missing_seen)
print("Stale/grace text seen:", stale_or_grace_seen)
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
  echo "BIRD route log: $BIRD_ROUTE_LOG"
  echo "BGP state log: $BGP_STATE_LOG"
  echo "CSV result: $CSV"
  echo "Latest CSV: $CSV_LATEST"

} | tee "$OUT"
