#!/usr/bin/env bash
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)

mkdir -p evidence/final_validation results/final_validation

OUT="evidence/final_validation/final_project_validation_${TS}.txt"
CSV="results/final_validation/final_project_validation_${TS}.csv"
CSV_LATEST="results/final_validation/final_project_validation.csv"

{
  echo "Final Project Validation"
  echo "Date: $(date)"
  echo

  echo "============================================================"
  echo "1. Container status"
  echo "============================================================"
  docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "hpe-r|hpe-h" || true

  echo
  echo "============================================================"
  echo "2. BIRD protocol status"
  echo "============================================================"
  for r in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9; do
    echo
    echo "========== $r =========="
    docker exec "$r" birdc show protocols || true
  done

  echo
  echo "============================================================"
  echo "3. BFD session status"
  echo "============================================================"
  for r in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9; do
    echo
    echo "========== $r BFD =========="
    docker exec "$r" birdc show bfd sessions || true
  done

  echo
  echo "============================================================"
  echo "4. Important route checks"
  echo "============================================================"

  echo
  echo "hpe-r1 route to hpe-h3 network:"
  docker exec hpe-r1 birdc show route 10.0.93.0/24 all || true
  docker exec hpe-r1 ip route get 10.0.93.2 || true

  echo
  echo "hpe-r2 route to hpe-h3 network:"
  docker exec hpe-r2 birdc show route 10.0.93.0/24 all || true
  docker exec hpe-r2 ip route get 10.0.93.2 || true

  echo
  echo "hpe-r3 route to hpe-h2 network:"
  docker exec hpe-r3 birdc show route 10.0.82.0/24 all || true
  docker exec hpe-r3 ip route get 10.0.82.2 || true

  echo
  echo "hpe-r4 route to hpe-h1 network:"
  docker exec hpe-r4 birdc show route 10.0.61.0/24 all || true
  docker exec hpe-r4 ip route get 10.0.61.2 || true

  echo
  echo "============================================================"
  echo "5. End-to-end connectivity"
  echo "============================================================"

  declare -A tests
  tests["h1_to_h2"]="hpe-h1 10.0.82.2"
  tests["h2_to_h1"]="hpe-h2 10.0.61.2"
  tests["h1_to_h3"]="hpe-h1 10.0.93.2"
  tests["h3_to_h1"]="hpe-h3 10.0.61.2"
  tests["h2_to_h3"]="hpe-h2 10.0.93.2"
  tests["h3_to_h2"]="hpe-h3 10.0.82.2"

  echo "timestamp,test,source,target,tx,rx,loss_percent,status" > "$CSV"

  for name in h1_to_h2 h2_to_h1 h1_to_h3 h3_to_h1 h2_to_h3 h3_to_h2; do
    src=$(echo "${tests[$name]}" | awk '{print $1}')
    dst=$(echo "${tests[$name]}" | awk '{print $2}')

    echo
    echo "========== $name: $src -> $dst =========="

    PING_OUT=$(docker exec "$src" ping -c 5 -W 1 "$dst" 2>&1 || true)
    echo "$PING_OUT"

    STATS=$(echo "$PING_OUT" | grep -E "packets transmitted" || true)

    TX=$(echo "$STATS" | awk '{print $1}')
    RX=$(echo "$STATS" | awk '{print $4}')
    LOSS=$(echo "$STATS" | grep -oE '[0-9]+(\.[0-9]+)?% packet loss' | awk '{print $1}' | tr -d '%')

    if [ -z "$TX" ]; then TX="NA"; fi
    if [ -z "$RX" ]; then RX="NA"; fi
    if [ -z "$LOSS" ]; then LOSS="NA"; fi

    if [ "$LOSS" = "0" ] || [ "$LOSS" = "0.0" ]; then
      STATUS="pass"
    else
      STATUS="fail"
    fi

    echo "$TS,$name,$src,$dst,$TX,$RX,$LOSS,$STATUS" >> "$CSV"
  done

  cp "$CSV" "$CSV_LATEST"

  echo
  echo "============================================================"
  echo "6. Documentation files"
  echo "============================================================"

  ls -l \
    docs/results/bfd_wan_edge_failure.md \
    docs/results/ospf_core_link_failure.md \
    docs/results/ospf_ecmp_failover.md \
    docs/results/nssa_type7_type5_translation.md \
    docs/results/ospf_area_healing.md \
    docs/results/bgp_gr_llgr.md \
    report/sections/bfd_wan_edge_failure.tex \
    report/sections/ospf_core_link_failure.tex \
    report/sections/ospf_ecmp_failover.tex \
    report/sections/nssa_type7_type5_translation.tex \
    report/sections/ospf_area_healing.tex \
    report/sections/bgp_gr_llgr.tex

  echo
  echo "============================================================"
  echo "7. Screenshot folders"
  echo "============================================================"

  find screenshots -maxdepth 2 -type f | sort

  echo
  echo "============================================================"
  echo "8. Final CSV"
  echo "============================================================"

  cat "$CSV"

  echo
  echo "Evidence saved to: $OUT"
  echo "CSV saved to: $CSV"
  echo "Latest CSV: $CSV_LATEST"

} | tee "$OUT"
