import csv
import statistics
import subprocess
import sys
import time
from pathlib import Path


SOCKET = "/run/bird.ctl"
PREFIX = "100.100.1.0/24"


def run_cmd(cmd):
    return subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def birdc(router, command):
    return run_cmd([
        "docker", "exec", router,
        "/usr/sbin/birdc", "-s", SOCKET,
        *command.split()
    ])


def route_exists(router):
    result = birdc(router, f"show route {PREFIX}")
    return PREFIX in result.stdout


def wait_until_route_state(router, expected_exists, timeout=10.0):
    start = time.perf_counter()

    while time.perf_counter() - start < timeout:
        exists = route_exists(router)

        if exists == expected_exists:
            return True

        time.sleep(0.01)

    return False


def main():
    if len(sys.argv) != 3:
        print("Usage: python3 scripts/measure_line_tls.py <number_of_routers> <trials>")
        print("Example: python3 scripts/measure_line_tls.py 10 10")
        sys.exit(1)

    n = int(sys.argv[1])
    trials = int(sys.argv[2])

    source_router = "r1"
    target_router = f"r{n}"

    output_dir = Path("results")
    output_dir.mkdir(exist_ok=True)

    output_file = output_dir / f"line_tls_{n}_routers.csv"

    print(f"Measuring TLS BGP convergence from {source_router} to {target_router}")
    print(f"Prefix: {PREFIX}")
    print(f"Trials: {trials}")
    print(f"Output: {output_file}")
    print()

    if not route_exists(target_router):
        print(f"ERROR: {target_router} does not currently have {PREFIX}")
        print("Run ./scripts/start_tls_line_lab.sh 10 first.")
        sys.exit(1)

    measurements = []

    with output_file.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([
            "trial",
            "transport",
            "routers",
            "source_router",
            "target_router",
            "prefix",
            "convergence_ms",
        ])

        for trial in range(1, trials + 1):
            print(f"Trial {trial}/{trials}")

            birdc(source_router, "disable static_routes")

            withdrawn = wait_until_route_state(target_router, expected_exists=False, timeout=10.0)
            if not withdrawn:
                print(f"  ERROR: route was not withdrawn from {target_router}")
                continue

            start = time.perf_counter()

            birdc(source_router, "enable static_routes")

            reappeared = wait_until_route_state(target_router, expected_exists=True, timeout=10.0)
            end = time.perf_counter()

            if not reappeared:
                print(f"  ERROR: route did not reappear on {target_router}")
                continue

            convergence_ms = (end - start) * 1000
            measurements.append(convergence_ms)

            writer.writerow([
                trial,
                "tls",
                n,
                source_router,
                target_router,
                PREFIX,
                f"{convergence_ms:.3f}",
            ])

            print(f"  Convergence time: {convergence_ms:.3f} ms")

            time.sleep(1)

    if not measurements:
        print("No successful measurements.")
        sys.exit(1)

    print()
    print("Summary:")
    print(f"  Successful trials: {len(measurements)}")
    print(f"  Average: {statistics.mean(measurements):.3f} ms")
    print(f"  Median:  {statistics.median(measurements):.3f} ms")
    print(f"  Min:     {min(measurements):.3f} ms")
    print(f"  Max:     {max(measurements):.3f} ms")


if __name__ == "__main__":
    main()
