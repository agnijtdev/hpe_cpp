#!/usr/bin/env python3
"""
=============================================================================
healthcheck.py  (v2 - uses BGP session restart to force reliable withdraw)
=============================================================================
"""

import argparse
import socket
import subprocess
import sys
import time
import datetime


def log(msg: str) -> None:
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] [healthcheck] {msg}", flush=True)


def dns_is_alive(dns_ip: str, timeout: float = 2.0) -> bool:
    header = bytes.fromhex("1234010000010000000000000000")
    # minimal query for service.bgpost.lab A IN
    qname = b""
    for label in "service.bgpost.lab".split("."):
        qname += bytes([len(label)]) + label.encode("ascii")
    qname += b"\x00"
    query = header + qname + bytes.fromhex("00010001")
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(timeout)
        sock.sendto(query, (dns_ip, 53))
        data, _ = sock.recvfrom(512)
        sock.close()
        return len(data) > 0
    except (socket.timeout, OSError):
        return False


def birdc(command: str) -> str:
    try:
        result = subprocess.run(
            ["birdc", command],
            capture_output=True, text=True, timeout=5)
        return result.stdout.strip()
    except Exception as e:
        return f"ERROR: {e}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--replica-name", required=True)
    parser.add_argument("--dns-ip", required=True)
    parser.add_argument("--protocol-name", required=True)
    parser.add_argument("--check-interval", type=float, default=2.0)
    args = parser.parse_args()

    currently_advertised = True
    log(f"Starting healthcheck for {args.replica_name}, "
        f"probing DNS at {args.dns_ip}, interval={args.check_interval}s")

    while True:
        alive = dns_is_alive(args.dns_ip)

        if alive and not currently_advertised:
            log("DNS RECOVERED — enabling route and restarting BGP session...")
            birdc(f"enable {args.protocol_name}")
            time.sleep(1)
            # Restart BGP so provider gets a fresh UPDATE with the route
            birdc("restart provider")
            currently_advertised = True
            log("BGP session restarted — route re-advertised.")

        elif not alive and currently_advertised:
            log("DNS DOWN — disabling route and restarting BGP session...")
            birdc(f"disable {args.protocol_name}")
            time.sleep(1)
            # Restart BGP so provider gets a clean session with NO route
            # (since anycast_route is now disabled, re-established session
            # will advertise nothing, causing provider to withdraw the prefix)
            birdc("restart provider")
            currently_advertised = False
            log("BGP session restarted — route withdrawn.")

        else:
            state = "UP / advertised" if alive else "DOWN / withdrawn"
            log(f"DNS check: {state} (no state change)")

        time.sleep(args.check_interval)


if __name__ == "__main__":
    sys.exit(main())