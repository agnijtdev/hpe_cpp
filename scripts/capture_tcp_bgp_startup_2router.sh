#!/usr/bin/env bash
set -e

CAPTURE_IN_CONTAINER="/tmp/r2_bgp_tcp_startup.pcap"
CAPTURE_ON_HOST="captures/r2_bgp_tcp_startup.pcap"

echo "Cleaning old routers and line networks..."
for i in $(seq 1 50); do
  docker rm -f "r$i" 2>/dev/null || true
done

docker network ls --format '{{.Name}}' | grep '^bgpost_line_net_' | xargs -r docker network rm

echo
echo "Generating 2-router configs..."
python3 scripts/generate_line_configs.py 2

echo
echo "Creating Docker network..."
docker network create --subnet 172.31.11.0/24 bgpost_line_net_1 >/dev/null

echo
echo "Starting r1 and r2..."
docker run -dit \
  --name r1 \
  --hostname r1 \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --network bgpost_line_net_1 \
  --ip 172.31.11.11 \
  bgpost-router >/dev/null

docker run -dit \
  --name r2 \
  --hostname r2 \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --network bgpost_line_net_1 \
  --ip 172.31.11.12 \
  bgpost-router >/dev/null

echo
echo "Copying BIRD configs..."
docker cp generated_configs/tcp_line_2/r1/bird.conf r1:/etc/bird/bird.conf
docker cp generated_configs/tcp_line_2/r2/bird.conf r2:/etc/bird/bird.conf

echo
echo "Validating BIRD configs..."
docker exec r1 bird -p -c /etc/bird/bird.conf
docker exec r2 bird -p -c /etc/bird/bird.conf

echo
echo "Removing old capture files..."
docker exec r2 rm -f "$CAPTURE_IN_CONTAINER" || true
rm -f "$CAPTURE_ON_HOST"

echo
echo "Starting tcpdump on r2 before BIRD starts..."
docker exec r2 tcpdump -i eth0 -U -w "$CAPTURE_IN_CONTAINER" tcp port 179 >/tmp/r2_startup_tcpdump.log 2>&1 &
TCPDUMP_PID=$!

sleep 2

echo
echo "Starting BIRD on r1 and r2..."
docker exec r1 bird -c /etc/bird/bird.conf
docker exec r2 bird -c /etc/bird/bird.conf

echo
echo "Waiting for BGP session and initial route exchange..."
sleep 8

echo
echo "Stopping tcpdump..."
kill "$TCPDUMP_PID" 2>/dev/null || true
sleep 2

echo
echo "Copying capture to host..."
docker cp "r2:$CAPTURE_IN_CONTAINER" "$CAPTURE_ON_HOST"

echo
echo "Capture file:"
ls -lh "$CAPTURE_ON_HOST"

echo
echo "tcpdump summary:"
tcpdump -nn -r "$CAPTURE_ON_HOST" || true

echo
echo "Detailed BGP decode using tshark:"
tshark -r "$CAPTURE_ON_HOST" -Y bgp -V | grep -E "Border Gateway Protocol|Type:|OPEN Message|KEEPALIVE Message|UPDATE Message|Withdrawn Routes|Network Layer Reachability Information|AS_PATH|NEXT_HOP|ORIGIN|100.100.1.0" || true

echo
echo "Done."
