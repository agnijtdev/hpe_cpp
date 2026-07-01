#!/usr/bin/env bash
set -euo pipefail

COUNT="${1:-100000}"
RUN_ID="${2:-1}"

PROJECT_DIR="$HOME/Documents/bgpost-lab"

IMAGE_ROUTER="bgpost-router-tls-runtime"
IMAGE_GOBGP="jauderho/gobgp:latest"

RIPE_MRT="$PROJECT_DIR/data/ripe_ris/bview.20231115.0800"

if [ ! -f "$RIPE_MRT" ]; then
  echo "ERROR: RIPE MRT file not found:"
  echo "$RIPE_MRT"
  exit 1
fi

BASE_DIR="$PROJECT_DIR/generated_configs/ripe_tcp_${COUNT}_run${RUN_ID}"
RESULT_DIR="$PROJECT_DIR/results/ripe_tcp_${COUNT}_run${RUN_ID}"

INJ_NET="bgpost_ripe_tcp_injector"
MID_NET="bgpost_ripe_tcp_r1_r2"
MON_NET="bgpost_ripe_tcp_r2_monitor"

GOBGP_IP="172.70.0.10"
R1_INJ_IP="172.70.0.2"

R1_MID_IP="172.70.12.11"
R2_MID_IP="172.70.12.12"

R2_MON_IP="172.70.23.11"
MON_IP="172.70.23.12"

mkdir -p "$BASE_DIR/gobgp" "$BASE_DIR/r1" "$BASE_DIR/r2" "$BASE_DIR/monitor" "$RESULT_DIR"

echo "[1/10] Cleaning old RIPE convergence containers/networks..."
docker rm -f injecter r1 r2 monitor >/dev/null 2>&1 || true
docker network ls --format '{{.Name}}' | awk '/^bgpost_ripe_/ {print}' | xargs -r docker network rm >/dev/null 2>&1 || true

echo "[2/10] Writing GoBGP config..."

cat > "$BASE_DIR/gobgp/gobgpd.conf" <<EOF
[global.config]
  as = 65000
  router-id = "100.100.100.100"

[[neighbors]]
  [neighbors.config]
    neighbor-address = "$R1_INJ_IP"
    peer-as = 65001

  [neighbors.transport.config]
    local-address = "$GOBGP_IP"

  [[neighbors.afi-safis]]
    [neighbors.afi-safis.config]
      afi-safi-name = "ipv4-unicast"
EOF

echo "[3/10] Writing BIRD configs..."

cat > "$BASE_DIR/r1/bird.conf" <<EOF
log "/tmp/bird.log" all;

router id 1.1.1.1;

protocol device {}

protocol direct {
  disabled;
}

protocol bgp from_gobgp {
  local $R1_INJ_IP as 65001;
  neighbor $GOBGP_IP as 65000;
  passive on;

  ipv4 {
    import all;
    export none;
  };
}

protocol bgp to_r2 {
  local $R1_MID_IP as 65001;
  neighbor $R2_MID_IP as 65002;

  ipv4 {
    import none;
    export all;
  };
}
EOF

cat > "$BASE_DIR/r2/bird.conf" <<EOF
log "/tmp/bird.log" all;

router id 2.2.2.2;

protocol device {}

protocol direct {
  disabled;
}

protocol bgp from_r1 {
  local $R2_MID_IP as 65002;
  neighbor $R1_MID_IP as 65001;
  passive on;

  ipv4 {
    import all;
    export none;
  };
}

protocol bgp to_monitor {
  local $R2_MON_IP as 65002;
  neighbor $MON_IP as 65003;

  ipv4 {
    import none;
    export all;
  };
}
EOF

cat > "$BASE_DIR/monitor/bird.conf" <<EOF
log "/tmp/bird.log" all;

router id 3.3.3.3;

mrtdump "/tmp/monitor.mrt";
mrtdump protocols { messages };
mrtdump extended_timestamp on;

protocol device {}

protocol direct {
  disabled;
}

protocol bgp from_r2 {
  local $MON_IP as 65003;
  neighbor $R2_MON_IP as 65002;
  passive on;

  ipv4 {
    import all;
    export none;
  };
}
EOF

echo "[4/10] Creating Docker networks..."
docker network create --subnet 172.70.0.0/24 "$INJ_NET" >/dev/null
docker network create --subnet 172.70.12.0/24 "$MID_NET" >/dev/null
docker network create --subnet 172.70.23.0/24 "$MON_NET" >/dev/null

echo "[5/10] Starting BIRD router containers..."

docker run -dit --privileged --name r1 \
  --network "$INJ_NET" --ip "$R1_INJ_IP" \
  --entrypoint /bin/sh \
  "$IMAGE_ROUTER" -lc "sleep 1000000" >/dev/null

docker network connect --ip "$R1_MID_IP" "$MID_NET" r1

docker run -dit --privileged --name r2 \
  --network "$MID_NET" --ip "$R2_MID_IP" \
  --entrypoint /bin/sh \
  "$IMAGE_ROUTER" -lc "sleep 1000000" >/dev/null

docker network connect --ip "$R2_MON_IP" "$MON_NET" r2

docker run -dit --privileged --name monitor \
  --network "$MON_NET" --ip "$MON_IP" \
  --entrypoint /bin/sh \
  "$IMAGE_ROUTER" -lc "sleep 1000000" >/dev/null

for r in r1 r2 monitor; do
  docker exec "$r" mkdir -p /run/bird /etc/bird
done

docker cp "$BASE_DIR/r1/bird.conf" r1:/etc/bird/bird.conf
docker cp "$BASE_DIR/r2/bird.conf" r2:/etc/bird/bird.conf
docker cp "$BASE_DIR/monitor/bird.conf" monitor:/etc/bird/bird.conf

docker exec -d r1 bird -c /etc/bird/bird.conf -s /run/bird.ctl -d
docker exec -d r2 bird -c /etc/bird/bird.conf -s /run/bird.ctl -d
docker exec -d monitor bird -c /etc/bird/bird.conf -s /run/bird.ctl -d

wait_established() {
  local container="$1"
  local proto="$2"

  echo "Waiting for $container:$proto..."

  for i in $(seq 1 90); do
    if docker exec "$container" birdc -s /run/bird.ctl show protocols 2>/dev/null | grep "$proto" | grep -q Established; then
      echo "$container:$proto is Established"
      return 0
    fi
    sleep 1
  done

  echo "ERROR: $container:$proto did not establish"
  docker exec "$container" birdc -s /run/bird.ctl show protocols || true
  docker exec "$container" cat /tmp/bird.log || true
  exit 1
}

wait_established r1 to_r2
wait_established r2 from_r1
wait_established r2 to_monitor
wait_established monitor from_r2

echo "[6/10] Starting GoBGP injecter..."

docker run -dit --name injecter \
  --network "$INJ_NET" --ip "$GOBGP_IP" \
  -v "$BASE_DIR/gobgp:/work" \
  -v "$PROJECT_DIR/data/ripe_ris:/ripe:ro" \
  --entrypoint gobgpd \
  "$IMAGE_GOBGP" -f /work/gobgpd.conf -l debug >/dev/null

echo "Waiting for GoBGP daemon..."
sleep 5

echo "[7/10] Checking GoBGP neighbor state..."

for i in $(seq 1 90); do
  if docker exec injecter gobgp neighbor 2>/dev/null | grep "$R1_INJ_IP" | grep -qi Establ; then
    echo "GoBGP neighbor is Established"
    break
  fi

  if [ "$i" -eq 90 ]; then
    echo "ERROR: GoBGP neighbor did not establish"
    docker exec injecter gobgp neighbor || true
    docker logs injecter --tail 100 || true
    docker exec r1 birdc -s /run/bird.ctl show protocols all from_gobgp || true
    docker exec r1 cat /tmp/bird.log || true
    exit 1
  fi

  sleep 1
done

wait_established r1 from_gobgp

echo "[8/10] Injecting $COUNT routes from RIPE MRT into GoBGP global RIB..."
echo "This can take some time."

START_TS=$(date +%s)

docker exec injecter gobgp mrt inject global /ripe/bview.20231115.0800 "$COUNT"

END_TS=$(date +%s)
INJECT_SECONDS=$((END_TS - START_TS))

echo "GoBGP MRT injection command finished in ${INJECT_SECONDS}s"

echo "Waiting 45 seconds for route propagation and MRT flush..."
sleep 45

echo "[9/10] Stopping monitor BIRD to flush MRT..."
docker exec monitor pkill -TERM bird || true
sleep 3

docker cp monitor:/tmp/monitor.mrt "$RESULT_DIR/monitor.mrt"

echo "[10/10] Result:"
ls -lh "$RESULT_DIR/monitor.mrt"

cat > "$RESULT_DIR/run_info.txt" <<EOF
mode=tcp
source=RIPE RIS rrc01 bview.20231115.0800
requested_count=$COUNT
run_id=$RUN_ID
inject_command_seconds=$INJECT_SECONDS
mrt_file=$RESULT_DIR/monitor.mrt
EOF

echo
echo "RIPE TCP convergence test complete."
echo "MRT file: $RESULT_DIR/monitor.mrt"
echo "Run info: $RESULT_DIR/run_info.txt"
