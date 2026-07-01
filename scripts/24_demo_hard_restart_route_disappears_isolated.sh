#!/usr/bin/env bash
set -u

mkdir -p evidence/hard_restart_route_disappear results/hard_restart_route_disappear configs/hard_restart_route_disappear

TS=$(date +%Y%m%d_%H%M%S)

EVIDENCE="evidence/hard_restart_route_disappear/hard_restart_route_disappears_isolated_${TS}.txt"
ROUTE_LOG="evidence/hard_restart_route_disappear/route_samples_hard_restart_isolated_${TS}.log"
CSV="results/hard_restart_route_disappear/hard_restart_route_disappears_isolated_${TS}.csv"
LATEST="results/hard_restart_route_disappear/hard_restart_route_disappears_isolated.csv"

TARGET_PREFIX="10.0.93.0/24"
TARGET_IP="10.0.93.2"

now_ms() {
    date +%s%3N
}

backup_configs() {
    for r in hpe-r1 hpe-r9; do
        docker cp "$r:/etc/bird/bird.conf" "configs/hard_restart_route_disappear/${r}_before_hard_isolated_${TS}.conf" >/dev/null
    done
}

restore_everything() {
    echo
    echo "Restoring original configs and sessions..."

    for r in hpe-r1 hpe-r9; do
        if [ -f "configs/hard_restart_route_disappear/${r}_before_hard_isolated_${TS}.conf" ]; then
            docker cp "configs/hard_restart_route_disappear/${r}_before_hard_isolated_${TS}.conf" "$r:/etc/bird/bird.conf" >/dev/null 2>&1 || true
        fi
    done

    if ! docker exec hpe-r9 pidof bird >/dev/null 2>&1; then
        docker exec hpe-r9 sh -c 'rm -f /run/bird/bird.ctl; nohup bird -c /etc/bird/bird.conf >/tmp/bird-hard-restore.log 2>&1 &' || true
        sleep 4
    fi

    docker exec hpe-r1 birdc configure >/dev/null 2>&1 || true
    docker exec hpe-r9 birdc configure >/dev/null 2>&1 || true

    docker exec hpe-r1 birdc enable r2 >/dev/null 2>&1 || true
    docker exec hpe-r1 birdc enable r9 >/dev/null 2>&1 || true
    docker exec hpe-r9 birdc enable r1 >/dev/null 2>&1 || true
    docker exec hpe-r9 birdc enable r2 >/dev/null 2>&1 || true

    sleep 5
}

trap restore_everything EXIT

patch_gr_llgr_off() {
python3 <<'PY'
from pathlib import Path
import subprocess
import re

for r in ["hpe-r1", "hpe-r9"]:
    local = Path(f"/tmp/{r}_hard_no_gr_llgr.conf")
    subprocess.run(["docker", "cp", f"{r}:/etc/bird/bird.conf", str(local)], check=True)

    text = local.read_text()

    text = re.sub(
        r"^(\s*)graceful restart yes;",
        r"\1# graceful restart yes;  # disabled for isolated hard restart demo",
        text,
        flags=re.M
    )

    text = re.sub(
        r"^(\s*)long lived graceful restart yes;",
        r"\1# long lived graceful restart yes;  # disabled for isolated hard restart demo",
        text,
        flags=re.M
    )

    local.write_text(text)
    subprocess.run(["docker", "cp", str(local), f"{r}:/etc/bird/bird.conf"], check=True)
    print(f"Disabled GR/LLGR temporarily on {r}")
PY
}

{
echo "============================================================"
echo "ISOLATED HARD BIRD DAEMON RESTART ROUTE DISAPPEARANCE TEST"
echo "Timestamp: $TS"
echo "Restarted router: hpe-r9"
echo "Backup path disabled: hpe-r1 protocol r2"
echo "GR/LLGR disabled: hpe-r1 and hpe-r9"
echo "============================================================"

echo
echo "1. Backing up configs"
echo "------------------------------------------------------------"
backup_configs
echo "Backups saved."

echo
echo "2. Temporarily disabling GR/LLGR"
echo "------------------------------------------------------------"
patch_gr_llgr_off

echo
echo "3. Applying configs first"
echo "------------------------------------------------------------"
docker exec hpe-r1 birdc configure || true
docker exec hpe-r9 birdc configure || true

sleep 5

echo
echo "4. NOW disabling alternate r2 path on hpe-r1"
echo "------------------------------------------------------------"
docker exec hpe-r1 birdc disable r2 || true

sleep 5

echo
echo "5. Isolation precheck"
echo "------------------------------------------------------------"
PRE_ROUTE="$(docker exec hpe-r1 birdc show route "$TARGET_PREFIX" all 2>/dev/null || true)"
echo "$PRE_ROUTE"

PRE_R9_COUNT=$(echo "$PRE_ROUTE" | grep -c "\[r9" || true)
PRE_R2_COUNT=$(echo "$PRE_ROUTE" | grep -c "\[r2" || true)
PRE_MISSING_COUNT=$(echo "$PRE_ROUTE" | grep -c "Network not found" || true)

echo
echo "Precheck r9 route count: $PRE_R9_COUNT"
echo "Precheck r2 route count: $PRE_R2_COUNT"
echo "Precheck missing count: $PRE_MISSING_COUNT"

if [ "$PRE_R9_COUNT" -eq 0 ]; then
    echo
    echo "ABORT: r9 route is not present before hard restart."
    exit 1
fi

if [ "$PRE_R2_COUNT" -ne 0 ]; then
    echo
    echo "ABORT: r2 backup route is still present. This is NOT isolated."
    exit 1
fi

if [ "$PRE_MISSING_COUNT" -ne 0 ]; then
    echo
    echo "ABORT: route is already missing before test."
    exit 1
fi

echo
echo "Isolation confirmed: only r9 route is present, r2 backup route is absent."

echo
echo "6. Starting route monitor"
echo "------------------------------------------------------------"
START_MONITOR_MS=$(now_ms)

(
    for i in $(seq 1 80); do
        NOW=$(now_ms)
        ELAPSED=$((NOW - START_MONITOR_MS))

        ROUTE="$(docker exec hpe-r1 birdc show route "$TARGET_PREFIX" all 2>/dev/null || true)"
        STATE_R9="$(docker exec hpe-r1 birdc show protocols r9 2>/dev/null | grep r9 || true)"
        STATE_R2="$(docker exec hpe-r1 birdc show protocols r2 2>/dev/null | grep r2 || true)"

        R9_PRESENT="no"
        R2_PRESENT="no"
        MISSING="no"

        echo "$ROUTE" | grep -q "\[r9" && R9_PRESENT="yes"
        echo "$ROUTE" | grep -q "\[r2" && R2_PRESENT="yes"
        echo "$ROUTE" | grep -q "Network not found" && MISSING="yes"

        echo "${ELAPSED} ms | r9_route=${R9_PRESENT} | r2_route=${R2_PRESENT} | missing=${MISSING} | r9_state=${STATE_R9} | r2_state=${STATE_R2}" >> "$ROUTE_LOG"
        sleep 0.2
    done
) &
MON_PID=$!

sleep 1

echo
echo "7. Hard killing BIRD on hpe-r9"
echo "------------------------------------------------------------"
FAIL_MS=$(now_ms)
docker exec hpe-r9 pkill -KILL bird || true

echo
echo "Waiting while route monitor observes withdrawal..."
sleep 10

wait "$MON_PID" >/dev/null 2>&1 || true

ROUTE_MISSING_SAMPLES=$(grep -c "missing=yes" "$ROUTE_LOG" || true)
R9_PRESENT_SAMPLES=$(grep -c "r9_route=yes" "$ROUTE_LOG" || true)
R2_PRESENT_SAMPLES=$(grep -c "r2_route=yes" "$ROUTE_LOG" || true)

FIRST_MISSING_MS=$(grep "missing=yes" "$ROUTE_LOG" | head -1 | awk '{print $1}')
FIRST_MISSING_MS=${FIRST_MISSING_MS:-NA}

if [ "$ROUTE_MISSING_SAMPLES" -gt 0 ] && [ "$R2_PRESENT_SAMPLES" -eq 0 ]; then
    ISOLATED_RESULT="pass"
else
    ISOLATED_RESULT="fail"
fi

echo
echo "8. Route after hard kill"
echo "------------------------------------------------------------"
docker exec hpe-r1 birdc show route "$TARGET_PREFIX" all || true

echo
echo "9. Result summary"
echo "------------------------------------------------------------"
echo "First missing observed at: $FIRST_MISSING_MS ms"
echo "Route missing samples on hpe-r1: $ROUTE_MISSING_SAMPLES"
echo "r9 route present samples: $R9_PRESENT_SAMPLES"
echo "r2 route present samples: $R2_PRESENT_SAMPLES"
echo "isolated_result: $ISOLATED_RESULT"

echo
echo "10. Starting BIRD normally again on hpe-r9"
echo "------------------------------------------------------------"
docker exec hpe-r9 sh -c 'rm -f /run/bird/bird.ctl; nohup bird -c /etc/bird/bird.conf >/tmp/bird-hard-isolated.log 2>&1 &' || true

sleep 5

echo
echo "11. CSV result"
echo "------------------------------------------------------------"
echo "timestamp,test_name,restarted_router,method,first_missing_ms,route_missing_samples,r9_route_present_samples,r2_route_present_samples,isolated_result"
echo "$TS,hard_restart_route_disappears_isolated,hpe-r9,pkill_KILL_plus_normal_bird_start,$FIRST_MISSING_MS,$ROUTE_MISSING_SAMPLES,$R9_PRESENT_SAMPLES,$R2_PRESENT_SAMPLES,$ISOLATED_RESULT"

} | tee "$EVIDENCE"

echo "timestamp,test_name,restarted_router,method,first_missing_ms,route_missing_samples,r9_route_present_samples,r2_route_present_samples,isolated_result" > "$CSV"
grep "^$TS,hard_restart_route_disappears_isolated" "$EVIDENCE" >> "$CSV"
cp "$CSV" "$LATEST"

trap - EXIT
restore_everything | tee -a "$EVIDENCE"

echo
echo "Saved evidence to: $EVIDENCE"
echo "Saved route log to: $ROUTE_LOG"
echo "Saved CSV to: $CSV"
echo "Updated latest CSV at: $LATEST"
