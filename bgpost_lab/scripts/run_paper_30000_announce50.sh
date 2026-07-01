#!/usr/bin/env bash
set -euo pipefail

cd "$HOME/Documents/bgpost-lab"

COUNT=30000
ANN=50
LINK=15

cleanup_lab() {
  for i in $(seq 1 50); do
    docker rm -f "r$i" >/dev/null 2>&1 || true
  done

  docker rm -f exabgp >/dev/null 2>&1 || true
  docker network ls --format '{{.Name}}' | awk '/^bgpost_mrt_/ {print}' | xargs -r docker network rm
}

run_one() {
  local name="$1"
  local script="$2"

  echo
  echo "============================================================"
  echo "Starting $name: $COUNT prefixes, ${ANN}ms interval, ${LINK}ms link delay"
  echo "Time: $(date)"
  echo "============================================================"

  cleanup_lab

  bash "$script" 10 "$COUNT" "$ANN" "$LINK" 2>&1 | tee "logs/${name}_${COUNT}_announce${ANN}_delay${LINK}.log"

  echo
  echo "Finished $name"
  echo "Time: $(date)"
}

run_one "tcp" "scripts/start_tcp_mrt_loop_lab.sh"
run_one "tls" "scripts/start_tls_mrt_loop_lab.sh"
run_one "quic" "scripts/start_quic_mrt_loop_lab.sh"
run_one "tls_ao_static" "scripts/start_tls_ao_mrt_loop_lab.sh"
run_one "tls_ao_dynamic" "scripts/start_tls_ao_dynamic_mrt_loop_lab.sh"

cleanup_lab

echo
echo "All 5 paper-scale experiments completed."
echo "Time: $(date)"
