#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-tcp}"
COUNT="${2:-10000}"
DELAY_MS="${3:-1}"
RUN_ID="${4:-1}"

PROJECT_DIR="$HOME/Documents/bgpost-lab"
IMAGE_EXABGP="bgpost-exabgp"

case "$MODE" in
  tcp|tls|tls_ao_static|tls_ao_dynamic)
    IMAGE_ROUTER="bgpost-router-tls-runtime"
    ;;
  quic)
    IMAGE_ROUTER="bgpost-router-quic-runtime"
    ;;
  *)
    echo "Usage: $0 {tcp|tls|quic|tls_ao_static|tls_ao_dynamic} [COUNT] [DELAY_MS] [RUN_ID]"
    exit 1
    ;;
esac

BASE_DIR="$PROJECT_DIR/generated_configs/convergence_${MODE}_${COUNT}_delay${DELAY_MS}_run${RUN_ID}"
RESULT_DIR="$PROJECT_DIR/results/convergence_${MODE}_${COUNT}_delay${DELAY_MS}_run${RUN_ID}"

INJ_NET="bgpost_conv_${MODE}_injector"
MID_NET="bgpost_conv_${MODE}_r1_r2"
MON_NET="bgpost_conv_${MODE}_r2_monitor"

EXABGP_IP="172.60.0.10"
R1_INJ_IP="172.60.0.2"

R1_MID_IP="172.60.12.11"
R2_MID_IP="172.60.12.12"

R2_MON_IP="172.60.23.11"
MON_IP="172.60.23.12"

mkdir -p "$BASE_DIR/exabgp" "$BASE_DIR/r1" "$BASE_DIR/r2" "$BASE_DIR/monitor" "$RESULT_DIR"

echo "[1/9] Cleaning old convergence containers/networks..."
docker rm -f injecter r1 r2 monitor >/dev/null 2>&1 || true
docker network ls --format '{{.Name}}' | awk '/^bgpost_conv_/ {print}' | xargs -r docker network rm >/dev/null 2>&1 || true

echo "[2/9] Generating $COUNT prefixes..."
PREFIX_FILE="$BASE_DIR/exabgp/prefixes.txt"
rm -f "$PREFIX_FILE"

for i in $(seq 1 "$COUNT"); do
  third=$((i / 256))
  fourth=$((i % 256))
  echo "10.220.${third}.${fourth}/32" >> "$PREFIX_FILE"
done

echo "Generated $(wc -l < "$PREFIX_FILE") prefixes"

echo "[3/9] Writing ExaBGP files..."

cat > "$BASE_DIR/exabgp/controlled_announce.py" <<'PY'
#!/usr/bin/env python3
import sys
import time
import os
from argparse import ArgumentParser
from ipaddress import ip_network, IPv4Network


def main():
    parser = ArgumentParser()
    parser.add_argument("--ipv4-nh", required=True)
    parser.add_argument("--ipv6-nh", required=True)
    parser.add_argument("-a", "--asn", required=True)
    parser.add_argument("-p", "--prefixes", required=True)
    parser.add_argument("-m", "--max-announce", type=int, default=0)
    parser.add_argument("-d", "--delay", type=int, default=1)
    args = parser.parse_args()

    sent = 0
    delay_s = args.delay / 1000.0
    progress_file = "/work/inject_progress.txt"
    done_file = "/work/inject_done.txt"

    def write_progress(prefix):
        with open(progress_file, "w") as pf:
            pf.write(f"sent={sent}\n")
            pf.write(f"last_prefix={prefix}\n")
            pf.write(f"time={time.time()}\n")
        os.chmod(progress_file, 0o666)

    write_progress("START")

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

            if sent % 100 == 0:
                write_progress(prefix)

            time.sleep(delay_s)

    write_progress("DONE")

    with open(done_file, "w") as df:
        df.write(f"done_sent={sent}\n")
        df.write(f"time={time.time()}\n")
    os.chmod(done_file, 0o666)

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
  -m $COUNT
EOF

chmod +x "$BASE_DIR/exabgp/exa_wrapper.sh"
chmod -R a+rwX "$BASE_DIR/exabgp"

cat > "$BASE_DIR/exabgp/exabgp.conf" <<EOF
process announce-routes {
  run /work/exa_wrapper.sh;
  encoder text;
}

neighbor $R1_INJ_IP {
  router-id 100.100.100.100;
  local-address $EXABGP_IP;
  local-as 65000;
  peer-as 65001;

  family {
    ipv4 unicast;
  }

  api {
    processes [ announce-routes ];
  }
}
EOF

make_certs() {
  CERT_DIR="$BASE_DIR/certs"
  mkdir -p "$CERT_DIR"

  openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout "$CERT_DIR/ca.key" \
    -out "$CERT_DIR/ca.cert.pem" \
    -subj "/CN=bgpost-ca" >/dev/null 2>&1

  for r in r1 r2; do
    openssl req -newkey rsa:2048 -nodes \
      -keyout "$CERT_DIR/${r}.key" \
      -out "$CERT_DIR/${r}.csr" \
      -subj "/CN=${r}.rtr" >/dev/null 2>&1

    cat > "$CERT_DIR/${r}.ext" <<EOF
subjectAltName=DNS:${r}.rtr
EOF

    openssl x509 -req \
      -in "$CERT_DIR/${r}.csr" \
      -CA "$CERT_DIR/ca.cert.pem" \
      -CAkey "$CERT_DIR/ca.key" \
      -CAcreateserial \
      -out "$CERT_DIR/${r}.cert.pem" \
      -days 365 \
      -sha256 \
      -extfile "$CERT_DIR/${r}.ext" >/dev/null 2>&1
  done
}

transport_block() {
  local local_router="$1"
  local peer_router="$2"
  local passive_line="${3:-}"

  case "$MODE" in
    tcp)
      ;;
    tls)
      cat <<EOF
  transport tls;
  strict bind on;
$passive_line
  tls certificate "/etc/bird/certs/${local_router}.cert.pem";
  tls root ca "/etc/bird/certs/ca.cert.pem";
  tls pkey "/etc/bird/certs/${local_router}.key";
  tls peer sni "${peer_router}.rtr";
  tls local sni "${local_router}.rtr";
EOF
      ;;
    tls_ao_static)
      cat <<EOF
  password "bgpost-static-ao-key";
  tcp authentication mode tcp_ao;
  transport tls;
  strict bind on;
$passive_line
  tls certificate "/etc/bird/certs/${local_router}.cert.pem";
  tls root ca "/etc/bird/certs/ca.cert.pem";
  tls pkey "/etc/bird/certs/${local_router}.key";
  tls peer sni "${peer_router}.rtr";
  tls local sni "${local_router}.rtr";
EOF
      ;;
    tls_ao_dynamic)
      cat <<EOF
  transport tls;
  strict bind on;
$passive_line
  tcp authentication mode tcp_ao_tls;
  tls certificate "/etc/bird/certs/${local_router}.cert.pem";
  tls root ca "/etc/bird/certs/ca.cert.pem";
  tls pkey "/etc/bird/certs/${local_router}.key";
  tls peer sni "${peer_router}.rtr";
  tls local sni "${local_router}.rtr";
EOF
      ;;
    quic)
      cat <<EOF
  transport quic;
  strict bind on;
$passive_line
  root ca "/etc/bird/certs/ca.cert.pem";
  certificate "/etc/bird/certs/${local_router}.cert.pem";
  key "/etc/bird/certs/${local_router}.key";
  alpn "BGP4";
  remote sni "${peer_router}.rtr";
  peer_require_auth on;
  tls_insecure on;
  tlskeylogfile "/tmp/${local_router}_${peer_router}.keys";
EOF
      ;;
  esac
}

if [ "$MODE" != "tcp" ]; then
  echo "[4/9] Generating certificates for $MODE..."
  make_certs
else
  echo "[4/9] TCP mode: no certificates needed"
fi

if [ "$MODE" = "tcp" ]; then
  PLAIN_STRICT_BIND=""
  R2_BGP_PASSIVE="  passive on;"
  R2_TRANSPORT_PASSIVE=""
else
  PLAIN_STRICT_BIND="  strict bind on;"
  R2_BGP_PASSIVE=""
  R2_TRANSPORT_PASSIVE="  passive on;"
fi

R1_TO_R2_BLOCK="$(transport_block r1 r2 "")"
R2_FROM_R1_BLOCK="$(transport_block r2 r1 "$R2_TRANSPORT_PASSIVE")"

echo "[5/9] Writing BIRD configs..."

cat > "$BASE_DIR/r1/bird.conf" <<EOF
log "/tmp/bird.log" all;

router id 1.1.1.1;

protocol device {}

protocol direct {
  disabled;
}

protocol bgp exabgp {
  local $R1_INJ_IP as 65001;
  neighbor $EXABGP_IP as 65000;
$PLAIN_STRICT_BIND
  passive on;

  ipv4 {
    import all;
    export none;
  };
}

protocol bgp to_r2 {
  local $R1_MID_IP as 65001;
  neighbor $R2_MID_IP as 65002;
$R1_TO_R2_BLOCK

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
$R2_BGP_PASSIVE
$R2_FROM_R1_BLOCK

  ipv4 {
    import all;
    export none;
  };
}

protocol bgp to_monitor {
  local $R2_MON_IP as 65002;
  neighbor $MON_IP as 65003;
$PLAIN_STRICT_BIND

  ipv4 {
    import none;
    export all;
  };
}
EOF

if [ "$MODE" = "quic" ]; then
  EXT_TS_LINE="mrtdump extended_timestamp;"
else
  EXT_TS_LINE="mrtdump extended_timestamp on;"
fi

cat > "$BASE_DIR/monitor/bird.conf" <<EOF
log "/tmp/bird.log" all;

router id 3.3.3.3;

mrtdump "/tmp/monitor.mrt";
mrtdump protocols { messages };
$EXT_TS_LINE

protocol device {}

protocol direct {
  disabled;
}

protocol bgp from_r2 {
  local $MON_IP as 65003;
  neighbor $R2_MON_IP as 65002;
$PLAIN_STRICT_BIND
  passive on;

  ipv4 {
    import all;
    export none;
  };
}
EOF

echo "[6/9] Creating Docker networks..."
docker network create --subnet 172.60.0.0/24 "$INJ_NET" >/dev/null
docker network create --subnet 172.60.12.0/24 "$MID_NET" >/dev/null
docker network create --subnet 172.60.23.0/24 "$MON_NET" >/dev/null

echo "[7/9] Starting router containers..."

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

if [ "$MODE" != "tcp" ]; then
  for r in r1 r2; do
    docker exec "$r" mkdir -p /etc/bird/certs
    docker cp "$BASE_DIR/certs/ca.cert.pem" "$r:/etc/bird/certs/ca.cert.pem"
    docker cp "$BASE_DIR/certs/${r}.cert.pem" "$r:/etc/bird/certs/${r}.cert.pem"
    docker cp "$BASE_DIR/certs/${r}.key" "$r:/etc/bird/certs/${r}.key"
  done
fi

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
  docker logs "$container" --tail 100 || true
  exit 1
}

wait_established r1 to_r2
wait_established r2 from_r1
wait_established r2 to_monitor
wait_established monitor from_r2

echo "[8/9] Starting ExaBGP injecter..."

docker run -d --name injecter \
  --network "$INJ_NET" --ip "$EXABGP_IP" \
  -v "$BASE_DIR/exabgp:/work" \
  "$IMAGE_EXABGP" sh -lc "exabgp server /work/exabgp.conf" >/dev/null

wait_established r1 exabgp

echo "Waiting for injecter to finish sending $COUNT routes..."

TIMEOUT=$(( (COUNT * (DELAY_MS + 2) / 1000) + 240 ))

for i in $(seq 1 "$TIMEOUT"); do
  if [ -f "$BASE_DIR/exabgp/inject_done.txt" ]; then
    echo "Injecter finished:"
    cat "$BASE_DIR/exabgp/inject_done.txt" || true
    break
  fi

  if [ $((i % 10)) -eq 0 ]; then
    cat "$BASE_DIR/exabgp/inject_progress.txt" 2>/dev/null || true
  fi

  sleep 1
done

if [ ! -f "$BASE_DIR/exabgp/inject_done.txt" ]; then
  echo "ERROR: injecter did not finish before timeout"
  cat "$BASE_DIR/exabgp/inject_progress.txt" 2>/dev/null || true
  docker logs injecter --tail 120 || true
  exit 1
fi

echo "Waiting 20 seconds for route propagation..."
sleep 20

echo "[9/9] Stopping monitor BIRD to flush MRT..."
docker exec monitor pkill -TERM bird || true
sleep 2

docker cp monitor:/tmp/monitor.mrt "$RESULT_DIR/monitor.mrt"

echo
echo "Result:"
ls -lh "$RESULT_DIR/monitor.mrt"

echo
echo "$MODE convergence experiment complete."
echo "MRT file: $RESULT_DIR/monitor.mrt"
