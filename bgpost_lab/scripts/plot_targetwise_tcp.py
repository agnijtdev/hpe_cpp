import csv
import sys
from pathlib import Path
import matplotlib.pyplot as plt


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 scripts/plot_targetwise_tcp.py <number_of_routers>")
        print("Example: python3 scripts/plot_targetwise_tcp.py 10")
        sys.exit(1)

    router_count = int(sys.argv[1])

    input_file = Path(f"results/targetwise_tcp_{router_count}_routers_summary.csv")
    output_file = Path(f"results/targetwise_tcp_{router_count}_routers_median.png")

    if not input_file.exists():
        print(f"ERROR: Input file not found: {input_file}")
        sys.exit(1)

    hops = []
    labels = []
    medians = []

    with input_file.open() as f:
        reader = csv.DictReader(f)

        for row in reader:
            hops.append(int(row["hop"]))
            labels.append(row["target_router"])
            medians.append(float(row["median_ms"]))

    plt.figure(figsize=(10, 5))

    plt.plot(hops, medians, marker="o", label="Median convergence time")

    plt.title(f"BGP over TCP: Target-wise median convergence in {router_count}-router line")
    plt.xlabel("Hop count from r1")
    plt.ylabel("Median convergence time (ms)")
    plt.xticks(hops, labels)
    plt.grid(True, alpha=0.3)
    plt.legend()
    plt.tight_layout()

    plt.savefig(output_file, dpi=200)

    print(f"Graph saved to {output_file}")


if __name__ == "__main__":
    main()
