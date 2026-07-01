#!/usr/bin/env bash
set -u

OUT="evidence/baseline_connectivity/baseline_connectivity_$(date +%Y%m%d_%H%M%S).txt"
mkdir -p evidence/baseline_connectivity

{
  echo "HPE BIRD Baseline Connectivity Test"
  echo "Date: $(date)"
  echo

  echo "=============================="
  echo "Host IP and route state"
  echo "=============================="

  for h in hpe-h1 hpe-h2 hpe-h3; do
    echo
    echo "---- $h interfaces ----"
    docker exec "$h" ip -br addr || true

    echo
    echo "---- $h routes ----"
    docker exec "$h" ip route || true
  done

  echo
  echo "=============================="
  echo "Ping tests"
  echo "=============================="

  echo
  echo "hpe-h1 -> hpe-h2"
  docker exec hpe-h1 ping -c 5 10.0.82.2 || true

  echo
  echo "hpe-h2 -> hpe-h1"
  docker exec hpe-h2 ping -c 5 10.0.61.2 || true

  echo
  echo "hpe-h1 -> hpe-h3"
  docker exec hpe-h1 ping -c 5 10.0.93.2 || true

  echo
  echo "hpe-h2 -> hpe-h3"
  docker exec hpe-h2 ping -c 5 10.0.93.2 || true

  echo
  echo "hpe-h1 -> external static prefix 100.100.100.1"
  docker exec hpe-h1 ping -c 5 100.100.100.1 || true

  echo
  echo "=============================="
  echo "BIRD protocol summary"
  echo "=============================="

  for r in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9; do
    echo
    echo "---- $r protocols ----"
    docker exec "$r" birdc show protocols || true
  done

} | tee "$OUT"

echo
echo "Saved baseline test to $OUT"
