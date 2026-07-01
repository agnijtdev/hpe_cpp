#!/usr/bin/env bash
set -u

mkdir -p evidence/recovery

TS=$(date +%Y%m%d_%H%M%S)
OUT="evidence/recovery/recovery_after_reboot_${TS}.txt"

ROUTERS="hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9"
HOSTS="hpe-h1 hpe-h2 hpe-h3"
ALL="$ROUTERS $HOSTS"

{
  echo "Recovery After Reboot"
  echo "Date: $(date)"
  echo

  echo "============================================================"
  echo "1. Starting containers"
  echo "============================================================"

  for c in $ALL; do
    echo "Starting $c ..."
    docker start "$c" >/dev/null 2>&1 && echo "$c started" || echo "$c start failed or already running"
  done

  echo
  echo "Waiting for containers to settle..."
  sleep 5

  echo
  echo "============================================================"
  echo "2. Container status"
  echo "============================================================"
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Networks}}" | grep -E "NAMES|^hpe-" || true

  echo
  echo "============================================================"
  echo "3. Starting or checking BIRD on routers"
  echo "============================================================"

  for r in $ROUTERS; do
    echo
    echo "---- $r ----"
    docker exec "$r" sh -lc '
      mkdir -p /run/bird

      if pgrep -x bird >/dev/null; then
        echo "bird_running"
        birdc show protocols >/dev/null 2>&1 && echo "birdc_ok" || echo "birdc_failed"
      else
        echo "bird_not_running"
        rm -f /run/bird/bird.ctl /run/bird/bird.pid 2>/dev/null || true
        bird -c /etc/bird/bird.conf && echo "bird_started" || echo "bird_start_failed"
      fi
    ' || true
  done

  echo
  echo "============================================================"
  echo "4. Running existing recovery helpers if present"
  echo "============================================================"

  if [ -f scripts/fix_runtime_forwarding.sh ]; then
    echo "Running scripts/fix_runtime_forwarding.sh"
    bash scripts/fix_runtime_forwarding.sh || true
  else
    echo "scripts/fix_runtime_forwarding.sh not found, skipping"
  fi

  echo

  if [ -f scripts/fix_bird_interfaces_after_reboot.py ]; then
    echo "Running scripts/fix_bird_interfaces_after_reboot.py"
    python3 scripts/fix_bird_interfaces_after_reboot.py || true
  else
    echo "scripts/fix_bird_interfaces_after_reboot.py not found, skipping"
  fi

  echo
  echo "============================================================"
  echo "5. Reconfiguring BIRD after recovery"
  echo "============================================================"

  for r in $ROUTERS; do
    echo
    echo "---- $r birdc configure ----"
    docker exec "$r" sh -lc '
      birdc configure || true
      birdc show protocols || true
    ' || true
  done

  echo
  echo "Waiting 25 seconds for OSPF/BGP/BFD to settle..."
  sleep 25

  echo
  echo "============================================================"
  echo "6. Final quick health check"
  echo "============================================================"

  echo
  echo "---- Protocol summary ----"
  for r in $ROUTERS; do
    echo
    echo "---- $r ----"
    docker exec "$r" birdc show protocols | grep -E "ospf|bgp|bfd|BGP|OSPF|up|Established|Running" || true
  done

  echo
  echo "---- Quick pings ----"

  echo
  echo "hpe-h1 -> hpe-h2"
  docker exec hpe-h1 ping -c 3 -W 1 10.0.82.2 || true

  echo
  echo "hpe-h1 -> hpe-h3"
  docker exec hpe-h1 ping -c 3 -W 1 10.0.93.2 || true

  echo
  echo "hpe-h3 -> hpe-h1"
  docker exec hpe-h3 ping -c 3 -W 1 10.0.61.2 || true

  echo
  echo "Saved recovery evidence to $OUT"

} | tee "$OUT"
