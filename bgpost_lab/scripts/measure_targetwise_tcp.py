import subprocess
import time
import csv
import statistics
import sys
from pathlib import Path

PREFIX = "100.100.1.0/24"


def run_cmd(cmd):
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True
    )
    return result.stdout


def route_present(router):
    output = run_cmd([
        "docker", "exec", router,
        "birdc", "show", "route", PREFIX, "all"
    ])

    return (PREFIX in output) and ("Type: BGP" in output)


def wait_until_all_absent(routers, timeout_seconds=20):
    start = time.monotonic()

    while time.monotonic() - start < timeout_seconds:
        all_absent = True

        for router in routers:
            if route_present(router):
                all_absent = False
                break

        if all_absent:
            return True

        time.sleep(0.05)

    return False


def wait_until_present(router, start_ns, timeout_seconds=20):
    deadline = time.monotonic() + timeout_seconds

    while time.monotonic() < deadline:
        if route_present(router):
            end_ns = time.monotonic_ns()
            return (end_ns - start_ns) / 1_000_000

        time.sleep(0.005)

    return None


def measure_one_trial(target_router, all_observed_routers):
    run_cmd(["docker", "exec", "r1", "birdc", "disable", "static_routes"])

    if not wait_until_all_absent(all_observed_routers):
        return None

    time.sleep(0.2)

    start_ns = time.monotonic_ns()
    run_cmd(["docker", "exec", "r1", "birdc", "enable", "static_routes"])

    return wait_until_present(target_router, start_ns)


def main():
    if len(sys.argv) != 3:
        print("Usage: python3 scripts/measure_targetwise_tcp.py <number_of_routers> <trials_per_target>")
        print("Example: python3 scripts/measure_targetwise_tcp.py 10 5")
        sys.exit(1)

    router_count = int(sys.argv[1])
    trials = int(sys.argv[2])

    if router_count < 2:
        print("ERROR: number_of_routers must be at least 2")
        sys.exit(1)

    if trials < 1:
        print("ERROR: trials_per_target must be at least 1")
        sys.exit(1)

    observed_routers = [f"r{i}" for i in range(2, router_count + 1)]

    raw_file = Path(f"results/targetwise_tcp_{router_count}_routers_raw.csv")
    summary_file = Path(f"results/targetwise_tcp_{router_count}_routers_summary.csv")

    raw_rows = []
    summary_rows = []

    print(f"Target-wise TCP convergence measurement")
    print(f"Topology: r1 to r{router_count}")
    print(f"Trials per target: {trials}")
    print(f"Prefix: {PREFIX}")

    for target_num in range(2, router_count + 1):
        target_router = f"r{target_num}"
        hop = target_num - 1
        values = []

        print(f"\n========== Target {target_router}, hop {hop} ==========")

        for trial in range(1, trials + 1):
            print(f"Trial {trial}: measuring r1 → {target_router}")

            value = measure_one_trial(target_router, observed_routers)

            if value is None:
                print("  ERROR: timeout")
                raw_rows.append(["tcp", router_count, target_router, hop, trial, PREFIX, "timeout"])
            else:
                print(f"  {value:.3f} ms")
                values.append(value)
                raw_rows.append(["tcp", router_count, target_router, hop, trial, PREFIX, f"{value:.3f}"])

            time.sleep(0.3)

        if values:
            summary_rows.append([
                "tcp",
                router_count,
                target_router,
                hop,
                len(values),
                PREFIX,
                f"{min(values):.3f}",
                f"{max(values):.3f}",
                f"{statistics.mean(values):.3f}",
                f"{statistics.median(values):.3f}"
            ])

    raw_file.parent.mkdir(parents=True, exist_ok=True)

    with raw_file.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["transport", "router_count", "target_router", "hop", "trial", "prefix", "convergence_ms"])
        writer.writerows(raw_rows)

    with summary_file.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([
            "transport",
            "router_count",
            "target_router",
            "hop",
            "successful_trials",
            "prefix",
            "min_ms",
            "max_ms",
            "avg_ms",
            "median_ms"
        ])
        writer.writerows(summary_rows)

    print("\n========== Summary ==========")
    print("Target   Hop   Median")
    print("----------------------")

    for row in summary_rows:
        target_router = row[2]
        hop = row[3]
        median = row[9]
        print(f"{target_router:<8} {hop:<5} {median} ms")

    print(f"\nSaved raw results to {raw_file}")
    print(f"Saved summary results to {summary_file}")


if __name__ == "__main__":
    main()
