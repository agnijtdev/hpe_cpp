import csv
import statistics
from pathlib import Path

import matplotlib.pyplot as plt


FILES = {
    "TCP": Path("results/line_tcp_10_routers.csv"),
    "TLS/TCP": Path("results/line_tls_10_routers.csv"),
    "QUIC/UDP": Path("results/line_quic_10_routers.csv"),
}

OUT_FILE = Path("results/tcp_tls_quic_10_router_convergence.png")


def read_values(path):
    values = []
    with path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            values.append(float(row["convergence_ms"]))
    return values


def main():
    data = {}

    for name, path in FILES.items():
        if not path.exists():
            print(f"Missing file for {name}: {path}")
            return
        data[name] = read_values(path)

    labels = list(data.keys())
    averages = [statistics.mean(data[name]) for name in labels]
    medians = [statistics.median(data[name]) for name in labels]

    plt.figure(figsize=(9, 5))

    x = range(len(labels))
    plt.bar(x, averages, label="Average")
    plt.plot(x, medians, marker="o", label="Median")

    plt.xticks(x, labels)
    plt.ylabel("Convergence time (ms)")
    plt.title("10-router BGP convergence: TCP vs TLS/TCP vs QUIC/UDP")
    plt.grid(axis="y", linestyle="--", alpha=0.5)
    plt.legend()

    for i, avg in enumerate(averages):
        plt.text(i, avg, f"{avg:.1f} ms", ha="center", va="bottom")

    plt.tight_layout()
    OUT_FILE.parent.mkdir(exist_ok=True)
    plt.savefig(OUT_FILE, dpi=200)

    print(f"Saved plot: {OUT_FILE}")
    print()
    print("Summary:")
    for name in labels:
        values = data[name]
        print(f"{name} average: {statistics.mean(values):.3f} ms")
        print(f"{name} median:  {statistics.median(values):.3f} ms")
        print(f"{name} min:     {min(values):.3f} ms")
        print(f"{name} max:     {max(values):.3f} ms")
        print()


if __name__ == "__main__":
    main()
