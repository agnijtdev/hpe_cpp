import subprocess
import time
import csv
import sys
import threading
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
        still_present = []

        for router in routers:
            if route_present(router):
                still_present.append(router)

        if not still_present:
            return True

        time.sleep(0.05)

    print("ERROR: Some routers still have the route:")
    for router in routers:
        if route_present(router):
            print(f"  {router}")

    return False


def poll_router(router, hop, start_event, stop_event, start_ns_holder, results, lock, timeout_seconds):
    start_event.wait()

    deadline = time.monotonic() + timeout_seconds

    while time.monotonic() < deadline and not stop_event.is_set():
        if route_present(router):
            elapsed_ms = (time.monotonic_ns() - start_ns_holder["value"]) / 1_000_000

            with lock:
                if router not in results:
                    results[router] = {
                        "hop": hop,
                        "convergence_ms": elapsed_ms
                    }

            return

        time.sleep(0.005)


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 scripts/measure_hop_timeline_tcp.py <number_of_routers>")
        print("Example: python3 scripts/measure_hop_timeline_tcp.py 10")
        sys.exit(1)

    router_count = int(sys.argv[1])

    if router_count < 2:
        print("ERROR: number_of_routers must be at least 2")
        sys.exit(1)

    routers = [f"r{i}" for i in range(2, router_count + 1)]
    result_file = Path(f"results/hop_timeline_tcp_{router_count}_routers.csv")

    print(f"Measuring hop-by-hop TCP propagation from r1 to r{router_count}")
    print(f"Prefix: {PREFIX}")
    print(f"Routers being observed: {', '.join(routers)}")

    print("\nDisabling static route on r1...")
    run_cmd(["docker", "exec", "r1", "birdc", "disable", "static_routes"])

    print("Waiting until all observed routers withdraw the route...")
    if not wait_until_all_absent(routers):
        sys.exit(1)

    time.sleep(0.3)

    results = {}
    lock = threading.Lock()
    start_event = threading.Event()
    stop_event = threading.Event()
    start_ns_holder = {"value": None}
    threads = []

    print("\nStarting polling threads...")

    for hop, router in enumerate(routers, start=1):
        thread = threading.Thread(
            target=poll_router,
            args=(router, hop, start_event, stop_event, start_ns_holder, results, lock, 20)
        )
        thread.start()
        threads.append(thread)

    print("Enabling static route on r1 and starting timer...")

    start_ns_holder["value"] = time.monotonic_ns()
    start_event.set()

    run_cmd(["docker", "exec", "r1", "birdc", "enable", "static_routes"])

    deadline = time.monotonic() + 20

    while time.monotonic() < deadline:
        with lock:
            if len(results) == len(routers):
                break

        time.sleep(0.05)

    stop_event.set()

    for thread in threads:
        thread.join()

    result_file.parent.mkdir(parents=True, exist_ok=True)

    with result_file.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["transport", "router_count", "router", "hop", "prefix", "first_seen_ms"])

        for hop, router in enumerate(routers, start=1):
            if router in results:
                writer.writerow([
                    "tcp",
                    router_count,
                    router,
                    hop,
                    PREFIX,
                    f"{results[router]['convergence_ms']:.3f}"
                ])
            else:
                writer.writerow([
                    "tcp",
                    router_count,
                    router,
                    hop,
                    PREFIX,
                    "timeout"
                ])

    print("\n========== Hop-by-hop timeline ==========")
    print("Router   Hop   First seen time")
    print("----------------------------------------")

    for hop, router in enumerate(routers, start=1):
        if router in results:
            print(f"{router:<8} {hop:<5} {results[router]['convergence_ms']:.3f} ms")
        else:
            print(f"{router:<8} {hop:<5} timeout")

    print(f"\nSaved results to {result_file}")


if __name__ == "__main__":
    main()
