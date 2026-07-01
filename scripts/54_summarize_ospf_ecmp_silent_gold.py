#!/usr/bin/env python3

import csv
from pathlib import Path
from statistics import mean, median, stdev

CSV_PATH = Path("measurement/summaries/ospf_ecmp_silent_gold_summary.csv")

if not CSV_PATH.exists():
    raise SystemExit(f"ERROR: {CSV_PATH} not found")

rows = []
with CSV_PATH.open() as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("mode") in ("no_bfd", "with_bfd"):
            rows.append(r)

def to_float(x):
    if x in (None, "", "NA"):
        return None
    try:
        return float(x)
    except ValueError:
        return None

def get_values(mode, metric):
    values = []
    for r in rows:
        if r.get("mode") != mode:
            continue
        v = to_float(r.get(metric))
        if v is not None:
            values.append(v)
    return values

def stat(mode, metric):
    values = get_values(mode, metric)
    if not values:
        return None
    return {
        "count": len(values),
        "avg": mean(values),
        "median": median(values),
        "min": min(values),
        "max": max(values),
        "stdev": stdev(values) if len(values) > 1 else 0.0,
    }

def fmt(v):
    return "NA" if v is None else f"{v:.2f}"

metrics = [
    "bfd_detect_ms",
    "kernel_event_ms",
    "route_get_switch_ms",
    "bird_route_survivor_only_ms",
    "traffic_outage_ms",
    "traffic_loss_percent",
    "bfd_packet_lines",
]

print("=" * 110)
print("OSPF ECMP SILENT FAILURE GOLD SUMMARY")
print("=" * 110)

for mode in ("no_bfd", "with_bfd"):
    mode_rows = [r for r in rows if r.get("mode") == mode]
    print()
    print(f"Mode: {mode} | Runs: {len(mode_rows)}")
    print("-" * 110)
    print(f"{'Metric':35} {'Count':>6} {'Average':>12} {'Median':>12} {'Min':>12} {'Max':>12} {'StdDev':>12}")

    for m in metrics:
        if mode == "no_bfd" and m == "bfd_detect_ms":
            print(f"{m:35} {'-':>6} {'ignored':>12} {'ignored':>12} {'-':>12} {'-':>12} {'-':>12}")
            continue

        s = stat(mode, m)
        if not s:
            print(f"{m:35} {'0':>6} {'NA':>12} {'NA':>12} {'NA':>12} {'NA':>12} {'NA':>12}")
        else:
            print(
                f"{m:35} "
                f"{s['count']:6d} "
                f"{s['avg']:12.2f} "
                f"{s['median']:12.2f} "
                f"{s['min']:12.2f} "
                f"{s['max']:12.2f} "
                f"{s['stdev']:12.2f}"
            )

print()
print("Comparison: no-BFD vs with-BFD")
print("-" * 110)

compare_metrics = [
    "kernel_event_ms",
    "route_get_switch_ms",
    "bird_route_survivor_only_ms",
    "traffic_outage_ms",
    "traffic_loss_percent",
]

for m in compare_metrics:
    a = stat("no_bfd", m)
    b = stat("with_bfd", m)

    if not a or not b:
        continue

    no_avg = a["avg"]
    with_avg = b["avg"]

    if no_avg == 0:
        improvement = "NA"
    else:
        pct = ((no_avg - with_avg) / no_avg) * 100
        improvement = f"{pct:.2f}% lower/faster with BFD"

    print(
        f"{m:35} "
        f"no_bfd_avg={no_avg:10.2f}, "
        f"with_bfd_avg={with_avg:10.2f}, "
        f"improvement={improvement}"
    )

print()
print("Professional wording:")
print("-" * 110)

no_route = stat("no_bfd", "route_get_switch_ms")
yes_route = stat("with_bfd", "route_get_switch_ms")
no_bird = stat("no_bfd", "bird_route_survivor_only_ms")
yes_bird = stat("with_bfd", "bird_route_survivor_only_ms")
no_outage = stat("no_bfd", "traffic_outage_ms")
yes_outage = stat("with_bfd", "traffic_outage_ms")
no_loss = stat("no_bfd", "traffic_loss_percent")
yes_loss = stat("with_bfd", "traffic_loss_percent")
bfd = stat("with_bfd", "bfd_detect_ms")

print(
    f"In the silent ECMP branch failure experiment, the interface was kept UP while packets on one ECMP branch were silently dropped using tc/netem. "
    f"Without BFD, the Linux forwarding decision switched to the surviving path in {no_route['avg']:.2f} ms on average, and BIRD route-table sampling observed the survivor-only route in {no_bird['avg']:.2f} ms on average. "
    f"With OSPF-BFD enabled, BFD failure was observed in {bfd['avg']:.2f} ms on average, the forwarding decision switched in {yes_route['avg']:.2f} ms on average, and BIRD observed the survivor-only route in {yes_bird['avg']:.2f} ms on average. "
    f"Traffic outage reduced from {no_outage['avg']:.2f} ms to {yes_outage['avg']:.2f} ms, and packet loss reduced from {no_loss['avg']:.2f}% to {yes_loss['avg']:.2f}%. "
    f"This shows that BFD is especially valuable for silent blackhole-style failures where the kernel does not receive an immediate link-down event."
)

print("=" * 110)
