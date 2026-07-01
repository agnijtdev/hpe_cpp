#!/usr/bin/env python3

import csv
import sys
from pathlib import Path
from statistics import mean, median, stdev

CSV_PATH = Path("measurement/summaries/convergence_gold_summary.csv")

TEST_NAME = sys.argv[1] if len(sys.argv) >= 2 else "ospf_core_failure_gold_timeline"

if not CSV_PATH.exists():
    print(f"ERROR: {CSV_PATH} does not exist.")
    sys.exit(1)

rows = []
with CSV_PATH.open() as f:
    reader = csv.DictReader(f)
    for row in reader:
        if row.get("test_name") != TEST_NAME:
            continue

        # Exclude invalid/debug runs where the route never changed.
        if row.get("bird_new_route_ms") in ("", "NA", None):
            continue
        if row.get("route_get_new_ms") in ("", "NA", None):
            continue

        rows.append(row)

if not rows:
    print(f"ERROR: No valid rows found for test_name={TEST_NAME}")
    sys.exit(1)

def to_float(value):
    if value is None:
        return None
    value = str(value).strip()
    if value in ("", "NA", "nan", "None"):
        return None
    try:
        return float(value)
    except ValueError:
        return None

metrics = [
    "bfd_detect_ms",
    "bird_new_route_ms",
    "kernel_event_ms",
    "route_get_new_ms",
    "first_loss_ms",
    "traffic_recovery_ms",
    "traffic_outage_ms",
    "ping_loss_percent",
]

print("=" * 92)
print(f"GOLD MEASUREMENT SUMMARY FOR: {TEST_NAME}")
print("=" * 92)
print(f"Valid runs found: {len(rows)}")
print()

print(f"{'Metric':30} {'Count':>6} {'Average':>10} {'Median':>10} {'Min':>10} {'Max':>10} {'StdDev':>10}")
print("-" * 92)

stats = {}

for metric in metrics:
    values = [to_float(r.get(metric)) for r in rows]
    values = [v for v in values if v is not None]

    if values:
        avg = mean(values)
        med = median(values)
        mn = min(values)
        mx = max(values)
        sd = stdev(values) if len(values) > 1 else 0.0
        stats[metric] = {
            "count": len(values),
            "avg": avg,
            "median": med,
            "min": mn,
            "max": mx,
            "stdev": sd,
        }
        print(f"{metric:30} {len(values):6d} {avg:10.2f} {med:10.2f} {mn:10.2f} {mx:10.2f} {sd:10.2f}")
    else:
        print(f"{metric:30} {'0':>6} {'NA':>10} {'NA':>10} {'NA':>10} {'NA':>10} {'NA':>10}")

print()
print("Individual valid runs:")
print("-" * 92)

wanted_cols = [
    "timestamp",
    "bfd_detect_ms",
    "route_get_new_ms",
    "kernel_event_ms",
    "bird_new_route_ms",
    "traffic_outage_ms",
    "ping_loss_percent",
]

print(",".join(wanted_cols))
for r in rows:
    print(",".join(str(r.get(c, "NA")) for c in wanted_cols))

print()
print("Professional wording:")
print("-" * 92)

def avg(metric):
    return stats.get(metric, {}).get("avg")

bfd = avg("bfd_detect_ms")
fib = avg("route_get_new_ms")
bird = avg("bird_new_route_ms")
outage = avg("traffic_outage_ms")
loss = avg("ping_loss_percent")

parts = []

if bfd is not None:
    parts.append(f"BFD/session failure detection averaged {bfd:.2f} ms")
if fib is not None:
    parts.append(f"the Linux forwarding decision changed in {fib:.2f} ms on average")
if bird is not None:
    parts.append(f"BIRD route-table sampling observed the new route in {bird:.2f} ms on average")
if outage is not None:
    parts.append(f"estimated traffic outage averaged {outage:.2f} ms")
if loss is not None:
    parts.append(f"average packet loss was {loss:.2f}%")

print("After the OSPF core-link failure, " + ", ".join(parts) + ".")

print("=" * 92)
