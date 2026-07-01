#!/usr/bin/env bash
set -e

echo "[1/3] Enable IP forwarding on HPE routers..."
for r in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9; do
  docker exec "$r" sysctl -w net.ipv4.ip_forward=1 >/dev/null
done

echo "[2/3] Fix internal router default routes..."
docker exec hpe-r6 ip route replace default via 10.0.56.2
docker exec hpe-r5 ip route replace default via 10.0.35.2
docker exec hpe-r8 ip route replace default via 10.0.78.2
docker exec hpe-r7 ip route replace default via 10.0.47.2

echo "[3/3] Fix host default routes..."
docker exec hpe-h1 ip route replace default via 10.0.61.3
docker exec hpe-h2 ip route replace default via 10.0.82.3
docker exec hpe-h3 ip route replace default via 10.0.93.3

echo "Done. Testing h1 <-> h2..."
docker exec hpe-h1 ping -c 3 10.0.82.2
docker exec hpe-h2 ping -c 3 10.0.61.2
