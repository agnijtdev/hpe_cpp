#!/usr/bin/env bash
set -euo pipefail

N="${1:-10}"
PREFIX_COUNT="${2:-100}"
DELAY_MS="${3:-50}"
LINK_DELAY_MS="${4:-0}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_ROUTER="bgpost-router-quic-runtime"
IMAGE_EXABGP="bgpost-exabgp"
SOCKET="/run/bird.ctl"

BASE_DIR="$PROJECT_DIR/generated_configs/quic_mrt_loop_${N}"
RESULT_DIR="$PROJECT_DIR/results/mrt_quic_loop_${N}_${PREFIX_COUNT}_announce${DELAY_MS}_delay${LINK_DELAY_MS}"
PREFIX_FILE="$BASE_DIR/exabgp/prefixes.txt"

CERT_DIR="$PROJECT_DIR/certs/quic_mrt_loop_${N}"
GEN_CERT="$PROJECT_DIR/external/BGPoST-Artifacts/cert-generator/generate_certs.sh"

mkdir -p "$BASE_DIR" "$BASE_DIR/exabgp" "$RESULT_DIR"

network_name() {
  echo "bgpost_mrt_quic_link_$1"
}

subnet_for_link() {
  echo "172.38.$((10 + $1)).0/24"
}

left_ip() {
  echo "172.38.$((10 + $1)).11"
}

right_ip() {
  echo "172.38.$((10 + $1)).12"
}

INJ_NET="bgpost_mrt_quic_injector"
INJ_SUBNET="172.38.0.0/24"
EXABGP_IP="172.38.0.10"
R1_EXABGP_IP="172.38.0.2"

RETURN_NET="bgpost_mrt_quic_return"
RETURN_SUBNET="172.38.20.0/24"
R10_RETURN_IP="172.38.20.11"
R1_RETURN_IP="172.38.20.12"

echo "[1/10] Cleaning old containers/networks..."
for i in $(seq 1 50); do
  docker rm -f "r$i" >/dev/null 2>&1 || true
done
docker rm -f exabgp >/dev/null 2>&1 || true

docker network ls --format '{{.Name}}' | grep '^bgpost_mrt_quic_' | xargs -r docker network rm >/dev/null || true

echo "[2/10] Generating certificates and prefixes..."
rm -rf "$CERT_DIR"
mkdir -p "$CERT_DIR"

for i in $(seq 1 "$N"); do
  bash "$GEN_CERT" "$CERT_DIR" "r$i" ED25519 "r$i.rtr" "0.0.0.$i" NULL NULL >/dev/null
done

rm -f "$PREFIX_FILE"

for i in $(seq 1 "$PREFIX_COUNT"); do
  third=$((i / 256))
  fourth=$((i % 256))
  echo "10.200.${third}.${fourth}/32" >> "$PREFIX_FILE"
done

echo "Generated $PREFIX_COUNT prefixes at $PREFIX_FILE"

echo "[3/10] Writing ExaBGP files..."

cat > "$BASE_DIR/exabgp/controlled_announce.py" <<'PY'
#!/usr/bin/env python3
import sys
import time
from argparse import ArgumentParser
from ipaddress import ip_network, IPv4Network


def main():
    parser = ArgumentParser()
    parser.add_argument("--ipv4-nh", required=True)
    parser.add_argument("--ipv6-nh", required=True)
    parser.add_argument("-a", "--asn", required=True)
    parser.add_argument("-p", "--prefixes", required=True)
    parser.add_argument("-d", "--delay", type=int, default=50)
    parser.add_argument("-m", "--max-announce", type=int, default=0)
    args = parser.parse_args()

    sent = 0
    delay_s = args.delay / 1000.0

    with open(args.prefixes) as f:
        for line in f:
            if args.max_announce > 0 and sent >= args.max_announce:
                break

            prefix = line.strip()
            if not prefix:
                continue

            p = ip_network(prefix)
            nh = args.ipv4_nh if isinstance(p, IPv4Network) else args.ipv6_nh

            print(f"announce route {prefix} next-hop {nh} origin incomplete as-path [ {args.asn} ]")
            sys.stdout.flush()

            sent += 1
            time.sleep(delay_s)

    while True:
        time.sleep(1)


if __name__ == "__main__":
    main()
PY

chmod +x "$BASE_DIR/exabgp/controlled_announce.py"

cat > "$BASE_DIR/exabgp/exa_wrapper.sh" <<EOF
#!/usr/bin/env bash
exec /work/controlled_announce.py \\
  --ipv6-nh fc01:: \\
  --ipv4-nh $EXABGP_IP \\
  -a 65000 \\
  -p /work/prefixes.txt \\
  -d $DELAY_MS \\
  -m $PREFIX_COUNT
EOF

chmod +x "$BASE_DIR/exabgp/exa_wrapper.sh"

cat > "$BASE_DIR/exabgp/exabgp.conf" <<EOF
process announce-routes {
  run "/work/exa_wrapper.sh";
  encoder text;
}

neighbor $R1_EXABGP_IP {
  router-id $EXABGP_IP;
  local-address $EXABGP_IP;
  local-as 65000;
  peer-as 65001;
  hold-time 180;

  family {
    ipv4 unicast;
  }

  api {
    processes [ announce-routes ];
  }
}
EOF

cat > "$BASE_DIR/exabgp/exabgp.env" <<'EOF'
[exabgp.api]
ack = false
cli = false

[exabgp.log]
all = true
destination = stdout
level = INFO

[exabgp.tcp]
bind = 
EOF

echo "[4/10] Writing BIRD configs..."

write_bgp_block() {
  local proto="$1"
  local local_ip="$2"
  local local_as="$3"
  local neigh_ip="$4"
  local neigh_as="$5"
  local passive="$6"
  local import_policy="$7"
  local export_policy="$8"
  local local_router="$9"
  local peer_router="${10}"

  cat <<CFG
protocol bgp $proto {
    local $local_ip as $local_as;
    neighbor $neigh_ip as $neigh_as;
    hold time 240;

    transport quic;
    strict bind on;
$passive

    root ca "/etc/bird/certs/ca.cert.pem";
    certificate "/etc/bird/certs/r${local_router}.cert.pem";
    key "/etc/bird/certs/r${local_router}.key";
    alpn "BGP4";
    remote sni "r${peer_router}.rtr";
    peer_require_auth on;
    tls_insecure on;
    tlskeylogfile "/tmp/r${local_router}.secrets";

    ipv4 {
        import $import_policy;
        export $export_policy;
    };
}

CFG
}

for i in $(seq 1 "$N"); do
  mkdir -p "$BASE_DIR/r$i"

  rid="$i.$i.$i.$i"
  asn=$((65000 + i))

  {
    echo "log stderr all;"
    echo
    echo "router id $rid;"
    echo
    if [ "$i" -eq 1 ]; then
      echo 'mrtdump "/tmp/r1.mrt";'
      echo 'mrtdump protocols { messages };'
      echo 'mrtdump extended_timestamp;'
      echo
    fi
    echo "protocol device { }"
    echo
    echo "protocol direct { ipv4; }"
    echo
  } > "$BASE_DIR/r$i/bird.conf"

  if [ "$i" -eq 1 ]; then
    cat >> "$BASE_DIR/r$i/bird.conf" <<CFG
protocol bgp exabgp {
    local $R1_EXABGP_IP as $asn;
    neighbor $EXABGP_IP as 65000;
    hold time 240;

    transport tcp;
    strict bind on;
    passive on;

    ipv4 {
        import all;
        export none;
    };
}

CFG
    write_bgp_block "to_r2" "$(left_ip 1)" "$asn" "$(right_ip 1)" "$((asn + 1))" "" "none" "all" "1" "2" >> "$BASE_DIR/r$i/bird.conf"
    write_bgp_block "to_r10" "$R1_RETURN_IP" "$asn" "$R10_RETURN_IP" "$((65000 + N))" "    passive on;" "all" "none" "1" "$N" >> "$BASE_DIR/r$i/bird.conf"

  elif [ "$i" -eq "$N" ]; then
    left_link=$((i - 1))
    write_bgp_block "to_r$((i - 1))" "$(right_ip "$left_link")" "$asn" "$(left_ip "$left_link")" "$((asn - 1))" "    passive on;" "all" "none" "$i" "$((i - 1))" >> "$BASE_DIR/r$i/bird.conf"
    write_bgp_block "to_r1" "$R10_RETURN_IP" "$asn" "$R1_RETURN_IP" "65001" "" "none" "all" "$N" "1" >> "$BASE_DIR/r$i/bird.conf"

  else
    left_link=$((i - 1))
    right_link="$i"

    write_bgp_block "to_r$((i - 1))" "$(right_ip "$left_link")" "$asn" "$(left_ip "$left_link")" "$((asn - 1))" "    passive on;" "all" "none" "$i" "$((i - 1))" >> "$BASE_DIR/r$i/bird.conf"
    write_bgp_block "to_r$((i + 1))" "$(left_ip "$right_link")" "$asn" "$(right_ip "$right_link")" "$((asn + 1))" "" "none" "all" "$i" "$((i + 1))" >> "$BASE_DIR/r$i/bird.conf"
  fi
done

echo "[5/10] Creating Docker networks..."

docker network create --subnet "$INJ_SUBNET" "$INJ_NET" >/dev/null

for link in $(seq 1 $((N - 1))); do
  docker network create --subnet "$(subnet_for_link "$link")" "$(network_name "$link")" >/dev/null
done

docker network create --subnet "$RETURN_SUBNET" "$RETURN_NET" >/dev/null

echo "[6/10] Starting router containers..."

for i in $(seq 1 "$N"); do
  if [ "$i" -eq 1 ]; then
    first_net="$INJ_NET"
    first_ip="$R1_EXABGP_IP"
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
    "$IMAGE_ROUTER" -c "sleep 1000000" >/dev/null
done

docker network connect --ip "$(left_ip 1)" "$(network_name 1)" r1
docker network connect --ip "$R1_RETURN_IP" "$RETURN_NET" r1

if [ "$N" -gt 2 ]; then
  for i in $(seq 2 $((N - 1))); do
    docker network connect --ip "$(left_ip "$i")" "$(network_name "$i")" "r$i"
  done
fi

docker network connect --ip "$R10_RETURN_IP" "$RETURN_NET" "r$N"

echo "[6b/10] Applying one-way link delay..."
if [ "$LINK_DELAY_MS" -gt 0 ]; then
  echo "Adding ${LINK_DELAY_MS}ms delay on the forwarding path r1 -> ... -> r$N -> r1"

  # r1 sends to r2 on eth1.
  # r2..r9 send to the next router on eth1.
  for i in $(seq 1 $((N - 1))); do
    docker exec "r$i" sh -lc "tc qdisc del dev eth1 root 2>/dev/null || true; tc qdisc add dev eth1 root netem delay ${LINK_DELAY_MS}ms"
  done

  # rN sends back to r1 on its return interface eth1.
  docker exec "r$N" sh -lc "tc qdisc del dev eth1 root 2>/dev/null || true; tc qdisc add dev eth1 root netem delay ${LINK_DELAY_MS}ms"

  echo "Delay summary:"
  docker exec r1 tc qdisc show dev eth1 || true
  docker exec "r$N" tc qdisc show dev eth1 || true
else
  echo "No artificial link delay requested."
fi

echo "[7/10] Copying BIRD configs and QUIC certificates..."

for i in $(seq 1 "$N"); do
  docker exec "r$i" mkdir -p /etc/bird/certs

  docker cp "$BASE_DIR/r$i/bird.conf" "r$i:/etc/bird/bird.conf" >/dev/null

  docker cp "$CERT_DIR/ca.cert.pem" "r$i:/etc/bird/certs/ca.cert.pem" >/dev/null
  docker cp "$CERT_DIR/r$i.cert.pem" "r$i:/etc/bird/certs/r$i.cert.pem" >/dev/null
  docker cp "$CERT_DIR/r$i.key" "r$i:/etc/bird/certs/r$i.key" >/dev/null
done

echo "[8/10] Validating and starting BIRD..."

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

  echo "Waiting for $router:$protocol..."

  for _ in $(seq 1 "$max_wait"); do
    if docker exec "$router" /usr/sbin/birdc -s "$SOCKET" show protocols | grep "$protocol" | grep -q "Established"; then
      echo "$router:$protocol is Established"
      return 0
    fi
    sleep 1
  done

  echo "ERROR: $router:$protocol did not establish"
  docker exec "$router" /usr/sbin/birdc -s "$SOCKET" show protocols || true
  docker logs "$router" | tail -80 || true
  return 1
}

echo "[9/10] Waiting for router-to-router BGP sessions..."

for link in $(seq 1 $((N - 1))); do
  wait_for_bgp "r$link" "to_r$((link + 1))" 60
  wait_for_bgp "r$((link + 1))" "to_r$link" 60
done

wait_for_bgp "r$N" "to_r1" 60
wait_for_bgp "r1" "to_r10" 60

echo "[10/10] Starting ExaBGP injector..."

docker run -dit \
  --name exabgp \
  --hostname exabgp \
  --network "$INJ_NET" \
  --ip "$EXABGP_IP" \
  -v "$BASE_DIR/exabgp:/work" \
  "$IMAGE_EXABGP" \
  sh -lc "exabgp server /work/exabgp.conf" >/dev/null

wait_for_bgp "r1" "exabgp" 60

echo
echo "ExaBGP logs:"
docker logs exabgp | tail -40 || true

echo
echo "Waiting for route injection to finish..."
WAIT_SECONDS=$(( (PREFIX_COUNT * DELAY_MS / 1000) + 20 ))
echo "Sleeping $WAIT_SECONDS seconds..."
sleep "$WAIT_SECONDS"

echo
echo "Stopping ExaBGP and BIRD on r1 to flush MRT..."
docker rm -f exabgp >/dev/null 2>&1 || true
docker exec r1 /usr/sbin/birdc -s "$SOCKET" down >/dev/null 2>&1 || true
sleep 2

echo
echo "Copying MRT file..."
docker cp r1:/tmp/r1.mrt "$RESULT_DIR/r1.mrt"

echo
echo "Result:"
ls -lh "$RESULT_DIR/r1.mrt"

echo
echo "QUIC MRT loop experiment complete."
echo "MRT file: $RESULT_DIR/r1.mrt"
