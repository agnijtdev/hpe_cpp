import csv
import gzip
import statistics
from pathlib import Path
from collections import defaultdict

import matplotlib.pyplot as plt


PROJECT = Path.home() / "Documents/bgpost-lab"

OUT_DIR = PROJECT / "results/final_5_mode_graphs_5000_announce50_delay15"
OUT_DIR.mkdir(parents=True, exist_ok=True)

# Transport label -> possible parsed CSV paths.
# The script will use the first path that exists.
INPUTS = {
    "TCP": [
        PROJECT / "results/mrt_parsed_tcp_5000_delay15/r1.csv.gz",
        PROJECT / "results/mrt_parsed_tcp_5000_announce50_delay15/r1.csv.gz",
    ],
    "TLS": [
        PROJECT / "results/mrt_parsed_tls_5000_delay15/r1.csv.gz",
        PROJECT / "results/mrt_parsed_tls_5000_announce50_delay15/r1.csv.gz",
    ],
    "QUIC": [
        PROJECT / "results/mrt_parsed_quic_5000_delay15/r1.csv.gz",
        PROJECT / "results/mrt_parsed_quic_5000_announce50_delay15/r1.csv.gz",
    ],
    "TLS-TCP-AO Static": [
        PROJECT / "results/mrt_parsed_tls_ao_static_5000_announce50_delay15/r1.csv.gz",
        PROJECT / "results/mrt_parsed_tls_ao_5000_announce50_delay15/r1.csv.gz",
    ],
    "TLS-AO Dynamic": [
        PROJECT / "results/mrt_parsed_tls_ao_dynamic_5000_announce50_delay15/r1.csv.gz",
    ],
}


def pick_existing_path(paths):
    for p in paths:
        if p.exists():
            return p
    return None


def load_durations_ms(path):
    seen = defaultdict(list)

    with gzip.open(path, "rt") as f:
        reader = csv.DictReader(f)

        for row in reader:
            prefix = row.get("prefix", "")
            if prefix.startswith("10.200."):
                seen[prefix].append(float(row["time"]))

    durations = []
    for prefix, times in seen.items():
        if len(times) == 2:
            durations.append(times[-1] - times[0])

    return durations, len(seen)


def percentile(sorted_values, pct):
    if not sorted_values:
        return None

    k = (len(sorted_values) - 1) * (pct / 100)
    low = int(k)
    high = min(low + 1, len(sorted_values) - 1)

    if low == high:
        return sorted_values[low]

    weight = k - low
    return sorted_values[low] * (1 - weight) + sorted_values[high] * weight


all_data = {}
summary_rows = []
missing = []

for label, paths in INPUTS.items():
    path = pick_existing_path(paths)

    if path is None:
        missing.append((label, paths))
        continue

    durations, total_seen = load_durations_ms(path)

    if not durations:
        print(f"WARNING: {label} has no valid duration samples in {path}")
        continue

    durations_sorted = sorted(durations)
    all_data[label] = durations_sorted

    summary_rows.append({
        "transport": label,
        "file": str(path),
        "injected_prefixes_seen": total_seen,
        "valid_prefixes_exactly_2_observations": len(durations),
        "average_ms": statistics.mean(durations),
        "median_ms": statistics.median(durations),
        "p95_ms": percentile(durations_sorted, 95),
        "p99_ms": percentile(durations_sorted, 99),
        "min_ms": min(durations),
        "max_ms": max(durations),
    })


if missing:
    print("\nMissing required parsed CSV files:")
    for label, paths in missing:
        print(f"\n{label}:")
        for p in paths:
            print(f"  tried: {p}")

    raise SystemExit(
        "\nSome modes are missing. Parse/run those modes first, then rerun this script."
    )


# Write summary CSV.
summary_path = OUT_DIR / "summary_5_modes.csv"
with open(summary_path, "w", newline="") as f:
    fieldnames = [
        "transport",
        "file",
        "injected_prefixes_seen",
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


# CDF plot.
plt.figure(figsize=(10, 6))

for label, durations in all_data.items():
    n = len(durations)
    y = [(i + 1) / n for i in range(n)]
    plt.plot(durations, y, label=label, linewidth=2)

plt.xlabel("Prefix propagation duration (ms)")
plt.ylabel("CDF")
plt.title("BGP Prefix Propagation Duration — 5 Transport Modes")
plt.grid(True, alpha=0.3)
plt.legend()
plt.tight_layout()

cdf_path = OUT_DIR / "fig5_style_cdf_5_modes.png"
plt.savefig(cdf_path, dpi=300)
plt.close()


# Boxplot.
labels = list(all_data.keys())
values = [all_data[label] for label in labels]

plt.figure(figsize=(11, 6))
plt.boxplot(values, labels=labels, showfliers=True)
plt.ylabel("Prefix propagation duration (ms)")
plt.title("BGP Prefix Propagation Duration Distribution — 5 Transport Modes")
plt.grid(True, axis="y", alpha=0.3)
plt.xticks(rotation=15, ha="right")
plt.tight_layout()

boxplot_path = OUT_DIR / "fig6_style_boxplot_5_modes.png"
plt.savefig(boxplot_path, dpi=300)
plt.close()


print("\nFinal 5-mode graph generation complete.")
print(f"CDF graph:     {cdf_path}")
print(f"Boxplot graph: {boxplot_path}")
print(f"Summary CSV:   {summary_path}")

print("\nSummary:")
for row in summary_rows:
    print(
        f"{row['transport']}: "
        f"count={row['valid_prefixes_exactly_2_observations']}, "
        f"avg={row['average_ms']:.3f} ms, "
        f"median={row['median_ms']:.3f} ms, "
        f"p95={row['p95_ms']:.3f} ms, "
        f"max={row['max_ms']:.3f} ms"
    )
