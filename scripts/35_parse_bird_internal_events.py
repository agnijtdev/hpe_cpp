#!/usr/bin/env python3

import sys
import re
import csv
from pathlib import Path
from datetime import datetime, timezone

def read_meta(run_dir: Path):
    meta = {}
    meta_file = run_dir / "metadata.env"

    if not meta_file.exists():
        raise FileNotFoundError(f"metadata.env not found in {run_dir}")

    for line in meta_file.read_text(errors="ignore").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            meta[k.strip()] = v.strip()

    return meta

def parse_bird_time_to_epoch_ms(ts_text: str):
    """
    BIRD log timestamp example:
    2026-06-24 18:56:10.413

    In this Docker lab, container time is effectively UTC for these logs.
    """
    dt = datetime.strptime(ts_text, "%Y-%m-%d %H:%M:%S.%f")
    dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)

def first_event(entries, pattern):
    regex = re.compile(pattern, re.IGNORECASE)
    for e in entries:
        if regex.search(e["message"]):
            return e
    return None

def parse_run(run_dir: Path):
    meta = read_meta(run_dir)

    t0 = int(meta["t0_ms"])
    test_name = meta.get("test_name", "unknown")
    timestamp = meta.get("timestamp", run_dir.name)

    log_file = run_dir / "bird_event_debug.log"

    if not log_file.exists():
        raise FileNotFoundError(f"bird_event_debug.log not found in {run_dir}")

    entries = []

    # Example line:
    # 1782327371329|2026-06-24 18:56:10.413 <WARN> Netlink: Network is down
    line_re = re.compile(
        r"^\d+\|"
        r"(?P<bird_ts>\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3})\s+"
        r"<(?P<level>[^>]+)>\s+"
        r"(?P<message>.*)$"
    )

    for line in log_file.read_text(errors="ignore").splitlines():
        m = line_re.match(line)
        if not m:
            continue

        bird_ts_text = m.group("bird_ts")
        bird_ms = parse_bird_time_to_epoch_ms(bird_ts_text)
        rel_ms = bird_ms - t0

        # Keep only events around/after failure.
        # A small negative window is useful because clocks/sample start can be close.
        if rel_ms < -1000:
            continue

        entries.append({
            "bird_ms": bird_ms,
            "rel_ms": rel_ms,
            "bird_ts": bird_ts_text,
            "level": m.group("level"),
            "message": m.group("message"),
            "raw": line,
        })

    # Only events after T0 for actual convergence timeline.
    after = [e for e in entries if e["rel_ms"] >= 0]

    event_defs = [
        ("bird_netlink_down_ms", r"Netlink: Network is down"),
        ("bird_interface_down_ms", r"Interface .* changed state .* Down|interface .* goes down"),
        ("bird_neighbor_down_ms", r"Neighbor .* changed state .* Down|Neighbor .* removed"),
        ("bird_router_state_update_ms", r"Updating router state"),
        ("bird_lsa_originated_ms", r"Originating LSA"),
        ("bird_spf_scheduled_ms", r"Scheduling routing table calculation"),
        ("bird_spf_started_ms", r"Starting routing table calculation"),
        ("bird_routes_updated_ms", r"routes? updated|routing table updated|installing route"),
    ]

    result = {
        "timestamp": timestamp,
        "test_name": test_name,
        "run_dir": str(run_dir),
        "t0_ms": str(t0),
        "bird_events_after_t0": str(len(after)),
    }

    evidence = {}

    for key, pattern in event_defs:
        ev = first_event(after, pattern)
        if ev:
            result[key] = str(ev["rel_ms"])
            evidence[key + "_line"] = ev["raw"]
        else:
            result[key] = "NA"
            evidence[key + "_line"] = "NA"

    return result, evidence, after

def print_single_run(result, evidence):
    print("=" * 90)
    print("BIRD INTERNAL EVENT TIMELINE")
    print("=" * 90)
    print(f"Run directory: {result['run_dir']}")
    print(f"Test name: {result['test_name']}")
    print(f"T0 ms: {result['t0_ms']}")
    print()
    print("BIRD internal events relative to T0:")
    print("-" * 90)

    keys = [
        "bird_netlink_down_ms",
        "bird_interface_down_ms",
        "bird_neighbor_down_ms",
        "bird_router_state_update_ms",
        "bird_lsa_originated_ms",
        "bird_spf_scheduled_ms",
        "bird_spf_started_ms",
        "bird_routes_updated_ms",
    ]

    for key in keys:
        print(f"{key:35} {result[key]:>10} ms")

    print()
    print("Evidence lines:")
    print("-" * 90)

    for key in keys:
        line = evidence.get(key + "_line", "NA")
        print(f"{key}:")
        print(line[:500])
        print()

    print("=" * 90)

def parse_all_runs():
    base = Path("measurement/runs")
    run_dirs = sorted(base.glob("*ospf_core_failure_gold_timeline"))

    rows = []
    for rd in run_dirs:
        try:
            result, evidence, after = parse_run(rd)
            rows.append(result)
        except Exception as e:
            print(f"[WARN] Skipping {rd}: {e}", file=sys.stderr)

    if not rows:
        print("No valid runs found.")
        return

    out = Path("measurement/summaries/bird_internal_events_summary.csv")
    out.parent.mkdir(parents=True, exist_ok=True)

    fieldnames = list(rows[0].keys())

    with out.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {out}")
    print(f"Runs parsed: {len(rows)}")
    print()
    print("Latest rows:")
    print("-" * 90)

    for r in rows[-10:]:
        print(
            f"{r['timestamp']}, "
            f"netlink={r['bird_netlink_down_ms']} ms, "
            f"iface_down={r['bird_interface_down_ms']} ms, "
            f"neighbor_down={r['bird_neighbor_down_ms']} ms, "
            f"spf_start={r['bird_spf_started_ms']} ms"
        )

def main():
    if len(sys.argv) == 2:
        run_dir = Path(sys.argv[1])
        result, evidence, after = parse_run(run_dir)
        print_single_run(result, evidence)
    else:
        parse_all_runs()

if __name__ == "__main__":
    main()
