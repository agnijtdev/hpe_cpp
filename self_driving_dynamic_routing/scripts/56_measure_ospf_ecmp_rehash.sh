#!/usr/bin/env bash
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)

mkdir -p evidence/ecmp_rehash results/ecmp_rehash screenshots

OUT="evidence/ecmp_rehash/ecmp_rehash_${TS}.txt"
CSV="results/ecmp_rehash/ecmp_rehash_${TS}.csv"
LATEST="results/ecmp_rehash/ecmp_rehash_latest.csv"

ROUTER="hpe-r3"
SRC_IP="10.0.35.2"
TARGET_NET="10.0.24.0/24"

FAILED_IF="eth3"
FAILED_NH="10.0.34.3"
SURVIVOR_NH="10.0.23.2"

FLOW_COUNT=40

restore_link() {
  docker exec "$ROUTER" ip link set "$FAILED_IF" up >/dev/null 2>&1 || true
}

trap restore_link EXIT

get_nh_for_flow() {
  local dst="$1"
  local sport="$2"
  local dport="$3"

  local line
  line=$(docker exec "$ROUTER" sh -lc \
    "ip route get $dst from $SRC_IP ipproto 6 sport $sport dport $dport 2>/dev/null || ip route get $dst 2>/dev/null" \
    | head -1 || true)

  local nh
  nh=$(echo "$line" | grep -oE 'via [0-9.]+' | head -1 | awk '{print $2}' || true)

  if [ -z "$nh" ]; then
    nh="NA"
  fi

  echo "$nh|$line"
}

sample_flows() {
  local phase="$1"
  local tmp="$2"

  : > "$tmp"

  for i in $(seq 1 "$FLOW_COUNT"); do
    host=$((2 + i))
    dst="10.0.24.$host"
    sport=$((10000 + i))
    dport=$((20000 + i))

    result=$(get_nh_for_flow "$dst" "$sport" "$dport")
    nh="${result%%|*}"
    line="${result#*|}"

    echo "$phase,$i,$dst,$sport,$dport,$nh,\"$line\"" >> "$tmp"
  done
}

count_nh() {
  local tmp="$1"
  local nh="$2"
  awk -F, -v nh="$nh" '$6 == nh {c++} END {print c+0}' "$tmp"
}

{
echo "============================================================"
echo "OSPF ECMP RE-HASH TO SURVIVING NEXT-HOP"
echo "Timestamp: $TS"
echo "============================================================"
echo
echo "Router under test: $ROUTER"
echo "Target prefix: $TARGET_NET"
echo "Source IP used for synthetic flow lookups: $SRC_IP"
echo
echo "Failed ECMP next-hop   : $FAILED_NH"
echo "Surviving ECMP next-hop: $SURVIVOR_NH"
echo "Failed interface       : $ROUTER $FAILED_IF"
echo
echo "Note:"
echo "This test uses synthetic route lookups with different flow keys."
echo "It observes ECMP next-hop selection before and after one ECMP branch fails."
echo

echo "============================================================"
echo "1. Baseline ECMP route"
echo "============================================================"
echo
echo "Kernel route:"
docker exec "$ROUTER" ip route show "$TARGET_NET" || true
echo
echo "BIRD route:"
docker exec "$ROUTER" birdc show route "$TARGET_NET" all | grep -E "$TARGET_NET|via|unicast" || true
echo

BEFORE_TMP=$(mktemp)
AFTER_TMP=$(mktemp)

echo "============================================================"
echo "2. Sampling synthetic flow lookups before failure"
echo "============================================================"
echo
sample_flows "before" "$BEFORE_TMP"

BEFORE_FAILED=$(count_nh "$BEFORE_TMP" "$FAILED_NH")
BEFORE_SURVIVOR=$(count_nh "$BEFORE_TMP" "$SURVIVOR_NH")
BEFORE_OTHER=$((FLOW_COUNT - BEFORE_FAILED - BEFORE_SURVIVOR))

echo "Before failure distribution:"
echo "Flows mapped to failed next-hop $FAILED_NH       : $BEFORE_FAILED"
echo "Flows mapped to survivor next-hop $SURVIVOR_NH   : $BEFORE_SURVIVOR"
echo "Flows mapped to other/NA                         : $BEFORE_OTHER"
echo

echo "Sample before-failure flow mappings:"
column -s, -t "$BEFORE_TMP" | head -15
echo

echo "============================================================"
echo "3. Failing one ECMP branch"
echo "============================================================"
echo
echo "Command: docker exec $ROUTER ip link set $FAILED_IF down"
docker exec "$ROUTER" ip link set "$FAILED_IF" down

sleep 3

echo
echo "Kernel route after failure:"
docker exec "$ROUTER" ip route show "$TARGET_NET" || true
echo
echo "BIRD route after failure:"
docker exec "$ROUTER" birdc show route "$TARGET_NET" all | grep -E "$TARGET_NET|via|unicast" || true
echo

echo "============================================================"
echo "4. Sampling same flow lookups after failure"
echo "============================================================"
echo
sample_flows "after" "$AFTER_TMP"

AFTER_FAILED=$(count_nh "$AFTER_TMP" "$FAILED_NH")
AFTER_SURVIVOR=$(count_nh "$AFTER_TMP" "$SURVIVOR_NH")
AFTER_OTHER=$((FLOW_COUNT - AFTER_FAILED - AFTER_SURVIVOR))

echo "After failure distribution:"
echo "Flows still mapped to failed next-hop $FAILED_NH : $AFTER_FAILED"
echo "Flows mapped to survivor next-hop $SURVIVOR_NH   : $AFTER_SURVIVOR"
echo "Flows mapped to other/NA                         : $AFTER_OTHER"
echo

echo "Sample after-failure flow mappings:"
column -s, -t "$AFTER_TMP" | head -15
echo

echo "============================================================"
echo "5. Re-hash analysis"
echo "============================================================"
echo

REMAPPED=0
STAYED_SURVIVOR=0
STILL_FAILED=0

for i in $(seq 1 "$FLOW_COUNT"); do
  before_nh=$(awk -F, -v id="$i" '$2 == id {print $6}' "$BEFORE_TMP")
  after_nh=$(awk -F, -v id="$i" '$2 == id {print $6}' "$AFTER_TMP")

  if [ "$before_nh" = "$FAILED_NH" ] && [ "$after_nh" = "$SURVIVOR_NH" ]; then
    REMAPPED=$((REMAPPED + 1))
  fi

  if [ "$before_nh" = "$SURVIVOR_NH" ] && [ "$after_nh" = "$SURVIVOR_NH" ]; then
    STAYED_SURVIVOR=$((STAYED_SURVIVOR + 1))
  fi

  if [ "$after_nh" = "$FAILED_NH" ]; then
    STILL_FAILED=$((STILL_FAILED + 1))
  fi
done

echo "Flows originally mapped to failed next-hop and remapped to survivor: $REMAPPED"
echo "Flows originally on survivor and still on survivor                  : $STAYED_SURVIVOR"
echo "Flows still mapped to failed next-hop after failure                 : $STILL_FAILED"
echo

if [ "$STILL_FAILED" -eq 0 ] && [ "$REMAPPED" -gt 0 ]; then
  echo "ECMP re-hash result: SUCCESS"
  echo "Conclusion: Flow lookups mapped to the failed next-hop were recalculated to the surviving next-hop."
else
  echo "ECMP re-hash result: CHECK REQUIRED"
  echo "Conclusion: The result did not clearly show remapping from failed next-hop to survivor."
fi

echo
echo "============================================================"
echo "6. Save CSV"
echo "============================================================"
echo

{
echo "timestamp,flow_id,dst_ip,sport,dport,before_next_hop,after_next_hop,rehash_status,before_line,after_line"

for i in $(seq 1 "$FLOW_COUNT"); do
  before_row=$(awk -F, -v id="$i" '$2 == id {print}' "$BEFORE_TMP")
  after_row=$(awk -F, -v id="$i" '$2 == id {print}' "$AFTER_TMP")

  dst=$(echo "$before_row" | cut -d, -f3)
  sport=$(echo "$before_row" | cut -d, -f4)
  dport=$(echo "$before_row" | cut -d, -f5)
  before_nh=$(echo "$before_row" | cut -d, -f6)
  after_nh=$(echo "$after_row" | cut -d, -f6)
  before_line=$(echo "$before_row" | cut -d, -f7-)
  after_line=$(echo "$after_row" | cut -d, -f7-)

  status="unchanged_or_other"

  if [ "$before_nh" = "$FAILED_NH" ] && [ "$after_nh" = "$SURVIVOR_NH" ]; then
    status="remapped_failed_to_survivor"
  elif [ "$before_nh" = "$SURVIVOR_NH" ] && [ "$after_nh" = "$SURVIVOR_NH" ]; then
    status="stayed_on_survivor"
  elif [ "$after_nh" = "$FAILED_NH" ]; then
    status="still_on_failed"
  fi

  echo "$TS,$i,$dst,$sport,$dport,$before_nh,$after_nh,$status,$before_line,$after_line"
done
} > "$CSV"

cp "$CSV" "$LATEST"

echo "CSV saved to: $CSV"
echo "Latest CSV saved to: $LATEST"
echo

echo "============================================================"
echo "7. Restore failed link"
echo "============================================================"
echo
restore_link
sleep 10

echo "Final ECMP route after restore:"
docker exec "$ROUTER" ip route show "$TARGET_NET" || true

rm -f "$BEFORE_TMP" "$AFTER_TMP"

} | tee "$OUT"

echo
echo "Evidence saved to: $OUT"
echo "CSV saved to: $CSV"
