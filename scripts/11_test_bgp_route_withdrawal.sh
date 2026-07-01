#!/usr/bin/env bash
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)

mkdir -p evidence/bgp_gr_llgr results/bgp_gr_llgr configs/bgp_withdraw_before configs/bgp_withdraw_after

OUT="evidence/bgp_gr_llgr/bgp_route_withdrawal_${TS}.txt"
PING_LOG="evidence/bgp_gr_llgr/ping_route_withdrawal_${TS}.log"
ROUTEGET_LOG="evidence/bgp_gr_llgr/route_get_withdrawal_${TS}.log"
BIRD_ROUTE_LOG="evidence/bgp_gr_llgr/bird_route_withdrawal_${TS}.log"
BGP_STATE_LOG="evidence/bgp_gr_llgr/bgp_state_withdrawal_${TS}.log"

CSV="results/bgp_gr_llgr/bgp_route_withdrawal_${TS}.csv"
CSV_LATEST="results/bgp_gr_llgr/bgp_route_withdrawal.csv"

TARGET_NET="10.0.93.0/24"
TARGET_IP="10.0.93.2"
OLD_NH="10.0.19.3"
PING_SRC="hpe-h1"

R9_BEFORE="configs/bgp_withdraw_before/hpe-r9_bird_${TS}.conf"
R9_AFTER="configs/bgp_withdraw_after/hpe-r9_withdraw_h3_to_r1_${TS}.conf"

cleanup() {
  echo
  echo "Cleanup: restoring hpe-r9 config, hpe-r1 eth1, blackhole guard, and r2 protocol..."

  if [ -f "$R9_BEFORE" ]; then
    docker cp "$R9_BEFORE" hpe-r9:/tmp/hpe-r9_restore_withdraw.conf >/dev/null 2>&1 || true
    docker exec hpe-r9 bird -p -c /tmp/hpe-r9_restore_withdraw.conf >/dev/null 2>&1 || true
    docker exec hpe-r9 cp /tmp/hpe-r9_restore_withdraw.conf /etc/bird/bird.conf >/dev/null 2>&1 || true
    docker exec hpe-r9 birdc configure >/dev/null 2>&1 || true
  fi

  docker exec hpe-r1 ip route del blackhole 10.0.93.0/24 metric 9999 >/dev/null 2>&1 || true
  docker exec hpe-r1 ip link set eth1 up >/dev/null 2>&1 || true
  docker exec hpe-r1 birdc enable r2 >/dev/null 2>&1 || true
  docker exec hpe-r9 birdc enable r1 >/dev/null 2>&1 || true
  sleep 5
}

trap cleanup EXIT

{
  echo "BGP Route Withdrawal Test"
  echo "Date: $(date)"
  echo
  echo "Goal: verify that a real BGP withdrawal removes the route."
  echo "Traffic: hpe-h1 -> hpe-h3"
  echo "Target: $TARGET_IP / $TARGET_NET"
  echo

  echo "1. Save hpe-r9 original config"
  docker exec hpe-r9 cat /etc/bird/bird.conf > "$R9_BEFORE"
  cp "$R9_BEFORE" "$R9_AFTER"
  echo "Saved original hpe-r9 config: $R9_BEFORE"
  echo

  echo "2. Add blackhole guard on hpe-r1"
  docker exec hpe-r1 ip route add blackhole "$TARGET_NET" metric 9999 2>/dev/null || true
  docker exec hpe-r1 ip route show "$TARGET_NET" || true
  docker exec hpe-r1 ip route get "$TARGET_IP" || true
  echo

  echo "3. Disable alternate hpe-r1 <-> hpe-r2 path"
  docker exec hpe-r1 birdc disable r2 || true
  docker exec hpe-r1 ip link set eth1 down
  sleep 6

  docker exec hpe-r1 ip -br addr | grep -E "eth1|eth0" || true
  docker exec hpe-r1 birdc show protocols | grep -Ei "r9|r2|BGP|Established|disabled|Active|down|start" || true
  docker exec hpe-r1 birdc show route "$TARGET_NET" all || true
  docker exec hpe-r1 ip route get "$TARGET_IP" || true

  echo
  echo "Baseline ping before withdrawal:"
  docker exec "$PING_SRC" ping -c 5 -W 1 "$TARGET_IP" || true

  echo
  echo "4. Modify hpe-r9 config to withdraw $TARGET_NET from BGP peer r1"

  python3 - "$R9_AFTER" <<'PY2'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

filter_block = """
filter withdraw_h3_to_r1 {
    if net = 10.0.93.0/24 then reject;
    accept;
}

"""

if "filter withdraw_h3_to_r1" not in text:
    text = filter_block + text

lines = text.splitlines()
out = []
inside = False
depth = 0
inserted = False

for line in lines:
    stripped = line.strip()

    if stripped.startswith("protocol bgp r1"):
        inside = True
        depth = line.count("{") - line.count("}")
        inserted = False
        out.append(line)
        continue

    if inside:
        depth += line.count("{") - line.count("}")

        if stripped.startswith("export "):
            if not inserted:
                out.append("    export filter withdraw_h3_to_r1;")
                inserted = True
            continue

        if depth <= 0:
            if not inserted:
                out.append("    export filter withdraw_h3_to_r1;")
                inserted = True
            out.append(line)
            inside = False
            continue

    out.append(line)

path.write_text("\n".join(out) + "\n")
PY2

  docker cp "$R9_AFTER" hpe-r9:/tmp/hpe-r9_withdraw_h3_to_r1.conf
  docker exec hpe-r9 bird -p -c /tmp/hpe-r9_withdraw_h3_to_r1.conf

  echo
  echo "5. Start monitoring"

  START_MS=$(date +%s%3N)

  (
    END_MS=$((START_MS + 25000))
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
    END_MS=$((START_MS + 25000))
    while [ "$(date +%s%3N)" -lt "$END_MS" ]; do
      NOW=$(date +%s%3N)
      REL=$((NOW - START_MS))
      LINE=$(docker exec hpe-r1 birdc show route "$TARGET_NET" all 2>&1 | grep -E "unicast|via|Type:|BGP|Network not found" | tr '\n' ' ' || true)
      echo "$REL ms | $LINE"
      sleep 0.08
    done
  ) > "$BIRD_ROUTE_LOG" &
  BIRD_ROUTE_PID=$!

  (
    END_MS=$((START_MS + 25000))
    while [ "$(date +%s%3N)" -lt "$END_MS" ]; do
      NOW=$(date +%s%3N)
      REL=$((NOW - START_MS))
      LINE=$(docker exec hpe-r1 birdc show protocols r9 2>&1 | tail -n +2 | tr '\n' ' ' || true)
      echo "$REL ms | $LINE"
      sleep 0.08
    done
  ) > "$BGP_STATE_LOG" &
  BGP_STATE_PID=$!

  docker exec "$PING_SRC" ping -i 0.1 -c 220 -W 1 "$TARGET_IP" > "$PING_LOG" 2>&1 &
  PING_PID=$!

  sleep 1

  echo
  echo "6. Apply withdrawal config on hpe-r9"

  WITHDRAW_MS=$(date +%s%3N)
  WITHDRAW_REL=$((WITHDRAW_MS - START_MS))

  echo "Withdrawal apply time relative to monitor start: ${WITHDRAW_REL} ms"
  echo "Running: docker exec hpe-r9 birdc configure"

  docker exec hpe-r9 cp /tmp/hpe-r9_withdraw_h3_to_r1.conf /etc/bird/bird.conf
  docker exec hpe-r9 birdc configure

  echo "Waiting for monitoring..."
  wait "$ROUTEGET_PID" || true
  wait "$BIRD_ROUTE_PID" || true
  wait "$BGP_STATE_PID" || true
  wait "$PING_PID" || true

  echo
  echo "7. Final state before cleanup"
  docker exec hpe-r1 birdc show protocols r9 || true
  docker exec hpe-r1 birdc show route "$TARGET_NET" all || true
  docker exec hpe-r1 ip route get "$TARGET_IP" || true

  echo
  echo "Final ping after withdrawal:"
  docker exec "$PING_SRC" ping -c 5 -W 1 "$TARGET_IP" || true

  echo
  echo "8. Parse result"

  python3 - "$WITHDRAW_REL" "$OLD_NH" "$ROUTEGET_LOG" "$BIRD_ROUTE_LOG" "$BGP_STATE_LOG" "$PING_LOG" "$CSV" "$CSV_LATEST" "$TS" <<'PY3'
import re
import sys
from pathlib import Path

withdraw_rel = int(sys.argv[1])
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

blackhole_seen_ms = "NA"
blackhole_line = "not observed"
old_nh_seen_after_withdraw = "no"
alternate_seen_after_withdraw = "no"
bgp_non_established_seen = "no"
bird_route_missing_ms = "NA"
bird_route_missing_line = "not observed"

for line in route_text.splitlines():
    m = re.match(r"(\d+) ms \| (.*)", line)
    if not m:
        continue

    rel = int(m.group(1))
    body = m.group(2)

    if rel < withdraw_rel:
        continue

    if old_nh in body:
        old_nh_seen_after_withdraw = "yes"

    if "10.0.12.3" in body or "10.0.12.2" in body:
        alternate_seen_after_withdraw = "yes"

    if blackhole_seen_ms == "NA" and ("blackhole" in body.lower() or "unreachable" in body.lower()):
        blackhole_seen_ms = str(rel - withdraw_rel)
        blackhole_line = body.strip()

for line in bird_text.splitlines():
    m = re.match(r"(\d+) ms \| (.*)", line)
    if not m:
        continue

    rel = int(m.group(1))
    body = m.group(2)

    if rel >= withdraw_rel and "Network not found" in body and bird_route_missing_ms == "NA":
        bird_route_missing_ms = str(rel - withdraw_rel)
        bird_route_missing_line = body.strip()

for line in bgp_text.splitlines():
    m = re.match(r"(\d+) ms \| (.*)", line)
    if not m:
        continue

    rel = int(m.group(1))
    body = m.group(2)

    if rel >= withdraw_rel and "Established" not in body:
        bgp_non_established_seen = "yes"
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

missing_text = " ".join(map(str, missing[:160]))

rows = [
    "timestamp,test_name,blackhole_guard_enabled,r1_r2_path_disabled,withdrawn_prefix,bgp_session_non_established_seen_after_withdraw,old_next_hop_seen_after_withdraw,alternate_next_hop_seen_after_withdraw,blackhole_seen_ms,bird_route_missing_ms,ping_tx,ping_rx,ping_lost,ping_loss_percent,blackhole_line,bird_route_missing_line,missing_ping_sequences",
    f"{ts},bgp_route_withdrawal,yes,yes,10.0.93.0/24,{bgp_non_established_seen},{old_nh_seen_after_withdraw},{alternate_seen_after_withdraw},{blackhole_seen_ms},{bird_route_missing_ms},{tx},{rx},{lost},{loss_percent},\"{blackhole_line}\",\"{bird_route_missing_line}\",\"{missing_text}\""
]

csv.write_text("\n".join(rows) + "\n")
csv_latest.write_text(csv.read_text())

print("BGP non-established seen after withdrawal:", bgp_non_established_seen)
print("Old next-hop seen after withdrawal:", old_nh_seen_after_withdraw)
print("Alternate next-hop seen after withdrawal:", alternate_seen_after_withdraw)
print("Blackhole seen ms:", blackhole_seen_ms)
print("Blackhole line:", blackhole_line)
print("BIRD route missing ms:", bird_route_missing_ms)
print("BIRD route missing line:", bird_route_missing_line)
print("Ping transmitted:", tx)
print("Ping received:", rx)
print("Ping lost:", lost)
print("Ping loss percent:", loss_percent)
print("Missing ping sequences:", missing_text)
print("CSV result saved to:", csv)
PY3

  echo
  echo "9. Evidence files"
  echo "Main output: $OUT"
  echo "Ping log: $PING_LOG"
  echo "Route-get log: $ROUTEGET_LOG"
  echo "BIRD route log: $BIRD_ROUTE_LOG"
  echo "BGP state log: $BGP_STATE_LOG"
  echo "CSV result: $CSV"
  echo "Latest CSV: $CSV_LATEST"

} | tee "$OUT"
