#!/usr/bin/env bash
set -u

echo "Fixing runtime forwarding for HPE BIRD lab..."
echo

ROUTERS="hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9"

echo "1. Disconnecting default Docker bridge from HPE routers..."
for r in $ROUTERS; do
  echo "  - $r"
  docker network disconnect bridge "$r" 2>/dev/null || true
done

echo
echo "2. Removing Docker gateway-style default routes ending in .1..."
for r in $ROUTERS; do
  echo "  - Cleaning $r"

  docker exec "$r" sh -lc '
    ip route | awk "/^default via/ {print \$3, \$5}" | while read gw dev; do
      case "$gw" in
        *.1)
          echo "    deleting default via $gw dev $dev"
          ip route del default via "$gw" dev "$dev" 2>/dev/null || true
          ;;
        *)
          echo "    keeping default via $gw dev $dev"
          ;;
      esac
    done
  ' 2>/dev/null || true
done

echo
echo "3. Reconfiguring BIRD on all HPE routers..."
for r in $ROUTERS; do
  echo "  - $r"
  docker exec "$r" birdc configure >/dev/null 2>&1 || true
done

sleep 5

echo
echo "4. Final router default routes:"
for r in $ROUTERS; do
  echo
  echo "---- $r ----"
  docker exec "$r" ip route | grep '^default' || echo "No kernel default route"
done

echo
echo "Runtime forwarding cleanup completed."
