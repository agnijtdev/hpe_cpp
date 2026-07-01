#!/usr/bin/env bash
set -u

mkdir -p evidence/bgp_protocol_restart results/bgp_protocol_restart

TS=$(date +%Y%m%d_%H%M%S)

EVIDENCE="evidence/bgp_protocol_restart/bgp_control_plane_two_way_isolated_${TS}.txt"
PING_LOG="evidence/bgp_protocol_restart/ping_control_plane_two_way_isolated_${TS}.log"
ROUTE_LOG="evidence/bgp_protocol_restart/route_control_plane_two_way_isolated_${TS}.log"
CSV="results/bgp_protocol_restart/bgp_control_plane_two_way_isolated_${TS}.csv"
LATEST="results/bgp_protocol_restart/bgp_control_plane_two_way_isolated.csv"

FORWARD_PREFIX="10.0.93.0/24"
RETURN_PREFIX="10.0.61.0/24"
PING_TARGET="10.0.93.2"

now_ms() {
    date +%s%3N
}

restore_everything() {
    echo
    echo "Restoring backup BGP paths..."
    docker exec hpe-r1 birdc enable r2 >/dev/null 2>&1 || true
    docker exec hpe-r9 birdc enable r2 >/dev/null 2>&1 || true
    docker exec hpe-r1 birdc enable r9 >/dev/null 2>&1 || true
    docker exec hpe-r9 birdc enable r1 >/dev/null 2>&1 || true
    sleep 5
}

trap restore_everything EXIT

parse_ping() {
    TX=$(grep -Eo '[0-9]+ packets transmitted' "$PING_LOG" | tail -1 | awk '{print $1}')
    RX=$(grep -Eo '[0-9]+ received' "$PING_LOG" | tail -1 | awk '{print $1}')
    LOSS=$(grep -Eo '[0-9.]+% packet loss' "$PING_LOG" | tail -1 | awk '{print $1}' | tr -d '%')

    TX=${TX:-NA}
    RX=${RX:-NA}
    LOSS=${LOSS:-NA}
}

{
echo "============================================================"
echo "TWO-WAY ISOLATED BGP CONTROL-PLANE RESTART TEST"
echo "Timestamp: $TS"
echo "Restart action: hpe-r9 birdc restart r1"
echo "GR/LLGR: kept enabled"
echo "BIRD daemon killed: no"
echo "Backup paths disabled:"
echo "  - hpe-r1 protocol r2 disabled"
echo "  - hpe-r9 protocol r2 disabled"
echo "Traffic: hpe-h1 -> hpe-h3 ($PING_TARGET)"
echo "============================================================"

echo
echo "1. Disabling backup paths on both sides"
echo "------------------------------------------------------------"
docker exec hpe-r1 birdc disable r2 || true
docker exec hpe-r9 birdc disable r2 || true

sleep 5

echo
echo "2. Two-way isolation precheck"
echo "------------------------------------------------------------"

F_ROUTE="$(docker exec hpe-r1 birdc show route "$FORWARD_PREFIX" all 2>/dev/null || true)"
R_ROUTE="$(docker exec hpe-r9 birdc show route "$RETURN_PREFIX" all 2>/dev/null || true)"

echo "Forward route on hpe-r1 to hpe-h3:"
echo "$F_ROUTE"

echo
echo "Return route on hpe-r9 to hpe-h1:"
echo "$R_ROUTE"

F_R9_COUNT=$(echo "$F_ROUTE" | grep -c "\[r9" || true)
F_R2_COUNT=$(echo "$F_ROUTE" | grep -c "\[r2" || true)
F_MISSING_COUNT=$(echo "$F_ROUTE" | grep -c "Network not found" || true)

R_R1_COUNT=$(echo "$R_ROUTE" | grep -c "\[r1" || true)
R_R2_COUNT=$(echo "$R_ROUTE" | grep -c "\[r2" || true)
R_MISSING_COUNT=$(echo "$R_ROUTE" | grep -c "Network not found" || true)

echo
echo "Forward precheck r9 route count: $F_R9_COUNT"
echo "Forward precheck r2 route count: $F_R2_COUNT"
echo "Forward precheck missing count: $F_MISSING_COUNT"

echo
echo "Return precheck r1 route count: $R_R1_COUNT"
echo "Return precheck r2 route count: $R_R2_COUNT"
echo "Return precheck missing count: $R_MISSING_COUNT"

if [ "$F_R9_COUNT" -eq 0 ]; then
    echo "ABORT: forward route from hpe-r1 via r9 is not present."
    exit 1
fi

if [ "$F_R2_COUNT" -ne 0 ]; then
    echo "ABORT: forward backup route via r2 is still present."
    exit 1
fi

if [ "$R_R1_COUNT" -eq 0 ]; then
    echo "ABORT: return route from hpe-r9 via r1 is not present."
    exit 1
fi

if [ "$R_R2_COUNT" -ne 0 ]; then
    echo "ABORT: return backup route via r2 is still present."
    exit 1
fi

echo
echo "Two-way isolation confirmed."

echo
echo "3. Starting continuous ping"
echo "------------------------------------------------------------"
docker exec hpe-h1 sh -c "ping -i 0.05 $PING_TARGET" > "$PING_LOG" 2>&1 &
PING_PID=$!

sleep 2

echo
echo "4. Starting route monitor"
echo "------------------------------------------------------------"
START_MS=$(now_ms)

(
    for i in $(seq 1 100); do
        NOW=$(now_ms)
        ELAPSED=$((NOW - START_MS))

        F_ROUTE_NOW="$(docker exec hpe-r1 birdc show route "$FORWARD_PREFIX" all 2>/dev/null || true)"
        R_ROUTE_NOW="$(docker exec hpe-r9 birdc show route "$RETURN_PREFIX" all 2>/dev/null || true)"

        F_R9="no"
        F_R2="no"
        F_MISSING="no"
        R_R1="no"
        R_R2="no"
        R_MISSING="no"

        echo "$F_ROUTE_NOW" | grep -q "\[r9" && F_R9="yes"
        echo "$F_ROUTE_NOW" | grep -q "\[r2" && F_R2="yes"
        echo "$F_ROUTE_NOW" | grep -q "Network not found" && F_MISSING="yes"

        echo "$R_ROUTE_NOW" | grep -q "\[r1" && R_R1="yes"
        echo "$R_ROUTE_NOW" | grep -q "\[r2" && R_R2="yes"
        echo "$R_ROUTE_NOW" | grep -q "Network not found" && R_MISSING="yes"

        echo "${ELAPSED} ms | forward_r9=${F_R9} | forward_r2=${F_R2} | forward_missing=${F_MISSING} | return_r1=${R_R1} | return_r2=${R_R2} | return_missing=${R_MISSING}" >> "$ROUTE_LOG"

        sleep 0.2
    done
) &
MON_PID=$!

sleep 1

echo
echo "5. Restarting only BGP protocol r1 on hpe-r9"
echo "------------------------------------------------------------"
FAIL_MS=$(now_ms)
docker exec hpe-r9 birdc restart r1 || true

BGP_REEST_MS="NA"
for i in $(seq 1 150); do
    NOW=$(now_ms)
    if docker exec hpe-r1 birdc show protocols r9 2>/dev/null | grep -q "Established"; then
        BGP_REEST_MS=$((NOW - FAIL_MS))
        break
    fi
    sleep 0.1
done

sleep 5

docker exec hpe-h1 pkill -INT ping >/dev/null 2>&1 || true
wait "$PING_PID" >/dev/null 2>&1 || true
wait "$MON_PID" >/dev/null 2>&1 || true

parse_ping

F_MISSING_SAMPLES=$(grep -c "forward_missing=yes" "$ROUTE_LOG" || true)
R_MISSING_SAMPLES=$(grep -c "return_missing=yes" "$ROUTE_LOG" || true)

F_R9_SAMPLES=$(grep -c "forward_r9=yes" "$ROUTE_LOG" || true)
R_R1_SAMPLES=$(grep -c "return_r1=yes" "$ROUTE_LOG" || true)

F_R2_SAMPLES=$(grep -c "forward_r2=yes" "$ROUTE_LOG" || true)
R_R2_SAMPLES=$(grep -c "return_r2=yes" "$ROUTE_LOG" || true)

if [ "$F_R2_SAMPLES" -eq 0 ] && [ "$R_R2_SAMPLES" -eq 0 ]; then
    ISOLATION_RESULT="pass"
else
    ISOLATION_RESULT="fail"
fi

if [ "$LOSS" = "0" ]; then
    FORWARDING_RESULT="pass"
else
    FORWARDING_RESULT="partial_or_fail"
fi

echo
echo "6. Result summary"
echo "------------------------------------------------------------"
echo "BGP r9 re-established on hpe-r1: $BGP_REEST_MS ms"
echo "Ping transmitted: $TX"
echo "Ping received: $RX"
echo "Ping loss percent: $LOSS"

echo
echo "Forward direction hpe-r1 -> hpe-h3:"
echo "Forward route missing samples: $F_MISSING_SAMPLES"
echo "Forward r9 route present samples: $F_R9_SAMPLES"
echo "Forward r2 route present samples: $F_R2_SAMPLES"

echo
echo "Return direction hpe-r9 -> hpe-h1:"
echo "Return route missing samples: $R_MISSING_SAMPLES"
echo "Return r1 route present samples: $R_R1_SAMPLES"
echo "Return r2 route present samples: $R_R2_SAMPLES"

echo
echo "isolation_result: $ISOLATION_RESULT"
echo "forwarding_result: $FORWARDING_RESULT"

echo
echo "7. CSV result"
echo "------------------------------------------------------------"
echo "timestamp,test_name,restarted_router,method,bgp_reestablished_ms,ping_tx,ping_rx,ping_loss_percent,forward_missing_samples,forward_r9_samples,forward_r2_samples,return_missing_samples,return_r1_samples,return_r2_samples,isolation_result,forwarding_result"
echo "$TS,bgp_control_plane_two_way_isolated,hpe-r9,birdc_restart_r1,$BGP_REEST_MS,$TX,$RX,$LOSS,$F_MISSING_SAMPLES,$F_R9_SAMPLES,$F_R2_SAMPLES,$R_MISSING_SAMPLES,$R_R1_SAMPLES,$R_R2_SAMPLES,$ISOLATION_RESULT,$FORWARDING_RESULT"

} | tee "$EVIDENCE"

echo "timestamp,test_name,restarted_router,method,bgp_reestablished_ms,ping_tx,ping_rx,ping_loss_percent,forward_missing_samples,forward_r9_samples,forward_r2_samples,return_missing_samples,return_r1_samples,return_r2_samples,isolation_result,forwarding_result" > "$CSV"
grep "^$TS,bgp_control_plane_two_way_isolated" "$EVIDENCE" >> "$CSV"
cp "$CSV" "$LATEST"

trap - EXIT
restore_everything | tee -a "$EVIDENCE"

echo
echo "Saved evidence to: $EVIDENCE"
echo "Saved ping log to: $PING_LOG"
echo "Saved route log to: $ROUTE_LOG"
echo "Saved CSV to: $CSV"
echo "Updated latest CSV at: $LATEST"
