#!/usr/bin/env bash
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
mkdir -p configs/ospf_bfd_disabled evidence/ospf_bfd

echo "============================================================"
echo "DISABLE OSPF-BFD ONLY"
echo "Timestamp: $TS"
echo "============================================================"

for r in hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9; do
    echo
    echo "---- $r ----"

    BEFORE="configs/ospf_bfd_disabled/${r}_bird_before_disable_ospf_bfd_${TS}.conf"
    AFTER="configs/ospf_bfd_disabled/${r}_bird_after_disable_ospf_bfd_${TS}.conf"
    TMP="/tmp/${r}_bird_disable_ospf_bfd_${TS}.conf"

    docker cp "$r:/etc/bird/bird.conf" "$BEFORE"

    python3 - "$BEFORE" "$AFTER" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

lines = src.read_text().splitlines()
out = []

in_ospf = False
depth = 0
removed = 0

for line in lines:
    if not in_ospf and re.search(r'\bprotocol\s+ospf\b', line):
        in_ospf = True
        depth = line.count("{") - line.count("}")
        out.append(line)
        if depth <= 0:
            in_ospf = False
        continue

    if in_ospf:
        if re.match(r'^\s*bfd\s+yes\s*;\s*$', line):
            removed += 1
            continue

        out.append(line)
        depth += line.count("{") - line.count("}")

        if depth <= 0:
            in_ospf = False
    else:
        out.append(line)

dst.write_text("\n".join(out) + "\n")
print(f"Removed OSPF bfd yes lines: {removed}")
PY

    docker cp "$AFTER" "$r:$TMP"

    docker exec "$r" bird -p -c "$TMP" >/dev/null

    docker exec "$r" cp "$TMP" /etc/bird/bird.conf
    docker exec "$r" birdc configure >/dev/null

    echo "[OK] OSPF-BFD disabled on $r"
done

echo
echo "Waiting 20 seconds for protocols to settle..."
sleep 20

echo
echo "Checking hpe-r3 BFD sessions for ECMP neighbours:"
docker exec hpe-r3 birdc show bfd sessions | grep -E "10.0.23.2|10.0.34.3" || echo "No OSPF-BFD sessions for ECMP neighbours. Good."

echo
echo "Done."
