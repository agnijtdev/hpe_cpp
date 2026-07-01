#!/usr/bin/env bash
set -u

mkdir -p evidence/validation

OUT="evidence/validation/validation_$(date +%Y%m%d_%H%M%S).txt"

{
  echo "HPE BIRD Lab Validation"
  echo "Date: $(date)"
  echo

  echo "============================================================"
  echo "1. Container networks"
  echo "============================================================"
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Networks}}" | grep -E "NAMES|^hpe-"

  echo
  echo "============================================================"
  echo "2. BIRD protocol state"
  echo "============================================================"

  for r in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9; do
    echo
    echo "---- $r protocols ----"
    docker exec "$r" birdc show protocols || true
  done

  echo
  echo "============================================================"
  echo "3. OSPF neighbors"
  echo "============================================================"

  for r in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8; do
    echo
    echo "---- $r OSPF neighbors ----"
    docker exec "$r" birdc show ospf neighbors || true
  done

  echo
  echo "============================================================"
  echo "4. Default routes"
  echo "============================================================"

  for r in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9; do
    echo
    echo "---- $r BIRD default route ----"
    docker exec "$r" birdc show route 0.0.0.0/0 || true

    echo
    echo "---- $r kernel default route ----"
    docker exec "$r" ip route | grep '^default' || echo "No kernel default route"
  done

  echo
  echo "============================================================"
  echo "5. Route decisions"
  echo "============================================================"

  for n in hpe-h1 hpe-r6 hpe-r5 hpe-r3 hpe-r1 hpe-r2 hpe-r9; do
    echo
    echo "---- $n route to external host hpe-h3 10.0.93.2 ----"
    docker exec "$n" ip route get 10.0.93.2 || true
  done

  echo
  echo "============================================================"
  echo "6. End-to-end connectivity"
  echo "============================================================"

  echo
  echo "hpe-h1 -> hpe-h2"
  timeout 8 docker exec hpe-h1 ping -c 5 -W 1 10.0.82.2 || true

  echo
  echo "hpe-h2 -> hpe-h1"
  timeout 8 docker exec hpe-h2 ping -c 5 -W 1 10.0.61.2 || true

  echo
  echo "hpe-h1 -> hpe-h3"
  timeout 8 docker exec hpe-h1 ping -c 5 -W 1 10.0.93.2 || true

  echo
  echo "hpe-h2 -> hpe-h3"
  timeout 8 docker exec hpe-h2 ping -c 5 -W 1 10.0.93.2 || true

  echo
  echo "hpe-h3 -> hpe-h1"
  timeout 8 docker exec hpe-h3 ping -c 5 -W 1 10.0.61.2 || true

  echo
  echo "hpe-h3 -> hpe-h2"
  timeout 8 docker exec hpe-h3 ping -c 5 -W 1 10.0.82.2 || true

} | tee "$OUT"

echo
echo "Saved validation evidence to $OUT"
