import csv
import statistics
from pathlib import Path

import matplotlib.pyplot as plt


TCP_FILE = Path("results/line_tcp_10_routers.csv")
TLS_FILE = Path("results/line_tls_10_routers.csv")
OUT_FILE = Path("results/tcp_vs_tls_10_router_convergence.png")


def read_values(path):
    values = []

    with path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            values.append(float(row["convergence_ms"]))

    return values


def main():
    if not TCP_FILE.exists():
        print(f"Missing TCP file: {TCP_FILE}")
        print("Run the TCP 10-router experiment first.")
        return

    if not TLS_FILE.exists():
        print(f"Missing TLS file: {TLS_FILE}")
        print("Run: python3 scripts/measure_line_tls.py 10 10")
        return

    tcp = read_values(TCP_FILE)
    tls = read_values(TLS_FILE)

    labels = ["TCP", "TLS/TCP"]
    averages = [statistics.mean(tcp), statistics.mean(tls)]
    medians = [statistics.median(tcp), statistics.median(tls)]

    plt.figure(figsize=(8, 5))
    x = range(len(labels))

    plt.bar(x, averages, label="Average")
    plt.plot(x, medians, marker="o", label="Median")

    plt.xticks(x, labels)
    plt.ylabel("Convergence time (ms)")
    plt.title("10-router BGP convergence: TCP vs TLS/TCP")
    plt.legend()
    plt.grid(axis="y", linestyle="--", alpha=0.5)

    for i, avg in enumerate(averages):
        plt.text(i, avg, f"{avg:.1f} ms", ha="center", va="bottom")

    plt.tight_layout()
    OUT_FILE.parent.mkdir(exist_ok=True)
    plt.savefig(OUT_FILE, dpi=200)

    print(f"Saved plot: {OUT_FILE}")
    print()
    print("Summary:")
    print(f"TCP average: {statistics.mean(tcp):.3f} ms")
    print(f"TCP median:  {statistics.median(tcp):.3f} ms")
    print(f"TLS average: {statistics.mean(tls):.3f} ms")
    print(f"TLS median:  {statistics.median(tls):.3f} ms")


if __name__ == "__main__":
    main()
