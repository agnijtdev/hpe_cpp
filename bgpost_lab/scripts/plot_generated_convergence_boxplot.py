import csv
import gzip
from pathlib import Path
from collections import defaultdict

import matplotlib.pyplot as plt

PROJECT = Path.home() / "Documents/bgpost-lab"

COUNT = 10000
DELAY = 1
RUNS = [1, 2, 3, 4, 5]

modes = [
    ("tcp", "TCP"),
    ("tls", "TLS"),
    ("quic", "QUIC"),
    ("tls_ao_static", "TLS-AO\nStatic"),
    ("tls_ao_dynamic", "TLS-AO\nDynamic"),
]

out_dir = PROJECT / f"results/generated_convergence_boxplot_{COUNT}_delay{DELAY}"
out_dir.mkdir(parents=True, exist_ok=True)

summary_rows = []
box_data = []
labels = []

for mode, label in modes:
    durations = []

    for run in RUNS:
        csv_path = (
            PROJECT
            / f"results/convergence_{mode}_{COUNT}_delay{DELAY}_run{run}_parsed"
            / "monitor.csv.gz"
        )

        if not csv_path.exists():
            print(f"Missing: {csv_path}")
            continue

        seen = defaultdict(list)

        with gzip.open(csv_path, "rt") as f:
            reader = csv.DictReader(f)

            for row in reader:
                prefix = row.get("prefix", "")

                if prefix.startswith("10.220."):
                    seen[prefix].append(float(row["time"]))

        first_times_ms = []

        for prefix, times in seen.items():
            if times:
                first_times_ms.append(min(times))

        first_times_ms.sort()
        observed = len(first_times_ms)

        if observed == 0:
            print(f"{mode} run {run}: no prefixes observed")
            continue

        duration_ms = first_times_ms[-1] - first_times_ms[0]
        duration_s = duration_ms / 1000.0

        durations.append(duration_s)

        summary_rows.append({
            "mode": mode,
            "run": run,
            "requested": COUNT,
            "observed": observed,
            "duration_s": duration_s,
            "duration_ms": duration_ms,
            "first_ms": first_times_ms[0],
            "last_ms": first_times_ms[-1],
        })

    box_data.append(durations)
    labels.append(label)

summary_csv = out_dir / "generated_convergence_boxplot_summary.csv"

with open(summary_csv, "w", newline="") as f:
    writer = csv.DictWriter(
        f,
        fieldnames=[
            "mode",
            "run",
            "requested",
            "observed",
            "duration_s",
            "duration_ms",
            "first_ms",
            "last_ms",
        ],
    )
    writer.writeheader()
    writer.writerows(summary_rows)

plt.figure(figsize=(7, 4.5))

plt.boxplot(
    box_data,
    labels=labels,
    showmeans=False,
    showfliers=True,
)

plt.ylabel("Convergence Duration (s)")
plt.xlabel("Transport Mode")
plt.title("Generated-prefix BGP Convergence — 10,000 Prefixes")
plt.grid(axis="y", alpha=0.45)

plt.tight_layout()

png_path = out_dir / "generated_convergence_10000_boxplot.png"
pdf_path = out_dir / "generated_convergence_10000_boxplot.pdf"

plt.savefig(png_path, dpi=300)
plt.savefig(pdf_path)

print()
print("Saved:")
print(png_path)
print(pdf_path)
print(summary_csv)

print()
print("Durations:")
for (mode, label), durations in zip(modes, box_data):
    values = ", ".join(f"{x:.6f}" for x in durations)
    print(f"{label.replace(chr(10), ' '):16s}: {values}")
