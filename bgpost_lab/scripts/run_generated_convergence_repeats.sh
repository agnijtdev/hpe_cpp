#!/usr/bin/env bash
set -euo pipefail

COUNT=10000
DELAY=1

MODES=(
  tcp
  tls
  quic
  tls_ao_static
  tls_ao_dynamic
)

for RUN in 2 3 4 5; do
  echo
  echo "===================================================="
  echo "Starting generated convergence run $RUN"
  echo "===================================================="

  for MODE in "${MODES[@]}"; do
    echo
    echo ">>> Running mode=$MODE count=$COUNT delay=${DELAY}ms run=$RUN"
    ./scripts/start_generated_convergence_lab.sh "$MODE" "$COUNT" "$DELAY" "$RUN"
  done
done
