#!/usr/bin/env bash
set -u

mkdir -p evidence/bfd results/bfd

TS=$(date +%Y%m%d_%H%M%S)
OUT="evidence/bfd/bfd_alternate_path_verification_${TS}.txt"

FAIL_ROUTER="hpe-r2"
LOCAL_IP="10.0.29.2"
TARGET_IP="10.0.93.2"

restore_link() {
  IFACE=$(docker exec "$FAIL_ROUTER" sh -lc "ip -o -4 addr show | awk -v ip='$LOCAL_IP' '\$4 ~ ip\"/\" {print \$2; exit}'" 2>/dev/null || true)
  if [ -n "$IFACE" ]; then
    docker exec "$FAIL_ROUTER" ip link set "$IFACE" up >/dev/null 2>&1 || true
  fi
}

trap restore_link EXIT

{
  echo "BFD Alternate Path Verification"
  echo "Date: $(date)"
  echo

  FAIL_IFACE=$(docker exec "$FAIL_ROUTER" sh -lc "ip -o -4 addr show | awk -v ip='$LOCAL_IP' '\$4 ~ ip\"/\" {print \$2; exit}'" 2>/dev/null || true)

  echo "Failed router: $FAIL_ROUTER"
  echo "Failed interface: $FAIL_IFACE"
  echo "Target: $TARGET_IP"
  echo

  echo "============================================================"
  echo "1. Before failure"
  echo "============================================================"

  echo
  echo "---- hpe-r2 route to hpe-h3 before failure ----"
  docker exec hpe-r2 ip route get "$TARGET_IP" || true
  docker exec hpe-r2 birdc show route 10.0.93.0/24 all || true

  echo
  echo "---- hpe-r1 route to hpe-h3 before failure ----"
  docker exec hpe-r1 ip route get "$TARGET_IP" || true
  docker exec hpe-r1 birdc show route 10.0.93.0/24 all || true

  echo
  echo "---- hpe-r9 route to internal hpe-h1 network before failure ----"
  docker exec hpe-r9 birdc show route 10.0.61.0/24 all || true

  echo
  echo "============================================================"
  echo "2. Bring down hpe-r2 to hpe-r9 link"
  echo "============================================================"

  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" down

  echo "Waiting 1 second for BFD/BGP reaction..."
  sleep 1

  echo
  echo "---- hpe-r2 BFD after failure ----"
  docker exec hpe-r2 birdc show bfd sessions || true

  echo
  echo "---- hpe-r2 BGP after failure ----"
  docker exec hpe-r2 birdc show protocols || true

  echo
  echo "============================================================"
  echo "3. During failure path check"
  echo "============================================================"

  echo
  echo "---- hpe-r2 route to hpe-h3 during failure ----"
  docker exec hpe-r2 ip route get "$TARGET_IP" || true
  docker exec hpe-r2 birdc show route 10.0.93.0/24 all || true

  echo
  echo "---- hpe-r1 route to hpe-h3 during failure ----"
  docker exec hpe-r1 ip route get "$TARGET_IP" || true
  docker exec hpe-r1 birdc show route 10.0.93.0/24 all || true

  echo
  echo "---- hpe-r9 route to hpe-h1 network during failure ----"
  docker exec hpe-r9 birdc show route 10.0.61.0/24 all || true

  echo
  echo "---- Ping during failure: hpe-h1 to hpe-h3 ----"
  docker exec hpe-h1 ping -c 10 -W 1 "$TARGET_IP" || true

  echo
  echo "============================================================"
  echo "4. Restore link"
  echo "============================================================"

  docker exec "$FAIL_ROUTER" ip link set "$FAIL_IFACE" up

  echo "Waiting 25 seconds for BFD/BGP restore..."
  sleep 25

  echo
  echo "---- hpe-r2 BFD after restore ----"
  docker exec hpe-r2 birdc show bfd sessions || true

  echo
  echo "---- hpe-r2 BGP after restore ----"
  docker exec hpe-r2 birdc show protocols || true

  echo
  echo "---- Final ping ----"
  docker exec hpe-h1 ping -c 5 -W 1 "$TARGET_IP" || true

  echo
  echo "Saved alternate path verification evidence to $OUT"

} | tee "$OUT"

trap - EXIT
restore_link
