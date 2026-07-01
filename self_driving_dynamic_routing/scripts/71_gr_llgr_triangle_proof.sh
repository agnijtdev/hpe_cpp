#!/usr/bin/env bash
set -u

TS=$(date +%Y%m%d_%H%M%S)

mkdir -p evidence/gr_llgr_triangle results/gr_llgr_triangle configs/gr_llgr_triangle

EVIDENCE="evidence/gr_llgr_triangle/gr_llgr_triangle_${TS}.txt"
R1_ROUTE_LOG="evidence/gr_llgr_triangle/r1_route_samples_${TS}.log"
R2_ROUTE_LOG="evidence/gr_llgr_triangle/r2_route_samples_${TS}.log"
R1_PING_LOG="evidence/gr_llgr_triangle/r1_ping_${TS}.log"
R2_PING_LOG="evidence/gr_llgr_triangle/r2_ping_${TS}.log"
CSV="results/gr_llgr_triangle/gr_llgr_triangle_${TS}.csv"
LATEST="results/gr_llgr_triangle/gr_llgr_triangle.csv"

ROUTERS="hpe-r1 hpe-r2 hpe-r9"

echo "============================================================" | tee "$EVIDENCE"
echo "BGP GR / LLGR TRIANGLE PROOF" | tee -a "$EVIDENCE"
echo "Timestamp: $TS" | tee -a "$EVIDENCE"
echo "Routers used: hpe-r1, hpe-r2, hpe-r9" | tee -a "$EVIDENCE"
echo "Restarted peer: hpe-r9" | tee -a "$EVIDENCE"
echo "Observers: hpe-r1 and hpe-r2" | tee -a "$EVIDENCE"
echo "Target prefix: 10.0.93.0/24" | tee -a "$EVIDENCE"
echo "Target host: 10.0.93.2" | tee -a "$EVIDENCE"
echo "GR timer: 5 seconds" | tee -a "$EVIDENCE"
echo "LLGR stale timer: 10 seconds" | tee -a "$EVIDENCE"
echo "Expected withdrawal: around 15 seconds" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

cleanup() {
    echo | tee -a "$EVIDENCE"
    echo "============================================================" | tee -a "$EVIDENCE"
    echo "CLEANUP: restoring original configs" | tee -a "$EVIDENCE"
    echo "============================================================" | tee -a "$EVIDENCE"

    docker exec hpe-r1 pkill -INT ping >/dev/null 2>&1 || true
    docker exec hpe-r2 pkill -INT ping >/dev/null 2>&1 || true

    for r in $ROUTERS; do
        if [ -f "configs/gr_llgr_triangle/${r}_before_${TS}.conf" ]; then
            docker cp "configs/gr_llgr_triangle/${r}_before_${TS}.conf" "$r:/etc/bird/bird.conf" >/dev/null 2>&1 || true
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

    sleep 15
}
trap cleanup EXIT

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "1. Backup current configs" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

for r in $ROUTERS; do
    docker cp "$r:/etc/bird/bird.conf" "configs/gr_llgr_triangle/${r}_before_${TS}.conf"
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
    # Disable only BGP-level BFD for clean GR/LLGR observation.
    block = re.sub(
        r'^(\s*)bfd yes;\s*$',
        r'\1# bfd yes;  # disabled temporarily for GR/LLGR proof',
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

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "2. Patch configs: GR/LLGR timers, kernel persist, disable BGP BFD" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

for r in $ROUTERS; do
    patch_router_config "$r"
    echo "Patched $r" | tee -a "$EVIDENCE"
done

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "3. Apply configs" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

for r in $ROUTERS; do
    echo "---- $r configure ----" | tee -a "$EVIDENCE"
    docker exec "$r" birdc configure 2>&1 | tee -a "$EVIDENCE"
done

echo "Waiting 15 seconds for BGP to settle..." | tee -a "$EVIDENCE"
sleep 15

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "4. Pre-check: BGP sessions" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

for r in $ROUTERS; do
    echo | tee -a "$EVIDENCE"
    echo "---- $r protocols ----" | tee -a "$EVIDENCE"
    docker exec "$r" birdc show protocols | tee -a "$EVIDENCE"
done

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "5. Pre-check: routes to 10.0.93.0/24" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

echo "---- hpe-r1 BIRD route ----" | tee -a "$EVIDENCE"
docker exec hpe-r1 birdc show route 10.0.93.0/24 all | tee -a "$EVIDENCE" || true
echo "---- hpe-r1 kernel route ----" | tee -a "$EVIDENCE"
docker exec hpe-r1 ip route get 10.0.93.2 | tee -a "$EVIDENCE" || true

echo "---- hpe-r2 BIRD route ----" | tee -a "$EVIDENCE"
docker exec hpe-r2 birdc show route 10.0.93.0/24 all | tee -a "$EVIDENCE" || true
echo "---- hpe-r2 kernel route ----" | tee -a "$EVIDENCE"
docker exec hpe-r2 ip route get 10.0.93.2 | tee -a "$EVIDENCE" || true

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "6. Pre-check: direct traffic from r1/r2 to h3" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

docker exec hpe-r1 ping -c 5 -W 1 -I 10.0.19.2 10.0.93.2 | tee -a "$EVIDENCE" || true
docker exec hpe-r2 ping -c 5 -W 1 -I 10.0.29.2 10.0.93.2 | tee -a "$EVIDENCE" || true

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "7. Start continuous pings" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

docker exec hpe-r1 sh -lc "rm -f /tmp/r1_gr_ping_${TS}.log; ping -i 0.1 -I 10.0.19.2 10.0.93.2 > /tmp/r1_gr_ping_${TS}.log 2>&1 & echo \$!" > /tmp/r1_gr_ping_pid_${TS}.txt
docker exec hpe-r2 sh -lc "rm -f /tmp/r2_gr_ping_${TS}.log; ping -i 0.1 -I 10.0.29.2 10.0.93.2 > /tmp/r2_gr_ping_${TS}.log 2>&1 & echo \$!" > /tmp/r2_gr_ping_pid_${TS}.txt

R1_PING_PID=$(cat /tmp/r1_gr_ping_pid_${TS}.txt)
R2_PING_PID=$(cat /tmp/r2_gr_ping_pid_${TS}.txt)

echo "hpe-r1 ping PID: $R1_PING_PID" | tee -a "$EVIDENCE"
echo "hpe-r2 ping PID: $R2_PING_PID" | tee -a "$EVIDENCE"

monitor_router() {
    local router="$1"
    local log="$2"
    local end_time=$(( $(date +%s) + 28 ))

    while [ "$(date +%s)" -lt "$end_time" ]; do
        now_ms=$(date +%s%3N)

        route_out=$(docker exec "$router" birdc show route 10.0.93.0/24 all 2>&1 | tr '\n' ' ')
        kernel_out=$(docker exec "$router" ip route get 10.0.93.2 2>&1 | tr '\n' ' ')
        proto_out=$(docker exec "$router" birdc show protocols 2>&1 | tr '\n' ' ')

        present="no"
        stale_marker="no"
        kernel_present="no"

        echo "$route_out" | grep -q "10.0.93.0/24" && present="yes"
        echo "$route_out" | grep -Eiq "stale|LLGR|65535,6|\([0-9]+s\)" && stale_marker="yes"
        echo "$kernel_out" | grep -q "10.0.93.2" && kernel_present="yes"

        echo "epoch_ms=$now_ms | router=$router | present=$present | stale_marker=$stale_marker | kernel_present=$kernel_present | protocols=$proto_out | bird_route=$route_out | kernel_route=$kernel_out" >> "$log"

        sleep 0.25
    done
}

monitor_router hpe-r1 "$R1_ROUTE_LOG" &
MON1_PID=$!

monitor_router hpe-r2 "$R2_ROUTE_LOG" &
MON2_PID=$!

sleep 2

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "8. Trigger: kill BIRD control plane on hpe-r9" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

T0=$(date +%s%3N)
echo "T0_EPOCH_MS=$T0" | tee -a "$EVIDENCE"

docker exec hpe-r9 sh -lc "pkill -KILL bird || true" 2>&1 | tee -a "$EVIDENCE"

echo "Keeping hpe-r9 BIRD down for 18 seconds..." | tee -a "$EVIDENCE"
sleep 18

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "9. Restart BIRD on hpe-r9" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

docker exec hpe-r9 sh -lc "pgrep bird >/dev/null || bird -c /etc/bird/bird.conf" 2>&1 | tee -a "$EVIDENCE" || true

sleep 8

kill "$MON1_PID" >/dev/null 2>&1 || true
kill "$MON2_PID" >/dev/null 2>&1 || true

docker exec hpe-r1 sh -lc "kill -INT $R1_PING_PID >/dev/null 2>&1 || true" || true
docker exec hpe-r2 sh -lc "kill -INT $R2_PING_PID >/dev/null 2>&1 || true" || true

sleep 1

docker cp "hpe-r1:/tmp/r1_gr_ping_${TS}.log" "$R1_PING_LOG" >/dev/null 2>&1 || true
docker cp "hpe-r2:/tmp/r2_gr_ping_${TS}.log" "$R2_PING_LOG" >/dev/null 2>&1 || true

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "10. Analyze timeline" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"

python3 - "$R1_ROUTE_LOG" "$R2_ROUTE_LOG" "$R1_PING_LOG" "$R2_PING_LOG" "$CSV" "$T0" "$TS" <<'PY' | tee -a "$EVIDENCE"
import sys, re, shutil

r1_log, r2_log, r1_ping, r2_ping, csv_path, t0_s, ts = sys.argv[1:]
t0 = int(t0_s)

def analyze_route(log):
    first_present = None
    last_present = None
    first_stale = None
    first_missing_after_present = None
    first_kernel_missing = None

    try:
        with open(log) as f:
            for line in f:
                m = re.search(r"epoch_ms=(\d+).*present=(yes|no).*stale_marker=(yes|no).*kernel_present=(yes|no)", line)
                if not m:
                    continue
                epoch = int(m.group(1))
                present = m.group(2)
                stale = m.group(3)
                kernel = m.group(4)
                rel = epoch - t0
                if rel < 0:
                    continue

                if present == "yes":
                    if first_present is None:
                        first_present = rel
                    last_present = rel

                if stale == "yes" and first_stale is None:
                    first_stale = rel

                if first_present is not None and present == "no" and first_missing_after_present is None:
                    first_missing_after_present = rel

                if kernel == "no" and first_kernel_missing is None:
                    first_kernel_missing = rel
    except FileNotFoundError:
        pass

    return first_stale, last_present, first_missing_after_present, first_kernel_missing

def analyze_ping(path):
    tx = rx = loss = "NA"
    try:
        text = open(path).read()
        m = re.search(r"(\d+) packets transmitted, (\d+) received.*?([0-9.]+)% packet loss", text, re.S)
        if m:
            tx, rx, loss = m.group(1), m.group(2), m.group(3)
    except FileNotFoundError:
        pass
    return tx, rx, loss

r1_stale, r1_last, r1_missing, r1_kernel_missing = analyze_route(r1_log)
r2_stale, r2_last, r2_missing, r2_kernel_missing = analyze_route(r2_log)

r1_tx, r1_rx, r1_loss = analyze_ping(r1_ping)
r2_tx, r2_rx, r2_loss = analyze_ping(r2_ping)

print("hpe-r1:")
print(f"  first_stale_marker_ms={r1_stale if r1_stale is not None else 'NA'}")
print(f"  first_route_missing_ms={r1_missing if r1_missing is not None else 'NA'}")
print(f"  first_kernel_route_missing_ms={r1_kernel_missing if r1_kernel_missing is not None else 'NA'}")
print(f"  ping_loss_percent={r1_loss}")

print()
print("hpe-r2:")
print(f"  first_stale_marker_ms={r2_stale if r2_stale is not None else 'NA'}")
print(f"  first_route_missing_ms={r2_missing if r2_missing is not None else 'NA'}")
print(f"  first_kernel_route_missing_ms={r2_kernel_missing if r2_kernel_missing is not None else 'NA'}")
print(f"  ping_loss_percent={r2_loss}")

print()
print("Expected interpretation:")
print("- Around 5 seconds: route should enter stale / LLGR state.")
print("- Around 15 seconds: stale route should be withdrawn if hpe-r9 does not return.")
print("- BIRD route table and Linux kernel route are both checked.")

with open(csv_path, "w") as f:
    f.write("timestamp,router,target_prefix,gr_time_s,llgr_stale_time_s,first_stale_marker_ms,first_route_missing_ms,first_kernel_route_missing_ms,ping_tx,ping_rx,ping_loss_percent\n")
    f.write(f"{ts},hpe-r1,10.0.93.0/24,5,10,{r1_stale if r1_stale is not None else 'NA'},{r1_missing if r1_missing is not None else 'NA'},{r1_kernel_missing if r1_kernel_missing is not None else 'NA'},{r1_tx},{r1_rx},{r1_loss}\n")
    f.write(f"{ts},hpe-r2,10.0.93.0/24,5,10,{r2_stale if r2_stale is not None else 'NA'},{r2_missing if r2_missing is not None else 'NA'},{r2_kernel_missing if r2_kernel_missing is not None else 'NA'},{r2_tx},{r2_rx},{r2_loss}\n")

shutil.copyfile(csv_path, "results/gr_llgr_triangle/gr_llgr_triangle.csv")
PY

echo | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "11. Proof files" | tee -a "$EVIDENCE"
echo "============================================================" | tee -a "$EVIDENCE"
echo "Evidence: $EVIDENCE" | tee -a "$EVIDENCE"
echo "hpe-r1 route log: $R1_ROUTE_LOG" | tee -a "$EVIDENCE"
echo "hpe-r2 route log: $R2_ROUTE_LOG" | tee -a "$EVIDENCE"
echo "hpe-r1 ping log: $R1_PING_LOG" | tee -a "$EVIDENCE"
echo "hpe-r2 ping log: $R2_PING_LOG" | tee -a "$EVIDENCE"
echo "CSV: $CSV" | tee -a "$EVIDENCE"
echo "Latest CSV: $LATEST" | tee -a "$EVIDENCE"

