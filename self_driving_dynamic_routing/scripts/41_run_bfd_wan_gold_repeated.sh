#!/usr/bin/env bash
set -euo pipefail

RUNS="${1:-5}"

echo "============================================================"
echo "REPEATED GOLD BFD WAN EDGE FAILURE MEASUREMENT"
echo "Runs: $RUNS"
echo "============================================================"

mkdir -p measurement/summaries

for i in $(seq 1 "$RUNS"); do
    echo
    echo "============================================================"
    echo "Starting BFD gold run $i of $RUNS"
    echo "============================================================"

    bash scripts/12_final_project_validation.sh >/tmp/hpe_final_validation_before_bfd_gold.log 2>&1 || {
        echo "ERROR: Final validation failed before BFD run $i."
        echo "See /tmp/hpe_final_validation_before_bfd_gold.log"
        exit 1
    }

    bash scripts/40a_prepare_bfd_direct_path.sh

    bash scripts/40_measure_bfd_wan_edge_gold_timeline.sh

    echo
    echo "Run $i complete. Waiting 30 seconds before next run..."
    sleep 30
done

echo
echo "All repeated BFD WAN gold runs completed."
echo "Now run:"
echo "python3 scripts/42_summarize_bfd_wan_gold.py"
