from pathlib import Path
import matplotlib.pyplot as plt

OUT = Path("report/figures")
OUT.mkdir(parents=True, exist_ok=True)

def save_bar_chart(title, labels, values, ylabel, output, rotation=25):
    plt.figure(figsize=(12, 6))
    plt.bar(labels, values)
    plt.title(title)
    plt.ylabel(ylabel)
    plt.xticks(rotation=rotation, ha="right")
    plt.tight_layout()
    plt.savefig(output, dpi=220)
    plt.close()
    print("Created:", output)

# ------------------------------------------------------------
# Graph 1: Main convergence / reaction time comparison
# ------------------------------------------------------------

labels = [
    "BFD WAN edge",
    "OSPF core link",
    "ECMP + BFD stress",
    "ECMP + BFD normal",
    "Area healing",
    "BGP peer flap alt",
    "LLGR route removal"
]

values = [
    61,
    628,
    292,
    517,
    931,
    93,
    15350
]

save_bar_chart(
    "Routing Reaction / Convergence Time Comparison",
    labels,
    values,
    "Time in milliseconds",
    OUT / "01_convergence_time_comparison.png"
)

# ------------------------------------------------------------
# Graph 2: Packet loss comparison
# ------------------------------------------------------------

labels = [
    "BFD WAN edge",
    "OSPF core link",
    "ECMP no BFD stress",
    "ECMP + BFD stress",
    "ECMP + BFD normal",
    "Area healing",
    "BGP GR protocol restart",
    "BGP daemon restart",
    "BGP peer flap"
]

values = [
    0.00,
    3.43,
    16.00,
    7.40,
    5.00,
    9.33,
    0.00,
    42.94,
    0.00
]

save_bar_chart(
    "Packet Loss Comparison Across Experiments",
    labels,
    values,
    "Packet loss percentage",
    OUT / "02_packet_loss_comparison.png"
)

# ------------------------------------------------------------
# Graph 3: Additional deliverable evidence summary
# ------------------------------------------------------------

labels = [
    "Multi-hop BFD packets",
    "BGP flap packets",
    "LLGR stale window",
    "BGP peer flap recovery"
]

values = [
    347,
    36,
    15.35,
    1.596
]

save_bar_chart(
    "Additional Deliverable Evidence Summary",
    labels,
    values,
    "Measured value",
    OUT / "03_additional_deliverables_summary.png"
)

print()
print("All graphs generated inside report/figures/")
