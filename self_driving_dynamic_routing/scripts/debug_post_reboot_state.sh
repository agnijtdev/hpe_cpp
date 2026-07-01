#!/usr/bin/env bash
set -u

mkdir -p evidence/post_reboot_debug

OUT="evidence/post_reboot_debug/post_reboot_debug_$(date +%Y%m%d_%H%M%S).txt"

ROUTERS="hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9"
HOSTS="hpe-h1 hpe-h2 hpe-h3"

{
  echo "Post-Reboot Debug State"
  echo "Date: $(date)"
  echo

  echo "============================================================"
  echo "1. Container status"
  echo "============================================================"
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Networks}}" | grep -E "NAMES|^hpe-" || true

  echo
  echo "============================================================"
  echo "2. Router interface/IP mapping"
  echo "============================================================"

  for r in $ROUTERS; do
    echo
    echo "---- $r interfaces ----"
    docker exec "$r" sh -lc "ip -br addr | grep -E 'eth|lo'" || true
  done

  echo
  echo "============================================================"
  echo "3. Host interface/IP/default route mapping"
  echo "============================================================"

  for h in $HOSTS; do
    echo
    echo "---- $h interfaces ----"
    docker exec "$h" sh -lc "ip -br addr | grep -E 'eth|lo'; echo; ip route" || true
  done

  echo
  echo "============================================================"
  echo "4. BIRD protocol state"
  echo "============================================================"

  for r in $ROUTERS; do
    echo
    echo "---- $r protocols ----"
    docker exec "$r" birdc show protocols || true
  done

  echo
  echo "============================================================"
  echo "5. OSPF neighbours"
  echo "============================================================"

  for r in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8; do
    echo
    echo "---- $r OSPF neighbours ----"
    docker exec "$r" birdc show ospf neighbors || true
  done

  echo
  echo "============================================================"
  echo "6. Important routes"
  echo "============================================================"

  for r in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9; do
    echo
    echo "---- $r routes to h1/h2/h3 ----"
    docker exec "$r" sh -lc "
      echo 'route to h1 10.0.61.2:'; ip route get 10.0.61.2 2>/dev/null || true
      echo 'route to h2 10.0.82.2:'; ip route get 10.0.82.2 2>/dev/null || true
      echo 'route to h3 10.0.93.2:'; ip route get 10.0.93.2 2>/dev/null || true
      echo 'default route:'; ip route show default || true
    " || true
  done

  echo
  echo "============================================================"
  echo "7. BIRD config interface lines"
  echo "============================================================"

  for r in $ROUTERS; do
    echo
    echo "---- $r config interface lines ----"
    docker exec "$r" sh -lc "grep -nE 'interface|neighbor|route 0.0.0.0|bfd yes|router id|area' /etc/bird/bird.conf" || true
  done

} | tee "$OUT"

echo
echo "Saved debug evidence to $OUT"
