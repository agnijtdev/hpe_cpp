import csv
from pathlib import Path
import matplotlib.pyplot as plt

PROJECT = Path.home() / "Documents/bgpost-lab"
COUNT = 10000
DELAY = 1
RUN = 1

summary = PROJECT / f"results/generated_convergence_summary_{COUNT}_delay{DELAY}_run{RUN}.csv"
out_dir = PROJECT / f"results/generated_convergence_graphs_{COUNT}_delay{DELAY}_run{RUN}"
out_dir.mkdir(parents=True, exist_ok=True)

labels_map = {
    "tcp": "TCP",
    "tls": "TLS",
    "quic": "QUIC",
    "tls_ao_static": "TLS-TCP-AO\nStatic",
    "tls_ao_dynamic": "TLS-AO\nDynamic",
}

modes = []
durations = []
observed = []

with open(summary, newline="") as f:
    reader = csv.DictReader(f)
    for row in reader:
        modes.append(labels_map.get(row["mode"], row["mode"]))
        durations.append(float(row["duration_s"]))
        observed.append(int(row["observed"]))

plt.figure(figsize=(9, 5))
bars = plt.bar(modes, durations)

plt.ylabel("Convergence Duration (s)")
plt.xlabel("Transport Mode")
plt.title("Generated-prefix BGP Convergence — 10,000 Prefixes")
plt.grid(axis="y", linestyle="--", alpha=0.4)

for bar, value in zip(bars, durations):
    plt.text(
        bar.get_x() + bar.get_width() / 2,
        bar.get_height(),
        f"{value:.3f}s",
        ha="center",
        va="bottom",
        fontsize=9,
    )

plt.tight_layout()

png_path = out_dir / "generated_convergence_10000_bar.png"
pdf_path = out_dir / "generated_convergence_10000_bar.pdf"

plt.savefig(png_path, dpi=300)
plt.savefig(pdf_path)

print("Saved:")
print(png_path)
print(pdf_path)
