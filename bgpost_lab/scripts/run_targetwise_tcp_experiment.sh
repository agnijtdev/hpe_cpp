#!/usr/bin/env bash
set -e

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <number_of_routers> <trials_per_target>"
  echo "Example: $0 10 5"
  exit 1
fi

N="$1"
TRIALS="$2"

if [ "$N" -lt 2 ]; then
  echo "ERROR: number_of_routers must be at least 2"
  exit 1
fi

if [ "$TRIALS" -lt 1 ]; then
  echo "ERROR: trials_per_target must be at least 1"
  exit 1
fi

RAW_FILE="results/targetwise_tcp_${N}_routers_raw.csv"
SUMMARY_FILE="results/targetwise_tcp_${N}_routers_summary.csv"
GRAPH_FILE="results/targetwise_tcp_${N}_routers_median.png"

echo "================================================="
echo "TCP Target-wise BGP Convergence Experiment"
echo "================================================="
echo "Routers:           $N"
echo "Trials per target: $TRIALS"
echo "Targets:           r2 to r$N"
echo

echo "[1/4] Starting TCP line topology..."
./scripts/start_tcp_line_lab.sh "$N"

echo
echo "[2/4] Running target-wise convergence measurement..."
python3 scripts/measure_targetwise_tcp.py "$N" "$TRIALS"

echo
echo "[3/4] Generating target-wise median graph..."
python3 scripts/plot_targetwise_tcp.py "$N"

echo
echo "[4/4] Showing generated files..."
ls -lh "$RAW_FILE" "$SUMMARY_FILE" "$GRAPH_FILE"

echo
echo "Target-wise experiment completed successfully."
echo
echo "Raw CSV:"
echo "  $RAW_FILE"
echo
echo "Summary CSV:"
echo "  $SUMMARY_FILE"
echo
echo "Graph:"
echo "  $GRAPH_FILE"
