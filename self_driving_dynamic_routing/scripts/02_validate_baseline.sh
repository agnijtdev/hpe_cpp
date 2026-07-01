#!/usr/bin/env bash
set -u

mkdir -p evidence/baseline
mkdir -p results/baseline

TS=$(date +%Y%m%d_%H%M%S)
OUT="evidence/baseline/baseline_validation_${TS}.txt"
CSV="results/baseline/baseline_connectivity_${TS}.csv"
LATEST_CSV="results/baseline/baseline_connectivity.csv"

ROUTERS="hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9"
OSPF_ROUTERS="hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8"

ping_test() {
  local name="$1"
  local src="$2"
  local dst="$3"

  echo
  echo "---- $name ----"
  RESULT=$(docker exec "$src" ping -c 5 -W 1 "$dst" 2>&1 || true)
  echo "$RESULT"

  LOSS=$(echo "$RESULT" | grep -oE '[0-9]+(\.[0-9]+)?% packet loss' | awk '{print $1}' || echo "unknown")
  TX=$(echo "$RESULT" | grep -oE '[0-9]+ packets transmitted' | awk '{print $1}' || echo "unknown")
  RX=$(echo "$RESULT" | grep -oE '[0-9]+ received' | awk '{print $1}' || echo "unknown")

  echo "$name,$src,$dst,$TX,$RX,$LOSS" >> "$CSV"
}

{
  echo "Baseline Validation"
  echo "Date: $(date)"
  echo

  echo "============================================================"
  echo "1. Container status"
  echo "============================================================"
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Networks}}" | grep -E "NAMES|^hpe-" || true

  echo
  echo "============================================================"
  echo "2. BIRD protocol status"
  echo "============================================================"

  for r in $ROUTERS; do
    echo
    echo "---- $r protocols ----"
    docker exec "$r" birdc show protocols || true
  done

  echo
  echo "============================================================"
  echo "3. OSPF neighbours"
  echo "============================================================"

  for r in $OSPF_ROUTERS; do
    echo
    echo "---- $r OSPF neighbours ----"
    docker exec "$r" birdc show ospf neighbors || true
  done

  echo
  echo "============================================================"
  echo "4. BGP routes and sessions"
  echo "============================================================"

  for r in hpe-r1 hpe-r2 hpe-r9; do
    echo
    echo "---- $r BGP details ----"
    docker exec "$r" birdc show protocols all | grep -E "BGP state|Neighbor address|Neighbor AS|Local AS|Graceful restart|Long-lived graceful restart|Established" || true
  done

  echo
  echo "---- hpe-r1 route to hpe-h3 network ----"
  docker exec hpe-r1 birdc show route 10.0.93.0/24 all || true

  echo
  echo "---- hpe-r2 route to hpe-h3 network ----"
  docker exec hpe-r2 birdc show route 10.0.93.0/24 all || true

  echo
  echo "---- hpe-r9 route to hpe-h1 network ----"
  docker exec hpe-r9 birdc show route 10.0.61.0/24 all || true

  echo
  echo "---- hpe-r9 route to hpe-h2 network ----"
  docker exec hpe-r9 birdc show route 10.0.82.0/24 all || true

  echo
  echo "============================================================"
  echo "5. BFD sessions"
  echo "============================================================"

  for r in hpe-r1 hpe-r2 hpe-r9; do
    echo
    echo "---- $r BFD sessions ----"
    docker exec "$r" birdc show bfd sessions || true
  done

  echo
  echo "============================================================"
  echo "6. Important default routes"
  echo "============================================================"

  for r in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8; do
    echo
    echo "---- $r default route ----"
    docker exec "$r" birdc show route 0.0.0.0/0 || true
  done

  echo
  echo "============================================================"
  echo "7. End-to-end connectivity"
  echo "============================================================"

  echo "test_name,source,target,packets_transmitted,packets_received,packet_loss" > "$CSV"

  ping_test "h1_to_h2" "hpe-h1" "10.0.82.2"
  ping_test "h2_to_h1" "hpe-h2" "10.0.61.2"
  ping_test "h1_to_h3" "hpe-h1" "10.0.93.2"
  ping_test "h2_to_h3" "hpe-h2" "10.0.93.2"
  ping_test "h3_to_h1" "hpe-h3" "10.0.61.2"
  ping_test "h3_to_h2" "hpe-h3" "10.0.82.2"

  cp "$CSV" "$LATEST_CSV"

  echo
  echo "============================================================"
  echo "8. CSV result"
  echo "============================================================"
  cat "$CSV"

  echo
  echo "Saved evidence to $OUT"
  echo "Saved CSV to $CSV"
  echo "Updated latest CSV at $LATEST_CSV"

} | tee "$OUT"
