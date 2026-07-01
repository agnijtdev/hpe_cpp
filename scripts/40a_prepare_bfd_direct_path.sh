#!/usr/bin/env bash
set -euo pipefail

R2="hpe-r2"
R9="hpe-r9"

TARGET_IP="10.0.93.2"
EXPECTED_NH="10.0.29.3"
EXPECTED_IFACE="eth2"
BGP_PROTO_R2="r9"
BGP_PROTO_R9="r2"

echo "============================================================"
echo "PREPARE BFD WAN DIRECT PATH"
echo "============================================================"

echo
echo "1. Bring direct WAN edge interface up"
echo "------------------------------------------------------------"

docker exec "$R2" ip link set "$EXPECTED_IFACE" up >/dev/null 2>&1 || true

# In the current topology, r9 side of r2-r9 is usually eth0.
docker exec "$R9" ip link set eth0 up >/dev/null 2>&1 || true

echo
echo "2. Enable/restart direct BGP protocols"
echo "------------------------------------------------------------"

docker exec "$R2" birdc enable "$BGP_PROTO_R2" >/dev/null 2>&1 || true
docker exec "$R9" birdc enable "$BGP_PROTO_R9" >/dev/null 2>&1 || true

docker exec "$R2" birdc restart "$BGP_PROTO_R2" >/dev/null 2>&1 || true
docker exec "$R9" birdc restart "$BGP_PROTO_R9" >/dev/null 2>&1 || true

echo
echo "3. Waiting until route uses direct r2-r9 path"
echo "------------------------------------------------------------"

for i in $(seq 1 90); do
    ROUTE="$(docker exec "$R2" ip route get "$TARGET_IP" 2>/dev/null || true)"
    BGP="$(docker exec "$R2" birdc show protocols "$BGP_PROTO_R2" 2>/dev/null || true)"
    BFD="$(docker exec "$R2" birdc show bfd sessions 2>/dev/null | grep "$EXPECTED_NH" || true)"

    ROUTE_OK="no"
    BGP_OK="no"
    BFD_OK="no"

    echo "$ROUTE" | grep -q "via $EXPECTED_NH" && echo "$ROUTE" | grep -q "dev $EXPECTED_IFACE" && ROUTE_OK="yes"
    echo "$BGP" | grep -q "Established" && BGP_OK="yes"
    echo "$BFD" | grep -q "Up" && BFD_OK="yes"

    printf "Attempt %02d: route=%s bgp=%s bfd=%s\n" "$i" "$ROUTE_OK" "$BGP_OK" "$BFD_OK"

    if [ "$ROUTE_OK" = "yes" ] && [ "$BGP_OK" = "yes" ] && [ "$BFD_OK" = "yes" ]; then
        echo
        echo "[OK] Direct BFD/BGP WAN path is ready."
        echo
        echo "Route:"
        echo "$ROUTE"
        echo
        echo "BFD:"
        echo "$BFD"
        exit 0
    fi

    sleep 1
done

echo
echo "[ERROR] Direct BFD/BGP WAN path did not become ready."
echo
echo "Final route:"
docker exec "$R2" ip route get "$TARGET_IP" || true

echo
echo "Final BGP state:"
docker exec "$R2" birdc show protocols "$BGP_PROTO_R2" || true

echo
echo "Final BFD sessions:"
docker exec "$R2" birdc show bfd sessions || true

exit 1
