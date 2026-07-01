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

OUT_DIR = PROJECT / "results/paper_style_observed_13104_announce50_delay15"
OUT_DIR.mkdir(parents=True, exist_ok=True)

INPUTS = {
    "TCP": PROJECT / f"results/mrt_parsed_tcp_{REQUESTED_COUNT}_announce{ANNOUNCE}_delay{LINK_DELAY}/r1.csv.gz",
    "TLS": PROJECT / f"results/mrt_parsed_tls_{REQUESTED_COUNT}_announce{ANNOUNCE}_delay{LINK_DELAY}/r1.csv.gz",
    "TLS-TCP-AO Static": PROJECT / f"results/mrt_parsed_tls_ao_static_{REQUESTED_COUNT}_announce{ANNOUNCE}_delay{LINK_DELAY}/r1.csv.gz",
    "TLS-AO Dynamic": PROJECT / f"results/mrt_parsed_tls_ao_dynamic_{REQUESTED_COUNT}_announce{ANNOUNCE}_delay{LINK_DELAY}/r1.csv.gz",
    "QUIC": PROJECT / f"results/mrt_parsed_quic_{REQUESTED_COUNT}_announce{ANNOUNCE}_delay{LINK_DELAY}/r1.csv.gz",
}

DISPLAY_LABELS = {
    "TCP": "TCP",
    "TLS": "TLS",
    "TLS-TCP-AO Static": "TLS-TCP-AO\nStatic",
    "TLS-AO Dynamic": "TLS-AO\nDynamic",
    "QUIC": "QUIC",
}


def load_durations_ms(path):
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
    values = sorted(values)
    k = (len(values) - 1) * pct / 100
    low = int(k)
    high = min(low + 1, len(values) - 1)

    if low == high:
        return values[low]

    weight = k - low
    return values[low] * (1 - weight) + values[high] * weight


all_data_ms = {}
summary_rows = []

for label, path in INPUTS.items():
    durations_ms, seen_count = load_durations_ms(path)

    if not durations_ms:
        raise SystemExit(f"No valid durations found for {label}")

    all_data_ms[label] = durations_ms

    summary_rows.append({
        "transport": label,
        "requested_prefixes": REQUESTED_COUNT,
        "observed_prefixes": len(durations_ms),
        "average_ms": statistics.mean(durations_ms),
        "median_ms": statistics.median(durations_ms),
        "p95_ms": percentile(durations_ms, 95),
        "p99_ms": percentile(durations_ms, 99),
        "min_ms": min(durations_ms),
        "max_ms": max(durations_ms),
    })


observed_count = min(len(v) for v in all_data_ms.values())


# -------------------------------
# Paper-style CDF: x-axis in ms
# -------------------------------
plt.figure(figsize=(7, 4.5))

for label, durations_ms in all_data_ms.items():
    n = len(durations_ms)
    y = [(i + 1) / n for i in range(n)]
    plt.plot(durations_ms, y, linewidth=2, label=label)

all_ms = []
for durations_ms in all_data_ms.values():
    all_ms.extend(durations_ms)

x_low = percentile(all_ms, 0.5)
x_high = percentile(all_ms, 99.5)
x_margin = (x_high - x_low) * 0.10

plt.xlim(x_low - x_margin, x_high + x_margin)
plt.ylim(0, 1.0)

plt.xlabel("Prefix Propagation Duration (ms)")
plt.ylabel("CDF")
plt.grid(True, alpha=0.4)
plt.legend()
plt.tight_layout()

cdf_path = OUT_DIR / "cdf_paper_style_observed_13104_announce50.png"
plt.savefig(cdf_path, dpi=300)
plt.close()


# ------------------------------------------
# Paper-style boxplot: y-axis in seconds
# ------------------------------------------
labels = list(all_data_ms.keys())
values_s = [[x / 1000.0 for x in all_data_ms[label]] for label in labels]

all_s = []
for values in values_s:
    all_s.extend(values)

y_low = percentile(all_s, 1)
y_high = percentile(all_s, 99)
y_margin = (y_high - y_low) * 0.20

plt.figure(figsize=(7, 4.5))
plt.boxplot(
    values_s,
    labels=[DISPLAY_LABELS[label] for label in labels],
    showfliers=False
)

plt.ylabel("Prefix Propagation Duration (s)")
plt.grid(True, alpha=0.4)
plt.ylim(y_low - y_margin, y_high + y_margin)
plt.tight_layout()

boxplot_path = OUT_DIR / "boxplot_paper_style_observed_13104_announce50_seconds.png"
plt.savefig(boxplot_path, dpi=300)
plt.close()


# Summary CSV
summary_path = OUT_DIR / "summary_paper_style_observed_13104.csv"

with open(summary_path, "w", newline="") as f:
    fieldnames = [
        "transport",
        "requested_prefixes",
        "observed_prefixes",
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


print("\nPaper-style graph generation complete.")
print(f"CDF graph:       {cdf_path}")
print(f"Boxplot graph:   {boxplot_path}")
print(f"Summary CSV:     {summary_path}")

print("\nSummary:")
for row in summary_rows:
    print(
        f"{row['transport']}: "
        f"requested={row['requested_prefixes']}, "
        f"observed={row['observed_prefixes']}, "
        f"avg={row['average_ms']:.3f} ms, "
        f"median={row['median_ms']:.3f} ms, "
        f"p95={row['p95_ms']:.3f} ms, "
        f"max={row['max_ms']:.3f} ms"
    )
