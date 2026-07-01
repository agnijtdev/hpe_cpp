#!/usr/bin/env bash
set -euo pipefail

RUNS="${1:-5}"

echo "============================================================"
echo "REPEATED GOLD OSPF CORE FAILURE MEASUREMENT"
echo "Runs: $RUNS"
echo "============================================================"

mkdir -p measurement/summaries

for i in $(seq 1 "$RUNS"); do
    echo
    echo "============================================================"
    echo "Starting run $i of $RUNS"
    echo "============================================================"

    bash scripts/12_final_project_validation.sh >/tmp/hpe_final_validation_before_ospf_gold.log 2>&1 || {
        echo "ERROR: Final validation failed before run $i."
        echo "See /tmp/hpe_final_validation_before_ospf_gold.log"
        exit 1
    }

    bash scripts/31_measure_ospf_core_gold_timeline.sh

    echo
    echo "Run $i complete. Waiting 10 seconds before next run..."
    sleep 30
done

echo
echo "All repeated OSPF gold runs completed."
echo "Now run:"
echo "python3 scripts/33_summarize_gold_measurements.py ospf_core_failure_gold_timeline"
