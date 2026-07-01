#!/usr/bin/env bash
set -u

mkdir -p evidence/ospf_core_link_failure

OUT="evidence/ospf_core_link_failure/ospf_core_link_failure_$(date +%Y%m%d_%H%M%S).txt"
PING_LOG="evidence/ospf_core_link_failure/ping_during_ospf_failure_$(date +%Y%m%d_%H%M%S).log"

FAIL_ROUTER="hpe-r3"
FAIL_IFACE="eth0"
FAILED_NEIGHBOR="hpe-r2"
FAILED_NEXT_HOP="10.0.23.2"
TARGET_IP="10.0.93.2"

restore_link() {
  echo
  echo "Restoring $FAIL_ROUTER $FAIL_IFACE..."
  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" up 2>/dev/null || true
  sleep 10
}

trap restore_link EXIT

ping_loop() {
  END_TIME=$((SECONDS + 18))

  while [ "$SECONDS" -lt "$END_TIME" ]; do
    TS=$(date +%s%3N)

    if docker exec hpe-h1 ping -c 1 -W 1 "$TARGET_IP" >/dev/null 2>&1; then
      echo "$TS OK" >> "$PING_LOG"
    else
      echo "$TS FAIL" >> "$PING_LOG"
    fi

    sleep 0.2
  done
}

{
  echo "OSPF Core Link Failure Test"
  echo "Date: $(date)"
  echo
  echo "Failed link: $FAIL_ROUTER $FAIL_IFACE toward $FAILED_NEIGHBOR"
  echo "Traffic tested: hpe-h1 -> hpe-h3 ($TARGET_IP)"
  echo

  echo "============================================================"
  echo "1. Before failure"
  echo "============================================================"

  echo
  echo "---- $FAIL_ROUTER OSPF neighbors before failure ----"
  docker exec "$FAIL_ROUTER" birdc show ospf neighbors || true

  echo
  echo "---- $FAIL_ROUTER default route before failure ----"
  docker exec "$FAIL_ROUTER" birdc show route 0.0.0.0/0 || true

  echo
  echo "---- Connectivity before failure ----"
  timeout 8 docker exec hpe-h1 ping -c 5 -W 1 "$TARGET_IP" || true

  echo
  echo "============================================================"
  echo "2. Start continuous ping and trigger failure"
  echo "============================================================"

  : > "$PING_LOG"
  ping_loop &
  PING_PID=$!

  sleep 2

  START_MS=$(date +%s%3N)
  echo "Failure start timestamp ms: $START_MS"
  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" down

  echo
  echo "Waiting for hpe-r3 default route to move away from $FAILED_NEXT_HOP..."

  SWITCH_MS=""

  for i in $(seq 1 100); do
    NOW_MS=$(date +%s%3N)

    ROUTE=$(docker exec "$FAIL_ROUTER" birdc show route 0.0.0.0/0 2>/dev/null | grep -E "via|Network not found" || true)
    NEIGH=$(docker exec "$FAIL_ROUTER" birdc show ospf neighbors 2>/dev/null | grep -E "2.2.2.2|1.1.1.1|4.4.4.4|5.5.5.5" || true)

    echo "t+$((NOW_MS - START_MS)) ms | route: ${ROUTE:-not shown}"
    echo "neighbors: ${NEIGH:-not shown}"

    if ! echo "$ROUTE" | grep "$FAILED_NEXT_HOP" >/dev/null; then
      SWITCH_MS=$((NOW_MS - START_MS))
      echo
      echo "Route moved away from failed next-hop after approximately ${SWITCH_MS} ms"
      break
    fi

    sleep 0.05
  done

  wait "$PING_PID" || true

  echo
  echo "============================================================"
  echo "3. State during failure"
  echo "============================================================"

  echo
  echo "---- $FAIL_ROUTER OSPF neighbors during failure ----"
  docker exec "$FAIL_ROUTER" birdc show ospf neighbors || true

  echo
  echo "---- $FAIL_ROUTER default route during failure ----"
  docker exec "$FAIL_ROUTER" birdc show route 0.0.0.0/0 || true

  echo
  echo "---- Connectivity during failure ----"
  timeout 8 docker exec hpe-h1 ping -c 5 -W 1 "$TARGET_IP" || true

  echo
  echo "============================================================"
  echo "4. Restore link"
  echo "============================================================"

  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" up
  sleep 12

  echo
  echo "---- $FAIL_ROUTER OSPF neighbors after restore ----"
  docker exec "$FAIL_ROUTER" birdc show ospf neighbors || true

  echo
  echo "---- $FAIL_ROUTER default route after restore ----"
  docker exec "$FAIL_ROUTER" birdc show route 0.0.0.0/0 || true

  echo
  echo "---- Connectivity after restore ----"
  timeout 8 docker exec hpe-h1 ping -c 5 -W 1 "$TARGET_IP" || true

  echo
  echo "============================================================"
  echo "5. Ping-loop packet loss summary"
  echo "============================================================"

  TOTAL=$(wc -l < "$PING_LOG" | tr -d ' ')
  FAILS=$(grep -c "FAIL" "$PING_LOG" || true)
  OKS=$(grep -c "OK" "$PING_LOG" || true)

  echo "Ping log: $PING_LOG"
  echo "Total ping samples: $TOTAL"
  echo "Successful samples: $OKS"
  echo "Failed samples: $FAILS"

  if [ "$TOTAL" -gt 0 ]; then
    LOSS_PERCENT=$(awk -v f="$FAILS" -v t="$TOTAL" 'BEGIN { printf "%.2f", (f/t)*100 }')
    echo "Approximate packet loss percent during test window: $LOSS_PERCENT%"
  else
    echo "Approximate packet loss percent during test window: unknown"
  fi

  echo
  echo "Approximate route switch time ms: ${SWITCH_MS:-not_detected}"

} | tee "$OUT"

trap - EXIT

echo
echo "Saved OSPF failure evidence to $OUT"
echo "Saved ping loop log to $PING_LOG"
