#!/usr/bin/env bash
set -u

TS=$(date +%Y%m%d_%H%M%S)

mkdir -p evidence/llgr_perfect_proof results/llgr_perfect_proof configs/llgr_perfect_proof

EVIDENCE="evidence/llgr_perfect_proof/llgr_perfect_proof_${TS}.txt"
ROUTE_LOG="evidence/llgr_perfect_proof/route_samples_${TS}.log"
PING_LOG="evidence/llgr_perfect_proof/ping_${TS}.log"
CSV="results/llgr_perfect_proof/llgr_perfect_proof_${TS}.csv"
LATEST="results/llgr_perfect_proof/llgr_perfect_proof.csv"

ROUTERS="hpe-r1 hpe-r2 hpe-r9"

echo "============================================================" | tee "$EVIDENCE"
echo "LLGR PERFECT PROOF TEST" | tee -a "$EVIDENCE"
echo "Timestamp: $TS" | tee -a "$EVIDENCE"
echo "Target prefix: 10.0.93.0/24" | tee -a "$EVIDENCE"
echo "Peer restarted/killed: hpe-r9" | tee -a "$EVIDENCE"
echo "Observer router: hpe-r1" | tee -a "$EVIDENCE"
echo "GR timer: 5 seconds" | tee -a "$EVIDENCE"
echo "LLGR stale timer: 10 seconds" | tee -a "$EVIDENCE"
echo "Expected route retention window: about 15 seconds" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

cleanup() {
    echo | tee -a "$EVIDENCE"
    echo "============================================================" | tee -a "$EVIDENCE"
    echo "CLEANUP: restoring original configs and BGP state" | tee -a "$EVIDENCE"
    echo "============================================================" | tee -a "$EVIDENCE"

    docker exec hpe-h1 pkill -INT ping >/dev/null 2>&1 || true

    for r in $ROUTERS; do
        if [ -f "configs/llgr_perfect_proof/${r}_before_${TS}.conf" ]; then
            docker cp "configs/llgr_perfect_proof/${r}_before_${TS}.conf" "$r:/etc/bird/bird.conf" >/dev/null 2>&1 || true
        fi
    done

    docker exec hpe-r9 sh -lc 'pgrep bird >/dev/null || bird -c /etc/bird/bird.conf' >/dev/null 2>&1 || true

    for r in $ROUTERS; do
        docker exec "$r" birdc configure >/dev/null 2>&1 || true
    done

    docker exec hpe-r1 birdc enable r2 >/dev/null 2>&1 || true
    docker exec hpe-r1 birdc enable r9 >/dev/null 2>&1 || true
    docker exec hpe-r9 birdc enable r1 >/dev/null 2>&1 || true
    docker exec hpe-r9 birdc enable r2 >/dev/null 2>&1 || true

    docker exec hpe-h1 ip route replace default via 10.0.61.3 >/dev/null 2>&1 || true
    docker exec hpe-h2 ip route replace default via 10.0.82.3 >/dev/null 2>&1 || true
    docker exec hpe-h3 ip route replace default via 10.0.93.3 >/dev/null 2>&1 || true

    for r in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9; do
        docker exec "$r" sh -lc '
            sysctl -w net.ipv4.ip_forward=1 >/dev/null
            for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f" 2>/dev/null || true; done
        ' >/dev/null 2>&1 || true
    done

    sleep 15
}
trap cleanup EXIT

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "1. Backup current configs" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

for r in $ROUTERS; do
    docker cp "$r:/etc/bird/bird.conf" "configs/llgr_perfect_proof/${r}_before_${TS}.conf"
    echo "Backed up $r config" | tee -a "$EVIDENCE"
done

patch_router_config() {
    local r="$1"
    local tmp
    tmp=$(mktemp)

    docker cp "$r:/etc/bird/bird.conf" "$tmp"

    python3 - "$tmp" <<'PY'
import sys
import re

path = sys.argv[1]
s = open(path).read()

def find_block_end(text, start):
    depth = 0
    i = start
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(text)

def patch_blocks(text, pattern, patch_func):
    out = []
    i = 0
    for m in re.finditer(pattern, text):
        if m.start() < i:
            continue
        out.append(text[i:m.start()])
        end = find_block_end(text, m.start())
        block = text[m.start():end]
        out.append(patch_func(block))
        i = end
    out.append(text[i:])
    return "".join(out)

def patch_kernel(block):
    if "persist;" not in block:
        block = block.replace("{", "{\n    persist;", 1)
    return block

def patch_bgp(block):
    # Disable BGP-level BFD only. OSPF BFD is untouched.
    block = re.sub(
        r'^(\s*)bfd yes;\s*$',
        r'\1# bfd yes;  # disabled temporarily for LLGR proof',
        block,
        flags=re.M
    )

    if "graceful restart yes;" not in block:
        block = re.sub(
            r'(^\s*neighbor\s+.*?;\s*$)',
            r'\1\n\n    graceful restart yes;',
            block,
            count=1,
            flags=re.M
        )

    if "long lived graceful restart yes;" not in block:
        block = block.replace(
            "graceful restart yes;",
            "graceful restart yes;\n    long lived graceful restart yes;",
            1
        )

    # Remove old timer lines if already present.
    block = re.sub(r'^\s*graceful restart time\s+\d+;\s*$', "", block, flags=re.M)
    block = re.sub(r'^\s*long lived stale time\s+\d+;\s*$', "", block, flags=re.M)

    # Add short timers for demo.
    block = block.replace(
        "long lived graceful restart yes;",
        "long lived graceful restart yes;\n    graceful restart time 5;\n    long lived stale time 10;",
        1
    )

    return block

s = patch_blocks(s, r'protocol\s+kernel\s*\{', patch_kernel)
s = patch_blocks(s, r'protocol\s+bgp\s+\w+\s*\{', patch_bgp)

open(path, "w").write(s)
PY

    docker cp "$tmp" "$r:/etc/bird/bird.conf"
    rm -f "$tmp"
}

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "2. Patch configs: persist + GR/LLGR timers + disable BGP BFD" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

for r in hpe-r1 hpe-r9; do
    patch_router_config "$r"
    echo "Patched $r" | tee -a "$EVIDENCE"
done

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "3. Configure BIRD after patch" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

for r in hpe-r1 hpe-r9; do
    echo "---- $r configure ----" | tee -a "$EVIDENCE"
    docker exec "$r" birdc configure 2>&1 | tee -a "$EVIDENCE"
done

sleep 10

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "4. Verify GR/LLGR capabilities and timers" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

docker exec hpe-r1 birdc show protocols all r9 | grep -i -E "BGP state|Graceful|Long-lived|Restart time|LL stale|bfd|stale" -C 2 | tee -a "$EVIDENCE" || true

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "5. Isolate r1 to use only direct r9 path" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

docker exec hpe-r1 birdc disable r2 2>&1 | tee -a "$EVIDENCE" || true
sleep 5

echo "Route before failure:" | tee -a "$EVIDENCE"
docker exec hpe-r1 birdc show route 10.0.93.0/24 all | tee -a "$EVIDENCE" || true
docker exec hpe-r1 ip route get 10.0.93.2 | tee -a "$EVIDENCE" || true

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "6. Start ping from h1 to h3" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

docker exec hpe-h1 sh -lc "rm -f /tmp/llgr_ping_${TS}.log; ping -i 0.1 10.0.93.2 > /tmp/llgr_ping_${TS}.log 2>&1 & echo \$!" > /tmp/llgr_ping_pid_${TS}.txt
PING_PID=$(cat /tmp/llgr_ping_pid_${TS}.txt)
echo "Ping PID inside hpe-h1: $PING_PID" | tee -a "$EVIDENCE"

monitor_routes() {
    local end_time=$(( $(date +%s) + 25 ))

    while [ "$(date +%s)" -lt "$end_time" ]; do
        now_ms=$(date +%s%3N)

        out=$(docker exec hpe-r1 birdc show route 10.0.93.0/24 all 2>&1 | tr '\n' ' ')
        proto=$(docker exec hpe-r1 birdc show protocols r9 2>&1 | tr '\n' ' ')

        present="no"
        stale_marker="no"

        echo "$out" | grep -q "10.0.93.0/24" && present="yes"

        # BIRD may show stale using text, route suffix like (100s), or LLGR_STALE community (65535,6).
        echo "$out" | grep -Eiq "stale|LLGR|65535,6|\([0-9]+s\)" && stale_marker="yes"

        echo "epoch_ms=$now_ms | present=$present | stale_marker=$stale_marker | protocol=$proto | route=$out" >> "$ROUTE_LOG"

        sleep 0.25
    done
}

monitor_routes &
MON_PID=$!

sleep 2

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "7. Trigger: hard kill BIRD on hpe-r9" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

T0=$(date +%s%3N)
echo "T0_EPOCH_MS=$T0" | tee -a "$EVIDENCE"

docker exec hpe-r9 sh -lc "pkill -KILL bird || true" 2>&1 | tee -a "$EVIDENCE"

echo "Keeping hpe-r9 BIRD down for 18 seconds..." | tee -a "$EVIDENCE"
sleep 18

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "8. Restart hpe-r9 BIRD" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

docker exec hpe-r9 sh -lc "pgrep bird >/dev/null || bird -c /etc/bird/bird.conf" 2>&1 | tee -a "$EVIDENCE" || true

sleep 8

kill "$MON_PID" >/dev/null 2>&1 || true

docker exec hpe-h1 sh -lc "kill -INT $PING_PID >/dev/null 2>&1 || true" || true
sleep 1
docker cp "hpe-h1:/tmp/llgr_ping_${TS}.log" "$PING_LOG" >/dev/null 2>&1 || true

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "9. Analyze route-retention timeline" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

python3 - "$EVIDENCE" "$ROUTE_LOG" "$PING_LOG" "$CSV" "$T0" "$TS" <<'PY' | tee -a "$EVIDENCE"
import sys
import re
import shutil

evidence, route_log, ping_log, csv_path, t0_s, ts = sys.argv[1:]
t0 = int(t0_s)

first_present = None
last_present = None
first_stale = None
first_missing_after_present = None

rows = []

try:
    with open(route_log) as f:
        for line in f:
            m = re.search(r"epoch_ms=(\d+).*present=(yes|no).*stale_marker=(yes|no)", line)
            if not m:
                continue

            epoch = int(m.group(1))
            present = m.group(2)
            stale = m.group(3)
            rel = epoch - t0

            if rel < 0:
                continue

            rows.append((rel, present, stale))

            if present == "yes":
                if first_present is None:
                    first_present = rel
                last_present = rel

            if stale == "yes" and first_stale is None:
                first_stale = rel

            if first_present is not None and present == "no" and first_missing_after_present is None:
                first_missing_after_present = rel

except FileNotFoundError:
    pass

tx = rx = loss = "NA"
try:
    text = open(ping_log).read()
    m = re.search(r"(\d+) packets transmitted, (\d+) received.*?([0-9.]+)% packet loss", text, re.S)
    if m:
        tx, rx, loss = m.group(1), m.group(2), m.group(3)
except FileNotFoundError:
    pass

print(f"first_stale_marker_ms={first_stale if first_stale is not None else 'NA'}")
print(f"last_route_present_ms={last_present if last_present is not None else 'NA'}")
print(f"first_route_missing_ms={first_missing_after_present if first_missing_after_present is not None else 'NA'}")
print(f"ping_tx={tx}")
print(f"ping_rx={rx}")
print(f"ping_loss_percent={loss}")

print()
print("Expected interpretation:")
print("- GR timer is 5 s and LLGR stale timer is 10 s.")
print("- Therefore, route retention until roughly 15 s is expected.")
print("- A stale marker around/after 5 s is strong LLGR evidence.")
print("- Route disappearance around/after 15 s proves LLGR stale timer expiry.")

with open(csv_path, "w") as f:
    f.write("timestamp,test_name,target_prefix,gr_time_s,llgr_stale_time_s,first_stale_marker_ms,last_route_present_ms,first_route_missing_ms,ping_tx,ping_rx,ping_loss_percent\n")
    f.write(f"{ts},llgr_perfect_proof,10.0.93.0/24,5,10,{first_stale if first_stale is not None else 'NA'},{last_present if last_present is not None else 'NA'},{first_missing_after_present if first_missing_after_present is not None else 'NA'},{tx},{rx},{loss}\n")

shutil.copyfile(csv_path, "results/llgr_perfect_proof/llgr_perfect_proof.csv")
PY

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "10. Important proof files" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "Evidence: $EVIDENCE" | tee -a "$EVIDENCE"
echo "Route samples: $ROUTE_LOG" | tee -a "$EVIDENCE"
echo "Ping log: $PING_LOG" | tee -a "$EVIDENCE"
echo "CSV: $CSV" | tee -a "$EVIDENCE"
echo "Latest CSV: $LATEST" | tee -a "$EVIDENCE"

