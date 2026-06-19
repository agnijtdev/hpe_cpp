#!/usr/bin/env bash
set -e

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <number_of_routers>"
  echo "Example: $0 2"
  echo "Example: $0 10"
  exit 1
fi

N="$1"

if [ "$N" -lt 2 ]; then
  echo "ERROR: number_of_routers must be at least 2"
  exit 1
fi

CONFIG_DIR="generated_configs/tcp_line_${N}"

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
  docker exec "$router" birdc show protocols || true
  return 1
}

link_subnet_octet() {
  local link="$1"
  echo $((10 + link))
}

left_ip() {
  local link="$1"
  local octet
  octet=$(link_subnet_octet "$link")
  echo "172.31.${octet}.11"
}

right_ip() {
  local link="$1"
  local octet
  octet=$(link_subnet_octet "$link")
  echo "172.31.${octet}.12"
}

echo "========================================"
echo "Starting TCP line topology with $N routers"
echo "========================================"

echo
echo "[1/7] Generating BIRD configs..."
python3 scripts/generate_line_configs.py "$N"

echo
echo "[2/7] Cleaning old line topology containers..."
for i in $(seq 1 50); do
  docker rm -f "r$i" 2>/dev/null || true
done

echo
echo "[3/7] Cleaning old line topology Docker networks..."
docker network ls --format '{{.Name}}' | grep '^bgpost_line_net_' | xargs -r docker network rm

echo
echo "[4/7] Creating Docker networks for each router-to-router link..."
for link in $(seq 1 $((N - 1))); do
  subnet_octet=$((10 + link))
  net_name="bgpost_line_net_${link}"
  subnet="172.31.${subnet_octet}.0/24"

  echo "Creating $net_name with subnet $subnet"
  docker network create --subnet "$subnet" "$net_name" >/dev/null
done

echo
echo "[5/7] Starting router containers on their first link network..."

for i in $(seq 1 "$N"); do
  if [ "$i" -eq 1 ]; then
    first_link=1
    first_net="bgpost_line_net_1"
    first_ip=$(left_ip 1)
  else
    first_link=$((i - 1))
    first_net="bgpost_line_net_${first_link}"
    first_ip=$(right_ip "$first_link")
  fi

  echo "Starting r$i on $first_net with IP $first_ip"

  docker run -dit \
    --name "r$i" \
    --hostname "r$i" \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    --network "$first_net" \
    --ip "$first_ip" \
    bgpost-router >/dev/null
done

echo
echo "[6/7] Connecting middle routers to their right-side link networks..."

for i in $(seq 2 $((N - 1))); do
  right_link="$i"
  right_net="bgpost_line_net_${right_link}"
  ip_on_right_link=$(left_ip "$right_link")

  echo "Connecting r$i to $right_net with IP $ip_on_right_link"
  docker network connect --ip "$ip_on_right_link" "$right_net" "r$i"
done

echo
echo "[7/7] Copying configs, validating, and starting BIRD..."

for i in $(seq 1 "$N"); do
  echo "Configuring r$i"
  docker cp "${CONFIG_DIR}/r${i}/bird.conf" "r$i:/etc/bird/bird.conf"
  docker exec "r$i" bird -p -c /etc/bird/bird.conf
  docker exec "r$i" bird -c /etc/bird/bird.conf
done

echo
echo "Waiting for all BGP sessions to establish..."

for link in $(seq 1 $((N - 1))); do
  left_router="r${link}"
  right_router="r$((link + 1))"

  wait_for_bgp "$left_router" "to_r$((link + 1))" 30
  wait_for_bgp "$right_router" "to_r${link}" 30
done

echo
echo "Final protocol status on all routers:"
for i in $(seq 1 "$N"); do
  echo
  echo "===== r$i ====="
  docker exec "r$i" birdc show protocols
done

echo
echo "Checking whether the test prefix reached the last router r$N:"
docker exec "r$N" birdc show route 100.100.1.0/24 all || true

echo
echo "TCP socket check:"
for i in $(seq 1 "$N"); do
  echo
  echo "===== r$i TCP sockets ====="
  docker exec "r$i" ss -tnp | grep 179 || true
done

echo
echo "TCP line topology with $N routers started successfully."
