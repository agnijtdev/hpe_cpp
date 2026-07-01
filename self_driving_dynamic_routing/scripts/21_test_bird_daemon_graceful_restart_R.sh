#!/usr/bin/env bash
set -u

mkdir -p evidence/bird_daemon_graceful_restart results/bird_daemon_graceful_restart configs/bird_daemon_graceful_restart

TS=$(date +%Y%m%d_%H%M%S)

EVIDENCE="evidence/bird_daemon_graceful_restart/bird_daemon_graceful_restart_R_${TS}.txt"
PING_LOG="evidence/bird_daemon_graceful_restart/ping_${TS}.log"
ROUTE_LOG="evidence/bird_daemon_graceful_restart/route_samples_${TS}.log"
CSV="results/bird_daemon_graceful_restart/bird_daemon_graceful_restart_R_${TS}.csv"
LATEST="results/bird_daemon_graceful_restart/bird_daemon_graceful_restart_R.csv"

TARGET_IP="10.0.93.2"
TARGET_PREFIX="10.0.93.0/24"

now_ms() {
    date +%s%3N
}

backup_configs() {
    for r in hpe-r1 hpe-r2 hpe-r9; do
        docker cp "$r:/etc/bird/bird.conf" "configs/bird_daemon_graceful_restart/${r}_before_R_${TS}.conf" >/dev/null
    done
}

restore_configs() {
    echo "Restoring configs..." >> "$EVIDENCE"

    for r in hpe-r1 hpe-r2 hpe-r9; do
        if [ -f "configs/bird_daemon_graceful_restart/${r}_before_R_${TS}.conf" ]; then
            docker cp "configs/bird_daemon_graceful_restart/${r}_before_R_${TS}.conf" "$r:/etc/bird/bird.conf" >/dev/null
        fi
    done

    # Make sure BIRD is running on hpe-r9
    if ! docker exec hpe-r9 pidof bird >/dev/null 2>&1; then
        docker exec hpe-r9 sh -c 'rm -f /run/bird/bird.ctl; nohup bird -c /etc/bird/bird.conf >/tmp/bird-restore.log 2>&1 &' || true
        sleep 3
    fi

    for r in hpe-r1 hpe-r2 hpe-r9; do
        docker exec "$r" birdc configure >/dev/null 2>&1 || true
    done

    docker exec hpe-r1 birdc enable r9 >/dev/null 2>&1 || true
    docker exec hpe-r2 birdc enable r9 >/dev/null 2>&1 || true
    docker exec hpe-r9 birdc enable r1 >/dev/null 2>&1 || true
    docker exec hpe-r9 birdc enable r2 >/dev/null 2>&1 || true
}

trap restore_configs EXIT

patch_bgp_bfd_off_for_gr_isolation() {
python3 <<'PY'
from pathlib import Path
import subprocess
import re

routers = ["hpe-r1", "hpe-r2", "hpe-r9"]
tmpdir = Path("/tmp/hpe_bird_gr_R")
tmpdir.mkdir(exist_ok=True)

def patch_bgp_blocks(text):
    # Disable only BGP-level BFD inside protocol bgp blocks.
    # This avoids BFD instantly overriding GR during daemon restart.
    def repl(match):
        block = match.group(0)
        block = block.replace("    bfd yes;", "    # bfd yes;  # temporarily disabled for daemon GR -R test")
        return block

    pattern = r"protocol\s+bgp\s+\w+\s*\{.*?\n\s*ipv4\s*\{.*?\n\s*\};"
    return re.sub(pattern, repl, text, flags=re.S)

for r in routers:
    local = tmpdir / f"{r}.conf"
    subprocess.run(["docker", "cp", f"{r}:/etc/bird/bird.conf", str(local)], check=True)
    text = local.read_text()
    text = patch_bgp_blocks(text)
    local.write_text(text)
    subprocess.run(["docker", "cp", str(local), f"{r}:/etc/bird/bird.conf"], check=True)
    print(f"Patched BGP-BFD off temporarily on {r}")
PY
}

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
echo "OFFICIAL BIRD DAEMON GRACEFUL RESTART TEST USING -R"
echo "Timestamp: $TS"
echo "Restarted router: hpe-r9"
echo "Traffic: hpe-h1 -> hpe-h3 ($TARGET_IP)"
echo "============================================================"

echo
echo "1. Baseline state before test"
echo "------------------------------------------------------------"

echo "hpe-r1 BGP route to hpe-h3:"
docker exec hpe-r1 birdc show route "$TARGET_PREFIX" all || true

echo
echo "hpe-r9 protocols:"
docker exec hpe-r9 birdc show protocols || true

echo
echo "Baseline ping:"
docker exec hpe-h1 ping -c 5 "$TARGET_IP" || true

echo
echo "2. Backing up configs"
echo "------------------------------------------------------------"
backup_configs
echo "Backups saved."

echo
echo "3. Temporarily disabling BGP-level BFD for GR isolation"
echo "------------------------------------------------------------"
patch_bgp_bfd_off_for_gr_isolation

echo
echo "Applying configs:"
docker exec hpe-r1 birdc configure || true
docker exec hpe-r2 birdc configure || true
docker exec hpe-r9 birdc configure || true

sleep 5

echo
echo "Checking BGP sessions after temporary config:"
docker exec hpe-r1 birdc show protocols r9 || true
docker exec hpe-r9 birdc show protocols r1 || true

echo
echo "4. Starting continuous ping"
echo "------------------------------------------------------------"
docker exec hpe-h1 sh -c "ping -i 0.05 $TARGET_IP" > "$PING_LOG" 2>&1 &
PING_PID=$!

sleep 2

echo
echo "5. Starting route monitor on hpe-r1"
echo "------------------------------------------------------------"
START_MONITOR_MS=$(now_ms)

(
    for i in $(seq 1 120); do
        NOW=$(now_ms)
        ELAPSED=$((NOW - START_MONITOR_MS))

        ROUTE="$(docker exec hpe-r1 birdc show route "$TARGET_PREFIX" all 2>/dev/null || true)"
        STATE="$(docker exec hpe-r1 birdc show protocols r9 2>/dev/null | grep r9 || true)"

        R9_PRESENT="no"
        R2_PRESENT="no"
        MISSING="no"

        echo "$ROUTE" | grep -q "\[r9" && R9_PRESENT="yes"
        echo "$ROUTE" | grep -q "\[r2" && R2_PRESENT="yes"
        echo "$ROUTE" | grep -q "Network not found" && MISSING="yes"

        echo "${ELAPSED} ms | r9_route=${R9_PRESENT} | r2_route=${R2_PRESENT} | missing=${MISSING} | state=${STATE}" >> "$ROUTE_LOG"
        sleep 0.2
    done
) &
MON_PID=$!

sleep 1

echo
echo "6. Performing official daemon graceful restart"
echo "------------------------------------------------------------"

FAIL_MS=$(now_ms)

echo "Running: birdc graceful restart on hpe-r9"
GR_OUTPUT=$(docker exec hpe-r9 sh -c "birdc graceful restart 2>&1" || true)
echo "$GR_OUTPUT"

echo
echo "Waiting for old hpe-r9 BIRD process to exit..."
for i in $(seq 1 30); do
    if ! docker exec hpe-r9 pidof bird >/dev/null 2>&1; then
        echo "Old BIRD process exited."
        break
    fi
    sleep 0.2
done

echo
echo "Starting BIRD with -R:"
echo "bird -R -c /etc/bird/bird.conf"

docker exec hpe-r9 sh -c 'rm -f /run/bird/bird.ctl; nohup bird -R -c /etc/bird/bird.conf >/tmp/bird-R.log 2>&1 &' || true

BIRDC_READY_MS="NA"
for i in $(seq 1 100); do
    NOW=$(now_ms)
    if docker exec hpe-r9 birdc show status >/dev/null 2>&1; then
        BIRDC_READY_MS=$((NOW - FAIL_MS))
        break
    fi
    sleep 0.1
done

BGP_REEST_MS="NA"
for i in $(seq 1 200); do
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

ROUTE_MISSING_SAMPLES=$(grep -c "missing=yes" "$ROUTE_LOG" || true)
R9_PRESENT_SAMPLES=$(grep -c "r9_route=yes" "$ROUTE_LOG" || true)
R2_PRESENT_SAMPLES=$(grep -c "r2_route=yes" "$ROUTE_LOG" || true)

echo
echo "7. Result summary"
echo "------------------------------------------------------------"
echo "birdc ready after restart: $BIRDC_READY_MS ms"
echo "BGP r9 re-established on hpe-r1: $BGP_REEST_MS ms"
echo "Ping transmitted: $TX"
echo "Ping received: $RX"
echo "Ping loss percent: $LOSS"
echo "Route missing samples on hpe-r1: $ROUTE_MISSING_SAMPLES"
echo "r9 route present samples: $R9_PRESENT_SAMPLES"
echo "r2 route present samples: $R2_PRESENT_SAMPLES"

echo
echo "8. Final protocol state before restore"
echo "------------------------------------------------------------"
docker exec hpe-r1 birdc show protocols r9 || true
docker exec hpe-r9 birdc show protocols r1 || true

echo
echo "9. Restoring original configs"
echo "------------------------------------------------------------"
restore_configs
trap - EXIT

sleep 5

echo
echo "10. Final health check"
echo "------------------------------------------------------------"
docker exec hpe-h1 ping -c 5 "$TARGET_IP" || true

echo
echo "11. CSV result"
echo "------------------------------------------------------------"
echo "timestamp,test_name,restarted_router,method,birdc_ready_ms,bgp_reestablished_ms,ping_tx,ping_rx,ping_loss_percent,route_missing_samples,r9_route_present_samples,r2_route_present_samples"
echo "$TS,bird_daemon_graceful_restart_R,hpe-r9,birdc_graceful_restart_plus_bird_R,$BIRDC_READY_MS,$BGP_REEST_MS,$TX,$RX,$LOSS,$ROUTE_MISSING_SAMPLES,$R9_PRESENT_SAMPLES,$R2_PRESENT_SAMPLES"

} | tee "$EVIDENCE"

echo "timestamp,test_name,restarted_router,method,birdc_ready_ms,bgp_reestablished_ms,ping_tx,ping_rx,ping_loss_percent,route_missing_samples,r9_route_present_samples,r2_route_present_samples" > "$CSV"
grep "^$TS,bird_daemon_graceful_restart_R" "$EVIDENCE" >> "$CSV"
cp "$CSV" "$LATEST"

echo
echo "Saved evidence to: $EVIDENCE"
echo "Saved ping log to: $PING_LOG"
echo "Saved route log to: $ROUTE_LOG"
echo "Saved CSV to: $CSV"
echo "Updated latest CSV at: $LATEST"
