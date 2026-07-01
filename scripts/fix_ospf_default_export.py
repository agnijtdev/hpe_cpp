#!/usr/bin/env python3

from pathlib import Path
import subprocess
import shutil
from datetime import datetime
import re
import sys

routers = {
    "hpe-r1": "10.0.19.3",
    "hpe-r2": "10.0.29.3",
}

ospf_ipv4_block = """    ipv4 {
        import all;

        # Export only the default route into OSPF.
        # This makes r1/r2 act as WAN exit routers for the OSPF domain.
        export filter {
            if net = 0.0.0.0/0 then {
                ospf_metric2 = 10;
                accept;
            }
            reject;
        };
    };

"""

def run(cmd, check=True):
    result = subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT
    )
    if check and result.returncode != 0:
        print(f"Command failed: {' '.join(cmd)}")
        print(result.stdout)
        sys.exit(1)
    return result.stdout

def ensure_ospf_export(text):
    lines = text.splitlines()

    start = None
    for i, line in enumerate(lines):
        if re.match(r'\s*protocol\s+ospf\s+ospf1\s*\{', line):
            start = i
            break

    if start is None:
        raise RuntimeError("Could not find protocol ospf ospf1 block")

    # Find the first area line inside the OSPF block.
    first_area = None
    for i in range(start + 1, len(lines)):
        if re.match(r'\s*area\s+', lines[i]):
            first_area = i
            break

    if first_area is None:
        raise RuntimeError("Could not find first OSPF area line")

    # Remove any existing ipv4 channel before the first area line.
    cleaned_prefix = []
    i = start + 1

    while i < first_area:
        line = lines[i]

        if re.match(r'\s*ipv4\s*\{', line):
            brace_count = line.count("{") - line.count("}")
            i += 1

            while i < first_area and brace_count > 0:
                brace_count += lines[i].count("{") - lines[i].count("}")
                i += 1

            # Skip old ipv4 block.
            continue

        cleaned_prefix.append(line)
        i += 1

    new_lines = (
        lines[:start + 1]
        + ospf_ipv4_block.rstrip("\n").splitlines()
        + cleaned_prefix
        + lines[first_area:]
    )

    return "\n".join(new_lines) + "\n"

timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
backup_dir = Path(f"configs/tuned_backup_before_ospf_default_export_fix_{timestamp}")
backup_dir.mkdir(parents=True, exist_ok=True)

print("Fixing OSPF default-route export on hpe-r1 and hpe-r2...")
print()

for router, isp_next_hop in routers.items():
    print(f"===== {router} =====")

    tuned_path = Path("configs/tuned") / router / "bird.conf"
    tuned_path.parent.mkdir(parents=True, exist_ok=True)

    # Pull currently running config, because it already has corrected interface names.
    run(["docker", "cp", f"{router}:/etc/bird/bird.conf", str(tuned_path)])

    backup_path = backup_dir / f"{router}.bird.conf"
    shutil.copy2(tuned_path, backup_path)

    text = tuned_path.read_text()

    # Ensure static default route exists.
    if "protocol static default_to_isp" not in text:
        text += f"""

# Static default route toward ISP/upstream.
# This route is exported into OSPF by protocol ospf ospf1.
protocol static default_to_isp {{
    ipv4;
    route 0.0.0.0/0 via {isp_next_hop};
}}
"""

    fixed = ensure_ospf_export(text)
    tuned_path.write_text(fixed)

    run(["docker", "cp", str(tuned_path), f"{router}:/tmp/bird.conf.ospfdefault"])
    validation = run(["docker", "exec", router, "bird", "-p", "-c", "/tmp/bird.conf.ospfdefault"])

    if "Configuration OK" not in validation:
        print(validation)

    run(["docker", "cp", str(tuned_path), f"{router}:/etc/bird/bird.conf"])
    run(["docker", "exec", router, "birdc", "configure"])

    print(f"Applied OSPF default export fix on {router}")
    print()

print(f"Backups saved in: {backup_dir}")
print("Done.")
