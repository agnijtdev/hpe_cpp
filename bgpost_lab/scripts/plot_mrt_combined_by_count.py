import csv
import gzip
import statistics
import sys
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt


def read_durations(path):
    seen = defaultdict(list)

    with gzip.open(path, "rt") as f:
        reader = csv.DictReader(f)
        for row in reader:
            prefix = row["prefix"]
            timestamp_ms = float(row["time"])

            # Only our injected prefixes, not Docker link prefixes.
            if prefix.startswith("10.200."):
                seen[prefix].append(timestamp_ms)

    durations = []

    for prefix, times in seen.items():
        if len(times) == 2:
            durations.append(times[-1] - times[0])

    return sorted(durations)


def main():
    if len(sys.argv) != 3:
        print("Usage: python3 scripts/plot_mrt_combined_by_count.py <prefix_count> <delay_ms>")
        print("Example: python3 scripts/plot_mrt_combined_by_count.py 1000 15")
        sys.exit(1)

    count = sys.argv[1]
    delay = sys.argv[2]

    inputs = {
        "TCP": Path(f"results/mrt_parsed_tcp_{count}_delay{delay}/r1.csv.gz"),
        "TLS": Path(f"results/mrt_parsed_tls_{count}_delay{delay}/r1.csv.gz"),
        "QUIC": Path(f"results/mrt_parsed_quic_{count}_delay{delay}/r1.csv.gz"),
    }

    output_dir = Path(f"results/mrt_final_{count}_delay{delay}")
    output_dir.mkdir(parents=True, exist_ok=True)

    out_cdf = output_dir / "fig5_style_cdf.png"
    out_box = output_dir / "fig6_style_boxplot.png"
    out_summary = output_dir / "summary.csv"

    data = {}

    for label, path in inputs.items():
        if not path.exists():
            raise FileNotFoundError(f"Missing parsed file for {label}: {path}")

        durations = read_durations(path)

        if not durations:
            raise RuntimeError(f"No injected prefix durations found for {label}")

        data[label] = durations

    # CDF graph
    plt.figure(figsize=(6.5, 4))

    for label, values in data.items():
        xs = values
        ys = [(i + 1) / len(xs) for i in range(len(xs))]
        plt.plot(xs, ys, label=label)

    plt.xlabel("Prefix Propagation Duration (ms)")
    plt.ylabel("CDF")
    plt.grid(True, alpha=0.4)
    plt.legend()
    plt.tight_layout()
    plt.savefig(out_cdf, dpi=300)
    print(f"Saved: {out_cdf}")

    # Boxplot
    labels = list(data.keys())
    values = [data[label] for label in labels]

    plt.figure(figsize=(6.5, 4))
    plt.boxplot(values, labels=labels, showfliers=False)
    plt.ylabel("Prefix Propagation Duration (ms)")
    plt.grid(True, axis="y", alpha=0.4)
    plt.tight_layout()
    plt.savefig(out_box, dpi=300)
    print(f"Saved: {out_box}")

    # Summary CSV
    with out_summary.open("w", newline="") as f:
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

    print(f"Saved: {out_summary}")

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
