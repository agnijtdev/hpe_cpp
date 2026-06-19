import csv
from pathlib import Path
import statistics
import matplotlib.pyplot as plt

INPUT_FILE = Path("results/multi_trial_tcp.csv")
OUTPUT_FILE = Path("results/tcp_convergence_trials.png")


def main():
    trials = []
    times = []

    with INPUT_FILE.open() as f:
        reader = csv.DictReader(f)

        for row in reader:
            trials.append(int(row["trial"]))
            times.append(float(row["convergence_ms"]))

    median_value = statistics.median(times)
    average_value = statistics.mean(times)

    plt.figure(figsize=(10, 5))

    plt.plot(trials, times, marker="o", label="TCP trial result")
    plt.axhline(median_value, linestyle="--", label=f"Median = {median_value:.3f} ms")
    plt.axhline(average_value, linestyle=":", label=f"Average = {average_value:.3f} ms")

    plt.title("BGP over TCP: Single-prefix convergence across trials")
    plt.xlabel("Trial number")
    plt.ylabel("Convergence time (ms)")
    plt.xticks(trials)
    plt.grid(True, alpha=0.3)
    plt.legend()
    plt.tight_layout()

    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(OUTPUT_FILE, dpi=200)

    print(f"Graph saved to {OUTPUT_FILE}")
    print(f"Median convergence time: {median_value:.3f} ms")
    print(f"Average convergence time: {average_value:.3f} ms")


if __name__ == "__main__":
    main()
