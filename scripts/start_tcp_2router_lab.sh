#!/usr/bin/env bash
set -e

wait_for_bgp() {
  local router="$1"
  local protocol="$2"
  local timeout="$3"

  echo "Waiting for $router:$protocol to reach Established..."

  for i in $(seq 1 "$timeout"); do
    if docker exec "$router" birdc show protocols | grep -q "$protocol.*Established"; then
      echo "$router:$protocol is Established."
      return 0
    fi

    sleep 1
  done

  echo "ERROR: $router:$protocol did not reach Established within ${timeout}s."
  echo
  docker exec "$router" birdc show protocols
  return 1
}

echo "Cleaning old containers and network..."
docker rm -f r1 r2 2>/dev/null || true
docker network rm bgpost_net12 2>/dev/null || true

echo "Creating Docker network bgpost_net12..."
docker network create --subnet 172.30.12.0/24 bgpost_net12 >/dev/null

echo "Starting r1..."
docker run -dit \
  --name r1 \
  --hostname r1 \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --network bgpost_net12 \
  --ip 172.30.12.11 \
  bgpost-router >/dev/null

echo "Starting r2..."
docker run -dit \
  --name r2 \
  --hostname r2 \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --network bgpost_net12 \
  --ip 172.30.12.12 \
  bgpost-router >/dev/null

echo "Copying BIRD configs..."
docker cp configs/r1/bird.conf r1:/etc/bird/bird.conf
docker cp configs/r2/bird.conf r2:/etc/bird/bird.conf

echo "Validating BIRD configs..."
docker exec r1 bird -p -c /etc/bird/bird.conf
docker exec r2 bird -p -c /etc/bird/bird.conf

echo "Starting BIRD..."
docker exec r1 bird -c /etc/bird/bird.conf
docker exec r2 bird -c /etc/bird/bird.conf

wait_for_bgp r1 to_r2 30
wait_for_bgp r2 to_r1 30

echo
echo "r1 protocols:"
docker exec r1 birdc show protocols

echo
echo "r2 protocols:"
docker exec r2 birdc show protocols

echo
echo "Checking test prefix on r2:"
docker exec r2 birdc show route 100.100.1.0/24 all || true

echo
echo "Checking TCP port 179:"
docker exec r1 ss -tnp | grep 179 || true
docker exec r2 ss -tnp | grep 179 || true

echo
echo "TCP 2-router BGP lab started successfully."
