#!/usr/bin/env bash
set -e

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <number_of_routers> <trials>"
  echo "Example: $0 10 10"
  exit 1
fi

N="$1"
TRIALS="$2"

if [ "$N" -lt 2 ]; then
  echo "ERROR: number_of_routers must be at least 2"
  exit 1
fi

if [ "$TRIALS" -lt 1 ]; then
  echo "ERROR: trials must be at least 1"
  exit 1
fi

CSV_FILE="results/line_tcp_${N}_routers.csv"
PNG_FILE="results/line_tcp_${N}_routers.png"

echo "=============================================="
echo "TCP BGP Line Topology Convergence Experiment"
echo "=============================================="
echo "Routers: $N"
echo "Trials:  $TRIALS"
echo "Target:  r1 to r$N"
echo

echo "[1/4] Starting TCP line topology..."
./scripts/start_tcp_line_lab.sh "$N"

echo
echo "[2/4] Measuring convergence..."
python3 scripts/measure_line_tcp.py "$N" "$TRIALS"

echo
echo "[3/4] Plotting convergence graph..."
python3 scripts/plot_line_tcp.py "$N"

echo
echo "[4/4] Showing generated result files..."
ls -lh "$CSV_FILE" "$PNG_FILE"

echo
echo "Experiment completed successfully."
echo
echo "CSV:"
echo "  $CSV_FILE"
echo
echo "Graph:"
echo "  $PNG_FILE"
