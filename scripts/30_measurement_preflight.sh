#!/usr/bin/env bash
set -euo pipefail

echo "============================================================"
echo "CONVERGENCE MEASUREMENT PREFLIGHT"
echo "============================================================"

check_cmd() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "[OK] $cmd found: $(command -v "$cmd")"
    else
        echo "[MISSING] $cmd not found"
        return 1
    fi
}

echo
echo "Checking host tools..."
check_cmd docker
check_cmd python3
check_cmd awk
check_cmd grep
check_cmd sed
check_cmd date

echo
echo "Checking optional but recommended tools..."
if command -v fping >/dev/null 2>&1; then
    echo "[OK] fping found"
else
    echo "[WARN] fping not found. Install with: sudo apt install -y fping"
fi

if command -v tshark >/dev/null 2>&1; then
    echo "[OK] tshark found"
else
    echo "[WARN] tshark not found. Install with: sudo apt install -y tshark"
fi

if command -v tcpdump >/dev/null 2>&1; then
    echo "[OK] tcpdump found on host"
else
    echo "[WARN] tcpdump not found on host. Install with: sudo apt install -y tcpdump"
fi

echo
echo "Checking containers..."
for c in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9 hpe-h1 hpe-h2 hpe-h3; do
    if docker ps --format '{{.Names}}' | grep -qx "$c"; then
        echo "[OK] $c running"
    else
        echo "[MISSING] $c not running"
    fi
done

echo
echo "Checking BIRD inside routers..."
for r in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9; do
    if docker exec "$r" birdc show status >/dev/null 2>&1; then
        echo "[OK] BIRD responding on $r"
    else
        echo "[BAD] BIRD not responding on $r"
    fi
done

echo
echo "Checking tcpdump inside routers..."
for r in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9; do
    if docker exec "$r" sh -lc "command -v tcpdump" >/dev/null 2>&1; then
        echo "[OK] tcpdump inside $r"
    else
        echo "[WARN] tcpdump missing inside $r"
    fi
done

echo
echo "Preflight complete."
