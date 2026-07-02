#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CERT_DIR="$PROJECT_DIR/certs/tls_2router"
CONFIG_DIR="$PROJECT_DIR/generated_configs/tls_2router"

IMAGE="bgpost-router-tls-runtime"
NETWORK="bgpost_tls_net12"
SUBNET="172.32.12.0/24"

R1_IP="172.32.12.11"
R2_IP="172.32.12.12"

SOCKET="/run/bird.ctl"

CAPTURE_IN_CONTAINER="/tmp/r2_bgp_tls_startup.pcap"
CAPTURE_ON_HOST="$PROJECT_DIR/captures/r2_bgp_tls_startup.pcap"

mkdir -p "$PROJECT_DIR/captures"

echo "[1/9] Checking required config/cert files..."

for f in \
  "$CONFIG_DIR/r1/bird.conf" \
  "$CONFIG_DIR/r2/bird.conf" \
  "$CERT_DIR/ca.cert.pem" \
  "$CERT_DIR/r1.cert.pem" \
  "$CERT_DIR/r1.key" \
  "$CERT_DIR/r2.cert.pem" \
  "$CERT_DIR/r2.key"
do
  if [ ! -f "$f" ]; then
    echo "ERROR: Missing required file: $f"
    echo "Run ./scripts/start_tls_2router_lab.sh once first."
    exit 1
  fi
done

echo "[2/9] Cleaning old TLS containers/network..."
docker rm -f r1 r2 >/dev/null 2>&1 || true
docker network rm "$NETWORK" >/dev/null 2>&1 || true
rm -f "$CAPTURE_ON_HOST"

echo "[3/9] Creating Docker network..."
docker network create --subnet "$SUBNET" "$NETWORK" >/dev/null

echo "[4/9] Starting TLS-capable router containers without BIRD..."

docker run -dit \
  --name r1 \
  --hostname r1 \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --network "$NETWORK" \
  --ip "$R1_IP" \
  --entrypoint /bin/sh \
  "$IMAGE" -c "sleep 1000000" >/dev/null

docker run -dit \
  --name r2 \
  --hostname r2 \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --network "$NETWORK" \
  --ip "$R2_IP" \
  --entrypoint /bin/sh \
  "$IMAGE" -c "sleep 1000000" >/dev/null

echo "[5/9] Copying configs and certificates..."

docker exec r1 mkdir -p /etc/bird/certs
docker exec r2 mkdir -p /etc/bird/certs

docker cp "$CONFIG_DIR/r1/bird.conf" r1:/etc/bird/bird.conf
docker cp "$CONFIG_DIR/r2/bird.conf" r2:/etc/bird/bird.conf

docker cp "$CERT_DIR/ca.cert.pem" r1:/etc/bird/certs/ca.cert.pem
docker cp "$CERT_DIR/r1.cert.pem" r1:/etc/bird/certs/r1.cert.pem
docker cp "$CERT_DIR/r1.key" r1:/etc/bird/certs/r1.key

docker cp "$CERT_DIR/ca.cert.pem" r2:/etc/bird/certs/ca.cert.pem
docker cp "$CERT_DIR/r2.cert.pem" r2:/etc/bird/certs/r2.cert.pem
docker cp "$CERT_DIR/r2.key" r2:/etc/bird/certs/r2.key

echo "[6/9] Validating configs..."

docker exec r1 /usr/sbin/bird -p -c /etc/bird/bird.conf
docker exec r2 /usr/sbin/bird -p -c /etc/bird/bird.conf

echo "[7/9] Starting tcpdump on r2 before BIRD starts..."

docker exec r2 rm -f "$CAPTURE_IN_CONTAINER" || true

docker exec r2 tcpdump -i eth0 -U -w "$CAPTURE_IN_CONTAINER" tcp port 179 >/tmp/r2_tls_tcpdump.log 2>&1 &
TCPDUMP_PID=$!

sleep 2

echo "[8/9] Starting BIRD on r1 and r2..."

docker exec r1 /usr/sbin/bird -c /etc/bird/bird.conf -s "$SOCKET"
docker exec r2 /usr/sbin/bird -c /etc/bird/bird.conf -s "$SOCKET"

echo "Waiting for TLS BGP session..."
sleep 10

echo "[9/9] Stopping tcpdump and copying capture..."

kill "$TCPDUMP_PID" 2>/dev/null || true
sleep 2

docker cp "r2:$CAPTURE_IN_CONTAINER" "$CAPTURE_ON_HOST"

echo
echo "Capture file:"
ls -lh "$CAPTURE_ON_HOST"

echo
echo "BGP protocol state:"
docker exec r1 /usr/sbin/birdc -s "$SOCKET" show protocols
docker exec r2 /usr/sbin/birdc -s "$SOCKET" show protocols

echo
echo "Route on r2:"
docker exec r2 /usr/sbin/birdc -s "$SOCKET" show route 100.100.1.0/24 all

echo
echo "Raw tcpdump summary:"
tcpdump -nn -r "$CAPTURE_ON_HOST" || true

echo
echo "Checking whether plain BGP is directly visible:"
tshark -r "$CAPTURE_ON_HOST" -Y bgp 2>/dev/null | head -30 || true

echo
echo "Forcing tshark to decode TCP port 179 as TLS:"
tshark -r "$CAPTURE_ON_HOST" -d tcp.port==179,tls -Y tls -V 2>/dev/null \
  | grep -E "Transport Layer Security|TLSv|Handshake Protocol|Client Hello|Server Hello|Certificate|Application Data|Content Type" \
  | head -100 || true

echo
echo "Done."
