#!/usr/bin/env bash
set -euo pipefail

IMAGE="bird-router:latest"
CONFIG_DIR="$HOME/Documents/HPE_bird/configs"

echo "[1/7] Removing only old router containers r1-r9 if any exist..."
for r in r1 r2 r3 r4 r5 r6 r7 r8 r9; do
  docker rm -f "$r" >/dev/null 2>&1 || true
done

echo "[2/7] Creating router containers on default bridge first..."
for r in r1 r2 r3 r4 r5 r6 r7 r8 r9; do
  docker run -dit --privileged --name "$r" "$IMAGE" bash >/dev/null
done

echo "[3/7] Connecting routers to old topology networks in expected interface order..."

# r1:
# eth1 -> r1-r2, eth2 -> r1-r3, eth3 -> r1-r4, eth4 -> r1-r9
docker network connect --ip 10.0.12.2 net_r1_r2 r1
docker network connect --ip 10.0.13.2 net_r1_r3 r1
docker network connect --ip 10.0.14.2 net_r1_r4 r1
docker network connect --ip 10.0.19.2 net_r1_r9 r1

# r2:
# eth1 -> r1-r2, eth2 -> r2-r3, eth3 -> r2-r4, eth4 -> r2-r9
docker network connect --ip 10.0.12.3 net_r1_r2 r2
docker network connect --ip 10.0.23.2 net_r2_r3 r2
docker network connect --ip 10.0.24.2 net_r2_r4 r2
docker network connect --ip 10.0.29.2 net_r2_r9 r2

# r3:
# eth1 -> r1-r3, eth2 -> r2-r3, eth3 -> r3-r4, eth4 -> r3-r5
docker network connect --ip 10.0.13.3 net_r1_r3 r3
docker network connect --ip 10.0.23.3 net_r2_r3 r3
docker network connect --ip 10.0.34.2 net_r3_r4 r3
docker network connect --ip 10.0.35.2 net_r3_r5 r3

# r4:
# eth1 -> r1-r4, eth2 -> r2-r4, eth3 -> r3-r4, eth4 -> r4-r7
docker network connect --ip 10.0.14.3 net_r1_r4 r4
docker network connect --ip 10.0.24.3 net_r2_r4 r4
docker network connect --ip 10.0.34.3 net_r3_r4 r4
docker network connect --ip 10.0.47.2 net_r4_r7 r4

# r5:
# eth1 -> r3-r5, eth2 -> r5-r6
docker network connect --ip 10.0.35.3 net_r3_r5 r5
docker network connect --ip 10.0.56.2 net_r5_r6 r5

# r6:
# eth1 -> r5-r6, eth2 -> h1-r6
docker network connect --ip 10.0.56.3 net_r5_r6 r6
docker network connect --ip 10.0.61.3 net_h1_r6 r6

# r7:
# eth1 -> r4-r7, eth2 -> r7-r8
docker network connect --ip 10.0.47.3 net_r4_r7 r7
docker network connect --ip 10.0.78.2 net_r7_r8 r7

# r8:
# eth1 -> r7-r8, eth2 -> h2-r8
docker network connect --ip 10.0.78.3 net_r7_r8 r8
docker network connect --ip 10.0.82.3 net_h2_r8 r8

# r9:
# eth1 -> r1-r9, eth2 -> r2-r9, eth3 -> h3-r9
docker network connect --ip 10.0.19.3 net_r1_r9 r9
docker network connect --ip 10.0.29.3 net_r2_r9 r9
docker network connect --ip 10.0.93.3 net_h3_r9 r9

echo "[4/7] Copying saved BIRD configs..."
for r in r1 r2 r3 r4 r5 r6 r7 r8 r9; do
  docker exec "$r" mkdir -p /etc/bird /run/bird
  docker cp "$CONFIG_DIR/$r.conf" "$r:/etc/bird/bird.conf"
done

echo "[5/7] Enabling forwarding and starting BIRD..."
for r in r1 r2 r3 r4 r5 r6 r7 r8 r9; do
  docker exec "$r" sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
  docker exec -d "$r" bird -c /etc/bird/bird.conf -s /run/bird/bird.ctl -d
done

echo "[6/7] Updating host default routes through routers..."
docker start h1 h2 h3 >/dev/null 2>&1 || true

docker exec h1 ip route replace default via 10.0.61.3 || true
docker exec h2 ip route replace default via 10.0.82.3 || true
docker exec h3 ip route replace default via 10.0.93.3 || true

echo "[7/7] Restore complete."
echo
echo "Check routers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | grep -E "^(r[1-9]|h[1-3])" || true
