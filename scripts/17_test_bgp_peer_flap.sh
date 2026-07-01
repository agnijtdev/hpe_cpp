#!/usr/bin/env bash
set -u

mkdir -p evidence/bgp_peer_flap results/bgp_peer_flap

TS=$(date +%Y%m%d_%H%M%S)
EVIDENCE="evidence/bgp_peer_flap/bgp_peer_flap_${TS}.txt"
PING_LOG="evidence/bgp_peer_flap/ping_bgp_peer_flap_${TS}.log"
ROUTE_LOG="evidence/bgp_peer_flap/route_bgp_peer_flap_${TS}.log"
STATE_LOG="evidence/bgp_peer_flap/state_bgp_peer_flap_${TS}.log"
CSV="results/bgp_peer_flap/bgp_peer_flap_${TS}.csv"
LATEST="results/bgp_peer_flap/bgp_peer_flap.csv"

TARGET="10.0.93.2"
DIRECT_NH="10.0.19.3"
ALT_NH="10.0.12.3"

now_ms() {
    date +%s%3N
}

r1_bgp_info() {
    docker exec hpe-r1 birdc show protocols 2>/dev/null | awk '$1=="r9"{print $0}'
}

r1_bgp_established() {
    docker exec hpe-r1 birdc show protocols 2>/dev/null | awk '$1=="r9"{print $6}'
}

route_line() {
    docker exec hpe-r1 ip route get "$TARGET" 2>/dev/null | head -1
}

wait_for_route_contains() {
    local pattern="$1"
    local start_ms="$2"
    local timeout_ms="$3"

    local now elapsed route

    while true; do
        now=$(now_ms)
        elapsed=$((now - start_ms))
        route=$(route_line)

        echo "${elapsed} ms | route=${route}" >> "$ROUTE_LOG"

        if echo "$route" | grep -q "$pattern"; then
            echo "$elapsed"
            return 0
        fi

        if [ "$elapsed" -ge "$timeout_ms" ]; then
            echo "TIMEOUT"
            return 1
        fi

        sleep 0.05
    done
}

wait_for_bgp_established() {
    local start_ms="$1"
    local timeout_ms="$2"

    local now elapsed state line

    while true; do
        now=$(now_ms)
        elapsed=$((now - start_ms))
        state=$(r1_bgp_established)
        line=$(r1_bgp_info)

        echo "${elapsed} ms | ${line}" >> "$STATE_LOG"

        if [ "$state" = "Established" ]; then
            echo "$elapsed"
            return 0
        fi

        if [ "$elapsed" -ge "$timeout_ms" ]; then
            echo "TIMEOUT"
            return 1
        fi

        sleep 0.1
    done
}

{
echo "============================================================"
echo "BGP PEER FLAP TEST"
echo "Timestamp: $TS"
echo "============================================================"

echo
echo "Test idea:"
echo "Disable and re-enable the BGP peer r9 on hpe-r1."
echo "Check whether hpe-r1 switches from direct hpe-r9 route to alternate hpe-r2 route."
echo

echo "============================================================"
echo "1. State before peer flap"
echo "============================================================"

echo "---- hpe-r1 protocols ----"
docker exec hpe-r1 birdc show protocols

echo
echo "---- hpe-r1 route to $TARGET before flap ----"
docker exec hpe-r1 ip route get "$TARGET"
docker exec hpe-r1 birdc show route 10.0.93.0/24 all || true

echo
echo "============================================================"
echo "2. Starting ping from hpe-r1 to hpe-h3"
echo "============================================================"
docker exec hpe-r1 ping -i 0.05 "$TARGET" > "$PING_LOG" 2>&1 &
PING_PID=$!
echo "Ping log: $PING_LOG"
echo "Ping PID: $PING_PID"

sleep 1

echo
echo "============================================================"
echo "3. Disabling BGP peer r9 on hpe-r1"
echo "============================================================"
FLAP_DOWN_MS=$(now_ms)
echo "Flap down time ms: $FLAP_DOWN_MS"
docker exec hpe-r1 birdc disable r9

ROUTE_TO_ALT_MS=$(wait_for_route_contains "$ALT_NH" "$FLAP_DOWN_MS" 10000)
echo "Route switched to alternate hpe-r2 next-hop after: $ROUTE_TO_ALT_MS ms"

sleep 3

echo
echo "---- hpe-r1 route during peer flap ----"
docker exec hpe-r1 ip route get "$TARGET"
docker exec hpe-r1 birdc show route 10.0.93.0/24 all || true
docker exec hpe-r1 birdc show protocols

echo
echo "============================================================"
echo "4. Re-enabling BGP peer r9 on hpe-r1"
echo "============================================================"
FLAP_UP_MS=$(now_ms)
echo "Flap up time ms: $FLAP_UP_MS"
docker exec hpe-r1 birdc enable r9

BGP_REESTABLISHED_MS=$(wait_for_bgp_established "$FLAP_UP_MS" 30000)
echo "BGP peer r9 re-established after: $BGP_REESTABLISHED_MS ms"

ROUTE_TO_DIRECT_MS=$(wait_for_route_contains "$DIRECT_NH" "$FLAP_UP_MS" 30000)
echo "Route switched back to direct hpe-r9 next-hop after: $ROUTE_TO_DIRECT_MS ms"

sleep 2

echo
echo "============================================================"
echo "5. Stopping ping"
echo "============================================================"
docker exec hpe-r1 pkill -INT ping 2>/dev/null || true
wait "$PING_PID" 2>/dev/null || true
sleep 1

TX=$(grep -Eo '[0-9]+ packets transmitted' "$PING_LOG" | tail -1 | awk '{print $1}')
RX=$(grep -Eo '[0-9]+ received' "$PING_LOG" | tail -1 | awk '{print $1}')
LOSS=$(grep -Eo '[0-9.]+% packet loss' "$PING_LOG" | tail -1 | awk '{print $1}')

echo "Ping transmitted: ${TX:-NA}"
echo "Ping received: ${RX:-NA}"
echo "Ping loss: ${LOSS:-NA}"

echo
echo "============================================================"
echo "6. Final state"
echo "============================================================"
docker exec hpe-r1 birdc show protocols
docker exec hpe-r1 ip route get "$TARGET"
docker exec hpe-r1 birdc show route 10.0.93.0/24 all || true

echo
echo "---- End-to-end hpe-h1 to hpe-h3 final ping ----"
docker exec hpe-h1 ping -c 5 "$TARGET" || true

echo
echo "============================================================"
echo "7. CSV result"
echo "============================================================"
echo "timestamp,test_name,flapped_router,flapped_peer,target,route_to_alternate_ms,bgp_reestablished_ms,route_to_direct_ms,ping_tx,ping_rx,ping_loss"
echo "$TS,bgp_peer_flap,hpe-r1,r9,$TARGET,$ROUTE_TO_ALT_MS,$BGP_REESTABLISHED_MS,$ROUTE_TO_DIRECT_MS,${TX:-NA},${RX:-NA},${LOSS:-NA}"

} | tee "$EVIDENCE"

echo "timestamp,test_name,flapped_router,flapped_peer,target,route_to_alternate_ms,bgp_reestablished_ms,route_to_direct_ms,ping_tx,ping_rx,ping_loss" > "$CSV"
grep "^$TS,bgp_peer_flap" "$EVIDENCE" >> "$CSV"
cp "$CSV" "$LATEST"

echo
echo "Saved evidence to: $EVIDENCE"
echo "Saved ping log to: $PING_LOG"
echo "Saved route log to: $ROUTE_LOG"
echo "Saved state log to: $STATE_LOG"
echo "Saved CSV to: $CSV"
echo "Updated latest CSV at: $LATEST"
