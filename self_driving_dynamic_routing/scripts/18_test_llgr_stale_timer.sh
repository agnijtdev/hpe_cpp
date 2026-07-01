#!/usr/bin/env bash
set -u

mkdir -p evidence/llgr_stale_timer results/llgr_stale_timer configs/llgr_stale_timer

TS=$(date +%Y%m%d_%H%M%S)
EVIDENCE="evidence/llgr_stale_timer/llgr_stale_timer_${TS}.txt"
ROUTE_LOG="evidence/llgr_stale_timer/llgr_route_samples_${TS}.log"
CSV="results/llgr_stale_timer/llgr_stale_timer_${TS}.csv"
LATEST="results/llgr_stale_timer/llgr_stale_timer.csv"

TARGET_PREFIX="10.0.93.0/24"
TARGET_IP="10.0.93.2"

now_ms() {
    date +%s%3N
}

backup_configs() {
    docker cp hpe-r1:/etc/bird/bird.conf "configs/llgr_stale_timer/hpe-r1_before_llgr_${TS}.conf"
    docker cp hpe-r9:/etc/bird/bird.conf "configs/llgr_stale_timer/hpe-r9_before_llgr_${TS}.conf"
}

restore_configs_and_state() {
    echo "Restoring configs and BIRD state..." >> "$EVIDENCE"

    if [ -f "configs/llgr_stale_timer/hpe-r1_before_llgr_${TS}.conf" ]; then
        docker cp "configs/llgr_stale_timer/hpe-r1_before_llgr_${TS}.conf" hpe-r1:/etc/bird/bird.conf
    fi

    if [ -f "configs/llgr_stale_timer/hpe-r9_before_llgr_${TS}.conf" ]; then
        docker cp "configs/llgr_stale_timer/hpe-r9_before_llgr_${TS}.conf" hpe-r9:/etc/bird/bird.conf
    fi

    # Make sure BIRD is running on hpe-r9
    if ! docker exec hpe-r9 pidof bird >/dev/null 2>&1; then
        docker exec hpe-r9 sh -c 'rm -f /run/bird/bird.ctl; nohup bird -c /etc/bird/bird.conf >/tmp/bird-restore.log 2>&1 &' || true
        sleep 2
    fi

    docker exec hpe-r1 birdc configure >/dev/null 2>&1 || true
    docker exec hpe-r9 birdc configure >/dev/null 2>&1 || true

    docker exec hpe-r1 birdc enable r2 >/dev/null 2>&1 || true
    docker exec hpe-r1 birdc enable r9 >/dev/null 2>&1 || true
    docker exec hpe-r9 birdc enable r1 >/dev/null 2>&1 || true

    sleep 3
}

trap restore_configs_and_state EXIT

patch_llgr_timers() {
python3 <<'PY'
from pathlib import Path
import subprocess
import re

Path("/tmp/hpe_llgr").mkdir(exist_ok=True)

targets = {
    "hpe-r1": "r9",
    "hpe-r9": "r1",
}

def patch_block(block):
    # Disable BFD only for this BGP session so BFD does not immediately override GR/LLGR observation.
    block = block.replace("    bfd yes;", "    # bfd yes;  # temporarily disabled for LLGR stale timer test")

    # Ensure GR and LLGR are enabled.
    if "graceful restart yes;" not in block:
        block = block.replace("neighbor", "graceful restart yes;\n\n    neighbor", 1)

    if "long lived graceful restart yes;" not in block:
        block = block.replace("graceful restart yes;", "graceful restart yes;\n    long lived graceful restart yes;", 1)

    # Remove old explicit timer lines if present.
    block = re.sub(r"\n\s*graceful restart time\s+\d+;\s*", "\n", block)
    block = re.sub(r"\n\s*long lived stale time\s+\d+;\s*", "\n", block)

    # Add short timers after LLGR enable line.
    block = block.replace(
        "    long lived graceful restart yes;",
        "    long lived graceful restart yes;\n    graceful restart time 5;\n    long lived stale time 10;",
        1
    )

    return block

for router, proto in targets.items():
    local = Path(f"/tmp/hpe_llgr/{router}.conf")
    subprocess.run(["docker", "cp", f"{router}:/etc/bird/bird.conf", str(local)], check=True)

    text = local.read_text()

    pattern = rf"protocol\s+bgp\s+{proto}\s*\{{.*?\n\}}"
    new_text, n = re.subn(pattern, lambda m: patch_block(m.group(0)), text, count=1, flags=re.S)

    if n == 0:
        raise SystemExit(f"Could not find protocol bgp {proto} in {router}")

    local.write_text(new_text)
    subprocess.run(["docker", "cp", str(local), f"{router}:/etc/bird/bird.conf"], check=True)

    print(f"Patched {router} BGP {proto} with short GR/LLGR timers")
PY
}

bird_running_r9() {
    docker exec hpe-r9 pidof bird >/dev/null 2>&1
}

start_bird_r9() {
    docker exec hpe-r9 sh -c 'rm -f /run/bird/bird.ctl; nohup bird -c /etc/bird/bird.conf >/tmp/bird-llgr-restore.log 2>&1 &' || true
}

stop_bird_r9() {
    docker exec hpe-r9 sh -c 'pkill -KILL bird || true' || true
}

route_from_r9_present() {
    docker exec hpe-r1 birdc show route "$TARGET_PREFIX" all 2>/dev/null | grep -q "\[r9"
}

route_text() {
    docker exec hpe-r1 birdc show route "$TARGET_PREFIX" all 2>/dev/null || true
}

{
echo "============================================================"
echo "LLGR STALE ROUTE TIMER EXPERIMENT"
echo "Timestamp: $TS"
echo "============================================================"

echo
echo "Goal:"
echo "Temporarily reduce GR/LLGR timers, stop hpe-r9 BIRD, and observe stale route behaviour on hpe-r1."
echo

echo "============================================================"
echo "1. Backing up configs"
echo "============================================================"
backup_configs
echo "Backups saved under configs/llgr_stale_timer/"

echo
echo "============================================================"
echo "2. Patching short LLGR timers"
echo "============================================================"
patch_llgr_timers

echo
echo "============================================================"
echo "3. Checking and applying config"
echo "============================================================"
echo "---- hpe-r1 configure check ----"
docker exec hpe-r1 birdc configure check
echo "---- hpe-r9 configure check ----"
docker exec hpe-r9 birdc configure check

echo "---- hpe-r1 configure ----"
docker exec hpe-r1 birdc configure
echo "---- hpe-r9 configure ----"
docker exec hpe-r9 birdc configure

sleep 3

echo
echo "============================================================"
echo "4. Confirm new timers"
echo "============================================================"
echo "---- hpe-r1 protocol r9 ----"
docker exec hpe-r1 birdc show protocols all r9 | grep -i -E "BGP state|Graceful|Long-lived|Restart time|LL stale|stale" -C 2 || true

echo
echo "---- hpe-r9 protocol r1 ----"
docker exec hpe-r9 birdc show protocols all r1 | grep -i -E "BGP state|Graceful|Long-lived|Restart time|LL stale|stale" -C 2 || true

echo
echo "============================================================"
echo "5. Isolating hpe-r1 from alternate r2 BGP path"
echo "============================================================"
docker exec hpe-r1 birdc disable r2 || true
sleep 2

echo "---- hpe-r1 route before hpe-r9 failure ----"
route_text

echo
echo "============================================================"
echo "6. Stopping BIRD on hpe-r9"
echo "============================================================"
FAIL_MS=$(now_ms)
echo "Failure time ms: $FAIL_MS"
stop_bird_r9

echo
echo "============================================================"
echo "7. Sampling route on hpe-r1 for 22 seconds"
echo "============================================================"

FIRST_MISSING="NA"
FIRST_STALE_TEXT="NA"
LAST_PRESENT="NA"

for i in $(seq 0 22); do
    NOW=$(now_ms)
    ELAPSED=$((NOW - FAIL_MS))

    SAMPLE="$(route_text)"
    ONE_LINE="$(echo "$SAMPLE" | tr '\n' ' ' | sed 's/  */ /g')"

    PRESENT="no"
    if echo "$SAMPLE" | grep -q "\[r9"; then
        PRESENT="yes"
        LAST_PRESENT="$ELAPSED"
    fi

    STALE_TEXT="no"
    if echo "$SAMPLE" | grep -i -q "stale\|LLGR\|LLGR_STALE"; then
        STALE_TEXT="yes"
        if [ "$FIRST_STALE_TEXT" = "NA" ]; then
            FIRST_STALE_TEXT="$ELAPSED"
        fi
    fi

    if [ "$PRESENT" = "no" ] && [ "$FIRST_MISSING" = "NA" ]; then
        FIRST_MISSING="$ELAPSED"
    fi

    echo "${ELAPSED} ms | r9_route_present=${PRESENT} | stale_text_seen=${STALE_TEXT} | ${ONE_LINE}" | tee -a "$ROUTE_LOG"
    sleep 1
done

echo
echo "First time route from r9 became missing: $FIRST_MISSING ms"
echo "Last time route from r9 was still present: $LAST_PRESENT ms"
echo "First time stale/LLGR text was seen: $FIRST_STALE_TEXT ms"

echo
echo "============================================================"
echo "8. Restarting hpe-r9 BIRD and restoring configs"
echo "============================================================"
start_bird_r9
sleep 3

restore_configs_and_state
trap - EXIT

echo
echo "============================================================"
echo "9. Final health check"
echo "============================================================"
docker exec hpe-r1 birdc show protocols
docker exec hpe-r9 birdc show protocols
docker exec hpe-r1 birdc enable r2 >/dev/null 2>&1 || true
docker exec hpe-h1 ping -c 5 "$TARGET_IP" || true

echo
echo "============================================================"
echo "10. CSV result"
echo "============================================================"
echo "timestamp,test_name,target_prefix,gr_time_s,llgr_stale_time_s,first_missing_ms,last_present_ms,first_stale_text_ms"
echo "$TS,llgr_stale_timer,$TARGET_PREFIX,5,10,$FIRST_MISSING,$LAST_PRESENT,$FIRST_STALE_TEXT"

} | tee "$EVIDENCE"

echo "timestamp,test_name,target_prefix,gr_time_s,llgr_stale_time_s,first_missing_ms,last_present_ms,first_stale_text_ms" > "$CSV"
grep "^$TS,llgr_stale_timer" "$EVIDENCE" >> "$CSV"
cp "$CSV" "$LATEST"

echo
echo "Saved evidence to: $EVIDENCE"
echo "Saved route samples to: $ROUTE_LOG"
echo "Saved CSV to: $CSV"
echo "Updated latest CSV at: $LATEST"
