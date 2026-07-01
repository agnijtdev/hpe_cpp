#!/bin/bash
# =============================================================================
# provider-router/entrypoint.sh
# Starts BIRD in the foreground with logging to stdout (so `docker logs` works)
# =============================================================================
set -e

echo "[provider-router] Validating BIRD config syntax..."
bird -c /etc/bird/bird.conf -p
if [ $? -ne 0 ]; then
    echo "[provider-router] FATAL: bird.conf failed syntax check."
    exit 1
fi

echo "[provider-router] Starting BIRD (BGPoTLS) in foreground..."
exec bird -c /etc/bird/bird.conf -f -d