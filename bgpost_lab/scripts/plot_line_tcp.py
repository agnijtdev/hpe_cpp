import csv
import sys
import statistics
from pathlib import Path
import matplotlib.pyplot as plt


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 scripts/plot_line_tcp.py <number_of_routers>")
        print("Example: python3 scripts/plot_line_tcp.py 10")
        sys.exit(1)

    router_count = int(sys.argv[1])

    input_file = Path(f"results/line_tcp_{router_count}_routers.csv")
    output_file = Path(f"results/line_tcp_{router_count}_routers.png")

    if not input_file.exists():
        print(f"ERROR: Input file not found: {input_file}")
        sys.exit(1)

    trials = []
    times = []

    with input_file.open() as f:
        reader = csv.DictReader(f)

        for row in reader:
            trials.append(int(row["trial"]))
            times.append(float(row["convergence_ms"]))

    median_value = statistics.median(times)
    average_value = statistics.mean(times)

    plt.figure(figsize=(10, 5))

    plt.plot(trials, times, marker="o", label=f"TCP {router_count}-router trial result")
    plt.axhline(median_value, linestyle="--", label=f"Median = {median_value:.3f} ms")
    plt.axhline(average_value, linestyle=":", label=f"Average = {average_value:.3f} ms")

    plt.title(f"BGP over TCP: r1 to r{router_count} convergence across trials")
    plt.xlabel("Trial number")
    plt.ylabel("Convergence time (ms)")
    plt.xticks(trials)
    plt.grid(True, alpha=0.3)
    plt.legend()
    plt.tight_layout()

    plt.savefig(output_file, dpi=200)

    print(f"Graph saved to {output_file}")
    print(f"Median convergence time: {median_value:.3f} ms")
    print(f"Average convergence time: {average_value:.3f} ms")


if __name__ == "__main__":
    main()
