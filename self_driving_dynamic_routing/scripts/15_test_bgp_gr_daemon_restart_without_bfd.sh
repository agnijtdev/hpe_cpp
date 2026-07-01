#!/usr/bin/env bash
set -u

mkdir -p evidence/bgp_daemon_restart results/bgp_daemon_restart configs/bgp_daemon_restart

TS=$(date +%Y%m%d_%H%M%S)
EVIDENCE="evidence/bgp_daemon_restart/bgp_gr_daemon_restart_without_bfd_${TS}.txt"
PING_LOG="evidence/bgp_daemon_restart/ping_bgp_gr_daemon_restart_without_bfd_${TS}.log"
ROUTE_LOG="evidence/bgp_daemon_restart/route_bgp_gr_daemon_restart_without_bfd_${TS}.log"
STATE_LOG="evidence/bgp_daemon_restart/state_bgp_gr_daemon_restart_without_bfd_${TS}.log"
CSV="results/bgp_daemon_restart/bgp_gr_daemon_restart_without_bfd_${TS}.csv"
LATEST="results/bgp_daemon_restart/bgp_gr_daemon_restart_without_bfd.csv"

TARGET="10.0.93.2"

now_ms() {
    date +%s%3N
}

backup_configs() {
    for r in hpe-r1 hpe-r2 hpe-r9; do
        docker cp "$r:/etc/bird/bird.conf" "configs/bgp_daemon_restart/${r}_before_without_bfd_${TS}.conf"
    done
}

restore_configs() {
    for r in hpe-r1 hpe-r2 hpe-r9; do
        if [ -f "configs/bgp_daemon_restart/${r}_before_without_bfd_${TS}.conf" ]; then
            docker cp "configs/bgp_daemon_restart/${r}_before_without_bfd_${TS}.conf" "$r:/etc/bird/bird.conf"
            docker exec "$r" birdc configure >/dev/null 2>&1 || true
        fi
    done
}

disable_bgp_bfd_only() {
python3 <<'PY'
from pathlib import Path
import subprocess
import re

routers = ["hpe-r1", "hpe-r2", "hpe-r9"]

Path("/tmp/hpe_bgp_gr_without_bfd").mkdir(exist_ok=True)

for r in routers:
    local = Path(f"/tmp/hpe_bgp_gr_without_bfd/{r}.conf")
    subprocess.run(["docker", "cp", f"{r}:/etc/bird/bird.conf", str(local)], check=True)
    text = local.read_text()

    # Disable only BGP-level bfd yes lines inside protocol bgp blocks.
    def patch_bgp_block(match):
        block = match.group(0)
        block = block.replace("    bfd yes;", "    # bfd yes;   # temporarily disabled for GR daemon restart test")
        block = block.replace("\n    bfd yes;\n", "\n    # bfd yes;   # temporarily disabled for GR daemon restart test\n")
        return block

    text = re.sub(r"protocol\s+bgp\s+\w+\s*\{.*?\n\}", patch_bgp_block, text, flags=re.S)

    local.write_text(text)
    subprocess.run(["docker", "cp", str(local), f"{r}:/etc/bird/bird.conf"], check=True)
    print(f"Disabled BGP-BFD in {r}")
PY
}

r1_state() {
    docker exec hpe-r1 birdc show protocols 2>/dev/null | awk '$1=="r9"{print $6}'
}

r2_state() {
    docker exec hpe-r2 birdc show protocols 2>/dev/null | awk '$1=="r9"{print $6}'
}

wait_for_bgp_established_before_test() {
    local timeout_ms="$1"
    local start now elapsed s1 s2
    start=$(now_ms)

    while true; do
        now=$(now_ms)
        elapsed=$((now - start))
        s1=$(r1_state)
        s2=$(r2_state)

        if [ "$s1" = "Established" ] && [ "$s2" = "Established" ]; then
            echo "$elapsed"
            return 0
        fi

        if [ "$elapsed" -ge "$timeout_ms" ]; then
            echo "TIMEOUT"
            return 1
        fi

        sleep 0.2
    done
}

restart_bird_on_r9() {
    docker exec hpe-r9 sh -c '
        pkill -TERM bird || true
        for i in $(seq 1 30); do
            pidof bird >/dev/null 2>&1 || break
            sleep 0.1
        done
        rm -f /run/bird/bird.ctl
        nohup bird -c /etc/bird/bird.conf >/tmp/bird-daemon-restart-without-bfd.log 2>&1 &
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

wait_for_bgp_reestablished() {
    local start_ms="$1"
    local timeout_ms="$2"
    local now elapsed s1 s2

    while true; do
        now=$(now_ms)
        elapsed=$((now - start_ms))
        s1=$(r1_state)
        s2=$(r2_state)

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
echo "CONTROLLED BGP GR DAEMON RESTART WITHOUT BGP-BFD"
echo "Timestamp: $TS"
echo "============================================================"

echo
echo "This test temporarily disables BFD only on BGP sessions."
echo "GR and LLGR remain enabled."
echo "After the test, original configs are restored."
echo

echo "============================================================"
echo "1. Backing up configs"
echo "============================================================"
backup_configs
echo "Configs backed up under configs/bgp_daemon_restart/"

echo
echo "============================================================"
echo "2. Disabling BGP-BFD only"
echo "============================================================"
disable_bgp_bfd_only

echo
echo "============================================================"
echo "3. Reconfiguring BIRD on hpe-r1, hpe-r2, hpe-r9"
echo "============================================================"
for r in hpe-r1 hpe-r2 hpe-r9; do
    echo "---- $r configure check ----"
    docker exec "$r" birdc configure check
    echo "---- $r configure ----"
    docker exec "$r" birdc configure
done

echo
echo "Waiting for BGP to be established before daemon restart..."
PRE_ESTABLISHED_MS=$(wait_for_bgp_established_before_test 30000)
echo "BGP established before test after: $PRE_ESTABLISHED_MS ms"

echo
echo "---- Protocols before daemon restart ----"
docker exec hpe-r1 birdc show protocols
docker exec hpe-r2 birdc show protocols
docker exec hpe-r9 birdc show protocols

echo
echo "============================================================"
echo "4. Starting background ping"
echo "============================================================"
docker exec hpe-h1 ping -i 0.05 "$TARGET" > "$PING_LOG" 2>&1 &
PING_PID=$!
echo "Ping log: $PING_LOG"
echo "Ping PID: $PING_PID"

echo
echo "============================================================"
echo "5. Starting route monitor on hpe-r1"
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

sleep 1

echo
echo "============================================================"
echo "6. Restarting full BIRD daemon on hpe-r9"
echo "============================================================"
RESTART_MS=$(now_ms)
echo "Restart command time ms: $RESTART_MS"
restart_bird_on_r9

BIRDC_READY_MS=$(wait_for_r9_birdc_ready "$RESTART_MS" 10000)
echo "hpe-r9 birdc ready after: $BIRDC_READY_MS ms"

BGP_REESTABLISHED_MS=$(wait_for_bgp_reestablished "$RESTART_MS" 30000)
echo "hpe-r1 and hpe-r2 BGP sessions to hpe-r9 re-established after: $BGP_REESTABLISHED_MS ms"

sleep 3

echo
echo "============================================================"
echo "7. Stopping monitors"
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
echo "8. Final state before restoring BFD"
echo "============================================================"
docker exec hpe-r1 birdc show protocols
docker exec hpe-r2 birdc show protocols
docker exec hpe-r9 birdc show protocols

echo
echo "---- Final hpe-h1 to hpe-h3 ping before restoring config ----"
docker exec hpe-h1 ping -c 5 "$TARGET" || true

FORWARDING_PRESERVED="unknown"
if [ "${LOSS:-NA}" = "0%" ] || [ "${LOSS:-NA}" = "0.0%" ] || [ "${LOSS:-NA}" = "0.00%" ]; then
    FORWARDING_PRESERVED="yes"
else
    FORWARDING_PRESERVED="partial_or_no"
fi

echo
echo "============================================================"
echo "9. Restoring original BGP-BFD configs"
echo "============================================================"
restore_configs
sleep 2
docker exec hpe-r1 birdc show protocols
docker exec hpe-r2 birdc show protocols
docker exec hpe-r9 birdc show protocols

echo
echo "============================================================"
echo "10. CSV result"
echo "============================================================"
echo "timestamp,test_name,restarted_router,bgp_bfd_state,birdc_ready_ms,bgp_reestablished_ms,ping_tx,ping_rx,ping_loss,direct_next_hop_samples,alternate_next_hop_samples,route_missing_samples,forwarding_preserved"
echo "$TS,bgp_gr_full_bird_daemon_restart,hpe-r9,bgp_bfd_temporarily_disabled,$BIRDC_READY_MS,$BGP_REESTABLISHED_MS,${TX:-NA},${RX:-NA},${LOSS:-NA},$DIRECT_R9_COUNT,$ALT_R2_COUNT,$MISSING_ROUTE_COUNT,$FORWARDING_PRESERVED"

} | tee "$EVIDENCE"

echo "timestamp,test_name,restarted_router,bgp_bfd_state,birdc_ready_ms,bgp_reestablished_ms,ping_tx,ping_rx,ping_loss,direct_next_hop_samples,alternate_next_hop_samples,route_missing_samples,forwarding_preserved" > "$CSV"
grep "^$TS,bgp_gr_full_bird_daemon_restart" "$EVIDENCE" >> "$CSV"
cp "$CSV" "$LATEST"

echo
echo "Saved evidence to: $EVIDENCE"
echo "Saved ping log to: $PING_LOG"
echo "Saved route log to: $ROUTE_LOG"
echo "Saved state log to: $STATE_LOG"
echo "Saved CSV to: $CSV"
echo "Updated latest CSV at: $LATEST"
