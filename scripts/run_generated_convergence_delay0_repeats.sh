#!/usr/bin/env bash
set -euo pipefail

COUNT=10000
DELAY=0

MODES=(
  tcp
  tls
  quic
  tls_ao_static
  tls_ao_dynamic
)

mkdir -p logs

for RUN in 1 2 3 4 5; do
  echo
  echo "===================================================="
  echo "Starting generated bulk convergence run $RUN"
  echo "COUNT=$COUNT DELAY=${DELAY}ms"
  echo "===================================================="

  for MODE in "${MODES[@]}"; do
    echo
    echo ">>> Running mode=$MODE count=$COUNT delay=${DELAY}ms run=$RUN"

    ./scripts/start_generated_convergence_lab.sh "$MODE" "$COUNT" "$DELAY" "$RUN" \
      2>&1 | tee "logs/convergence_${MODE}_${COUNT}_delay${DELAY}_run${RUN}.log"
  done
done
