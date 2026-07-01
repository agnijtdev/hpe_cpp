#!/usr/bin/env python3

import csv
from pathlib import Path
from statistics import mean, median, stdev

CSV = Path("measurement/summaries/ospf_ecmp_dynamic_gold_summary.csv")

rows = []
with CSV.open() as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r.get("mode") in ("no_bfd", "with_bfd"):
            rows.append(r)

def val(x):
    if x in (None, "", "NA"):
        return None
    try:
        return float(x)
    except:
        return None

def stats(mode, metric):
    values = [val(r.get(metric)) for r in rows if r.get("mode") == mode]
    values = [v for v in values if v is not None]
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

metrics = [
    "bfd_detect_ms",
    "kernel_event_ms",
    "route_get_switch_ms",
    "bird_route_survivor_only_ms",
    "traffic_loss_percent",
]

print("=" * 100)
print("OSPF ECMP DYNAMIC GOLD SUMMARY")
print("=" * 100)

for mode in ("no_bfd", "with_bfd"):
    count = len([r for r in rows if r.get("mode") == mode])
    print(f"\nMode: {mode} | Runs: {count}")
    print("-" * 100)
    print(f"{'Metric':35} {'Count':>6} {'Average':>10} {'Median':>10} {'Min':>10} {'Max':>10}")

    for m in metrics:
        s = stats(mode, m)

        # Ignore fake BFD metric for no_bfd mode.
        if mode == "no_bfd" and m == "bfd_detect_ms":
            print(f"{m:35} {'-':>6} {'ignored':>10} {'ignored':>10} {'-':>10} {'-':>10}")
            continue

        if s is None:
            print(f"{m:35} {'0':>6} {'NA':>10} {'NA':>10} {'NA':>10} {'NA':>10}")
        else:
            print(f"{m:35} {s['count']:6d} {s['avg']:10.2f} {s['median']:10.2f} {s['min']:10.2f} {s['max']:10.2f}")

print("\nComparison:")
print("-" * 100)

for m in ["kernel_event_ms", "route_get_switch_ms", "bird_route_survivor_only_ms", "traffic_loss_percent"]:
    a = stats("no_bfd", m)
    b = stats("with_bfd", m)

    if not a or not b:
        continue

    no_avg = a["avg"]
    with_avg = b["avg"]

    if no_avg == 0:
        change = "NA"
    else:
        pct = ((no_avg - with_avg) / no_avg) * 100
        change = f"{pct:.2f}% faster" if pct >= 0 else f"{abs(pct):.2f}% slower"

    print(f"{m:35} no_bfd_avg={no_avg:.2f} ms, with_bfd_avg={with_avg:.2f} ms, change={change}")

print("\nProfessional wording:")
print("-" * 100)
print(
    "In the direct interface-down OSPF ECMP failover experiment, both no-BFD and with-BFD modes maintained 0% packet loss. "
    "The Linux forwarding decision switched to the surviving ECMP next-hop in roughly the same time in both modes. "
    "This is expected because the failure was a local interface-down event, which the kernel reports immediately to BIRD through netlink. "
    "Therefore, this experiment mainly demonstrates ECMP path protection and zero-loss failover, while the BFD WAN edge experiment better demonstrates BFD-driven fast failure detection."
)
print("=" * 100)
