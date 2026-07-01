#!/bin/sh
# entrypoint.sh — Start BIRD daemon then launch tunnel_manager.py
set -e

echo "[AS3] Starting BIRD BGP daemon..."
/usr/sbin/bird -f -c /etc/bird/bird.conf &
BIRD_PID=$!

# Wait for BIRD socket to be ready
for i in $(seq 1 15); do
  [ -S /run/bird/bird.ctl ] && break
  echo "[AS3] Waiting for BIRD socket... ($i/15)"
  sleep 1
done

echo "[AS3] BIRD is up (PID $BIRD_PID)"
echo "[AS3] Starting BGPoST Tunnel Manager..."

python3 /usr/local/bin/tunnel_manager.py \
  --cert-config /certs/bgpost_config.json \
  --main-iface  eth0 \
  --backup-iface eth1 \
  --log-level INFO &
TUNNEL_PID=$!

echo "[AS3] Tunnel Manager PID: $TUNNEL_PID"
echo "[AS3] All services running. Waiting..."

# If either process dies, exit so Docker can restart
wait -n $BIRD_PID $TUNNEL_PID
echo "[AS3] A subprocess exited. Shutting down."
kill $BIRD_PID $TUNNEL_PID 2>/dev/null || true