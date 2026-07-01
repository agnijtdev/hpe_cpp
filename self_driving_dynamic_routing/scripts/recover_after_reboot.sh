#!/usr/bin/env bash
set -u

ROUTERS="hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9"
HOSTS="hpe-h1 hpe-h2 hpe-h3"
ALL="$ROUTERS $HOSTS"

echo "Recovering HPE BIRD lab after reboot..."
echo

echo "1. Starting HPE containers if stopped..."
for c in $ALL; do
  RUNNING=$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo "missing")
  if [ "$RUNNING" = "true" ]; then
    echo "  - $c already running"
  elif [ "$RUNNING" = "false" ]; then
    echo "  - starting $c"
    docker start "$c" >/dev/null
  else
    echo "  - $c missing"
  fi
done

sleep 3

echo
echo "2. Ensuring BIRD daemon is running on routers..."
for r in $ROUTERS; do
  echo "  - $r"
  docker exec "$r" sh -lc '
    mkdir -p /run/bird
    if pgrep -x bird >/dev/null; then
      echo "    bird already running"
    else
      echo "    starting bird"
      bird -c /etc/bird/bird.conf
    fi
  ' || true
done

sleep 3

echo
echo "3. Restoring host default routes..."
docker exec hpe-h1 ip route replace default via 10.0.61.3 || true
docker exec hpe-h2 ip route replace default via 10.0.82.3 || true
docker exec hpe-h3 ip route replace default via 10.0.93.3 || true

echo
echo "4. Removing Docker gateway-style default routes from routers..."
for r in $ROUTERS; do
  echo "  - $r"
  docker network disconnect bridge "$r" 2>/dev/null || true

  docker exec "$r" sh -lc "ip route show default | awk '/via .*\\.1/ {print \$3}' | while read gw; do ip route del default via \$gw 2>/dev/null || true; done" || true
done

echo
echo "5. Reconfiguring BIRD..."
for r in $ROUTERS; do
  echo "  - $r"
  docker exec "$r" birdc configure >/dev/null 2>&1 || true
done

echo
echo "6. Waiting for OSPF/BGP to settle..."
sleep 25

echo
echo "7. Quick protocol check..."
for r in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9; do
  echo
  echo "---- $r protocols ----"
  docker exec "$r" birdc show protocols 2>/dev/null | grep -E "OSPF|BGP|Established|Running|BFD|Static" || true
done

echo
echo "Recovery script completed."
