#!/usr/bin/env bash
set -u

mkdir -p evidence/recovery

TS=$(date +%Y%m%d_%H%M%S)
OUT="evidence/recovery/data_plane_fix_after_reboot_${TS}.txt"

ROUTERS="hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9"
OSPF_ROUTERS="hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8"

{
  echo "Data-plane Fix After Reboot"
  echo "Date: $(date)"
  echo

  echo "============================================================"
  echo "1. Ensure all containers are running"
  echo "============================================================"

  for c in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9 hpe-h1 hpe-h2 hpe-h3; do
    docker start "$c" >/dev/null 2>&1 || true
  done

  sleep 3

  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Networks}}" | grep -E "NAMES|^hpe-" || true

  echo
  echo "============================================================"
  echo "2. Enable router forwarding"
  echo "============================================================"

  for r in $ROUTERS; do
    echo
    echo "---- $r forwarding ----"
    docker exec "$r" sh -lc '
      sysctl -w net.ipv4.ip_forward=1
      sysctl -w net.ipv4.conf.all.rp_filter=0
      sysctl -w net.ipv4.conf.default.rp_filter=0
    ' || true
  done

  echo
  echo "============================================================"
  echo "3. Re-add host default routes"
  echo "============================================================"

  echo "hpe-h1 default via hpe-r6"
  docker exec hpe-h1 ip route replace default via 10.0.61.3 || true
  docker exec hpe-h1 ip route || true

  echo
  echo "hpe-h2 default via hpe-r8"
  docker exec hpe-h2 ip route replace default via 10.0.82.3 || true
  docker exec hpe-h2 ip route || true

  echo
  echo "hpe-h3 default via hpe-r9"
  docker exec hpe-h3 ip route replace default via 10.0.93.3 || true
  docker exec hpe-h3 ip route || true

  echo
  echo "============================================================"
  echo "4. Run existing recovery helpers"
  echo "============================================================"

  if [ -f scripts/fix_runtime_forwarding.sh ]; then
    echo "Running scripts/fix_runtime_forwarding.sh"
    bash scripts/fix_runtime_forwarding.sh || true
  else
    echo "scripts/fix_runtime_forwarding.sh not found"
  fi

  echo

  if [ -f scripts/fix_bird_interfaces_after_reboot.py ]; then
    echo "Running scripts/fix_bird_interfaces_after_reboot.py"
    python3 scripts/fix_bird_interfaces_after_reboot.py || true
  else
    echo "scripts/fix_bird_interfaces_after_reboot.py not found"
  fi

  echo
  echo "============================================================"
  echo "5. Start/reconfigure BIRD"
  echo "============================================================"

  for r in $ROUTERS; do
    echo
    echo "---- $r ----"
    docker exec "$r" sh -lc '
      mkdir -p /run/bird

      if ! pgrep -x bird >/dev/null; then
        rm -f /run/bird/bird.ctl /run/bird/bird.pid 2>/dev/null || true
        bird -c /etc/bird/bird.conf || true
        sleep 1
      fi

      birdc configure || true
      birdc show protocols || true
    ' || true
  done

  echo
  echo "============================================================"
  echo "6. Refresh OSPF after reboot"
  echo "============================================================"

  echo "Disabling OSPF temporarily..."
  for r in $OSPF_ROUTERS; do
    docker exec "$r" birdc disable ospf1 >/dev/null 2>&1 || true
  done

  sleep 3

  echo "Enabling OSPF again..."
  for r in $OSPF_ROUTERS; do
    docker exec "$r" birdc enable ospf1 >/dev/null 2>&1 || true
  done

  echo "Waiting 35 seconds for OSPF/BGP/BFD to settle..."
  sleep 35

  echo
  echo "============================================================"
  echo "7. Route sanity checks"
  echo "============================================================"

  echo
  echo "---- hpe-r3 default route ----"
  docker exec hpe-r3 birdc show route 0.0.0.0/0 || true
  docker exec hpe-r3 ip route get 10.0.93.2 || true

  echo
  echo "---- hpe-r4 default route ----"
  docker exec hpe-r4 birdc show route 0.0.0.0/0 || true
  docker exec hpe-r4 ip route get 10.0.93.2 || true

  echo
  echo "---- hpe-r9 routes to internal networks ----"
  docker exec hpe-r9 birdc show route 10.0.61.0/24 || true
  docker exec hpe-r9 birdc show route 10.0.82.0/24 || true

  echo
  echo "============================================================"
  echo "8. Protocol sanity checks"
  echo "============================================================"

  for r in $ROUTERS; do
    echo
    echo "---- $r protocols ----"
    docker exec "$r" birdc show protocols | grep -E "ospf|bgp|bfd|Established|Running|up" || true
  done

  echo
  echo "============================================================"
  echo "9. Final ping tests"
  echo "============================================================"

  echo
  echo "hpe-h1 -> hpe-h2"
  docker exec hpe-h1 ping -c 5 -W 1 10.0.82.2 || true

  echo
  echo "hpe-h2 -> hpe-h1"
  docker exec hpe-h2 ping -c 5 -W 1 10.0.61.2 || true

  echo
  echo "hpe-h1 -> hpe-h3"
  docker exec hpe-h1 ping -c 5 -W 1 10.0.93.2 || true

  echo
  echo "hpe-h3 -> hpe-h1"
  docker exec hpe-h3 ping -c 5 -W 1 10.0.61.2 || true

  echo
  echo "Saved data-plane recovery evidence to $OUT"

} | tee "$OUT"
