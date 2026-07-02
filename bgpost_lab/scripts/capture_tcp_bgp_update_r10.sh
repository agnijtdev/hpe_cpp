#!/usr/bin/env bash
set -e

CAPTURE_IN_CONTAINER="/tmp/r10_bgp_tcp_update.pcap"
CAPTURE_ON_HOST="captures/r10_bgp_tcp_update.pcap"

echo "Removing old capture files..."
docker exec r10 rm -f "$CAPTURE_IN_CONTAINER" || true
rm -f "$CAPTURE_ON_HOST"

echo "Checking r10 BGP state..."
docker exec r10 birdc show protocols

echo
echo "Starting tcpdump on r10 eth0..."
docker exec r10 tcpdump -i eth0 -U -w "$CAPTURE_IN_CONTAINER" tcp port 179 >/tmp/r10_tcpdump.log 2>&1 &
TCPDUMP_PID=$!

sleep 2

echo
echo "Withdrawing prefix from r1..."
docker exec r1 birdc disable static_routes

sleep 3

echo
echo "Re-announcing prefix from r1..."
docker exec r1 birdc enable static_routes

sleep 5

echo
echo "Stopping tcpdump..."
kill "$TCPDUMP_PID" 2>/dev/null || true
sleep 2

echo
echo "Copying capture from r10 to host..."
docker cp "r10:$CAPTURE_IN_CONTAINER" "$CAPTURE_ON_HOST"

echo
echo "Capture file:"
ls -lh "$CAPTURE_ON_HOST"

echo
echo "Reading capture summary:"
tcpdump -nn -r "$CAPTURE_ON_HOST" || true

echo
echo "Done."
