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


def wait_until_route_absent(router, timeout_seconds=10):
    start = time.monotonic()

    while time.monotonic() - start < timeout_seconds:
        if not route_present(router):
            return True
        time.sleep(0.01)

    return False


def wait_until_route_present(router, timeout_seconds=10):
    start_ns = time.monotonic_ns()

    while (time.monotonic_ns() - start_ns) < timeout_seconds * 1_000_000_000:
        if route_present(router):
            end_ns = time.monotonic_ns()
            return (end_ns - start_ns) / 1_000_000

        time.sleep(0.005)

    return None


def run_one_trial(trial_number, target_router):
    print(f"\n--- Trial {trial_number} ---")

    print("Disabling static route on r1...")
    run_cmd(["docker", "exec", "r1", "birdc", "disable", "static_routes"])

    print(f"Waiting until {target_router} withdraws the route...")
    if not wait_until_route_absent(target_router):
        print(f"ERROR: {target_router} still has the route after timeout.")
        return None

    time.sleep(0.2)

    print("Enabling static route on r1...")
    run_cmd(["docker", "exec", "r1", "birdc", "enable", "static_routes"])

    print(f"Measuring until {target_router} learns the route again...")
    convergence_ms = wait_until_route_present(target_router)

    if convergence_ms is None:
        print(f"ERROR: {target_router} did not learn the route within timeout.")
        return None

    print(f"Trial {trial_number} convergence time: {convergence_ms:.3f} ms")
    return convergence_ms


def main():
    if len(sys.argv) != 3:
        print("Usage: python3 scripts/measure_line_tcp.py <number_of_routers> <trials>")
        print("Example: python3 scripts/measure_line_tcp.py 10 10")
        sys.exit(1)

    router_count = int(sys.argv[1])
    trials = int(sys.argv[2])

    if router_count < 2:
        print("ERROR: number_of_routers must be at least 2")
        sys.exit(1)

    if trials < 1:
        print("ERROR: trials must be at least 1")
        sys.exit(1)

    target_router = f"r{router_count}"
    result_file = Path(f"results/line_tcp_{router_count}_routers.csv")

    print(f"Measuring TCP convergence from r1 to {target_router}")
    print(f"Prefix: {PREFIX}")
    print(f"Trials: {trials}")

    results = []

    for trial in range(1, trials + 1):
        value = run_one_trial(trial, target_router)

        if value is not None:
            results.append(value)

        time.sleep(0.5)

    if not results:
        print("No successful trials.")
        sys.exit(1)

    result_file.parent.mkdir(parents=True, exist_ok=True)

    with result_file.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["transport", "router_count", "target_router", "trial", "prefix", "convergence_ms"])

        for index, value in enumerate(results, start=1):
            writer.writerow(["tcp", router_count, target_router, index, PREFIX, f"{value:.3f}"])

    print("\n========== Summary ==========")
    print(f"Successful trials: {len(results)}/{trials}")
    print(f"Minimum: {min(results):.3f} ms")
    print(f"Maximum: {max(results):.3f} ms")
    print(f"Average: {statistics.mean(results):.3f} ms")
    print(f"Median: {statistics.median(results):.3f} ms")
    print(f"Saved results to {result_file}")


if __name__ == "__main__":
    main()
