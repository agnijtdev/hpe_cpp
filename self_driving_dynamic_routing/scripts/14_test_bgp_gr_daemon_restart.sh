#!/usr/bin/env bash
set -u

mkdir -p evidence/bgp_daemon_restart results/bgp_daemon_restart

TS=$(date +%Y%m%d_%H%M%S)
EVIDENCE="evidence/bgp_daemon_restart/bgp_gr_daemon_restart_${TS}.txt"
PING_LOG="evidence/bgp_daemon_restart/ping_bgp_gr_daemon_restart_${TS}.log"
STATE_LOG="evidence/bgp_daemon_restart/bgp_state_daemon_restart_${TS}.log"
ROUTE_LOG="evidence/bgp_daemon_restart/route_daemon_restart_${TS}.log"
CSV="results/bgp_daemon_restart/bgp_gr_daemon_restart_${TS}.csv"
LATEST="results/bgp_daemon_restart/bgp_gr_daemon_restart.csv"

TARGET="10.0.93.2"

now_ms() {
    date +%s%3N
}

r1_bgp_state_to_r9() {
    docker exec hpe-r1 birdc show protocols 2>/dev/null | awk '$1=="r9"{print $6}'
}

r2_bgp_state_to_r9() {
    docker exec hpe-r2 birdc show protocols 2>/dev/null | awk '$1=="r9"{print $6}'
}

r9_bird_pid() {
    docker exec hpe-r9 sh -c "pidof bird" 2>/dev/null || true
}

restart_bird_on_r9() {
    docker exec hpe-r9 sh -c '
        pkill -TERM bird || true
        for i in $(seq 1 30); do
            pidof bird >/dev/null 2>&1 || break
            sleep 0.1
        done
        rm -f /run/bird/bird.ctl
        nohup bird -c /etc/bird/bird.conf >/tmp/bird-daemon-restart.log 2>&1 &
    '
}

wait_for_r9_birdc_ready() {
    local start_ms="$1"
    local timeout_ms="$2"
    local now elapsed

    while true; do
        now=$(now_ms)
        elapsed=$((now - start_ms))

        if docker exec hpe-r9 birdc show protocols >/dev/null 2>&1; then
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
    local now elapsed s1 s2

    while true; do
        now=$(now_ms)
        elapsed=$((now - start_ms))
        s1=$(r1_bgp_state_to_r9)
        s2=$(r2_bgp_state_to_r9)

        echo "${elapsed} ms | hpe-r1->hpe-r9=${s1} | hpe-r2->hpe-r9=${s2}" >> "$STATE_LOG"

        if [ "$s1" = "Established" ] && [ "$s2" = "Established" ]; then
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
echo "BGP GR FULL BIRD DAEMON RESTART TEST"
echo "Timestamp: $TS"
echo "============================================================"

echo
echo "Test idea:"
echo "Restart the full BIRD daemon on hpe-r9."
echo "Check whether forwarding from hpe-h1 to hpe-h3 continues."
echo "Target traffic: hpe-h1 -> $TARGET"
echo

echo "============================================================"
echo "1. State before restart"
echo "============================================================"
echo "---- hpe-r9 BIRD process ----"
docker exec hpe-r9 sh -c "ps aux | grep '[b]ird'" || true

echo
echo "---- hpe-r1 protocols ----"
docker exec hpe-r1 birdc show protocols

echo
echo "---- hpe-r2 protocols ----"
docker exec hpe-r2 birdc show protocols

echo
echo "---- hpe-r9 protocols ----"
docker exec hpe-r9 birdc show protocols

echo
echo "---- hpe-r1 route to $TARGET ----"
docker exec hpe-r1 ip route get "$TARGET" || true
docker exec hpe-r1 birdc show route 10.0.93.0/24 all || true

echo
echo "---- hpe-r9 route back to hpe-h1 network ----"
docker exec hpe-r9 ip route get 10.0.61.2 || true
docker exec hpe-r9 birdc show route 10.0.61.0/24 all || true

echo
echo "============================================================"
echo "2. Starting background ping"
echo "============================================================"
docker exec hpe-h1 ping -i 0.05 "$TARGET" > "$PING_LOG" 2>&1 &
PING_PID=$!
echo "Ping log: $PING_LOG"
echo "Ping PID: $PING_PID"

echo
echo "============================================================"
echo "3. Starting route monitor"
echo "============================================================"
(
    START=$(now_ms)
    while true; do
        NOW=$(now_ms)
        ELAPSED=$((NOW - START))
        ROUTE=$(docker exec hpe-r1 ip route get "$TARGET" 2>/dev/null | head -1)
        BIRD_ROUTE=$(docker exec hpe-r1 birdc show route 10.0.93.0/24 2>/dev/null | grep -m1 "10.0.93.0/24" || true)
        echo "${ELAPSED} ms | ip route get: ${ROUTE} | bird: ${BIRD_ROUTE}"
        sleep 0.05
    done
) > "$ROUTE_LOG" &
ROUTE_PID=$!
echo "Route log: $ROUTE_LOG"
echo "Route monitor PID: $ROUTE_PID"

sleep 1

echo
echo "============================================================"
echo "4. Restarting full BIRD daemon on hpe-r9"
echo "============================================================"
RESTART_MS=$(now_ms)
echo "Restart command time ms: $RESTART_MS"
echo "Old hpe-r9 BIRD PID: $(r9_bird_pid)"

restart_bird_on_r9

echo "Restart command issued."

BIRDC_READY_MS=$(wait_for_r9_birdc_ready "$RESTART_MS" 10000)
echo "hpe-r9 birdc ready after: $BIRDC_READY_MS ms"

BGP_REESTABLISHED_MS=$(wait_for_bgp_established "$RESTART_MS" 30000)
echo "hpe-r1 and hpe-r2 BGP sessions to hpe-r9 re-established after: $BGP_REESTABLISHED_MS ms"

sleep 3

echo
echo "============================================================"
echo "5. Stopping monitors"
echo "============================================================"
docker exec hpe-h1 pkill -INT ping 2>/dev/null || true
wait "$PING_PID" 2>/dev/null || true

kill "$ROUTE_PID" 2>/dev/null || true
sleep 1

TX=$(grep -Eo '[0-9]+ packets transmitted' "$PING_LOG" | tail -1 | awk '{print $1}')
RX=$(grep -Eo '[0-9]+ received' "$PING_LOG" | tail -1 | awk '{print $1}')
LOSS=$(grep -Eo '[0-9.]+% packet loss' "$PING_LOG" | tail -1 | awk '{print $1}')

echo "Ping transmitted: ${TX:-NA}"
echo "Ping received: ${RX:-NA}"
echo "Ping loss: ${LOSS:-NA}"

MISSING_ROUTE_COUNT=$(grep -c "Network is unreachable\\|RTNETLINK\\|unreachable\\|throw\\|blackhole" "$ROUTE_LOG" || true)
ALT_R2_COUNT=$(grep -c "via 10.0.12.3" "$ROUTE_LOG" || true)
DIRECT_R9_COUNT=$(grep -c "via 10.0.19.3" "$ROUTE_LOG" || true)

echo "Route samples using direct hpe-r9 next-hop: $DIRECT_R9_COUNT"
echo "Route samples using hpe-r2 alternate next-hop: $ALT_R2_COUNT"
echo "Route missing/unreachable samples: $MISSING_ROUTE_COUNT"

echo
echo "============================================================"
echo "6. Final state after restart"
echo "============================================================"
echo "---- hpe-r9 BIRD process ----"
docker exec hpe-r9 sh -c "ps aux | grep '[b]ird'" || true

echo
echo "---- hpe-r1 protocols ----"
docker exec hpe-r1 birdc show protocols

echo
echo "---- hpe-r2 protocols ----"
docker exec hpe-r2 birdc show protocols

echo
echo "---- hpe-r9 protocols ----"
docker exec hpe-r9 birdc show protocols

echo
echo "---- Final hpe-h1 to hpe-h3 ping ----"
docker exec hpe-h1 ping -c 5 "$TARGET" || true

FORWARDING_PRESERVED="unknown"
if [ "${LOSS:-NA}" = "0%" ] || [ "${LOSS:-NA}" = "0.0%" ] || [ "${LOSS:-NA}" = "0.00%" ]; then
    FORWARDING_PRESERVED="yes"
else
    FORWARDING_PRESERVED="partial_or_no"
fi

echo
echo "============================================================"
echo "7. CSV result"
echo "============================================================"
echo "timestamp,test_name,restarted_router,birdc_ready_ms,bgp_reestablished_ms,ping_tx,ping_rx,ping_loss,direct_next_hop_samples,alternate_next_hop_samples,route_missing_samples,forwarding_preserved"
echo "$TS,bgp_gr_full_bird_daemon_restart,hpe-r9,$BIRDC_READY_MS,$BGP_REESTABLISHED_MS,${TX:-NA},${RX:-NA},${LOSS:-NA},$DIRECT_R9_COUNT,$ALT_R2_COUNT,$MISSING_ROUTE_COUNT,$FORWARDING_PRESERVED"

} | tee "$EVIDENCE"

echo "timestamp,test_name,restarted_router,birdc_ready_ms,bgp_reestablished_ms,ping_tx,ping_rx,ping_loss,direct_next_hop_samples,alternate_next_hop_samples,route_missing_samples,forwarding_preserved" > "$CSV"
grep "^$TS,bgp_gr_full_bird_daemon_restart" "$EVIDENCE" >> "$CSV"
cp "$CSV" "$LATEST"

echo
echo "Saved evidence to: $EVIDENCE"
echo "Saved ping log to: $PING_LOG"
echo "Saved route log to: $ROUTE_LOG"
echo "Saved state log to: $STATE_LOG"
echo "Saved CSV to: $CSV"
echo "Updated latest CSV at: $LATEST"
