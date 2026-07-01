#!/usr/bin/env python3

import csv
import sys
from pathlib import Path
from statistics import mean, median, stdev

CSV_PATH = Path("measurement/summaries/bfd_wan_gold_summary.csv")

if not CSV_PATH.exists():
    print(f"ERROR: {CSV_PATH} does not exist.")
    sys.exit(1)

rows = []
with CSV_PATH.open() as f:
    reader = csv.DictReader(f)
    for row in reader:
        if row.get("test_name") != "bfd_wan_edge_failure_gold_timeline":
            continue

        # A valid BFD WAN failover run must have BFD detection and route change.
        if row.get("bfd_detect_ms") in ("", "NA", None):
            continue
        if row.get("route_get_changed_ms") in ("", "NA", None):
            continue
        if row.get("bird_route_changed_ms") in ("", "NA", None):
            continue

        rows.append(row)

if not rows:
    print("ERROR: No valid BFD WAN gold rows found.")
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
    "bgp_non_established_ms",
    "bgp_reestablished_ms",
    "bird_route_changed_ms",
    "route_get_changed_ms",
    "kernel_event_ms",
    "first_loss_ms",
    "traffic_recovery_ms",
    "traffic_outage_ms",
    "traffic_loss_percent",
    "bfd_packet_lines",
    "bgp_packet_lines",
]

print("=" * 100)
print("GOLD BFD WAN EDGE FAILURE SUMMARY")
print("=" * 100)
print(f"Valid runs found: {len(rows)}")
print()

print(f"{'Metric':32} {'Count':>6} {'Average':>10} {'Median':>10} {'Min':>10} {'Max':>10} {'StdDev':>10}")
print("-" * 100)

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
        print(f"{metric:32} {len(values):6d} {avg:10.2f} {med:10.2f} {mn:10.2f} {mx:10.2f} {sd:10.2f}")
    else:
        print(f"{metric:32} {'0':>6} {'NA':>10} {'NA':>10} {'NA':>10} {'NA':>10} {'NA':>10}")

print()
print("Individual valid runs:")
print("-" * 100)

wanted = [
    "timestamp",
    "bfd_detect_ms",
    "bgp_non_established_ms",
    "bgp_reestablished_ms",
    "route_get_changed_ms",
    "bird_route_changed_ms",
    "traffic_outage_ms",
    "traffic_loss_percent",
    "bfd_packet_lines",
    "bgp_packet_lines",
]

print(",".join(wanted))
for r in rows:
    print(",".join(str(r.get(c, "NA")) for c in wanted))

print()
print("Professional wording:")
print("-" * 100)

def avg(metric):
    return stats.get(metric, {}).get("avg")

bfd = avg("bfd_detect_ms")
bgp_down = avg("bgp_non_established_ms")
route_get = avg("route_get_changed_ms")
bird_route = avg("bird_route_changed_ms")
outage = avg("traffic_outage_ms")
loss = avg("traffic_loss_percent")

parts = []

if bfd is not None:
    parts.append(f"BFD session failure was observed in {bfd:.2f} ms on average")
if bgp_down is not None:
    parts.append(f"BGP reacted to the failure in {bgp_down:.2f} ms on average")
if route_get is not None:
    parts.append(f"the Linux forwarding decision switched to the alternate path in {route_get:.2f} ms on average")
if bird_route is not None:
    parts.append(f"BIRD route-table sampling observed the alternate route in {bird_route:.2f} ms on average")
if outage is not None:
    parts.append(f"estimated traffic outage averaged {outage:.2f} ms")
if loss is not None:
    parts.append(f"average packet loss was {loss:.2f}%")

print("After the WAN edge failure, " + ", ".join(parts) + ".")

print("=" * 100)
