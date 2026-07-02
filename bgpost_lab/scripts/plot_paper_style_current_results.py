import csv
from pathlib import Path

import matplotlib.pyplot as plt


FILES = {
    "TCP": Path("results/line_tcp_10_routers.csv"),
    "TLS": Path("results/line_tls_10_routers.csv"),
    "QUIC": Path("results/line_quic_10_routers.csv"),
}

OUT_CDF = Path("results/fig5_style_cdf_current_method.png")
OUT_BOX = Path("results/fig6_style_boxplot_current_method.png")


def read_values(path):
    values = []
    with path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            values.append(float(row["convergence_ms"]))
    return values


def plot_cdf(data):
    plt.figure(figsize=(6.5, 4))

    for label, values in data.items():
        xs = sorted(values)
        ys = [(i + 1) / len(xs) for i in range(len(xs))]
        plt.plot(xs, ys, label=label)

    plt.xlabel("Prefix propagation duration (ms)")
    plt.ylabel("CDF")
    plt.title("CDF of BGP update propagation duration")
    plt.grid(True, alpha=0.4)
    plt.legend()
    plt.tight_layout()
    plt.savefig(OUT_CDF, dpi=250)
    print(f"Saved {OUT_CDF}")


def plot_boxplot(data):
    labels = list(data.keys())
    values = [data[label] for label in labels]

    plt.figure(figsize=(6.5, 4))
    plt.boxplot(values, labels=labels, showfliers=True)

    plt.ylabel("Convergence duration (ms)")
    plt.title("BGP convergence duration using different transports")
    plt.grid(True, axis="y", alpha=0.4)
    plt.tight_layout()
    plt.savefig(OUT_BOX, dpi=250)
    print(f"Saved {OUT_BOX}")


def main():
    data = {}

    for label, path in FILES.items():
        if not path.exists():
            raise FileNotFoundError(f"Missing file: {path}")
        data[label] = read_values(path)

    plot_cdf(data)
    plot_boxplot(data)


if __name__ == "__main__":
    main()
