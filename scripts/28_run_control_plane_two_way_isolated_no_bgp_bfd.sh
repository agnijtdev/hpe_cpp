#!/usr/bin/env bash
set -u

mkdir -p configs/bgp_protocol_restart evidence/bgp_protocol_restart

TS=$(date +%Y%m%d_%H%M%S)
EVIDENCE="evidence/bgp_protocol_restart/control_plane_no_bgp_bfd_wrapper_${TS}.txt"

echo "============================================================" | tee "$EVIDENCE"
echo "CONTROL-PLANE RESTART WITH TWO-WAY ISOLATION AND BGP-BFD OFF" | tee -a "$EVIDENCE"
echo "Timestamp: $TS" | tee -a "$EVIDENCE"
echo "GR/LLGR: kept enabled" | tee -a "$EVIDENCE"
echo "BGP-level BFD: temporarily disabled" | tee -a "$EVIDENCE"
echo "Actual test script: scripts/27_test_bgp_control_plane_two_way_isolated.sh" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

echo | tee -a "$EVIDENCE"
echo "1. Backing up configs" | tee -a "$EVIDENCE"

for r in hpe-r1 hpe-r2 hpe-r9; do
    docker cp "$r:/etc/bird/bird.conf" "configs/bgp_protocol_restart/${r}_before_no_bgp_bfd_${TS}.conf"
done

restore_configs() {
    echo | tee -a "$EVIDENCE"
    echo "Restoring original configs and sessions..." | tee -a "$EVIDENCE"

    for r in hpe-r1 hpe-r2 hpe-r9; do
        docker cp "configs/bgp_protocol_restart/${r}_before_no_bgp_bfd_${TS}.conf" "$r:/etc/bird/bird.conf" >/dev/null 2>&1 || true
        docker exec "$r" birdc configure >/dev/null 2>&1 || true
    done

    docker exec hpe-r1 birdc enable r2 >/dev/null 2>&1 || true
    docker exec hpe-r1 birdc enable r9 >/dev/null 2>&1 || true
    docker exec hpe-r9 birdc enable r1 >/dev/null 2>&1 || true
    docker exec hpe-r9 birdc enable r2 >/dev/null 2>&1 || true

    sleep 5
}

trap restore_configs EXIT

echo | tee -a "$EVIDENCE"
echo "2. Temporarily disabling BGP-level BFD only" | tee -a "$EVIDENCE"

python3 <<'PY'
from pathlib import Path
import subprocess

routers = ["hpe-r1", "hpe-r2", "hpe-r9"]
tmp = Path("/tmp/hpe_no_bgp_bfd")
tmp.mkdir(exist_ok=True)

for r in routers:
    local = tmp / f"{r}.conf"
    subprocess.run(["docker", "cp", f"{r}:/etc/bird/bird.conf", str(local)], check=True)

    text = local.read_text()
    text = text.replace(
        "    bfd yes;",
        "    # bfd yes;  # temporarily disabled for GR/LLGR control-plane restart test"
    )

    local.write_text(text)
    subprocess.run(["docker", "cp", str(local), f"{r}:/etc/bird/bird.conf"], check=True)
    print(f"Disabled BGP-level BFD temporarily on {r}")
PY

echo | tee -a "$EVIDENCE"
echo "3. Applying configs" | tee -a "$EVIDENCE"

docker exec hpe-r1 birdc configure | tee -a "$EVIDENCE"
docker exec hpe-r2 birdc configure | tee -a "$EVIDENCE"
docker exec hpe-r9 birdc configure | tee -a "$EVIDENCE"

sleep 5

echo | tee -a "$EVIDENCE"
echo "4. Verifying GR/LLGR still enabled and BFD line removed from BGP config" | tee -a "$EVIDENCE"

echo "--- hpe-r1 r9 protocol config/status ---" | tee -a "$EVIDENCE"
docker exec hpe-r1 birdc show protocols all r9 | grep -i -E "BGP state|graceful|long-lived|bfd|restart|Established" | tee -a "$EVIDENCE" || true

echo "--- hpe-r9 r1 protocol config/status ---" | tee -a "$EVIDENCE"
docker exec hpe-r9 birdc show protocols all r1 | grep -i -E "BGP state|graceful|long-lived|bfd|restart|Established" | tee -a "$EVIDENCE" || true

echo | tee -a "$EVIDENCE"
echo "5. Running the two-way isolated control-plane restart test" | tee -a "$EVIDENCE"
echo "------------------------------------------------------------" | tee -a "$EVIDENCE"

./scripts/27_test_bgp_control_plane_two_way_isolated.sh | tee -a "$EVIDENCE"

trap - EXIT
restore_configs

echo | tee -a "$EVIDENCE"
echo "Wrapper evidence saved to: $EVIDENCE" | tee -a "$EVIDENCE"
