#!/usr/bin/env bash
set -u

TS=$(date +%Y%m%d_%H%M%S)

CYCLES="${1:-5}"

R1="hpe-r2"
R2="hpe-r9"

R1_PEER="10.0.29.3"
R2_PEER="10.0.29.2"

mkdir -p evidence/bfd_flap results/bfd_flap screenshots/bfd_flap

OUT="evidence/bfd_flap/bfd_flap_cycles_${TS}.txt"
CSV="results/bfd_flap/bfd_flap_cycles_${TS}.csv"
LATEST="results/bfd_flap/bfd_flap_cycles_latest.csv"

now_ms() {
  date +%s%3N
}

get_iface_to_peer() {
  local router="$1"
  local peer="$2"

  docker exec "$router" ip -o route get "$peer" 2>/dev/null \
    | awk '{
        for (i=1; i<=NF; i++) {
          if ($i == "dev") {
            print $(i+1);
            exit
          }
        }
      }'
}

get_bfd_state() {
  local router="$1"
  local peer="$2"

  local line
  line=$(docker exec "$router" birdc show bfd sessions 2>/dev/null | grep "$peer" || true)

  if echo "$line" | grep -qw "Up"; then
    echo "Up"
  elif echo "$line" | grep -qw "Down"; then
    echo "Down"
  elif [ -z "$line" ]; then
    echo "Missing"
  else
    echo "Other"
  fi
}

wait_both_up() {
  local timeout_ms="$1"
  local start
  start=$(now_ms)

  while true; do
    local s1 s2 now elapsed
    s1=$(get_bfd_state "$R1" "$R1_PEER")
    s2=$(get_bfd_state "$R2" "$R2_PEER")
    now=$(now_ms)
    elapsed=$((now - start))

    if [ "$s1" = "Up" ] && [ "$s2" = "Up" ]; then
      echo "$elapsed"
      return 0
    fi

    if [ "$elapsed" -ge "$timeout_ms" ]; then
      echo "TIMEOUT"
      return 1
    fi

    sleep 0.05
  done
}

wait_both_not_up() {
  local timeout_ms="$1"
  local start
  start=$(now_ms)

  while true; do
    local s1 s2 now elapsed
    s1=$(get_bfd_state "$R1" "$R1_PEER")
    s2=$(get_bfd_state "$R2" "$R2_PEER")
    now=$(now_ms)
    elapsed=$((now - start))

    if [ "$s1" != "Up" ] && [ "$s2" != "Up" ]; then
      echo "$elapsed"
      return 0
    fi

    if [ "$elapsed" -ge "$timeout_ms" ]; then
      echo "TIMEOUT"
      return 1
    fi

    sleep 0.05
  done
}

cleanup() {
  echo
  echo "Cleanup: removing tc loss and allowing BFD to recover..."
  docker exec "$R1" tc qdisc del dev "$IF1" root >/dev/null 2>&1 || true
  docker exec "$R2" tc qdisc del dev "$IF2" root >/dev/null 2>&1 || true
  sleep 2
}

IF1=$(get_iface_to_peer "$R1" "$R1_PEER")
IF2=$(get_iface_to_peer "$R2" "$R2_PEER")

if [ -z "$IF1" ] || [ -z "$IF2" ]; then
  echo "Could not detect interfaces. R1_IF=$IF1 R2_IF=$IF2"
  exit 1
fi

trap cleanup EXIT

{
echo "============================================================"
echo "BFD REPEATED FLAP BEHAVIOUR TEST"
echo "Timestamp: $TS"
echo "Cycles: $CYCLES"
echo "BFD session: $R1 <-> $R2"
echo "$R1 peer: $R1_PEER via $IF1"
echo "$R2 peer: $R2_PEER via $IF2"
echo "Failure method: tc netem loss 100%"
echo "============================================================"
echo

echo "1. Initial BFD state"
echo "------------------------------------------------------------"
docker exec "$R1" birdc show bfd sessions | grep "$R1_PEER" || true
docker exec "$R2" birdc show bfd sessions | grep "$R2_PEER" || true
echo

S1=$(get_bfd_state "$R1" "$R1_PEER")
S2=$(get_bfd_state "$R2" "$R2_PEER")

echo "Initial state on $R1: $S1"
echo "Initial state on $R2: $S2"
echo

if [ "$S1" != "Up" ] || [ "$S2" != "Up" ]; then
  echo "ERROR: BFD is not Up on both sides. Aborting."
  exit 1
fi

echo "2. Running flap cycles"
echo "------------------------------------------------------------"

echo "timestamp,cycle,r1_state_before,r2_state_before,down_detect_ms,recovery_ms,r1_state_after_down,r2_state_after_down,r1_state_after_recovery,r2_state_after_recovery,result" > "$CSV"

for i in $(seq 1 "$CYCLES"); do
  echo
  echo "Cycle $i"

  R1_BEFORE=$(get_bfd_state "$R1" "$R1_PEER")
  R2_BEFORE=$(get_bfd_state "$R2" "$R2_PEER")

  echo "  Before flap: $R1=$R1_BEFORE, $R2=$R2_BEFORE"

  docker exec "$R1" tc qdisc del dev "$IF1" root >/dev/null 2>&1 || true
  docker exec "$R2" tc qdisc del dev "$IF2" root >/dev/null 2>&1 || true

  START_DOWN=$(now_ms)
  docker exec "$R1" tc qdisc add dev "$IF1" root netem loss 100%
  docker exec "$R2" tc qdisc add dev "$IF2" root netem loss 100%

  DOWN_MS=$(wait_both_not_up 5000)

  R1_DOWN=$(get_bfd_state "$R1" "$R1_PEER")
  R2_DOWN=$(get_bfd_state "$R2" "$R2_PEER")

  echo "  After packet loss injection: $R1=$R1_DOWN, $R2=$R2_DOWN, down_detect_ms=$DOWN_MS"

  START_UP=$(now_ms)
  docker exec "$R1" tc qdisc del dev "$IF1" root >/dev/null 2>&1 || true
  docker exec "$R2" tc qdisc del dev "$IF2" root >/dev/null 2>&1 || true

  RECOVERY_MS=$(wait_both_up 7000)

  R1_UP=$(get_bfd_state "$R1" "$R1_PEER")
  R2_UP=$(get_bfd_state "$R2" "$R2_PEER")

  echo "  After restore: $R1=$R1_UP, $R2=$R2_UP, recovery_ms=$RECOVERY_MS"

  RESULT="pass"
  if [ "$DOWN_MS" = "TIMEOUT" ] || [ "$RECOVERY_MS" = "TIMEOUT" ]; then
    RESULT="fail"
  fi

  echo "$TS,$i,$R1_BEFORE,$R2_BEFORE,$DOWN_MS,$RECOVERY_MS,$R1_DOWN,$R2_DOWN,$R1_UP,$R2_UP,$RESULT" >> "$CSV"

  sleep 1
done

cp "$CSV" "$LATEST"

echo
echo "3. Final BFD state"
echo "------------------------------------------------------------"
docker exec "$R1" birdc show bfd sessions | grep "$R1_PEER" || true
docker exec "$R2" birdc show bfd sessions | grep "$R2_PEER" || true

echo
echo "4. CSV result"
echo "------------------------------------------------------------"
cat "$CSV"

echo
echo "Saved evidence to: $OUT"
echo "Saved CSV to: $CSV"
echo "Updated latest CSV at: $LATEST"

} | tee "$OUT"

python3 - <<PY
import csv
from pathlib import Path

csv_path = Path("$CSV")
rows = list(csv.DictReader(csv_path.open()))

valid_down = [int(r["down_detect_ms"]) for r in rows if r["down_detect_ms"].isdigit()]
valid_up = [int(r["recovery_ms"]) for r in rows if r["recovery_ms"].isdigit()]
passed = sum(1 for r in rows if r["result"] == "pass")

print()
print("Summary:")
print(f"Cycles passed: {passed}/{len(rows)}")
if valid_down:
    print(f"Average BFD Down detection: {sum(valid_down)/len(valid_down):.2f} ms")
    print(f"Minimum BFD Down detection: {min(valid_down)} ms")
    print(f"Maximum BFD Down detection: {max(valid_down)} ms")
if valid_up:
    print(f"Average BFD recovery: {sum(valid_up)/len(valid_up):.2f} ms")
    print(f"Minimum BFD recovery: {min(valid_up)} ms")
    print(f"Maximum BFD recovery: {max(valid_up)} ms")
PY
