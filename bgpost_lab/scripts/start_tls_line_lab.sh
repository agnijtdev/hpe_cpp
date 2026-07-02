#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <number_of_routers>"
  echo "Example: $0 10"
  exit 1
fi

N="$1"
if [ "$N" -lt 2 ]; then
  echo "ERROR: number_of_routers must be at least 2"
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="bgpost-router-tls-runtime"
SOCKET="/run/bird.ctl"

CERT_DIR="$PROJECT_DIR/certs/tls_line_${N}"
CONFIG_DIR="$PROJECT_DIR/generated_configs/tls_line_${N}"
GEN_CERT="$PROJECT_DIR/external/BGPoST-Artifacts/cert-generator/generate_certs.sh"

network_name() {
  echo "bgpost_tls_line_net_$1"
}

subnet_for_link() {
  echo "172.33.$((10 + $1)).0/24"
}

left_ip() {
  echo "172.33.$((10 + $1)).11"
}

right_ip() {
  echo "172.33.$((10 + $1)).12"
}

echo "[1/9] Generating TLS BIRD configs..."
python3 "$PROJECT_DIR/scripts/generate_tls_line_configs.py" "$N"

echo "[2/9] Cleaning old TLS line containers/networks..."
for i in $(seq 1 50); do
  docker rm -f "r$i" >/dev/null 2>&1 || true
done

docker network ls --format '{{.Name}}' | grep '^bgpost_tls_line_net_' | xargs -r docker network rm >/dev/null || true

echo "[3/9] Generating fresh certificates..."
rm -rf "$CERT_DIR"
mkdir -p "$CERT_DIR"

for i in $(seq 1 "$N"); do
  bash "$GEN_CERT" "$CERT_DIR" "r$i" ED25519 "r$i.rtr" "0.0.0.$i" NULL NULL >/dev/null
done

echo "CA certificate:"
ls -lh "$CERT_DIR/ca.cert.pem"

echo "[4/9] Creating Docker networks..."
for link in $(seq 1 $((N - 1))); do
  docker network create \
    --subnet "$(subnet_for_link "$link")" \
    "$(network_name "$link")" >/dev/null
done

echo "[5/9] Starting TLS router containers..."
for i in $(seq 1 "$N"); do
  if [ "$i" -eq 1 ]; then
    first_net="$(network_name 1)"
    first_ip="$(left_ip 1)"
  else
    left_link=$((i - 1))
    first_net="$(network_name "$left_link")"
    first_ip="$(right_ip "$left_link")"
  fi

  docker run -dit \
    --name "r$i" \
    --hostname "r$i" \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    --network "$first_net" \
    --ip "$first_ip" \
    --entrypoint /bin/sh \
    "$IMAGE" -c "sleep 1000000" >/dev/null
done

echo "[6/9] Connecting middle routers to their right-side links..."
if [ "$N" -gt 2 ]; then
  for i in $(seq 2 $((N - 1))); do
    docker network connect \
      --ip "$(left_ip "$i")" \
      "$(network_name "$i")" \
      "r$i"
  done
fi

echo "[7/9] Copying configs and certificates..."
for i in $(seq 1 "$N"); do
  docker exec "r$i" mkdir -p /etc/bird/certs

  docker cp "$CONFIG_DIR/r$i/bird.conf" "r$i:/etc/bird/bird.conf" >/dev/null

  docker cp "$CERT_DIR/ca.cert.pem" "r$i:/etc/bird/certs/ca.cert.pem" >/dev/null
  docker cp "$CERT_DIR/r$i.cert.pem" "r$i:/etc/bird/certs/r$i.cert.pem" >/dev/null
  docker cp "$CERT_DIR/r$i.key" "r$i:/etc/bird/certs/r$i.key" >/dev/null
done

echo "[8/9] Validating configs and starting BIRD..."
for i in $(seq 1 "$N"); do
  echo "Validating r$i..."
  docker exec "r$i" /usr/sbin/bird -p -c /etc/bird/bird.conf

  echo "Starting BIRD on r$i..."
  docker exec "r$i" /usr/sbin/bird -c /etc/bird/bird.conf -s "$SOCKET"
done

wait_for_bgp() {
  local router="$1"
  local protocol="$2"
  local max_wait="$3"

  echo "Waiting for $router:$protocol to become Established..."

  for _ in $(seq 1 "$max_wait"); do
    if docker exec "$router" /usr/sbin/birdc -s "$SOCKET" show protocols | grep "$protocol" | grep -q "Established"; then
      echo "$router:$protocol is Established"
      return 0
    fi
    sleep 1
  done

  echo "ERROR: $router:$protocol did not become Established"
  echo "Protocols on $router:"
  docker exec "$router" /usr/sbin/birdc -s "$SOCKET" show protocols || true
  echo "Logs from $router:"
  docker logs "$router" | tail -80 || true
  return 1
}

echo "[9/9] Waiting for all TLS BGP sessions..."
for link in $(seq 1 $((N - 1))); do
  left_router="r${link}"
  right_router="r$((link + 1))"

  wait_for_bgp "$left_router" "to_r$((link + 1))" 60
  wait_for_bgp "$right_router" "to_r${link}" 60
done

echo
echo "TLS line topology is up."
echo

echo "Protocols on r1:"
docker exec r1 /usr/sbin/birdc -s "$SOCKET" show protocols

echo
echo "Protocols on r$N:"
docker exec "r$N" /usr/sbin/birdc -s "$SOCKET" show protocols

echo
echo "Route on r$N:"
docker exec "r$N" /usr/sbin/birdc -s "$SOCKET" show route 100.100.1.0/24 all

echo
echo "Socket summary on r$N:"
docker exec "r$N" ss -tnp | grep 179 || true

echo
echo "TLS line lab started successfully."
