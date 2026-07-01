#!/usr/bin/env bash
set -u

TS=$(date +%Y%m%d_%H%M%S)

mkdir -p evidence/gr_llgr_video results/gr_llgr_video configs/gr_llgr_video

EVIDENCE="evidence/gr_llgr_video/gr_llgr_video_${TS}.txt"
R1_PING_LOG="evidence/gr_llgr_video/r1_ping_${TS}.log"
R2_PING_LOG="evidence/gr_llgr_video/r2_ping_${TS}.log"
CSV="results/gr_llgr_video/gr_llgr_video_${TS}.csv"

ROUTERS="hpe-r1 hpe-r2 hpe-r9"
TARGET_PREFIX="10.0.93.0/24"
TARGET_IP="10.0.93.2"

cleanup() {
    echo
    echo "============================================================"
    echo "CLEANUP: restoring original configs and BGP state"
    echo "============================================================"

    docker exec hpe-r1 pkill -INT ping >/dev/null 2>&1 || true
    docker exec hpe-r2 pkill -INT ping >/dev/null 2>&1 || true

    for r in $ROUTERS; do
        if [ -f "configs/gr_llgr_video/${r}_before_${TS}.conf" ]; then
            docker cp "configs/gr_llgr_video/${r}_before_${TS}.conf" "$r:/etc/bird/bird.conf" >/dev/null 2>&1 || true
        fi
    done

    docker exec hpe-r9 sh -lc 'pgrep bird >/dev/null || bird -c /etc/bird/bird.conf' >/dev/null 2>&1 || true

    for r in $ROUTERS; do
        docker exec "$r" birdc configure >/dev/null 2>&1 || true
    done

    docker exec hpe-r1 birdc enable r2 >/dev/null 2>&1 || true
    docker exec hpe-r1 birdc enable r9 >/dev/null 2>&1 || true
    docker exec hpe-r2 birdc enable r1 >/dev/null 2>&1 || true
    docker exec hpe-r2 birdc enable r9 >/dev/null 2>&1 || true
    docker exec hpe-r9 birdc enable r1 >/dev/null 2>&1 || true
    docker exec hpe-r9 birdc enable r2 >/dev/null 2>&1 || true

    for r in hpe-r1 hpe-r2 hpe-r9; do
        docker exec "$r" sh -lc '
            sysctl -w net.ipv4.ip_forward=1 >/dev/null
            for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f" 2>/dev/null || true; done
        ' >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

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
    # Disable BGP-level BFD only for clean GR/LLGR observation.
    block = re.sub(
        r'^(\s*)bfd yes;\s*$',
        r'\1# bfd yes;  # disabled temporarily for GR/LLGR video demo',
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

    block = re.sub(r'^\s*graceful restart time\s+\d+;\s*$', "", block, flags=re.M)
    block = re.sub(r'^\s*long lived stale time\s+\d+;\s*$', "", block, flags=re.M)

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

clear
echo "============================================================"
echo "BGP GR / LLGR VIDEO DEMO"
echo "Routers: hpe-r1, hpe-r2, hpe-r9"
echo "Restarted peer: hpe-r9"
echo "Target prefix: 10.0.93.0/24"
echo "Target host: 10.0.93.2"
echo "============================================================"
echo
echo "Backing up configs..."

for r in $ROUTERS; do
    docker cp "$r:/etc/bird/bird.conf" "configs/gr_llgr_video/${r}_before_${TS}.conf"
done

echo "Patching configs: GR=5s, LLGR stale=10s, BGP-BFD disabled, kernel persist enabled..."

for r in $ROUTERS; do
    patch_router_config "$r"
done

echo "Applying configs..."
for r in $ROUTERS; do
    docker exec "$r" birdc configure >/dev/null 2>&1 || true
done

echo "Waiting 15 seconds for BGP to settle..."
sleep 15

clear
echo "============================================================"
echo "PRE-CHECK BEFORE GR/LLGR DEMO"
echo "============================================================"
echo
echo "BGP sessions:"
echo "-------------"
echo "hpe-r1:"
docker exec hpe-r1 birdc show protocols | grep -E "Name|r9|r2|BGP|Established|start|Idle" || true
echo
echo "hpe-r2:"
docker exec hpe-r2 birdc show protocols | grep -E "Name|r9|r1|BGP|Established|start|Idle" || true
echo
echo "hpe-r9:"
docker exec hpe-r9 birdc show protocols | grep -E "Name|r1|r2|BGP|Established|start|Idle" || true

echo
echo "Routes to 10.0.93.0/24:"
echo "-----------------------"
echo "hpe-r1 BIRD route:"
docker exec hpe-r1 birdc show route "$TARGET_PREFIX" all | head -n 12 || true
echo
echo "hpe-r1 kernel route:"
docker exec hpe-r1 ip route get "$TARGET_IP" || true
echo
echo "hpe-r2 BIRD route:"
docker exec hpe-r2 birdc show route "$TARGET_PREFIX" all | head -n 12 || true
echo
echo "hpe-r2 kernel route:"
docker exec hpe-r2 ip route get "$TARGET_IP" || true

echo
echo "Traffic pre-check:"
echo "------------------"
docker exec hpe-r1 ping -c 3 -W 1 -I 10.0.19.2 "$TARGET_IP" || true
docker exec hpe-r2 ping -c 3 -W 1 -I 10.0.29.2 "$TARGET_IP" || true

echo
echo "============================================================"
echo "START SCREEN RECORDING NOW."
echo "Then come back here and press ENTER."
echo "============================================================"
read -r

docker exec hpe-r1 sh -lc "rm -f /tmp/r1_video_ping_${TS}.log; ping -i 0.1 -I 10.0.19.2 $TARGET_IP > /tmp/r1_video_ping_${TS}.log 2>&1 & echo \$!" > /tmp/r1_video_ping_pid_${TS}.txt
docker exec hpe-r2 sh -lc "rm -f /tmp/r2_video_ping_${TS}.log; ping -i 0.1 -I 10.0.29.2 $TARGET_IP > /tmp/r2_video_ping_${TS}.log 2>&1 & echo \$!" > /tmp/r2_video_ping_pid_${TS}.txt

R1_PING_PID=$(cat /tmp/r1_video_ping_pid_${TS}.txt)
R2_PING_PID=$(cat /tmp/r2_video_ping_pid_${TS}.txt)

sleep 2

T0=$(date +%s%3N)
RESTARTED="no"

echo "T0=$T0" > "$EVIDENCE"
echo "Trigger: killing BIRD on hpe-r9" >> "$EVIDENCE"

docker exec hpe-r9 sh -lc "pkill -KILL bird || true" >/dev/null 2>&1 || true

FIRST_R1_STALE="NA"
FIRST_R2_STALE="NA"
FIRST_R1_MISSING="NA"
FIRST_R2_MISSING="NA"
FIRST_R1_KERNEL_MISSING="NA"
FIRST_R2_KERNEL_MISSING="NA"

for i in $(seq 0 28); do
    NOW=$(date +%s%3N)
    REL=$((NOW - T0))

    if [ "$i" -eq 18 ] && [ "$RESTARTED" = "no" ]; then
        docker exec hpe-r9 sh -lc "pgrep bird >/dev/null || bird -c /etc/bird/bird.conf" >/dev/null 2>&1 || true
        RESTARTED="yes"
    fi

    R1_ROUTE=$(docker exec hpe-r1 birdc show route "$TARGET_PREFIX" all 2>&1 | tr '\n' ' ')
    R2_ROUTE=$(docker exec hpe-r2 birdc show route "$TARGET_PREFIX" all 2>&1 | tr '\n' ' ')
    R1_KERNEL=$(docker exec hpe-r1 ip route get "$TARGET_IP" 2>&1 | tr '\n' ' ')
    R2_KERNEL=$(docker exec hpe-r2 ip route get "$TARGET_IP" 2>&1 | tr '\n' ' ')

    R1_PRESENT="no"
    R2_PRESENT="no"
    R1_STALE="no"
    R2_STALE="no"
    R1_KERNEL_PRESENT="no"
    R2_KERNEL_PRESENT="no"

    echo "$R1_ROUTE" | grep -q "$TARGET_PREFIX" && R1_PRESENT="yes"
    echo "$R2_ROUTE" | grep -q "$TARGET_PREFIX" && R2_PRESENT="yes"

    echo "$R1_ROUTE" | grep -Eiq "stale|LLGR|65535,6|\([0-9]+s\)" && R1_STALE="yes"
    echo "$R2_ROUTE" | grep -Eiq "stale|LLGR|65535,6|\([0-9]+s\)" && R2_STALE="yes"

    echo "$R1_KERNEL" | grep -q "$TARGET_IP" && R1_KERNEL_PRESENT="yes"
    echo "$R2_KERNEL" | grep -q "$TARGET_IP" && R2_KERNEL_PRESENT="yes"

    if [ "$R1_STALE" = "yes" ] && [ "$FIRST_R1_STALE" = "NA" ]; then FIRST_R1_STALE=$REL; fi
    if [ "$R2_STALE" = "yes" ] && [ "$FIRST_R2_STALE" = "NA" ]; then FIRST_R2_STALE=$REL; fi

    if [ "$R1_PRESENT" = "no" ] && [ "$FIRST_R1_MISSING" = "NA" ]; then FIRST_R1_MISSING=$REL; fi
    if [ "$R2_PRESENT" = "no" ] && [ "$FIRST_R2_MISSING" = "NA" ]; then FIRST_R2_MISSING=$REL; fi

    if [ "$R1_KERNEL_PRESENT" = "no" ] && [ "$FIRST_R1_KERNEL_MISSING" = "NA" ]; then FIRST_R1_KERNEL_MISSING=$REL; fi
    if [ "$R2_KERNEL_PRESENT" = "no" ] && [ "$FIRST_R2_KERNEL_MISSING" = "NA" ]; then FIRST_R2_KERNEL_MISSING=$REL; fi

    R1_LAST_PING=$(docker exec hpe-r1 sh -lc "tail -n 1 /tmp/r1_video_ping_${TS}.log 2>/dev/null" || true)
    R2_LAST_PING=$(docker exec hpe-r2 sh -lc "tail -n 1 /tmp/r2_video_ping_${TS}.log 2>/dev/null" || true)

    clear
    echo "============================================================"
    echo "BGP GR / LLGR LIVE DEMO"
    echo "============================================================"
    echo "Topology used: hpe-r1, hpe-r2, hpe-r9"
    echo "Target route : 10.0.93.0/24"
    echo "Target host  : 10.0.93.2"
    echo
    echo "Trigger: BIRD control plane on hpe-r9 was killed."
    echo "Physical links are still UP."
    echo
    echo "Configured timers:"
    echo "  GR time          = 5 seconds"
    echo "  LLGR stale time  = 10 seconds"
    echo "  Expected withdraw ≈ 15 seconds"
    echo
    echo "Time since hpe-r9 BIRD kill: ${REL} ms"
    echo

    if [ "$REL" -lt 5000 ]; then
        echo "Current phase: GR phase - route should be retained normally"
    elif [ "$REL" -lt 15000 ]; then
        echo "Current phase: LLGR stale phase - stale marker should be visible"
    else
        echo "Current phase: stale timer expired - BIRD route may be withdrawn"
    fi

    if [ "$RESTARTED" = "yes" ]; then
        echo "hpe-r9 BIRD restart: started after 18 seconds"
    else
        echo "hpe-r9 BIRD restart: not yet"
    fi

    echo
    echo "---------------- hpe-r1 observer ----------------"
    echo "BIRD route present        : $R1_PRESENT"
    echo "LLGR/stale marker visible : $R1_STALE"
    echo "Kernel route present      : $R1_KERNEL_PRESENT"
    echo "First stale marker        : $FIRST_R1_STALE ms"
    echo "First BIRD route missing  : $FIRST_R1_MISSING ms"
    echo "First kernel route missing: $FIRST_R1_KERNEL_MISSING"
    echo "Kernel route:"
    echo "$R1_KERNEL" | cut -c1-110
    echo "Last ping:"
    echo "$R1_LAST_PING" | cut -c1-110

    echo
    echo "---------------- hpe-r2 observer ----------------"
    echo "BIRD route present        : $R2_PRESENT"
    echo "LLGR/stale marker visible : $R2_STALE"
    echo "Kernel route present      : $R2_KERNEL_PRESENT"
    echo "First stale marker        : $FIRST_R2_STALE ms"
    echo "First BIRD route missing  : $FIRST_R2_MISSING ms"
    echo "First kernel route missing: $FIRST_R2_KERNEL_MISSING"
    echo "Kernel route:"
    echo "$R2_KERNEL" | cut -c1-110
    echo "Last ping:"
    echo "$R2_LAST_PING" | cut -c1-110

    echo
    echo "What this proves:"
    echo "  Control plane can restart while forwarding remains available."
    echo "  Stale route appears after GR timer."
    echo "  Route withdrawal matches GR + LLGR stale timer."
    echo "  Ping shows whether forwarding was preserved."
    echo "============================================================"

    sleep 1
done

docker exec hpe-r1 sh -lc "kill -INT $R1_PING_PID >/dev/null 2>&1 || true" || true
docker exec hpe-r2 sh -lc "kill -INT $R2_PING_PID >/dev/null 2>&1 || true" || true
sleep 1

docker cp "hpe-r1:/tmp/r1_video_ping_${TS}.log" "$R1_PING_LOG" >/dev/null 2>&1 || true
docker cp "hpe-r2:/tmp/r2_video_ping_${TS}.log" "$R2_PING_LOG" >/dev/null 2>&1 || true

R1_STATS=$(tail -n 2 "$R1_PING_LOG" 2>/dev/null | tr '\n' ' ')
R2_STATS=$(tail -n 2 "$R2_PING_LOG" 2>/dev/null | tr '\n' ' ')

parse_loss() {
    local f="$1"
    python3 - "$f" <<'PY'
import sys, re
try:
    text=open(sys.argv[1]).read()
except FileNotFoundError:
    print("NA,NA,NA")
    raise SystemExit
m=re.search(r"(\d+) packets transmitted, (\d+) received.*?([0-9.]+)% packet loss", text, re.S)
if m:
    print(",".join(m.groups()))
else:
    print("NA,NA,NA")
PY
}

R1_PARSED=$(parse_loss "$R1_PING_LOG")
R2_PARSED=$(parse_loss "$R2_PING_LOG")

{
echo "timestamp,router,first_stale_marker_ms,first_bird_route_missing_ms,first_kernel_route_missing_ms,ping_tx,ping_rx,ping_loss_percent"
echo "$TS,hpe-r1,$FIRST_R1_STALE,$FIRST_R1_MISSING,$FIRST_R1_KERNEL_MISSING,$R1_PARSED"
echo "$TS,hpe-r2,$FIRST_R2_STALE,$FIRST_R2_MISSING,$FIRST_R2_KERNEL_MISSING,$R2_PARSED"
} > "$CSV"

cp "$CSV" results/gr_llgr_video/gr_llgr_video.csv

clear
echo "============================================================"
echo "BGP GR / LLGR VIDEO DEMO - FINAL SUMMARY"
echo "============================================================"
echo
cat "$CSV"
echo
echo "hpe-r1 ping summary:"
echo "$R1_STATS"
echo
echo "hpe-r2 ping summary:"
echo "$R2_STATS"
echo
echo "Saved files:"
echo "Evidence CSV : $CSV"
echo "hpe-r1 ping  : $R1_PING_LOG"
echo "hpe-r2 ping  : $R2_PING_LOG"
echo
echo "Now stop the screen recording."
echo "============================================================"

read -p "Press ENTER after stopping recording to restore configs..." _
