import csv
import gzip
import statistics
from pathlib import Path
from collections import defaultdict

import matplotlib.pyplot as plt


PROJECT = Path.home() / "Documents/bgpost-lab"

REQUESTED_COUNT = 30000
ANNOUNCE = 50
LINK_DELAY = 15

OUT_DIR = PROJECT / "results/final_5_mode_graphs_observed_13104_announce50_delay15"
OUT_DIR.mkdir(parents=True, exist_ok=True)

INPUTS = {
    "TCP": PROJECT / f"results/mrt_parsed_tcp_{REQUESTED_COUNT}_announce{ANNOUNCE}_delay{LINK_DELAY}/r1.csv.gz",
    "TLS": PROJECT / f"results/mrt_parsed_tls_{REQUESTED_COUNT}_announce{ANNOUNCE}_delay{LINK_DELAY}/r1.csv.gz",
    "QUIC": PROJECT / f"results/mrt_parsed_quic_{REQUESTED_COUNT}_announce{ANNOUNCE}_delay{LINK_DELAY}/r1.csv.gz",
    "TLS-TCP-AO Static": PROJECT / f"results/mrt_parsed_tls_ao_static_{REQUESTED_COUNT}_announce{ANNOUNCE}_delay{LINK_DELAY}/r1.csv.gz",
    "TLS-AO Dynamic": PROJECT / f"results/mrt_parsed_tls_ao_dynamic_{REQUESTED_COUNT}_announce{ANNOUNCE}_delay{LINK_DELAY}/r1.csv.gz",
}


def load_durations(path):
    seen = defaultdict(list)

    with gzip.open(path, "rt") as f:
        reader = csv.DictReader(f)

        for row in reader:
            prefix = row.get("prefix", "")

            if prefix.startswith("10."):
                seen[prefix].append(float(row["time"]))

    durations = [
        times[-1] - times[0]
        for times in seen.values()
        if len(times) == 2
    ]

    return sorted(durations), len(seen)


def percentile(values, pct):
    k = (len(values) - 1) * pct / 100
    low = int(k)
    high = min(low + 1, len(values) - 1)

    if low == high:
        return values[low]

    weight = k - low
    return values[low] * (1 - weight) + values[high] * weight


all_data = {}
summary_rows = []

for label, path in INPUTS.items():
    if not path.exists():
        raise SystemExit(f"Missing parsed file for {label}: {path}")

    durations, seen_count = load_durations(path)

    if not durations:
        raise SystemExit(f"No valid durations found for {label}: {path}")

    all_data[label] = durations

    summary_rows.append({
        "transport": label,
        "requested_prefixes": REQUESTED_COUNT,
        "observed_10x_prefixes": seen_count,
        "valid_prefixes_exactly_2_observations": len(durations),
        "average_ms": statistics.mean(durations),
        "median_ms": statistics.median(durations),
        "p95_ms": percentile(durations, 95),
        "p99_ms": percentile(durations, 99),
        "min_ms": min(durations),
        "max_ms": max(durations),
    })


observed_count = min(len(v) for v in all_data.values())

summary_path = OUT_DIR / "summary_5_modes_observed_13104.csv"

with open(summary_path, "w", newline="") as f:
    fieldnames = [
        "transport",
        "requested_prefixes",
        "observed_10x_prefixes",
        "valid_prefixes_exactly_2_observations",
        "average_ms",
        "median_ms",
        "p95_ms",
        "p99_ms",
        "min_ms",
        "max_ms",
    ]

    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()

    for row in summary_rows:
        formatted = row.copy()

        for key in ["average_ms", "median_ms", "p95_ms", "p99_ms", "min_ms", "max_ms"]:
            formatted[key] = f"{formatted[key]:.3f}"

        writer.writerow(formatted)


# CDF graph
plt.figure(figsize=(10, 6))

for label, durations in all_data.items():
    n = len(durations)
    y = [(i + 1) / n for i in range(n)]
    plt.plot(durations, y, label=label, linewidth=2)

plt.xlabel("Prefix propagation duration (ms)")
plt.ylabel("CDF")
plt.title(f"BGP Prefix Propagation Duration — {observed_count} Observed Prefixes, 50 ms Interval")
plt.grid(True, alpha=0.3)
plt.legend()
plt.tight_layout()

cdf_path = OUT_DIR / "cdf_5_modes_observed_13104_announce50.png"
plt.savefig(cdf_path, dpi=300)
plt.close()


labels = list(all_data.keys())
values = [all_data[label] for label in labels]


# Full boxplot with outliers
plt.figure(figsize=(11, 6))
plt.boxplot(values, labels=labels, showfliers=True)
plt.ylabel("Prefix propagation duration (ms)")
plt.title(f"BGP Prefix Propagation Distribution — {observed_count} Observed Prefixes, 50 ms Interval")
plt.grid(True, axis="y", alpha=0.3)
plt.xticks(rotation=15, ha="right")
plt.tight_layout()

boxplot_path = OUT_DIR / "boxplot_5_modes_observed_13104_announce50_full.png"
plt.savefig(boxplot_path, dpi=300)
plt.close()


# Zoomed boxplot without extreme outliers
all_values = []
for durations in all_data.values():
    all_values.extend(durations)

all_values = sorted(all_values)

y_low = percentile(all_values, 1)
y_high = percentile(all_values, 99)

margin = (y_high - y_low) * 0.15
y_low = y_low - margin
y_high = y_high + margin

plt.figure(figsize=(8, 5))
plt.boxplot(values, labels=labels, showfliers=False)
plt.ylabel("Prefix propagation duration (ms)")
plt.title(f"BGP Prefix Propagation Distribution — {observed_count} Observed Prefixes, 50 ms Interval")
plt.grid(True, axis="y", alpha=0.3)
plt.xticks(rotation=15, ha="right")
plt.ylim(y_low, y_high)
plt.tight_layout()

zoomed_boxplot_path = OUT_DIR / "boxplot_5_modes_observed_13104_announce50_zoomed.png"
plt.savefig(zoomed_boxplot_path, dpi=300)
plt.close()


print("\nGraph generation complete.")
print(f"CDF graph:          {cdf_path}")
print(f"Full boxplot:       {boxplot_path}")
print(f"Zoomed boxplot:     {zoomed_boxplot_path}")
print(f"Summary CSV:        {summary_path}")

print("\nSummary:")
for row in summary_rows:
    print(
        f"{row['transport']}: "
        f"requested={row['requested_prefixes']}, "
        f"observed={row['valid_prefixes_exactly_2_observations']}, "
        f"avg={row['average_ms']:.3f} ms, "
        f"median={row['median_ms']:.3f} ms, "
        f"p95={row['p95_ms']:.3f} ms, "
        f"max={row['max_ms']:.3f} ms"
    )
