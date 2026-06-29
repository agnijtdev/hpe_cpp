#!/bin/bash
# =============================================================================
# replica-a/entrypoint.sh
# 1) Binds the anycast address 192.0.2.1/32 to loopback
# 2) Starts NSD (DNS server) in the background
# 3) Starts the BGPoTLS healthcheck monitor in the background
# 4) Starts BIRD in the foreground (keeps the container alive)
# =============================================================================
set -e

ANYCAST_IP="192.0.2.1"

echo "[replica-a] Binding anycast address ${ANYCAST_IP}/32 to lo..."
ip addr add ${ANYCAST_IP}/32 dev lo || echo "[replica-a] (already bound, continuing)"

echo "[replica-a] Starting NSD..."
nsd-checkconf /etc/nsd/nsd.conf
nsd -c /etc/nsd/nsd.conf

echo "[replica-a] Validating BIRD config syntax..."
bird -c /etc/bird/bird.conf -p

echo "[replica-a] Starting BIRD (BGPoTLS) in background so we can layer the healthcheck on top..."
bird -c /etc/bird/bird.conf -d &
BIRD_PID=$!

# Give BIRD a moment to create its control socket before the healthcheck
# script tries to talk to it via birdc.
sleep 2

echo "[replica-a] Starting healthcheck monitor (DNS liveness -> BGP withdraw/announce)..."
python3 /usr/local/bin/healthcheck.py \
    --replica-name "replica-a" \
    --dns-ip "${ANYCAST_IP}" \
    --protocol-name "anycast_route" \
    --check-interval 2 &

# Wait on BIRD so the container exits if BIRD dies.
wait ${BIRD_PID}