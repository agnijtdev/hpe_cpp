#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CERT_DIR="$PROJECT_DIR/certs/quic_2router"
CONFIG_DIR="$PROJECT_DIR/generated_configs/quic_2router"
GEN_CERT="$PROJECT_DIR/external/BGPoST-Artifacts/cert-generator/generate_certs.sh"

IMAGE="bgpost-router-quic-runtime"
NETWORK="bgpost_quic_net12"
SUBNET="172.34.12.0/24"

R1_IP="172.34.12.11"
R2_IP="172.34.12.12"

SOCKET="/run/bird.ctl"

mkdir -p "$CERT_DIR" "$CONFIG_DIR/r1" "$CONFIG_DIR/r2"

echo "[1/8] Cleaning old QUIC containers/network..."
docker rm -f r1 r2 >/dev/null 2>&1 || true
docker network rm "$NETWORK" >/dev/null 2>&1 || true

echo "[2/8] Generating certificates..."
bash "$GEN_CERT" "$CERT_DIR" "r1" ED25519 "r1.rtr" "$R1_IP" NULL NULL >/dev/null
bash "$GEN_CERT" "$CERT_DIR" "r2" ED25519 "r2.rtr" "$R2_IP" NULL NULL >/dev/null

ls -lh \
  "$CERT_DIR/ca.cert.pem" \
  "$CERT_DIR/r1.cert.pem" \
  "$CERT_DIR/r1.key" \
  "$CERT_DIR/r2.cert.pem" \
  "$CERT_DIR/r2.key"

echo "[3/8] Writing BIRD QUIC configs..."

cat > "$CONFIG_DIR/r1/bird.conf" <<CFG
log stderr all;

router id 1.1.1.1;

protocol device {
}

protocol direct {
    ipv4;
}

protocol static static_routes {
    ipv4;
    route 100.100.1.0/24 blackhole;
}

protocol bgp to_r2 {
    local $R1_IP as 65001;
    neighbor $R2_IP as 65002;
    hold time 240;

    transport quic;
    strict bind on;

    root ca "/etc/bird/certs/ca.cert.pem";
    certificate "/etc/bird/certs/r1.cert.pem";
    key "/etc/bird/certs/r1.key";
    alpn "BGP4";
    remote sni "r2.rtr";
    peer_require_auth on;
    tls_insecure on;
    tlskeylogfile "/tmp/r1.secrets";

    ipv4 {
        import all;
        export all;
    };
}
CFG

cat > "$CONFIG_DIR/r2/bird.conf" <<CFG
log stderr all;

router id 2.2.2.2;

protocol device {
}

protocol direct {
    ipv4;
}

protocol bgp to_r1 {
    local $R2_IP as 65002;
    neighbor $R1_IP as 65001;
    hold time 240;

    transport quic;
    strict bind on;
    passive on;

    root ca "/etc/bird/certs/ca.cert.pem";
    certificate "/etc/bird/certs/r2.cert.pem";
    key "/etc/bird/certs/r2.key";
    alpn "BGP4";
    remote sni "r1.rtr";
    peer_require_auth on;
    tls_insecure on;
    tlskeylogfile "/tmp/r2.secrets";

    ipv4 {
        import all;
        export all;
    };
}
CFG

echo "[4/8] Creating Docker network..."
docker network create --subnet "$SUBNET" "$NETWORK" >/dev/null

echo "[5/8] Starting QUIC-capable router containers..."

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

echo "[6/8] Copying configs and certificates..."

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

echo "[7/8] Validating configs..."

docker exec r1 /usr/sbin/bird -p -c /etc/bird/bird.conf
docker exec r2 /usr/sbin/bird -p -c /etc/bird/bird.conf

echo "[8/8] Starting BIRD..."

docker exec r1 /usr/sbin/bird -c /etc/bird/bird.conf -s "$SOCKET"
docker exec r2 /usr/sbin/bird -c /etc/bird/bird.conf -s "$SOCKET"

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
  docker logs "$router" | tail -120 || true
  return 1
}

wait_for_bgp r1 to_r2 60
wait_for_bgp r2 to_r1 60

echo
echo "r1 protocols:"
docker exec r1 /usr/sbin/birdc -s "$SOCKET" show protocols

echo
echo "r2 protocols:"
docker exec r2 /usr/sbin/birdc -s "$SOCKET" show protocols

echo
echo "Route on r2:"
docker exec r2 /usr/sbin/birdc -s "$SOCKET" show route 100.100.1.0/24 all

echo
echo "UDP socket summary:"
docker exec r1 ss -unlp || true
docker exec r2 ss -unlp || true

echo
echo "QUIC 2-router lab started successfully."
