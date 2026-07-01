#!/usr/bin/env bash
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)

mkdir -p evidence/nssa results/nssa configs/nssa_static_before configs/nssa_static_after

OUT="evidence/nssa/nssa_static_external_route_${TS}.txt"
CSV="results/nssa/nssa_static_external_route_${TS}.csv"
CSV_LATEST="results/nssa/nssa_static_external_route.csv"

TEST_NET="172.16.66.0/24"
TEST_IP="172.16.66.1"
ORIGIN_ROUTER="hpe-r6"

{
  echo "Clean NSSA Static External Route Test"
  echo "Date: $(date)"
  echo
  echo "Test external network: $TEST_NET"
  echo "Test IP used only for route-get: $TEST_IP"
  echo "Origin router inside NSSA: $ORIGIN_ROUTER"
  echo "Important: This is a static blackhole test route, so ping is not expected/needed."
  echo

  echo "============================================================"
  echo "1. Remove old loopback test IP if present"
  echo "============================================================"

  docker exec hpe-r6 sh -lc "ip addr del $TEST_IP/24 dev lo 2>/dev/null || true"
  docker exec hpe-r6 ip addr show lo | grep "$TEST_IP" || echo "Loopback test IP removed / not present"

  echo
  echo "============================================================"
  echo "2. Save current hpe-r6 config"
  echo "============================================================"

  docker exec hpe-r6 cat /etc/bird/bird.conf > "configs/nssa_static_before/hpe-r6_bird_${TS}.conf"
  echo "Saved configs/nssa_static_before/hpe-r6_bird_${TS}.conf"

  echo
  echo "============================================================"
  echo "3. Add static blackhole route to hpe-r6 BIRD config"
  echo "============================================================"

  TMP_LOCAL="configs/nssa_static_after/hpe-r6_bird_${TS}.conf"
  cp "configs/nssa_static_before/hpe-r6_bird_${TS}.conf" "$TMP_LOCAL"

  # Remove older copy of this static protocol if script is rerun
  perl -0777 -pi -e 's/\nprotocol static nssa_test_static \{.*?\n\}\n//s' "$TMP_LOCAL"

  cat >> "$TMP_LOCAL" <<'EOF_STATIC'

protocol static nssa_test_static {
    ipv4;
    route 172.16.66.0/24 blackhole;
}
EOF_STATIC

  echo "Added protocol static nssa_test_static to $TMP_LOCAL"

  echo
  echo "============================================================"
  echo "4. Confirm OSPF export filter exists"
  echo "============================================================"

  if grep -q "$TEST_NET" "$TMP_LOCAL"; then
    echo "OSPF export filter for $TEST_NET exists."
  else
    echo "ERROR: OSPF export filter for $TEST_NET not found."
    echo "We need to add the export filter before continuing."
    exit 1
  fi

  echo
  echo "============================================================"
  echo "5. Validate and apply hpe-r6 config"
  echo "============================================================"

  docker cp "$TMP_LOCAL" hpe-r6:/tmp/hpe-r6_nssa_static_test.conf

  echo "Validating candidate config..."
  docker exec hpe-r6 bird -p -c /tmp/hpe-r6_nssa_static_test.conf

  echo "Backing up live config inside hpe-r6..."
  docker exec hpe-r6 cp /etc/bird/bird.conf "/etc/bird/bird.conf.before_nssa_static_${TS}"

  echo "Applying candidate config..."
  docker exec hpe-r6 cp /tmp/hpe-r6_nssa_static_test.conf /etc/bird/bird.conf

  echo "Reloading BIRD..."
  docker exec hpe-r6 birdc configure

  echo "Waiting 10 seconds for OSPF/NSSA propagation..."
  sleep 10

  echo
  echo "============================================================"
  echo "6. Route visibility check"
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
  echo "7. OSPF LSADB Type-7 and Type-5 check"
  echo "============================================================"

  for r in hpe-r6 hpe-r5 hpe-r3 hpe-r1 hpe-r2 hpe-r4 hpe-r8; do
    echo
    echo "========== $r LSADB type 7 =========="
    docker exec "$r" birdc show ospf lsadb type 7 || true

    echo
    echo "========== $r LSADB type 5 =========="
    docker exec "$r" birdc show ospf lsadb type 5 || true
  done

  echo
  echo "============================================================"
  echo "8. Build CSV summary"
  echo "============================================================"

  echo "timestamp,router,route_present,first_route_type,first_route_line" > "$CSV"

  for r in hpe-r6 hpe-r5 hpe-r3 hpe-r1 hpe-r2 hpe-r4 hpe-r8; do
    ROUTE_OUT=$(docker exec "$r" birdc show route "$TEST_NET" all || true)

    if echo "$ROUTE_OUT" | grep -q "$TEST_NET"; then
      PRESENT="yes"
    else
      PRESENT="no"
    fi

    TYPE_LINE=$(echo "$ROUTE_OUT" | grep -m1 "Type:" | sed 's/,/;/g' | xargs || true)
    ROUTE_LINE=$(echo "$ROUTE_OUT" | grep -m1 "$TEST_NET" | sed 's/,/;/g' | xargs || true)

    [ -z "$TYPE_LINE" ] && TYPE_LINE="unknown"
    [ -z "$ROUTE_LINE" ] && ROUTE_LINE=""

    echo "$TS,$r,$PRESENT,$TYPE_LINE,$ROUTE_LINE" >> "$CSV"
  done

  cp "$CSV" "$CSV_LATEST"

  cat "$CSV"

  echo
  echo "============================================================"
  echo "9. Evidence files"
  echo "============================================================"
  echo "Main output: $OUT"
  echo "CSV result: $CSV"
  echo "Latest CSV: $CSV_LATEST"
  echo "Before config: configs/nssa_static_before/hpe-r6_bird_${TS}.conf"
  echo "After config: configs/nssa_static_after/hpe-r6_bird_${TS}.conf"

} | tee "$OUT"
