import subprocess
import time
import csv
from pathlib import Path

PREFIX = "100.100.1.0/24"
RESULT_FILE = Path("results/single_prefix_tcp.csv")


def run_cmd(cmd):
    """
    Runs a shell command and returns its output as text.
    We use this to call docker exec and birdc from Python.
    """
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True
    )
    return result.stdout


def route_present_on_r2():
    """
    Checks whether r2 currently has the test prefix learned through BGP.
    """
    output = run_cmd([
        "docker", "exec", "r2",
        "birdc", "show", "route", PREFIX, "all"
    ])

    return (PREFIX in output) and ("Type: BGP" in output)


def wait_until_route_absent(timeout_seconds=5):
    """
    Waits until r2 no longer has the test route.
    """
    start = time.monotonic()

    while time.monotonic() - start < timeout_seconds:
        if not route_present_on_r2():
            return True
        time.sleep(0.01)

    return False


def wait_until_route_present(timeout_seconds=5):
    """
    Waits until r2 learns the test route again.
    Returns the time taken in milliseconds.
    """
    start_ns = time.monotonic_ns()

    while (time.monotonic_ns() - start_ns) < timeout_seconds * 1_000_000_000:
        if route_present_on_r2():
            end_ns = time.monotonic_ns()
            return (end_ns - start_ns) / 1_000_000

        time.sleep(0.005)

    return None


def main():
    RESULT_FILE.parent.mkdir(parents=True, exist_ok=True)

    print("Disabling static route on r1...")
    print(run_cmd(["docker", "exec", "r1", "birdc", "disable", "static_routes"]).strip())

    print("Waiting until r2 withdraws the route...")
    if not wait_until_route_absent():
        print("ERROR: r2 still has the route after timeout.")
        return

    time.sleep(0.2)

    print("Enabling static route on r1...")
    print(run_cmd(["docker", "exec", "r1", "birdc", "enable", "static_routes"]).strip())

    print("Waiting until r2 learns the route again...")
    convergence_ms = wait_until_route_present()

    if convergence_ms is None:
        print("ERROR: r2 did not learn the route within timeout.")
        return

    print(f"Convergence time: {convergence_ms:.3f} ms")

    with RESULT_FILE.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["transport", "prefix", "convergence_ms"])
        writer.writerow(["tcp", PREFIX, f"{convergence_ms:.3f}"])

    print(f"Saved result to {RESULT_FILE}")


if __name__ == "__main__":
    main()
