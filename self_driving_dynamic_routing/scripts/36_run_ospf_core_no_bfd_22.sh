#!/usr/bin/env bash
set -u

RUNS="${1:-22}"
TS=$(date +%Y%m%d_%H%M%S)

ROUTERS="hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9"

BACKUP_DIR="configs/ospf_core_no_bfd_backup_${TS}"
mkdir -p "$BACKUP_DIR"
mkdir -p measurement/summaries

BASE_CSV="measurement/summaries/convergence_gold_summary.csv"
WITH_BFD_BACKUP="measurement/summaries/convergence_gold_summary_with_ospf_bfd_before_no_bfd_${TS}.csv"
NO_BFD_CSV="measurement/summaries/convergence_gold_summary_no_ospf_bfd_${TS}.csv"

restore_configs_and_summary() {
  echo
  echo "Restoring original BIRD configs and original convergence summary..."

  for r in $ROUTERS; do
    if [ -f "$BACKUP_DIR/${r}_bird.conf" ]; then
      docker cp "$BACKUP_DIR/${r}_bird.conf" "$r:/etc/bird/bird.conf" >/dev/null 2>&1 || true
      docker exec "$r" birdc configure >/dev/null 2>&1 || true
    fi
  done

  if [ -f "$WITH_BFD_BACKUP" ]; then
    cp "$WITH_BFD_BACKUP" "$BASE_CSV"
  fi

  echo "Restore step completed."
}

trap restore_configs_and_summary EXIT

echo "============================================================"
echo "OSPF CORE LINK FAILURE WITHOUT OSPF-BFD"
echo "Runs: $RUNS"
echo "Timestamp: $TS"
echo "============================================================"

echo
echo "1. Backing up current router configs..."
for r in $ROUTERS; do
  docker cp "$r:/etc/bird/bird.conf" "$BACKUP_DIR/${r}_bird.conf"
done

echo
echo "2. Backing up existing with-BFD convergence summary..."
if [ -f "$BASE_CSV" ]; then
  cp "$BASE_CSV" "$WITH_BFD_BACKUP"
  rm -f "$BASE_CSV"
  echo "With-BFD summary backed up to: $WITH_BFD_BACKUP"
else
  echo "No existing convergence summary found."
fi

echo
echo "3. Temporarily disabling only OSPF-level 'bfd yes;' lines..."
python3 <<'PY'
from pathlib import Path
import subprocess
import re

routers = "hpe-r1 hpe-r2 hpe-r3 hpe-r4 hpe-r5 hpe-r6 hpe-r7 hpe-r8 hpe-r9".split()

for r in routers:
    local = Path(f"/tmp/{r}_bird_no_ospf_bfd.conf")
    subprocess.run(["docker", "cp", f"{r}:/etc/bird/bird.conf", str(local)], check=True)

    lines = local.read_text().splitlines()
    out = []

    in_ospf = False
    depth = 0
    changed = 0

    for line in lines:
        stripped = line.strip()

        if re.match(r"protocol\s+ospf\b", stripped):
            in_ospf = True
            depth = 0

        if in_ospf and re.match(r"bfd\s+yes\s*;", stripped):
            indent = line[:len(line) - len(line.lstrip())]
            out.append(indent + "# bfd yes;  # disabled temporarily for OSPF core no-BFD experiment")
            changed += 1
        else:
            out.append(line)

        if in_ospf:
            depth += line.count("{") - line.count("}")
            if depth <= 0 and "}" in line:
                in_ospf = False

    local.write_text("\n".join(out) + "\n")
    subprocess.run(["docker", "cp", str(local), f"{r}:/etc/bird/bird.conf"], check=True)
    print(f"{r}: disabled {changed} OSPF-BFD line(s)")
PY

echo
echo "4. Applying BIRD configs..."
for r in $ROUTERS; do
  echo "Configuring $r"
  docker exec "$r" birdc configure check
  docker exec "$r" birdc configure
done

echo
echo "5. Waiting for OSPF to settle..."
sleep 30

echo
echo "6. Running final validation before no-BFD experiment..."
bash scripts/12_final_project_validation.sh

echo
echo "7. Running OSPF active-path patcher..."
bash scripts/31a_patch_ospf_gold_active_path.sh || true

echo
echo "8. Running OSPF core failure experiment WITHOUT OSPF-BFD..."
bash scripts/32_run_ospf_gold_repeated.sh "$RUNS"

echo
echo "9. Saving no-BFD result separately..."
if [ -f "$BASE_CSV" ]; then
  cp "$BASE_CSV" "$NO_BFD_CSV"
  echo "No-BFD CSV saved to: $NO_BFD_CSV"
else
  echo "ERROR: No convergence summary CSV was generated."
  exit 1
fi

echo
echo "============================================================"
echo "NO-BFD RUN COMPLETE"
echo "No-BFD CSV: $NO_BFD_CSV"
echo "Original with-BFD CSV backup: $WITH_BFD_BACKUP"
echo "Original configs will now be restored automatically."
echo "============================================================"
