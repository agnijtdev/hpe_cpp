#!/usr/bin/env bash
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)

mkdir -p evidence/nssa results/nssa configs/nssa_before configs/nssa_after

OUT="evidence/nssa/nssa_external_route_${TS}.txt"
CSV="results/nssa/nssa_external_route_${TS}.csv"
CSV_LATEST="results/nssa/nssa_external_route.csv"

TEST_NET="172.16.66.0/24"
TEST_IP="172.16.66.1"
ORIGIN_ROUTER="hpe-r6"

{
  echo "NSSA External Route Injection Test"
  echo "Date: $(date)"
  echo
  echo "Test external network: $TEST_NET"
  echo "Test external IP: $TEST_IP"
  echo "Origin router inside NSSA: $ORIGIN_ROUTER"
  echo

  echo "============================================================"
  echo "1. Save original hpe-r6 config"
  echo "============================================================"

  docker exec hpe-r6 cat /etc/bird/bird.conf > "configs/nssa_before/hpe-r6_bird_${TS}.conf"
  echo "Saved configs/nssa_before/hpe-r6_bird_${TS}.conf"

  echo
  echo "============================================================"
  echo "2. Add test IP on hpe-r6 loopback"
  echo "============================================================"

  docker exec hpe-r6 sh -lc "ip addr show lo | grep -q '$TEST_IP' || ip addr add $TEST_IP/24 dev lo"
  docker exec hpe-r6 ip addr show lo | grep -E "$TEST_IP|lo" || true

  echo
  echo "============================================================"
  echo "3. Modify hpe-r6 OSPF config to export test route"
  echo "============================================================"

  TMP_LOCAL="configs/nssa_after/hpe-r6_bird_${TS}.conf"
  cp "configs/nssa_before/hpe-r6_bird_${TS}.conf" "$TMP_LOCAL"

  python3 - "$TMP_LOCAL" <<'PY2'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

test_net = "172.16.66.0/24"

if test_net not in text:
    replacement = (
        "protocol ospf ospf1 {\n"
        "    ipv4 {\n"
        "        import all;\n"
        "        export filter {\n"
        f"            if net = {test_net} then {{\n"
        "                ospf_metric2 = 66;\n"
        "                accept;\n"
        "            }\n"
        "            reject;\n"
        "        };\n"
        "    };\n"
    )

    text = re.sub(
        r'protocol\s+ospf\s+ospf1\s*\{',
        replacement,
        text,
        count=1
    )

path.write_text(text)
PY2

  echo "Modified config saved to $TMP_LOCAL"

  echo
  echo "============================================================"
  echo "4. Validate and apply hpe-r6 config"
  echo "============================================================"

  docker cp "$TMP_LOCAL" hpe-r6:/tmp/hpe-r6_nssa_test.conf

  echo "Validating candidate config..."
  docker exec hpe-r6 bird -p -c /tmp/hpe-r6_nssa_test.conf

  echo "Backing up live config inside hpe-r6..."
  docker exec hpe-r6 cp /etc/bird/bird.conf "/etc/bird/bird.conf.before_nssa_${TS}"

  echo "Applying candidate config..."
  docker exec hpe-r6 cp /tmp/hpe-r6_nssa_test.conf /etc/bird/bird.conf

  echo "Reloading BIRD..."
  docker exec hpe-r6 birdc configure

  echo "Waiting 8 seconds for OSPF/NSSA propagation..."
  sleep 8

  echo
  echo "============================================================"
  echo "5. Route visibility check"
  echo "============================================================"

  for r in hpe-r6 hpe-r5 hpe-r3 hpe-r1 hpe-r2 hpe-r4 hpe-r8; do
    echo
    echo "========== $r route to $TEST_NET =========="
    docker exec "$r" birdc show route "$TEST_NET" all || true

    echo
    echo "========== $r kernel route-get to $TEST_IP =========="
    docker exec "$r" ip route get "$TEST_IP" || true
  done

  echo
  echo "============================================================"
  echo "6. OSPF LSADB Type-7 and Type-5 check"
  echo "============================================================"

  for r in hpe-r6 hpe-r5 hpe-r3 hpe-r1 hpe-r2 hpe-r4; do
    echo
    echo "========== $r LSADB type 7 =========="
    docker exec "$r" birdc show ospf lsadb type 7 || true

    echo
    echo "========== $r LSADB type 5 =========="
    docker exec "$r" birdc show ospf lsadb type 5 || true
  done

  echo
  echo "============================================================"
  echo "7. Connectivity check to NSSA external IP"
  echo "============================================================"

  echo
  echo "---- hpe-r5 to $TEST_IP ----"
  docker exec hpe-r5 ping -c 3 -W 1 "$TEST_IP" || true

  echo
  echo "---- hpe-r1 to $TEST_IP ----"
  docker exec hpe-r1 ping -c 3 -W 1 "$TEST_IP" || true

  echo
  echo "---- hpe-h1 to $TEST_IP ----"
  docker exec hpe-h1 ping -c 3 -W 1 "$TEST_IP" || true

  echo
  echo "============================================================"
  echo "8. Build CSV summary"
  echo "============================================================"

  python3 - "$CSV" "$CSV_LATEST" "$TS" <<'PY3'
import subprocess
import sys
from pathlib import Path

csv = Path(sys.argv[1])
latest = Path(sys.argv[2])
ts = sys.argv[3]
routers = ["hpe-r6", "hpe-r5", "hpe-r3", "hpe-r1", "hpe-r2", "hpe-r4", "hpe-r8"]
net = "172.16.66.0/24"

rows = ["timestamp,router,route_present,route_type,route_source_line"]

for r in routers:
    cmd = ["docker", "exec", r, "birdc", "show", "route", net, "all"]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    present = "yes" if net in out else "no"
    route_type = "unknown"
    source_line = ""

    for line in out.splitlines():
        if "Type:" in line:
            route_type = line.strip().replace(",", ";")
        if net in line:
            source_line = line.strip().replace(",", ";")

    rows.append(f"{ts},{r},{present},{route_type},{source_line}")

csv.write_text("\n".join(rows) + "\n")
latest.write_text(csv.read_text())

print(csv.read_text())
print(f"CSV result saved to: {csv}")
print(f"Latest CSV updated: {latest}")
PY3

  echo
  echo "============================================================"
  echo "9. Evidence files"
  echo "============================================================"
  echo "Main output: $OUT"
  echo "CSV result: $CSV"
  echo "Latest CSV: $CSV_LATEST"
  echo "Before config: configs/nssa_before/hpe-r6_bird_${TS}.conf"
  echo "After config: configs/nssa_after/hpe-r6_bird_${TS}.conf"

} | tee "$OUT"
