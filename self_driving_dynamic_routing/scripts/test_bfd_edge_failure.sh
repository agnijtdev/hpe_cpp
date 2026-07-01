#!/usr/bin/env bash
set -u

mkdir -p evidence/bfd_edge_failure

OUT="evidence/bfd_edge_failure/bfd_edge_failure_$(date +%Y%m%d_%H%M%S).txt"

FAIL_ROUTER="hpe-r2"
FAIL_IFACE="eth4"
PEER_ROUTER="hpe-r9"
PEER_IP="10.0.29.3"

restore_link() {
  echo
  echo "Restoring $FAIL_ROUTER $FAIL_IFACE..."
  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" up 2>/dev/null || true
  sleep 8
}

trap restore_link EXIT

{
  echo "BFD Edge Failure Test"
  echo "Date: $(date)"
  echo
  echo "Failing link: $FAIL_ROUTER $FAIL_IFACE toward $PEER_ROUTER"
  echo "BFD peer IP: $PEER_IP"
  echo

  echo "============================================================"
  echo "1. Before failure"
  echo "============================================================"

  echo
  echo "---- $FAIL_ROUTER BFD sessions ----"
  docker exec "$FAIL_ROUTER" birdc show bfd sessions || true

  echo
  echo "---- $FAIL_ROUTER BGP protocols ----"
  docker exec "$FAIL_ROUTER" birdc show protocols || true

  echo
  echo "---- Connectivity before failure: hpe-h1 -> hpe-h3 ----"
  timeout 8 docker exec hpe-h1 ping -c 5 -W 1 10.0.93.2 || true

  echo
  echo "============================================================"
  echo "2. Trigger failure"
  echo "============================================================"

  START_MS=$(date +%s%3N)
  echo "Failure start timestamp ms: $START_MS"
  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" down

  echo
  echo "Waiting for BFD/BGP session to go down..."

  DETECT_MS=""
  for i in $(seq 1 80); do
    NOW_MS=$(date +%s%3N)

    BFD_STATE=$(docker exec "$FAIL_ROUTER" birdc show bfd sessions 2>/dev/null | grep "$PEER_IP" || true)
    BGP_STATE=$(docker exec "$FAIL_ROUTER" birdc show protocols 2>/dev/null | grep -E "^r9[[:space:]]+BGP" || true)

    echo "t+$((NOW_MS - START_MS)) ms | BFD: ${BFD_STATE:-not shown} | BGP: ${BGP_STATE:-not shown}"

    if echo "$BFD_STATE $BGP_STATE" | grep -E "Down|down|start|Active|Passive|Idle|not shown" >/dev/null; then
      DETECT_MS=$((NOW_MS - START_MS))
      echo
      echo "Detected failure after approximately ${DETECT_MS} ms"
      break
    fi

    sleep 0.05
  done

  if [ -z "$DETECT_MS" ]; then
    echo
    echo "Failure was not detected within polling window."
  fi

  echo
  echo "============================================================"
  echo "3. State during failure"
  echo "============================================================"

  echo
  echo "---- $FAIL_ROUTER BFD sessions during failure ----"
  docker exec "$FAIL_ROUTER" birdc show bfd sessions || true

  echo
  echo "---- $FAIL_ROUTER BGP protocols during failure ----"
  docker exec "$FAIL_ROUTER" birdc show protocols || true

  echo
  echo "---- Default route on hpe-r3 during failure ----"
  docker exec hpe-r3 birdc show route 0.0.0.0/0 || true

  echo
  echo "---- Connectivity during failure: hpe-h1 -> hpe-h3 ----"
  timeout 8 docker exec hpe-h1 ping -c 5 -W 1 10.0.93.2 || true

  echo
  echo "============================================================"
  echo "4. Restore link"
  echo "============================================================"

  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" up
  sleep 10

  echo
  echo "---- $FAIL_ROUTER BFD sessions after restore ----"
  docker exec "$FAIL_ROUTER" birdc show bfd sessions || true

  echo
  echo "---- $FAIL_ROUTER BGP protocols after restore ----"
  docker exec "$FAIL_ROUTER" birdc show protocols || true

  echo
  echo "---- Connectivity after restore: hpe-h1 -> hpe-h3 ----"
  timeout 8 docker exec hpe-h1 ping -c 5 -W 1 10.0.93.2 || true

  echo
  echo "============================================================"
  echo "5. Result summary"
  echo "============================================================"
  echo "Approximate detection time ms: ${DETECT_MS:-not_detected}"

} | tee "$OUT"

trap - EXIT

echo
echo "Saved BFD failure evidence to $OUT"
