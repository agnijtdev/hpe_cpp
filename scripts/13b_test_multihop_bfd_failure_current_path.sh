#!/usr/bin/env bash
set -u

mkdir -p evidence/multihop_bfd results/multihop_bfd

TS=$(date +%Y%m%d_%H%M%S)
EVIDENCE="evidence/multihop_bfd/multihop_bfd_failure_${TS}.txt"
CSV="results/multihop_bfd/multihop_bfd_failure_${TS}.csv"
LATEST="results/multihop_bfd/multihop_bfd_failure.csv"

FAILED_ROUTER="hpe-r4"
FAILED_IFACE="eth3"
FAILED_LINK="hpe-r4-eth3_to_hpe-r7-eth1"

R1_PEER="10.0.82.3"
R8_PEER="10.0.14.2"

now_ms() {
    date +%s%3N
}

bfd_state() {
    local router="$1"
    local peer="$2"

    docker exec "$router" birdc show bfd sessions 2>/dev/null \
        | awk -v peer="$peer" '$1 == peer {print $3}'
}

wait_for_state_not_up() {
    local router="$1"
    local peer="$2"
    local start_ms="$3"
    local timeout_ms="$4"

    local now state elapsed

    while true; do
        now=$(now_ms)
        elapsed=$((now - start_ms))

        state=$(bfd_state "$router" "$peer")
        echo "${elapsed} ms | ${router} peer ${peer} state=${state}" >> "$EVIDENCE"

        if [ "$state" != "Up" ] && [ -n "$state" ]; then
            echo "$elapsed"
            return 0
        fi

        if [ "$elapsed" -ge "$timeout_ms" ]; then
            echo "TIMEOUT"
            return 1
        fi

        sleep 0.03
    done
}

wait_for_state_up() {
    local router="$1"
    local peer="$2"
    local timeout_ms="$3"

    local start now elapsed state
    start=$(now_ms)

    while true; do
        now=$(now_ms)
        elapsed=$((now - start))

        state=$(bfd_state "$router" "$peer")

        if [ "$state" = "Up" ]; then
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
echo "MULTI-HOP BFD FAILURE DETECTION TEST"
echo "Timestamp: $TS"
echo "============================================================"

echo
echo "Test idea:"
echo "Multi-hop BFD session is between hpe-r1 and hpe-r8."
echo "hpe-r1 peer: $R1_PEER"
echo "hpe-r8 peer: $R8_PEER"
echo "We fail the routed path by bringing down $FAILED_ROUTER $FAILED_IFACE."

echo
echo "============================================================"
echo "1. BFD state before failure"
echo "============================================================"
echo "---- hpe-r1 ----"
docker exec hpe-r1 birdc show bfd sessions
echo
echo "---- hpe-r8 ----"
docker exec hpe-r8 birdc show bfd sessions

echo
echo "============================================================"
echo "2. Routes before failure"
echo "============================================================"
echo "---- hpe-r1 route to hpe-r8 endpoint $R1_PEER ----"
docker exec hpe-r1 ip route get "$R1_PEER" || true
echo
echo "---- hpe-r8 route to hpe-r1 endpoint $R8_PEER ----"
docker exec hpe-r8 ip route get "$R8_PEER" || true

echo
echo "============================================================"
echo "3. Starting background ping"
echo "============================================================"
PING_LOG="evidence/multihop_bfd/multihop_bfd_ping_${TS}.log"
docker exec hpe-r1 ping -i 0.05 "$R1_PEER" > "$PING_LOG" 2>&1 &
PING_PID=$!
echo "Ping log: $PING_LOG"
echo "Ping PID: $PING_PID"

sleep 1

echo
echo "============================================================"
echo "4. Failing routed path"
echo "============================================================"
FAIL_MS=$(now_ms)
echo "Failure time ms: $FAIL_MS"
echo "Command: docker exec $FAILED_ROUTER ip link set $FAILED_IFACE down"
docker exec "$FAILED_ROUTER" ip link set "$FAILED_IFACE" down

echo
echo "============================================================"
echo "5. Measuring BFD transition from Up to non-Up"
echo "============================================================"
R1_DOWN_MS=$(wait_for_state_not_up hpe-r1 "$R1_PEER" "$FAIL_MS" 5000)
R8_DOWN_MS=$(wait_for_state_not_up hpe-r8 "$R8_PEER" "$FAIL_MS" 5000)

echo "hpe-r1 multi-hop BFD detection time: $R1_DOWN_MS ms"
echo "hpe-r8 multi-hop BFD detection time: $R8_DOWN_MS ms"

sleep 2

echo
echo "============================================================"
echo "6. BFD state during failure"
echo "============================================================"
echo "---- hpe-r1 ----"
docker exec hpe-r1 birdc show bfd sessions || true
echo
echo "---- hpe-r8 ----"
docker exec hpe-r8 birdc show bfd sessions || true

echo
echo "============================================================"
echo "7. Restoring failed path"
echo "============================================================"
echo "Command: docker exec $FAILED_ROUTER ip link set $FAILED_IFACE up"
docker exec "$FAILED_ROUTER" ip link set "$FAILED_IFACE" up

echo
echo "Waiting for BFD to recover..."
R1_RECOVERY_MS=$(wait_for_state_up hpe-r1 "$R1_PEER" 15000)
R8_RECOVERY_MS=$(wait_for_state_up hpe-r8 "$R8_PEER" 15000)

echo "hpe-r1 BFD recovery time after link restore: $R1_RECOVERY_MS ms"
echo "hpe-r8 BFD recovery time after link restore: $R8_RECOVERY_MS ms"

sleep 2

echo
echo "============================================================"
echo "8. Stopping ping"
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
echo "9. Final BFD state"
echo "============================================================"
echo "---- hpe-r1 ----"
docker exec hpe-r1 birdc show bfd sessions || true
echo
echo "---- hpe-r8 ----"
docker exec hpe-r8 birdc show bfd sessions || true

echo
echo "============================================================"
echo "10. Final connectivity check"
echo "============================================================"
docker exec hpe-r1 ping -c 5 "$R1_PEER" || true
docker exec hpe-r8 ping -c 5 "$R8_PEER" || true

TARGET_MET="no"
if [[ "$R1_DOWN_MS" != "TIMEOUT" && "$R1_DOWN_MS" -lt 1000 ]]; then
    TARGET_MET="yes"
fi

echo
echo "============================================================"
echo "11. CSV result"
echo "============================================================"
echo "timestamp,test_name,failed_link,r1_peer,r8_peer,r1_bfd_detection_ms,r8_bfd_detection_ms,r1_recovery_ms,r8_recovery_ms,ping_tx,ping_rx,ping_loss,target_under_1s"
echo "$TS,multihop_bfd_failure,$FAILED_LINK,$R1_PEER,$R8_PEER,$R1_DOWN_MS,$R8_DOWN_MS,$R1_RECOVERY_MS,$R8_RECOVERY_MS,${TX:-NA},${RX:-NA},${LOSS:-NA},$TARGET_MET"

} | tee "$EVIDENCE"

echo "timestamp,test_name,failed_link,r1_peer,r8_peer,r1_bfd_detection_ms,r8_bfd_detection_ms,r1_recovery_ms,r8_recovery_ms,ping_tx,ping_rx,ping_loss,target_under_1s" > "$CSV"
grep "^$TS,multihop_bfd_failure" "$EVIDENCE" >> "$CSV"
cp "$CSV" "$LATEST"

echo
echo "Saved evidence to: $EVIDENCE"
echo "Saved CSV to: $CSV"
echo "Updated latest CSV at: $LATEST"
