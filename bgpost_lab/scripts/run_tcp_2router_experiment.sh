#!/usr/bin/env bash
set -e

echo "========================================"
echo "TCP 2-Router BGP Convergence Experiment"
echo "========================================"

echo
echo "[1/4] Starting clean TCP 2-router BGP lab..."
./scripts/start_tcp_2router_lab.sh

echo
echo "[2/4] Running multi-trial convergence measurement..."
python3 scripts/measure_multi_trial_tcp.py

echo
echo "[3/4] Generating TCP convergence graph..."
python3 scripts/plot_tcp_trials.py

echo
echo "[4/4] Showing generated result files..."
ls -lh results/multi_trial_tcp.csv results/tcp_convergence_trials.png

echo
echo "Experiment completed successfully."
echo
echo "CSV result:"
echo "  results/multi_trial_tcp.csv"
echo
echo "Graph:"
echo "  results/tcp_convergence_trials.png"
