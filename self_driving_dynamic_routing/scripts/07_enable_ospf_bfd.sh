#!/usr/bin/env bash
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
mkdir -p evidence/ospf_bfd configs/ospf_bfd_before configs/ospf_bfd_after

OUT="evidence/ospf_bfd/enable_ospf_bfd_${TS}.txt"

ROUTERS="hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8"

python_modify_config() {
python3 - "$1" <<'PY2'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

# Add protocol bfd if missing.
if not re.search(r'protocol\s+bfd\b', text):
    text = re.sub(
        r'\nprotocol\s+ospf\s+ospf1\s*\{',
        '\nprotocol bfd {\n}\n\nprotocol ospf ospf1 {',
        text,
        count=1
    )

lines = text.splitlines()
out = []
i = 0
inside_ospf = False
ospf_depth = 0

while i < len(lines):
    line = lines[i]

    if re.match(r'\s*protocol\s+ospf\s+ospf1\s*\{', line):
        inside_ospf = True
        ospf_depth = line.count('{') - line.count('}')
        out.append(line)
        i += 1
        continue

    if inside_ospf:
        ospf_depth += line.count('{') - line.count('}')

        m = re.match(r'(\s*)interface\s+"([^"]+)"\s*\{', line)
        if m:
            indent = m.group(1)
            iface = m.group(2)

            block = [line]
            depth = line.count('{') - line.count('}')
            i += 1

            while i < len(lines):
                block.append(lines[i])
                depth += lines[i].count('{') - lines[i].count('}')
                if depth <= 0:
                    break
                i += 1

            # Add bfd yes only to real OSPF data interfaces, not loopback.
            if iface != "lo" and not any(re.search(r'\bbfd\s+yes\s*;', b) for b in block):
                insert_indent = indent + "    "
                # Insert before the closing line of the interface block.
                block.insert(-1, insert_indent + "bfd yes;")

            out.extend(block)
            i += 1

            if ospf_depth <= 0:
                inside_ospf = False
            continue

        out.append(line)
        if ospf_depth <= 0:
            inside_ospf = False
        i += 1
        continue

    out.append(line)
    i += 1

path.write_text("\n".join(out) + "\n")
PY2
}

{
  echo "Enable BFD for OSPF interfaces"
  echo "Date: $(date)"
  echo

  for r in $ROUTERS; do
    echo "============================================================"
    echo "Router: $r"
    echo "============================================================"

    BEFORE="configs/ospf_bfd_before/${r}_bird_${TS}.conf"
    AFTER="configs/ospf_bfd_after/${r}_bird_${TS}.conf"
    TMP="/tmp/${r}_bird_ospf_bfd_${TS}.conf"

    echo "[1] Saving current config from $r"
    docker exec "$r" cat /etc/bird/bird.conf > "$BEFORE"
    cp "$BEFORE" "$AFTER"

    echo "[2] Modifying config locally"
    python_modify_config "$AFTER"

    echo "[3] Copying candidate config to $r:/tmp"
    docker cp "$AFTER" "$r:$TMP"

    echo "[4] Validating candidate config inside $r"
    docker exec "$r" bird -p -c "$TMP"

    echo "[5] Backing up live config inside $r"
    docker exec "$r" cp /etc/bird/bird.conf "/etc/bird/bird.conf.before_ospf_bfd_${TS}"

    echo "[6] Applying candidate config"
    docker exec "$r" cp "$TMP" /etc/bird/bird.conf

    echo "[7] Reloading BIRD config"
    docker exec "$r" birdc configure

    echo "[8] Checking OSPF and BFD"
    docker exec "$r" birdc show protocols | grep -E "ospf|bfd|Running|up" || true
    docker exec "$r" birdc show bfd sessions || true

    echo
  done

  echo "============================================================"
  echo "Final OSPF neighbour check"
  echo "============================================================"

  for r in $ROUTERS; do
    echo "[$r]"
    docker exec "$r" birdc show ospf neighbors || true
    echo
  done

  echo "============================================================"
  echo "Final connectivity check"
  echo "============================================================"
  docker exec hpe-h1 ping -c 3 -W 1 10.0.82.2
  docker exec hpe-h1 ping -c 3 -W 1 10.0.93.2
  docker exec hpe-h3 ping -c 3 -W 1 10.0.61.2

  echo
  echo "Saved evidence: $OUT"

} | tee "$OUT"
