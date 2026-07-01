import subprocess
import time
import csv
import statistics
from pathlib import Path

PREFIX = "100.100.1.0/24"
TRIALS = 10
RESULT_FILE = Path("results/multi_trial_tcp.csv")


def run_cmd(cmd):
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True
    )
    return result.stdout


def route_present_on_r2():
    output = run_cmd([
        "docker", "exec", "r2",
        "birdc", "show", "route", PREFIX, "all"
    ])

    return (PREFIX in output) and ("Type: BGP" in output)


def wait_until_route_absent(timeout_seconds=5):
    start = time.monotonic()

    while time.monotonic() - start < timeout_seconds:
        if not route_present_on_r2():
            return True
        time.sleep(0.01)

    return False


def wait_until_route_present(timeout_seconds=5):
    start_ns = time.monotonic_ns()

    while (time.monotonic_ns() - start_ns) < timeout_seconds * 1_000_000_000:
        if route_present_on_r2():
            end_ns = time.monotonic_ns()
            return (end_ns - start_ns) / 1_000_000

        time.sleep(0.005)

    return None


def run_one_trial(trial_number):
    print(f"\n--- Trial {trial_number} ---")

    print("Disabling static route on r1...")
    run_cmd(["docker", "exec", "r1", "birdc", "disable", "static_routes"])

    print("Waiting until r2 withdraws the route...")
    if not wait_until_route_absent():
        print("ERROR: r2 still has the route after timeout.")
        return None

    # Small pause so the system reaches a clean no-route state.
    time.sleep(0.2)

    print("Enabling static route on r1...")
    run_cmd(["docker", "exec", "r1", "birdc", "enable", "static_routes"])

    print("Measuring until r2 learns the route...")
    convergence_ms = wait_until_route_present()

    if convergence_ms is None:
        print("ERROR: r2 did not learn the route within timeout.")
        return None

    print(f"Trial {trial_number} convergence time: {convergence_ms:.3f} ms")
    return convergence_ms


def main():
    RESULT_FILE.parent.mkdir(parents=True, exist_ok=True)

    results = []

    for trial in range(1, TRIALS + 1):
        convergence_ms = run_one_trial(trial)

        if convergence_ms is not None:
            results.append(convergence_ms)

        time.sleep(0.5)

    if not results:
        print("No successful trials.")
        return

    with RESULT_FILE.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["transport", "trial", "prefix", "convergence_ms"])

        for index, value in enumerate(results, start=1):
            writer.writerow(["tcp", index, PREFIX, f"{value:.3f}"])

    print("\n========== Summary ==========")
    print(f"Successful trials: {len(results)}/{TRIALS}")
    print(f"Minimum: {min(results):.3f} ms")
    print(f"Maximum: {max(results):.3f} ms")
    print(f"Average: {statistics.mean(results):.3f} ms")
    print(f"Median: {statistics.median(results):.3f} ms")
    print(f"Saved results to {RESULT_FILE}")


if __name__ == "__main__":
    main()
