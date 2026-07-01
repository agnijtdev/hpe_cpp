import csv
import gzip
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt


INPUTS = {
    "TCP": Path("results/mrt_parsed_tcp_delay15/r1.csv.gz"),
    "TLS": Path("results/mrt_parsed_tls_delay15/r1.csv.gz"),
    "QUIC": Path("results/mrt_parsed_quic_delay15/r1.csv.gz"),
}

OUT_CDF = Path("results/mrt_final_fig5_cdf.png")
OUT_BOX = Path("results/mrt_final_fig6_boxplot.png")
OUT_SUMMARY = Path("results/mrt_final_summary.csv")


def read_mrt_csv(path):
    seen = defaultdict(list)

    with gzip.open(path, "rt") as f:
        reader = csv.DictReader(f)
        for row in reader:
            prefix = row["prefix"]
            timestamp_ms = float(row["time"])

            # Only count our injected test prefixes.
            # This removes Docker/BIRD connected link prefixes like 172.36.x.0/24.
            if prefix.startswith("10.200."):
                seen[prefix].append(timestamp_ms)

    durations = []

    for prefix, times in seen.items():
        if len(times) == 2:
            durations.append(times[-1] - times[0])

    return sorted(durations)


def plot_cdf(data):
    plt.figure(figsize=(6.5, 4))

    for label, values in data.items():
        xs = sorted(values)
        ys = [(i + 1) / len(xs) for i in range(len(xs))]
        plt.plot(xs, ys, label=label)

    plt.xlabel("Prefix Propagation Duration (ms)")
    plt.ylabel("CDF")
    plt.grid(True, alpha=0.4)
    plt.legend()
    plt.tight_layout()
    plt.savefig(OUT_CDF, dpi=300)
    print(f"Saved: {OUT_CDF}")


def plot_boxplot(data):
    labels = list(data.keys())
    values = [data[label] for label in labels]

    plt.figure(figsize=(6.5, 4))
    plt.boxplot(values, labels=labels, showfliers=False)

    plt.ylabel("Prefix Propagation Duration (ms)")
    plt.grid(True, axis="y", alpha=0.4)
    plt.tight_layout()
    plt.savefig(OUT_BOX, dpi=300)
    print(f"Saved: {OUT_BOX}")


def write_summary(data):
    with OUT_SUMMARY.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([
            "transport",
            "prefix_count",
            "average_ms",
            "median_ms",
            "min_ms",
            "max_ms",
        ])

        for label, values in data.items():
            writer.writerow([
                label,
                len(values),
                f"{statistics.mean(values):.3f}",
                f"{statistics.median(values):.3f}",
                f"{min(values):.3f}",
                f"{max(values):.3f}",
            ])

    print(f"Saved: {OUT_SUMMARY}")


def main():
    data = {}

    for label, path in INPUTS.items():
        if not path.exists():
            raise FileNotFoundError(f"Missing file for {label}: {path}")

        values = read_mrt_csv(path)

        if not values:
            raise RuntimeError(f"No injected prefix durations found for {label}")

        data[label] = values

    plot_cdf(data)
    plot_boxplot(data)
    write_summary(data)

    print()
    print("Summary:")
    for label, values in data.items():
        print(f"{label}:")
        print(f"  prefixes: {len(values)}")
        print(f"  average:  {statistics.mean(values):.3f} ms")
        print(f"  median:   {statistics.median(values):.3f} ms")
        print(f"  min:      {min(values):.3f} ms")
        print(f"  max:      {max(values):.3f} ms")
        print()


if __name__ == "__main__":
    main()
