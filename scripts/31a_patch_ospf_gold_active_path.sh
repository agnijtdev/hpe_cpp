#!/usr/bin/env bash
set -euo pipefail

SCRIPT="scripts/31_measure_ospf_core_gold_timeline.sh"
OBS_ROUTER="hpe-r3"
TARGET_IP="10.0.82.2"

echo "============================================================"
echo "PATCH OSPF GOLD SCRIPT TO FAIL ACTIVE PATH"
echo "============================================================"

echo
echo "1. Detecting current active route"
echo "------------------------------------------------------------"

PRE="$(docker exec "$OBS_ROUTER" ip route get "$TARGET_IP")"
echo "$PRE"

OLD_NH="$(echo "$PRE" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' | head -1)"
FAIL_IFACE="$(echo "$PRE" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)"

if [ -z "$OLD_NH" ] || [ -z "$FAIL_IFACE" ]; then
    echo "ERROR: Could not detect active next-hop/interface."
    exit 1
fi

echo
echo "Current active next-hop: $OLD_NH"
echo "Current active outgoing interface: $FAIL_IFACE"

echo
echo "2. Temporarily failing active interface to discover backup route"
echo "------------------------------------------------------------"

docker exec "$OBS_ROUTER" ip link set "$FAIL_IFACE" down
sleep 4

POST="$(docker exec "$OBS_ROUTER" ip route get "$TARGET_IP" || true)"
echo "$POST"

NEW_NH="$(echo "$POST" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' | head -1)"

echo
echo "3. Restoring active interface"
echo "------------------------------------------------------------"

docker exec "$OBS_ROUTER" ip link set "$FAIL_IFACE" up
sleep 8

if [ -z "$NEW_NH" ]; then
    echo "ERROR: Could not detect backup next-hop after failure."
    echo "The route may have disappeared instead of switching."
    exit 1
fi

echo "Backup/new next-hop after failure: $NEW_NH"

echo
echo "4. Patching $SCRIPT"
echo "------------------------------------------------------------"

cp "$SCRIPT" "${SCRIPT}.backup_before_active_path_patch_$(date +%Y%m%d_%H%M%S)"

sed -i "s/^FAIL_IFACE=.*/FAIL_IFACE=\"$FAIL_IFACE\"/" "$SCRIPT"
sed -i "s/^OLD_NH=.*/OLD_NH=\"$OLD_NH\"/" "$SCRIPT"
sed -i "s/^NEW_NH=.*/NEW_NH=\"$NEW_NH\"/" "$SCRIPT"
sed -i "s/^BFD_PEER=.*/BFD_PEER=\"$OLD_NH\"/" "$SCRIPT"

echo
echo "Patched values:"
grep -E '^(FAIL_IFACE|OLD_NH|NEW_NH|BFD_PEER)=' "$SCRIPT"

echo
echo "Done. Now run:"
echo "bash scripts/31_measure_ospf_core_gold_timeline.sh"
