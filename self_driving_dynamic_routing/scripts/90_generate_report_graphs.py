import matplotlib.pyplot as plt
from pathlib import Path

OUT = Path("report_graphs")
OUT.mkdir(exist_ok=True)

def save_bar(title, labels, values, ylabel, filename):
    plt.figure(figsize=(10, 5))
    plt.bar(labels, values)
    plt.title(title)
    plt.ylabel(ylabel)
    plt.xticks(rotation=25, ha="right")
    plt.tight_layout()
    plt.savefig(OUT / filename, dpi=200)
    plt.close()

def save_grouped_bar(title, labels, before, after, ylabel, filename):
    x = range(len(labels))
    width = 0.35

    plt.figure(figsize=(10, 5))
    plt.bar([i - width/2 for i in x], before, width, label="Without BFD")
    plt.bar([i + width/2 for i in x], after, width, label="With BFD")
    plt.title(title)
    plt.ylabel(ylabel)
    plt.xticks(list(x), labels, rotation=20, ha="right")
    plt.legend()
    plt.tight_layout()
    plt.savefig(OUT / filename, dpi=200)
    plt.close()

# Graph 1: BFD detection times
save_bar(
    "BFD Detection Time Comparison",
    [
        "WAN edge",
        "Multihop r1",
        "Multihop r8",
        "BFD flap",
        "OSPF blackhole"
    ],
    [72.07, 511.27, 570.73, 656.60, 706.07],
    "Detection time (ms)",
    "01_bfd_detection_times.png"
)

# Graph 2: OSPF silent blackhole comparison
save_grouped_bar(
    "OSPF Silent Blackhole Recovery: Without BFD vs With BFD",
    ["Route switch", "Traffic outage"],
    [17989.40, 12369.80],
    [1264.60, 1126.00],
    "Time (ms)",
    "02_ospf_silent_blackhole_time_comparison.png"
)

save_grouped_bar(
    "OSPF Silent Blackhole Packet Loss: Without BFD vs With BFD",
    ["Packet loss"],
    [41.81],
    [3.48],
    "Packet loss (%)",
    "03_ospf_silent_blackhole_loss_comparison.png"
)

# Graph 3: OSPF area healing blackhole comparison
save_grouped_bar(
    "OSPF Area Healing Blackhole: Without BFD vs With BFD",
    ["Route-get", "Kernel update", "BIRD update"],
    [18761, 18762, 18835],
    [1313, 1315, 1250],
    "Time (ms)",
    "04_area_healing_blackhole_comparison.png"
)

# Graph 4: BGP timing summary
save_bar(
    "BGP GR, LLGR and Peer Flap Timing Summary",
    [
        "BIRD ready after GR",
        "BGP re-established",
        "LLGR stale marker",
        "LLGR route removed",
        "Peer flap alt path",
        "Peer flap re-est.",
        "Peer flap direct return"
    ],
    [166, 4001, 5183, 15239, 93, 1596, 1754],
    "Time (ms)",
    "05_bgp_gr_llgr_peer_flap_timing.png"
)

print("Graphs saved in:", OUT)
for f in sorted(OUT.glob("*.png")):
    print(f)
